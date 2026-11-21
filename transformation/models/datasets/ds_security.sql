-- One row per security (company), keyed by md5(CIK). Shows the latest ticker after a rename.
SELECT
    security_key,
    cik,
    ticker,
    name
FROM {{ ref('int_ticker_map') }}
QUALIFY ROW_NUMBER() OVER (PARTITION BY cik ORDER BY last_seen_at DESC, first_seen_at DESC) = 1
