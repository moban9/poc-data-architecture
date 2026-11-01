-- Map dbt subfolders to exact lakehouse schema names (silver, gold, lakehouse)
-- instead of dbt's default "<target_schema>_<custom_schema>" prefixing.
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
