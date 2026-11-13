{#
    Wide view of the factor library, as known on each row's own day.
    Latest factor_version per factor unless a version is pinned: {'vol_21d': 1}.
#}
{% macro factors_wide(factors, versions={}) %}
SELECT
    security_key,
    about_date,
    {%- for f in factors %}
    MAX(value) FILTER (WHERE factor = '{{ f }}') AS {{ f }}{{ "," if not loop.last }}
    {%- endfor %}
FROM (
    SELECT *
    FROM {{ ref('mart_factor_value') }}
    WHERE
        known_as_of <= about_date
        AND factor IN ({% for f in factors %}'{{ f }}'{{ ", " if not loop.last }}{% endfor %})
        {%- for f, v in versions.items() %}
        AND (factor != '{{ f }}' OR factor_version = {{ v }})
        {%- endfor %}
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY security_key, about_date, factor
        ORDER BY factor_version DESC, known_as_of DESC, computed_at DESC
    ) = 1
) AS latest
GROUP BY security_key, about_date
{% endmacro %}


{#
    DuckDB table macro for serving: the factor library as of any date.
    SELECT * FROM marts.factor_values_as_of(DATE '2021-03-01')
    SELECT * FROM marts.factor_values_as_of(DATE '2021-03-01', computed_by := TIMESTAMPTZ '2026-12-01')
#}
{% macro create_factor_table_macros(relation) %}
CREATE OR REPLACE MACRO {{ relation.schema }}.factor_values_as_of(
    as_of, computed_by := TIMESTAMPTZ '9999-12-31'
) AS TABLE
SELECT *
FROM {{ relation }}
WHERE about_date <= as_of AND known_as_of <= as_of AND computed_at <= computed_by
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY security_key, about_date, factor, factor_version
    ORDER BY known_as_of DESC, computed_at DESC
) = 1
{% endmacro %}
