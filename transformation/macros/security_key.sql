{% macro security_key(cik) -%}
    MD5(CAST({{ cik }} AS VARCHAR))
{%- endmacro %}
