-- Unadjusted daily prices, every version. A new version only when values change between ingests.
-- As of date A: known_as_of <= A AND (known_until IS NULL OR known_until > A).
-- Split-adjusted close as seen on date A: close * split_index / split_index on A.
WITH prices AS (
    SELECT
        tkr.security_key,
        prc.ticker,
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
    INNER JOIN {{ ref('int_ticker_map') }} AS tkr ON prc.ticker = tkr.ticker
),

changes AS (
    SELECT
        *,
        LAG(row_hash) OVER (PARTITION BY security_key, about_date ORDER BY ingested_at) AS prev_hash
    FROM prices
    QUALIFY prev_hash IS DISTINCT FROM row_hash
),

versioned AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY security_key, about_date ORDER BY ingested_at) AS version_no
    FROM changes
)

SELECT
    ver.security_key,
    ver.about_date,
    ver.open,
    ver.high,
    ver.low,
    ver.close,
    ver.volume,
    ver.dividend_cash,
    ver.split_factor,
    COALESCE(spl.split_index, 1) AS split_index,
    ver.version_no,
    ver.ingested_at,
    CASE WHEN ver.version_no = 1 THEN ver.about_date ELSE ver.ingest_date END AS known_as_of,
    LEAD(CASE WHEN ver.version_no = 1 THEN ver.about_date ELSE ver.ingest_date END) OVER (
        PARTITION BY ver.security_key, ver.about_date ORDER BY ver.version_no
    ) AS known_until
FROM versioned AS ver
ASOF LEFT JOIN {{ ref('int_splits') }} AS spl
    ON ver.security_key = spl.security_key AND ver.about_date >= spl.about_date
