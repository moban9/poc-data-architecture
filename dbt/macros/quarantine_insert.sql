-- Append one failing row to lakehouse.quarantine_lms (append-only, reviewed by Seal).
-- Call from a post-test hook or the Seal review workflow, e.g.:
--   {{ quarantine_row('loan', 'positive_value', 'amount must be > 0', '{"id":"L-1002","amount":-500.00}') }}
{% macro quarantine_row(source_table, failing_test, reason, payload_json) %}
    insert into lakehouse.quarantine_lms
        (quarantined_at, source_table, failing_test, reason, payload)
    values (
        current_timestamp,
        '{{ source_table }}',
        '{{ failing_test }}',
        '{{ reason }}',
        '{{ payload_json }}'
    );
{% endmacro %}
