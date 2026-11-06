# 08 — Metabase → Trino authentication (the `presto-jdbc` / `X-Presto-User` gap)

Status: **staged, not applied.** The change set below is in the repo and inert;
applying it needs one operator command (or a worker with a shell). Produced by
Keel; reviewed by nobody yet.

## 1. Symptom

Every card in the "LMS POC — Business Performance (Gold)" dashboard errors even
though Metabase shows the `Lakehouse` connection as saved. Direct probing of the
coordinator gives:

| Request | Trino 484 answer |
|---|---|
| `X-Trino-User: admin` | `200` |
| `X-Presto-User: admin` | `401` |
| no user header | `401` |

Metabase v0.65 ships exactly one Trino engine — `presto-jdbc`
(`io.prestosql.jdbc.PrestoDriver`) — and that driver sends `X-Presto-User`.
Metabase rejects the engine names `trino`, `presto` and `trino-jdbc`, so there
is no client-side switch to flip.

## 2. Why the "turn on Trino password auth" plan does not work

Two independent walls, either one is fatal:

1. **Client side.** The Presto JDBC family refuses a password unless the
   connection is TLS:

   ```
   java.sql.SQLException: Authentication using username/password requires
   SSL to be enabled
     at io.prestosql.jdbc.PrestoDriverUri.setupClient(PrestoDriverUri.java:160)
   ```

   `useSecureConnection` is true only when `SSL=true` or the port is 443, so
   passing `password=admin` with `ssl=false` (the state the provisioner was
   patched into) makes *every* query fail before a single byte reaches Trino.

2. **Server side.** Trino 484's docs for `http-server.authentication.type` say
   all authentication "requires secure connections using TLS and HTTPS or
   process forwarding enabled, **and a configured shared secret**". Setting
   `http-server.authentication.allow-insecure-over-http=true` alone does nothing
   useful: it defaults to `false` once an authenticator is active and must be
   overridden together with `internal-communication.shared-secret`. Also, Trino
   file passwords must be **bcrypt** hashes (`htpasswd -B -C 10`), so a
   literal `admin:admin` password.db fails with
   `Error in password file line 1: Password hashing algorithm cannot be
   determined`.

Making password auth work therefore means: Trino TLS (self-signed), a
truststore uploaded into Metabase, a bcrypt password file, a shared secret,
**and** re-authenticating every other Trino client (dbt, Dagster, the Trino
healthcheck, the demo panel). That is a stack-wide change to unblock one
connection — the wrong trade.

See §7 if that is nevertheless what is wanted.

## 3. The fix that is staged

A 1-worker nginx gateway in front of Trino that translates the header. Trino
itself is untouched, so nothing that works today changes.

```
Metabase ──X-Presto-User: admin──▶ trino-metabase-gw (nginx) ──X-Trino-User: admin──▶ trino:8080
dbt / Dagster ──────────────────X-Trino-User: meridian──────────────────────────────▶ trino:8080
```

Files:

| File | What it is |
|---|---|
| `compose/trino-metabase-gw/nginx.conf` | `map $http_x_presto_user → X-Trino-User`, streaming proxy (buffering off), `Host` preserved so Trino's `nextUri` still points back through the gateway |
| `compose/docker-compose.metabase-trino-gw.yml` | **Separate** additive override: one `nginx:1.27-alpine` service, no host port, `mem_limit: 64m`, healthcheck through the gateway |
| `bi/metabase/dashboard/provision_metabase.py` | connection details now `host=trino-metabase-gw, port=8080, user=admin, ssl=off, **no password**`, catalog `lakehouse`, schema `gold`; `--create-db` also **refreshes** an existing `Lakehouse` row (a stale row pointing at `trino` is itself a failure mode) |

A separate override file is deliberate: `docker compose up -d` in `compose/`
keeps behaving exactly as it does today until someone applies this on purpose.

## 4. Apply

The repo is developed here (`/opt/data/poc-iac`) and deployed to the POC VM
(`/home/ubuntu/poc`) with `make deploy`, which rsyncs and runs compose. The
gateway is already wired into both deploy paths — `Makefile`'s `deploy` target
and `scripts/poc-stack.service` (the reboot path) now pass the 4th `-f` — so
after approval the deploy is:

```bash
cd /opt/data/poc-iac
make deploy          # rsync + compose up, gateway included
```

Applying on an already-deployed VM without a full deploy:

