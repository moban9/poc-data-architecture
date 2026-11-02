-- Append offending rows for ONE data-quality rule to lakehouse.quarantine_lms.
-- Append-only, reviewed by Seal. Idempotent: anti-joins against rows already
-- quarantined for the same (target_table, rule, offending_row), so re-running a
-- job does not duplicate records.
--
-- Callers:
--   1. Per-rule quarantine models — post_hook (models/silver/quarantine/*.sql),
--      which run BEFORE the clean Silver models and isolate bad rows first.
--   2. The on-run-end test hook (see quarantine_failed_tests) — reactive backstop.
--
-- Args:
--   layer               'bronze' | 'silver' | 'gold'
--   target_table        model the offending row belongs to (e.g. 'loan')
--   rule                rule id (e.g. 'positive_value__amount')
--   rule_type           rule family (not_null|unique|relationships|accepted_values|positive_value|valid_date)
--   error_detail        human-readable reason the row is quarantined
--   source              'batch' | 'cdc'
--   offending_row_expr  SQL expression producing the JSON snapshot of the offending row
--   from_relation       relation to read the offending rows from (use {{ this }} in a post_hook)
--   quarantine_relation relation of the quarantine table (pass ref('quarantine'))
{% macro quarantine_insert(layer, target_table, rule, rule_type, error_detail, source, offending_row_expr, from_relation, quarantine_relation) %}
    insert into {{ quarantine_relation }}
        (quarantine_id, layer, target_table, rule, rule_type, offending_row,
         error_detail, source, run_id, quarantined_at, _ingested_at)
    select
        uuid(),
        '{{ layer }}',
        '{{ target_table }}',
        '{{ rule }}',
        '{{ rule_type }}',
        {{ offending_row_expr }},
        '{{ error_detail }}',
        '{{ source }}',
        '{{ invocation_id }}',
        current_timestamp,
        current_timestamp
    from {{ from_relation }} as __src
    where not exists (
        select 1
        from {{ quarantine_relation }} q
        where q.target_table = '{{ target_table }}'
          and q.rule = '{{ rule }}'
          and q.offending_row = {{ offending_row_expr }}
    );
{% endmacro %}
