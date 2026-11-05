#!/bin/bash
# keel t_df6a7bb7: rebuild silver/gold from the deduped Bronze changelog, then
# run the dbt test suite. --threads 1 is deliberate: the repayment_schedule
# dedupe window peaks near Trino's per-node query memory limit (921MB), so
# concurrent model queries on the single node push it over.
# Run on the POC VM host. Log: /tmp/keel-dbt.log
set -u
C="docker exec -w /dbt -e DBT_PROFILES_DIR=/dbt -e TRINO_HOST=trino lms-monitoring-dagster-1"
$C dbt run --select silver gold --threads 1
echo "RUN_RC=$?"
$C dbt test --threads 1
echo "TEST_RC=$?"
