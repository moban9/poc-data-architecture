-- JSON snapshot of a loan-shaped offending row, returned as a SQL expression
-- producing a VARCHAR holding JSON text (Iceberg has no native json type, so we
-- store the JSON as varchar). Used by the per-rule quarantine post_hooks.
-- Column shape matches models/silver/loan.sql (id, amount, currency,
-- origination_date, borrower_id).
{% macro loan_offending_row() -%}
    cast(json_object(
        'id' value id,
        'amount' value amount,
        'currency' value currency,
        'origination_date' value origination_date,
        'borrower_id' value borrower_id
    ) as varchar)
{%- endmacro %}
