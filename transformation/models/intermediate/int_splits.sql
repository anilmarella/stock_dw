-- One row per split. split_index = all splits up to and including this one multiplied.
-- A day's split_index = the latest split on or before that day (1 if none).
-- Known on the ex-date. Uses the latest ingested value (no split correction seen so far).
WITH ticker_map AS (
    SELECT DISTINCT
        ticker,
        {{ security_key('cik') }} AS security_key
    FROM {{ ref('stg_sec__company_tickers') }}
),

latest AS (
    SELECT
        ticker,
        about_date,
        split_factor
    FROM {{ ref('stg_tiingo__prices') }}
    QUALIFY ROW_NUMBER() OVER (PARTITION BY ticker, about_date ORDER BY ingested_at DESC) = 1
)

SELECT
    tkr.security_key,
    lat.ticker,
    lat.about_date,
    lat.split_factor,
    PRODUCT(lat.split_factor) OVER (
        PARTITION BY tkr.security_key ORDER BY lat.about_date ROWS UNBOUNDED PRECEDING
    ) AS split_index
FROM latest AS lat
INNER JOIN ticker_map AS tkr ON lat.ticker = tkr.ticker
WHERE lat.split_factor != 1
