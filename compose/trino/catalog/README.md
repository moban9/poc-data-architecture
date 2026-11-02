# Trino → Polaris → MinIO (Iceberg REST)

Trino's Iceberg connector reads/writes Iceberg tables whose metadata is managed by
Apache Polaris (Iceberg REST catalog) and whose data lives in MinIO (S3-compatible).

## Files

| Path | Purpose |
|---|---|
| `trino/catalog/lakehouse.properties` | Trino catalog `lakehouse` (Iceberg + REST + native S3) |
| `../polaris/init-lakehouse.sh` | Creates the Polaris `lakehouse` catalog (via Management API) |

> **Why `lakehouse.properties`, not `iceberg.properties`:** the Trino catalog name
> is the file's basename. The dbt project (`dbt/profiles.yml.example`) and every
> model reference the catalog as `lakehouse`, so the file must be named
> `lakehouse.properties`. `connector.name` is still `iceberg`.

## Environment variables

Set these in `compose/.env` (copy from `compose/.env.example`). docker-compose.yml
injects them into the `trino`, `polaris`, `bucket-setup` and `polaris-setup`
containers.

| Var | Default | Used by |
|---|---|---|
| `POLARIS_URI` | `http://polaris:8181/api/catalog` | Trino `iceberg.rest-catalog.uri` |
| `POLARIS_WAREHOUSE` | `lakehouse` | Polaris catalog name (Trino + init script) |
| `POLARIS_REALM` | `POLARIS` | Polaris realm (bootstrap + `Polaris-Realm` header) |
| `POLARIS_CLIENT_ID` / `POLARIS_CLIENT_SECRET` | `root` / `CHANGE_ME_…` | OAuth2 client-credentials (bootstrap root principal) |
| `MINIO_ENDPOINT` | `http://minio:9000` | S3 endpoint (Trino + Polaris + bucket setup) |
| `MINIO_REGION` | `us-east-1` | S3 region (MinIO ignores it, AWS SDK wants one) |
| `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` | `minioadmin` / `CHANGE_ME_…` | static S3 creds — **must match** `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` |
| `MINIO_BUCKET` | `lakehouse` | Iceberg base-location bucket |

## How it's wired

- `lakehouse.properties` uses Trino's `${ENV:...}` substitution; the vars are
  injected into the `trino` container in `docker-compose.yml`.
- Polaris is bootstrapped with `POLARIS_BOOTSTRAP_CREDENTIALS`
  (`<realm>,<client_id>,<client_secret>`) so the realm + `root` principal exist.
- `bucket-setup` (one-shot `minio/mc`) creates the MinIO bucket; `polaris-setup`
  (one-shot `alpine/curl`) runs `init-lakehouse.sh` to create the `lakehouse`
  catalog. Trino waits on `polaris-setup` before starting.
- Trino authenticates to Polaris over OAuth2 and lets Polaris **vend** the MinIO
  credentials (`vended-credentials-enabled=true`), so no S3 keys are needed in
  Trino itself.

## Verify

```bash
cd compose && docker compose up -d
docker compose exec trino trino --execute \
  "SHOW SCHEMAS IN lakehouse"
```
