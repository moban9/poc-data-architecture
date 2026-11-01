-- Generic test: valid_date
-- Fails on any non-null value that is not an ISO-8601 date (YYYY-MM-DD).
-- Works on VARCHAR date strings (and DATE/TIMESTAMP columns via cast).
-- Used on seeds/dirty_data.origination_date (see seeds/properties.yml).
{% test valid_date(model, column_name) %}
    select *
    from {{ model }}
    where {{ column_name }} is not null
      and not regexp_like(cast({{ column_name }} as varchar), '^\d{4}-\d{2}-\d{2}$')
{% endtest %}
