"""Dagster code location — orchestration for the LMS dbt medallion pipeline.

One asset wraps the *existing* dbt entrypoint (`dbt/scripts/run-and-push-metrics.sh`,
the same script the `dbt` one-shot service runs), so:

  * Bronze seeds → Silver → Gold models and the `dbt test` DQ gate are unchanged;
  * the pushgateway metric contract (`dbt_run_success`, `dbt_test_failures`,
    `dbt_tests_total`, `quarantine_rows_total`) that Grafana reads is unchanged;
  * the pipeline body stays in one place — no second copy of dbt logic to drift.

What Dagster adds on top: run history, per-run log capture, retry/queueing, and a
schedule that replaces the 2-minute cron (`scripts/dbt-schedule.sh`) on the VM.

Env contract (set by compose/docker-compose.yml):
  DBT_PROJECT_DIR       dbt project root                (default /dbt)
  DBT_PIPELINE_SCRIPT   entrypoint, relative to the root (default scripts/run-and-push-metrics.sh)
  DAGSTER_DBT_CRON      schedule cadence                 (default */15 * * * * — see docs/09 §6.1)
"""

import os
import subprocess
import time
from datetime import datetime, timezone
from typing import List

from dagster import (
    AssetExecutionContext,
    DefaultScheduleStatus,
    Definitions,
    MaterializeResult,
    MetadataValue,
    ScheduleDefinition,
    asset,
    define_asset_job,
)

DBT_PROJECT_DIR = os.environ.get("DBT_PROJECT_DIR", "/dbt")
PIPELINE_SCRIPT = os.environ.get("DBT_PIPELINE_SCRIPT", "scripts/run-and-push-metrics.sh")
# A full silver/gold rebuild over the 6.9M-row silver and 14.3M-row bronze
# changelog cannot finish in 2 minutes; */15 (with dbt tag concurrency=1) gives
# a slow run time to drain instead of queuing ticks (kanban t_1184e3c6).
DBT_CRON = os.environ.get("DAGSTER_DBT_CRON", "*/15 * * * *")


@asset(
    name="dbt_medallion_pipeline",
    group_name="dbt",
    compute_kind="dbt",
    description=(
        "Materialises the dbt medallion pipeline against Trino (seeds if absent, "
        "silver + gold models, dbt test) and pushes dbt/quarantine metrics to the "
        "Prometheus pushgateway."
    ),
    # Consumed by dagster.yaml's tag_concurrency_limits so only one dbt run is
    # ever in flight — a slower-than-cadence run queues the next tick.
    tags={"dagster/concurrency_key": "dbt"},
)
def dbt_medallion_pipeline(context: AssetExecutionContext) -> MaterializeResult:
    script_path = os.path.join(DBT_PROJECT_DIR, PIPELINE_SCRIPT)
    if not os.path.exists(script_path):
        raise FileNotFoundError(
            f"dbt entrypoint not found: {script_path} (check the ../dbt mount and DBT_PIPELINE_SCRIPT)"
        )

    env = os.environ.copy()
    env.setdefault("DBT_PROFILES_DIR", DBT_PROJECT_DIR)

    context.log.info("running %s from %s", PIPELINE_SCRIPT, DBT_PROJECT_DIR)
    started = time.time()
    proc = subprocess.Popen(
        ["sh", PIPELINE_SCRIPT],
        cwd=DBT_PROJECT_DIR,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    tail: List[str] = []
    assert proc.stdout is not None
    for raw in proc.stdout:
        line = raw.rstrip("\n")
        context.log.info(line)
        tail.append(line)
        del tail[:-40]  # keep the last 40 lines for the failure message / metadata
    exit_code = proc.wait()
    duration = round(time.time() - started, 1)

    if exit_code != 0:
        raise RuntimeError(
            f"dbt pipeline exited {exit_code} after {duration}s; tail:\n" + "\n".join(tail[-5:])
        )

    return MaterializeResult(
        metadata={
            "exit_code": exit_code,
            "duration_seconds": duration,
            "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "script": PIPELINE_SCRIPT,
            "log_tail": MetadataValue.text("\n".join(tail)),
        }
    )


dbt_pipeline_job = define_asset_job(
    name="dbt_pipeline_job",
    selection=[dbt_medallion_pipeline],
    description="Materialise the dbt medallion pipeline (Bronze → Silver → Gold).",
    tags={"pipeline": "dbt"},
)

dbt_pipeline_schedule = ScheduleDefinition(
    name="dbt_pipeline_schedule",
    job=dbt_pipeline_job,
    cron_schedule=DBT_CRON,
    execution_timezone="UTC",
    # Live by default: this is the replacement for the VM cron, so it must not
    # need a manual "turn on" click after a stack bring-up.
    default_status=DefaultScheduleStatus.RUNNING,
)

defs = Definitions(
    assets=[dbt_medallion_pipeline],
    jobs=[dbt_pipeline_job],
    schedules=[dbt_pipeline_schedule],
)
