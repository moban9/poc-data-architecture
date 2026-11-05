# dagster/ — orchestrator for the dbt medallion pipeline

Dagster owns the scheduled dbt run in the LMS POC: it replaces the 2-minute cron
(`scripts/dbt-schedule.sh` → `docker compose run --rm dbt`) with a schedule, run
history, per-run logs, and queueing.

```
dagster/
  Dockerfile          python:3.11-slim + dagster-webserver + dagster-postgres + dbt-trino
  requirements.txt    pinned versions (bump here, rebuild the image)
  dagster.yaml        DAGSTER_HOME instance config (postgres storage, dbt concurrency cap)
  workspace.yaml      code location → /dagster/code/definitions.py
  code/definitions.py the asset + job + schedule
```

## What runs

| Object | Kind | Detail |
|---|---|---|
| `dbt_medallion_pipeline` | asset (`group=dbt`) | shells out to `dbt/scripts/run-and-push-metrics.sh` — seed if missing, `dbt run` (silver + gold), `dbt test`, pushgateway metrics |
| `dbt_pipeline_job` | asset job | selection = the asset above |
| `dbt_pipeline_schedule` | schedule, `RUNNING` by default | `DAGSTER_DBT_CRON` (default `*/15 * * * *`, UTC) |

The dbt project is mounted read-write at `/dbt` in both `dagster` and
`dagster-daemon`, so the job executes the *same* script the one-shot service and
the cron use. There is exactly one copy of the pipeline logic; Dagster only wraps
it. The pushgateway metric contract (`dbt_run_success`, `dbt_test_failures`,
`dbt_tests_total`, `quarantine_rows_total`) therefore stays intact and Grafana's
Bronze/Silver/Gold + DQ panels keep working.

## Services (compose/docker-compose.yml)

| Service | Role | Ports |
|---|---|---|
| `dagster-postgres` | Dagster instance metadata (runs, schedule ticks) | internal 5432 |
| `dagster` | webserver: UI + GraphQL | 3000 internal → **3001** host (`DAGSTER_HOST_PORT`) |
| `dagster-daemon` | ticks schedules, launches runs | none |

Host port 3001 exists because **Grafana already publishes host 3000**. The
Traefik router `dagster.<DOMAIN>` → `dagster:3000` is in place as well, but
HTTPS through the GCP LB needs `dagster` added to the managed cert's SAN list
(`terraform/gcp/network/main.tf`) — not done yet.

## Verify

```bash
cd compose
docker compose -f docker-compose.yml up -d --build dagster-postgres dagster dagster-daemon

curl -fsS http://localhost:3001/server_info                     # UI up
docker compose -f docker-compose.yml logs dagster | tail -30    # "Loaded repository lms_dbt"
docker compose -f docker-compose.yml logs dagster-daemon | tail -30

# job + schedule are registered and the schedule is running
curl -fsS http://localhost:3001/graphql -H 'Content-Type: application/json' \
  -d '{"query":"{ workspaceOrError { ... on Workspace { locationEntries { locationOrLoadError { ... on RepositoryLocation { repositories { name jobs { name } schedules { name cronSchedule scheduleState { status } } } } } } } } }"}'

# trigger one run on demand (same code path as the schedule)
curl -fsS http://localhost:3001/graphql -H 'Content-Type: application/json' \
  -d '{"query":"mutation { launchPipelineExecution(executionParams: {selector: {repositoryLocationName: \"lms_dbt\", repositoryName: \"__repository__\", jobName: \"dbt_pipeline_job\"}, runConfigData: {}, mode: \"default\"}) { __typename ... on LaunchRunSuccess { run { runId status } } ... on RunConfigValidationInvalid { errors { message } } } }"}'
```

Or click **Jobs → dbt_pipeline_job → Materialize** in the UI. A run writes
`SUCCESS` in the Runs tab and the dbt log lines are attached to the asset.

Manual CLI equivalent (inside the container):

```bash
docker compose -f docker-compose.yml exec dagster dagster asset materialize \
  -w /opt/dagster/dagster_home/workspace.yaml --select dbt_medallion_pipeline
```

## Failure modes seen / handled

- **Code server crash-loop ("No heartbeat received in 20 seconds")** → the
  daemon's in-process code server has a hard-coded 20s heartbeat TTL
  (`dagster._daemon.controller.DAEMON_GRPC_SERVER_HEARTBEAT_TTL`, not configurable).
  Under `mem_limit`/`cpus` starvation (was 1g/0.5 CPU) it can't answer the 1s
  heartbeat pings and shuts down ~every 65s, wedging runs in `STARTED`/`STARTING`.
  Fix: raise the container limits (host has headroom) and keep the schedule
  cadence above the rebuild time so the daemon is never hammered. See t_1184e3c6.
- **Schedule does not fire** → `dagster-daemon` is not running, or its storage
  cannot reach `dagster-postgres`. Schedules are ticked by the daemon only.
- **Run fails with `dbt entrypoint not found`** → the `../dbt` mount is missing
  from the service or `DBT_PIPELINE_SCRIPT` was changed.
- **Run fails with a Trino connection error** → `trino` is unhealthy; the job has
  `depends_on: trino: service_healthy` at container start, but not per run.
- **Two dbt runs at once** (e.g. cron + schedule overlapping during the
  transition) → the `dbt` tag concurrency limit in `dagster.yaml` only serialises
  Dagster runs; the cron keeps its own `/tmp/dbt-schedule.lock`. Remove the cron
  to eliminate the overlap entirely.
- **No metrics in Grafana but the run is SUCCESS** → pushgateway push failed;
  the script exits non-zero on that, so a green run means the push landed.
