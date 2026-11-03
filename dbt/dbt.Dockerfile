# Pre-built dbt image so the scheduled re-run is fast (no `pip install dbt-trino`
# on every cycle). Rebuild when dbt-trino is bumped:
#   docker compose -f docker-compose.yml build dbt
FROM python:3.11-slim

RUN pip install --no-cache-dir dbt-trino

WORKDIR /dbt
ENTRYPOINT ["/bin/sh", "-c"]
