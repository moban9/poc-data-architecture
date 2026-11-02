# Examples

Concrete, copy-pasteable examples.

## Bring-up (one node)

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# set project_id, region=asia-southeast2, zone=asia-southeast2-a, tighten allowed_ssh_cidrs
terraform init && terraform plan && terraform apply -auto-approve
cd ..
make deploy      # rsync repo -> VM, docker compose up -d
make status      # all services healthy
```

## Verify GCP auth without deploying (read-only)

Run the `auth-test` workflow (Actions → auth-test → Run workflow). Green =
WIF auth works end-to-end, no VM, no cost.

## Run a demo scenario (control panel)

```bash
# healthy CDC flow
curl -s -X POST http://localhost:8001/scenario/healthy | jq

# dirty-data failure (watch dbt tests fail + rows quarantine)
curl -s -X POST http://localhost:8001/scenario/dirty | jq

# stream per-hop results as they happen
curl -sN -X POST 'http://localhost:8001/scenario/failure?stream=sse'
```

Expected `healthy` shape (per hop):

```json
{
  "scenario": "healthy",
  "status": "success",
  "hops": [
    {"id": "lms",   "status": "ok", "ms": 12},
    {"id": "cdc",   "status": "ok", "ms": 210},
    {"id": "kafka", "status": "ok", "ms": 45},
    {"id": "silver","status": "ok", "ms": 120},
    {"id": "gold",  "status": "ok", "ms": 90},
    {"id": "bi",    "status": "ok", "ms": 30}
  ],
  "verdict": "reached Gold in ~0.5s — queryable: YES"
}
```

## Simulate an incident (offline, no alert path)

```bash
INCIDENT_TYPE=data-quality INCIDENT_MSG="Gold freshness check failed" \
  PLANE_API_URL=http://plane:8000/api/v1 PLANE_API_KEY=... \
  PLANE_WORKSPACE=poc PLANE_PROJECT_ID=... \
  python3 scripts/incident-simulator.py
```

Output:

```
✅ incident ticket created — id <uuid>
   title: [INCIDENT] data-quality: Gold freshness check failed
   link:  http://plane:3000/poc/projects/<uuid>/issues/<uuid>
```

## Trigger an incident via the real alert path

```bash
# pause the Iceberg sink -> KafkaConnectConnectorFailed alert (2m) -> Alertmanager
# -> ticket-bridge -> Plane issue
curl -s -X PUT http://localhost:8083/connectors/iceberg-sink/pause
# ... alert fires, ticket auto-opens in Plane
```

## Cost — 1-day demo

```
e2-standard-8 (8 vCPU/32 GB)   $0.268/hr  × 24h = $6.43
100 GB pd-balanced             $4/mo            ≈ $0.13/day
                                               --------
                                               ≈ $6.60  (~2-3% of $300 credit)
```

Delete (not stop) the VM + disk after the run — disk keeps billing while stopped.
