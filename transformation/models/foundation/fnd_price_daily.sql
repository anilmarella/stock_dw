-- Versioned daily prices. A new version only when values change between ingests.
WITH ticker_map AS (
    SELECT DISTINCT
        ticker,
        {{ security_key('cik') }} AS security_key
    FROM {{ ref('stg_sec__company_tickers') }}
),

prices AS (
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
        MD5(CONCAT_WS(
            '|', prc.open, prc.high, prc.low, prc.close,
            prc.volume, prc.dividend_cash, prc.split_factor
        )) AS row_hash
    FROM {{ ref('stg_tiingo__prices') }} AS prc
    INNER JOIN ticker_map AS tkr ON prc.ticker = tkr.ticker
),

changes AS (
    SELECT
        *,
        LAG(row_hash) OVER (
            PARTITION BY security_key, about_date ORDER BY ingested_at
        ) AS prev_hash
    FROM prices
    QUALIFY prev_hash IS DISTINCT FROM row_hash
),

versioned AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY security_key, about_date ORDER BY ingested_at
        ) AS version_no
    FROM changes
)

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
    version_no,
    ingested_at,
    CASE WHEN version_no = 1 THEN about_date ELSE ingest_date END AS known_as_of,
    LEAD(CASE WHEN version_no = 1 THEN about_date ELSE ingest_date END) OVER (
        PARTITION BY security_key, about_date ORDER BY version_no
    ) AS known_until
FROM versioned
