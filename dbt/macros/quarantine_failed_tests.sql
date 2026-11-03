-- on-run-end hook (wired in dbt_project.yml: `on-run-end`). Reactive backstop to
-- the proactive per-rule quarantine models: after `dbt test` / `dbt build`, any
-- test that FAILED has its offending rows re-selected (from the test's compiled
-- SQL) and appended to lakehouse.quarantine_lms, traceable to its rule +
-- error_detail. The test itself still fails the run — schema.yml is the assert
-- gate that blocks downstream.
--
-- Trino has no generic whole-row -> JSON cast, so offending_row is a JSON
-- marker identifying the (rule, model) that failed rather than a per-column
-- snapshot (the proactive per-rule models already capture per-column JSON via
-- json_object). Idempotent: anti-joins on (target_table, rule, offending_row),
-- so re-runs do not duplicate already-quarantined rows.
{% macro quarantine_failed_tests(results) %}
    {%- for result in results -%}
        {%- if result.node.resource_type == 'test' and result.status == 'fail' -%}
            {%- set tm = result.node.test_metadata -%}
            {%- set rule = tm.name -%}
            {# tm.kwargs.model is the compiled Jinja ref expression
               (e.g. "{{ get_where_subquery(ref('dirty_data')) }}"), not the
               model name — extract the model name from the ref() call. #}
            {%- set model_ref = tm.kwargs.get('model', '') | string -%}
            {%- set m = modules.re.search("ref\\(['\"]([^'\"]+)['\"]\\)", model_ref) -%}
            {%- set model_name = m.group(1) if m else 'unknown' -%}
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
                cast(json_object(
                    'rule' value '{{ rule }}',
                    'model' value '{{ model_name }}'
                ) as varchar),
                '{{ detail }}',
                'batch',
                '{{ invocation_id }}',
                current_timestamp,
                current_timestamp
            from (
                {{ result.node.compiled_code }}
            ) as t
            where not exists (
                select 1
                from lakehouse.quarantine_lms.quarantine_lms q
                where q.target_table = '{{ model_name }}'
                  and q.rule = '{{ rule }}'
                  and q.offending_row = cast(json_object(
                        'rule' value '{{ rule }}',
                        'model' value '{{ model_name }}'
                    ) as varchar)
            );
        {%- endif -%}
    {%- endfor -%}
{% endmacro %}
