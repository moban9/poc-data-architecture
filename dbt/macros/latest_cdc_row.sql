{#
  latest_cdc_row(relation, columns, id_column='id')

  Collapse a Bronze CDC changelog into one row per business key — the Silver
  boundary's contract with Bronze.

  WHY: Bronze is APPEND-ONLY. The Apache Iceberg Kafka Connect sink (1.9.2,
  pinned in scripts/fetch-iceberg-jars.sh) has no upsert mode; it appends every
  record it is fed. Two things feed it duplicates:
    * at-least-once delivery: a sink task restart replays the window since the
      last committed consumer offset, and
    * Debezium re-snapshots: a connector recreate without offsets re-emits every
      row of every captured table (snapshot.mode=initial, the 2026-11-05
      incident — see docs/09-cdc-delivery-semantics.md).
  So count(*) in Bronze is NOT the row count of the source table, and any model
  that treats Bronze as current-state will double-count. This macro is the fix:
  Silver reads the changelog collapsed to its newest version per id.

  `columns` is the EXPLICIT projection, and it matters for more than style: the
  window's top-n operator holds one row per id in memory, so passing the wide
  `_cdc` STRUCT (or `select *`) makes the query exceed Trino's per-node memory
  limit on a 6.9M-id table. Projecting only the needed columns keeps the
  repayment_schedule dedupe at ~200MB instead of >900MB (verified 2026-11-05:
  6,908,334 rows in 21s on the 14.3M-row Bronze table).

  ORDERING: "_cdc"."ts" (Debezium ts_ms, epoch millis) descending, ties broken
  by "_cdc"."offset" (Kafka offset). Both NULLS LAST explicitly so a malformed
  record can never outrank a real one. row_number() (not max()/join) is
  deliberate: an at-least-once replay writes the SAME Kafka offset twice, so
  offset is not a unique row identity and a join on it would return both copies.

  LIMITS (documented, not accidental):
    * Deletes are not represented — the sink's append writer drops tombstone
      records, so a DELETEd source row keeps its last value here.
    * The whole relation is rescanned on every dbt run (materialized='table');
      this is a batch job, not a streaming dedupe.
#}
{% macro latest_cdc_row(relation, columns, id_column='id') %}
select {{ columns }}
from (
    select
        {{ columns }},
        row_number() over (
            partition by {{ id_column }}
            order by "_cdc"."ts" desc nulls last,
                     "_cdc"."offset" desc nulls last
        ) as _cdc_row_num
    from {{ relation }}
)
where _cdc_row_num = 1
{% endmacro %}
