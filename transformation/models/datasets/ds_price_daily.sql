-- Unadjusted daily prices, every version. A new version only when values change between ingests.
-- As of date A: known_as_of <= A AND (known_until IS NULL OR known_until > A).
-- Split-adjusted close as seen on date A: close * split_index / split_index on A.
-- Incremental: reads rows ingested since the last run. For each day they touch, the stored current version
-- is reloaded, new versions are added after it, and its known_until is closed (delete + insert).
-- A split that arrives late or is corrected changes past split_index: run with --full-refresh.
{{ config(
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key=['security_key', 'about_date', 'version_no']
) }}

WITH new_prices AS (
    SELECT
        tkr.security_key,
        prc.about_date,
        prc.open,
        prc.high,
        prc.low,
        prc.close,
        prc.volume,
        prc.dividend_cash,
        prc.split_factor,
        prc.ingested_at,
        prc.ingest_date,
        CAST(NULL AS BIGINT) AS stored_version_no,
        CAST(NULL AS DATE) AS stored_known_as_of
    FROM {{ ref('stg_tiingo__prices') }} AS prc
    INNER JOIN {{ ref('int_ticker_map') }} AS tkr ON prc.ticker = tkr.ticker
    {% if is_incremental() %}
        WHERE prc.ingested_at > (SELECT MAX(ingested_at) FROM {{ this }})
    {% endif %}
),

candidates AS (
    SELECT * FROM new_prices
    {% if is_incremental() %}
        UNION ALL BY NAME
        -- Current stored version of each day the new ingests touch.
        SELECT
            security_key,
            about_date,
            open,
            high,
            low,
            close,
            volume,
            dividend_cash,
            split_factor,
            ingested_at,
            version_no AS stored_version_no,
            known_as_of AS stored_known_as_of
        FROM {{ this }}
        WHERE
            known_until IS NULL
            AND (security_key, about_date) IN (SELECT (security_key, about_date) FROM new_prices)
    {% endif %}
),

changes AS (
    SELECT
        *,
        MD5(CONCAT_WS('|', open, high, low, close, volume, dividend_cash, split_factor)) AS row_hash,
        LAG(row_hash) OVER (PARTITION BY security_key, about_date ORDER BY ingested_at) AS prev_hash
    FROM candidates
    QUALIFY prev_hash IS DISTINCT FROM row_hash
),

versioned AS (
    SELECT
        *,
        -- Continue numbering after the stored version (or start at 1).
        COALESCE(MAX(stored_version_no) OVER (PARTITION BY security_key, about_date), 1)
        + ROW_NUMBER() OVER (PARTITION BY security_key, about_date ORDER BY ingested_at) - 1 AS version_no
    FROM changes
),

dated AS (
    SELECT
        *,
        COALESCE(
            stored_known_as_of, CASE WHEN version_no = 1 THEN about_date ELSE ingest_date END
        ) AS known_as_of
    FROM versioned
)

SELECT
    dtd.security_key,
    dtd.about_date,
    dtd.open,
    dtd.high,
    dtd.low,
    dtd.close,
    dtd.volume,
    dtd.dividend_cash,
    dtd.split_factor,
    COALESCE(spl.split_index, 1) AS split_index,
    dtd.version_no,
    dtd.ingested_at,
    dtd.known_as_of,
    LEAD(dtd.known_as_of) OVER (
        PARTITION BY dtd.security_key, dtd.about_date ORDER BY dtd.version_no
    ) AS known_until
FROM dated AS dtd
ASOF LEFT JOIN {{ ref('int_splits') }} AS spl
    ON dtd.security_key = spl.security_key AND dtd.about_date >= spl.about_date