```bash
ssh ubuntu@<vm-ip>
cd /home/ubuntu/poc/compose

# 1. start the gateway (Trino must already be healthy; it is not restarted)
docker compose -f docker-compose.yml -f monitoring.yml -f traefik.yml \
               -f docker-compose.metabase-trino-gw.yml up -d trino-metabase-gw metabase

# 2. prove the translation works *inside* the compose network, no Metabase involved
docker compose -f docker-compose.yml -f docker-compose.metabase-trino-gw.yml \
  exec trino-metabase-gw wget -qO- --header='X-Presto-User: admin' \
  http://localhost:8080/v1/info          # -> {"nodeVersion":{...}}   (200)
docker compose -f docker-compose.yml -f docker-compose.metabase-trino-gw.yml \
  exec trino-metabase-gw wget -qO- \
  http://localhost:8080/v1/info          # -> 200, user defaults to `metabase`

# 3. (optional, still no Metabase) a real query through the gateway
docker compose -f docker-compose.yml -f docker-compose.metabase-trino-gw.yml \
  exec trino-metabase-gw wget -qO- --header='X-Presto-User: admin' \
  --header='Content-Type: text/plain' \
  --post-data='SELECT count(*) FROM lakehouse.gold.loan_portfolio_summary' \
  http://localhost:8080/v1/statement
```

## 5. Acceptance (the task's own command)

Run **on the VM** (or over the tunnel), because it talks to the published
Metabase port `8085`:

```bash
cd /home/ubuntu/poc/bi/metabase/dashboard     # or bi/metabase/dashboard from the repo root
METABASE_USER='randy.joeandy@gmail.com' METABASE_PASSWORD='metabase89' \
  python3 provision_metabase.py --base-url http://localhost:8085 --create-db
```

Expected: `[db] refreshed connection details …`, 35 `[card] created/updated`
lines, a `[dash] layout applied (35 cards)` line, and every card `PASS` with a
row count — exit code `0`. Exit `2` means a card returned zero rows (stale gold
mart, not an auth problem); exit `1` with a `401` means the gateway is not being
used (check the connection's host really is `trino-metabase-gw`).

Also confirm the pipeline is untouched:

```bash
cd /opt/data/poc-iac/dbt && dbt debug --target dev      # or the Dagster run
docker compose -f compose/docker-compose.yml ps trino dagster
```

`dbt/profiles.yml` stays `method: none` — it keeps sending `X-Trino-User`,
which Trino accepts exactly as before.

## 6. Cost, risk, rollback

- **Cost**: one container, `nginx:1.27-alpine` (~50 MB image, already-pulled
  class), `mem_limit: 64m`, `cpus: 0.25`. No new disk volume, no new host port,
  no new cloud resource. **$0** — it replaces no existing capacity and fits well
  inside the 16 GB / 8 vCPU node budget.
- **Risk (low)**: +1 network hop for Metabase queries only. The two real
  hazards are handled explicitly — response buffering would break Trino's
  chunked `nextUri` polling (disabled), and rewriting `Host` would send the
  client around the gateway mid-query (preserved). Worst case if nginx is
  misconfigured: Metabase cards fail, everything else unaffected.
- **Rollback**: `docker compose -f docker-compose.yml -f docker-compose.metabase-trino-gw.yml rm -sf trino-metabase-gw`,
  then `PUT /api/database/<id>` (or re-run the provisioner with the old host) to
  point the connection back at `trino`. No data is touched, no volume removed.
  `git checkout` reverts the two new files and the provisioner hunk.

## 7. Alternative, if password auth is mandatory

Do it through TLS, not HTTP — anything else is refused by the driver:

```
# compose/trino/config.properties (new mount)
coordinator=true
node-scheduler.include-coordinator=true
http-server.http.port=8080
http-server.https.enabled=true
http-server.https.port=8443
http-server.https.keystore.path=/etc/trino/certs/trino.pem   # self-signed
http-server.authentication.type=PASSWORD
internal-communication.shared-secret=<random>
# etc/password-authenticator.properties
password-authenticator.name=file
file.password-file=/etc/trino/auth/password.db               # htpasswd -B -C 10 admin
```

Consequences to budget for before applying: Metabase needs `ssl=true` plus a
truststore (`SSLTrustStorePath`) uploaded through the API; `dbt/profiles.yml`
must move to `method: ldap` + `http_scheme: https` + `session_properties`
(dbt-trino over HTTP+LDAP is a known rough edge, starburstdata/dbt-trino#384);
the Trino healthcheck and the demo panel must send credentials; the public
`trino.<DOMAIN>` SAN mismatch already observed stays a problem. Blast radius is
the whole stack, so this needs Atlas sign-off, not just an infra patch.

---

Produced by: Keel · Reviewed by: — (pending)
