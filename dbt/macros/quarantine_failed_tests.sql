-- on-run-end hook (wired in dbt_project.yml: `on-run-end`). Reactive backstop to
-- the proactive per-rule quarantine models: after `dbt test` / `dbt build`, any
-- test that FAILED has its offending rows re-selected (from the test's compiled
-- SQL) and appended to lakehouse.quarantine_lms, traceable to its rule +
-- error_detail. The test itself still fails the run — schema.yml is the assert
-- gate that blocks downstream.
--
-- Idempotent: anti-joins on (target_table, rule, offending_row).
-- Note: offending_row here is serialized as json_format(cast(t as json)); this
-- may format differently from the per-rule models' json_object output, so the
-- two paths are keyed distinctly — the per-rule models are the primary capture
-- during `dbt run`, this hook is the backstop during `dbt test`.
{% macro quarantine_failed_tests(results) %}
    {%- for result in results -%}
        {%- if result.node.resource_type == 'test' and result.status == 'fail' -%}
            {%- set tm = result.node.test_metadata -%}
            {%- set rule = tm.name -%}
            {%- set model_name = tm.kwargs.get('model', 'unknown') -%}
            {%- set column = tm.kwargs.get('column_name') or tm.kwargs.get('field') or '' -%}
            {%- set detail = rule ~ ' failed on ' ~ model_name ~ ((' (column ' ~ column ~ ')') if column else '') -%}
            insert into lakehouse.quarantine_lms.quarantine_lms
                (quarantine_id, layer, target_table, rule, rule_type, offending_row,
                 error_detail, source, run_id, quarantined_at, _ingested_at)
            select
                uuid(),
                'silver',
                '{{ model_name }}',
                '{{ rule }}',
                '{{ rule }}',
                x.offending_row,
                '{{ detail }}',
                'batch',
                '{{ invocation_id }}',
                current_timestamp,
                current_timestamp
            from (
                select json_format(cast(t as json)) as offending_row
                from (
                    {{ result.node.compiled_code }}
                ) as t
            ) as x
            where not exists (
                select 1
                from lakehouse.quarantine_lms.quarantine_lms q
                where q.target_table = '{{ model_name }}'
                  and q.rule = '{{ rule }}'
                  and q.offending_row = x.offending_row
            );
        {%- endif -%}
    {%- endfor -%}
{% endmacro %}
