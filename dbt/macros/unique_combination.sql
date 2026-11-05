-- Generic test: unique_combination
-- Fails on any row that duplicates across the combination of columns (a composite
-- grain key). Used on gold.loan_event_daily to assert the (event_date, currency)
-- grain is unique — a daily rollup must never emit two rows for the same day +
-- currency, which would double-count money.
--
-- Usage (schema.yml, model-level):
--   tests:
--     - unique_combination:
--         combination: [event_date, currency]
{% test unique_combination(model, combination) %}
    select
        {{ combination | join(', ') }}
    from {{ model }}
    group by {{ combination | join(', ') }}
    having count(*) > 1
{% endtest %}
