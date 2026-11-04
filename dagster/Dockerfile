# Dagster OSS (webserver + daemon) for the LMS POC dbt pipeline.
#
# Built from python:3.11-slim rather than a prebuilt Dagster image so that the
# orchestrator and the dbt CLI live in the same image: the code location shells
# out to `dbt` (dbt-trino) exactly like the `dbt` one-shot service does, so the
# job cannot diverge from what the cron used to run.
#
# Why not `dagster/dagster` / `ghcr.io/dagster-io/dagster`: neither path resolves
# to a public manifest at build time (Docker Hub `dagster/dagster` returns
# "object not found"; ghcr denies the token for that repository), and both would
# still need `dbt-trino` added. This mirrors the existing `dbt/dbt.Dockerfile`
# pattern instead. Bump the pins in requirements.txt, then rebuild:
#   docker compose -f docker-compose.yml build dagster
FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    DAGSTER_HOME=/opt/dagster/dagster_home \
    DBT_PROJECT_DIR=/dbt

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# Instance config (storage / concurrency) + code location declaration.
RUN mkdir -p /opt/dagster/dagster_home /dagster/code
COPY dagster.yaml workspace.yaml /opt/dagster/dagster_home/
COPY code/ /dagster/code/

WORKDIR /dagster/code

# No ENTRYPOINT: compose selects the role with `command`
# (`dagster-webserver` for the UI, `dagster-daemon run` for schedules).
CMD ["dagster-webserver", "-h", "0.0.0.0", "-p", "3000", "-w", "/opt/dagster/dagster_home/workspace.yaml"]
