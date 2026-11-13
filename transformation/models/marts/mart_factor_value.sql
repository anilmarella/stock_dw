-- The factor library. Append-only: rows are never updated or deleted.
-- Each run appends values for new days and values whose inputs changed (new filing, price correction, formula fix).
{{ config(
    materialized='incremental',
    incremental_strategy='append',
    full_refresh=false,
    post_hook="{{ create_factor_table_macros(this) }}"
) }}

{% if is_incremental() %}
    {% set since = "(SELECT MAX(known_as_of) - INTERVAL 10 DAY FROM " ~ this ~ ")" %}
{% else %}
    {% set since = "DATE '1900-01-01'" %}
{% endif %}

WITH price_rows AS (
    {{ price_factors(since) }}
),

fundamental_rows AS (
    {{ fundamental_factors(since) }}
),

candidates AS (
    SELECT * FROM price_rows
    UNION ALL BY NAME
    SELECT * FROM fundamental_rows
)

{% if is_incremental() %}
    ,

    stored AS (
        SELECT
            security_key,
            about_date,
            factor,
            factor_version,
            known_as_of,
            value
        FROM {{ this }}
        WHERE about_date >= {{ since }} - INTERVAL 3 YEAR
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY security_key, about_date, factor, factor_version, known_as_of
            ORDER BY computed_at DESC
        ) = 1
    )

    SELECT
        cnd.security_key,
        cnd.about_date,
        cnd.factor,
        cnd.factor_version,
        cnd.value,
        cnd.known_as_of,
        CAST('{{ run_started_at }}' AS TIMESTAMPTZ) AS computed_at
    FROM candidates AS cnd
    ASOF LEFT JOIN stored AS sto
        ON
            cnd.security_key = sto.security_key
            AND cnd.about_date = sto.about_date
            AND cnd.factor = sto.factor
            AND cnd.factor_version = sto.factor_version
            AND cnd.known_as_of >= sto.known_as_of
    -- Window sums over a shorter input differ in the last bits, so compare with a small tolerance.
    WHERE sto.value IS NULL OR ABS(cnd.value - sto.value) > 1e-9 * GREATEST(ABS(sto.value), 1)
{% else %}
    SELECT
        security_key,
        about_date,
        factor,
        factor_version,
        value,
        known_as_of,
        CAST('{{ run_started_at }}' AS TIMESTAMPTZ) AS computed_at
    FROM candidates
{% endif %}
