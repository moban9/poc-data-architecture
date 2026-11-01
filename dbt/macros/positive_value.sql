-- Generic test: positive_value
-- Fails on any row where the numeric column is <= 0 (must be strictly positive).
-- Used on loan.amount (see models/schema.yml).
{% test positive_value(model, column_name) %}
    select *
    from {{ model }}
    where {{ column_name }} <= 0
{% endtest %}
