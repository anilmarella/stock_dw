-- Every feature, from the registry macro. Also creates the feature functions (post_hook).
-- depends_on: {{ ref('ds_price_daily') }} {{ ref('ds_security') }}
{{ config(post_hook="{{ create_feature_functions(this.schema) }}") }}

SELECT *
FROM (VALUES
    {%- for f in feature_registry() %}
    ('{{ f.name }}', '{{ f.category }}', '{{ f.description | replace("'", "''") }}',
        '{{ f.sql | replace("'", "''") | replace("\n", " ") }}', {{ f.lookback_days }}){{ "," if not loop.last }}
    {%- endfor %}
) AS reg (feature, category, description, formula_sql, lookback_days)
