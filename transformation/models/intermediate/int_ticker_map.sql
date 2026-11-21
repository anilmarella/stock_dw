-- One row per ticker and company pair seen in SEC's ticker list. Name is the latest seen.
SELECT
    ticker,
    cik,
    {{ security_key('cik') }} AS security_key,
    ARG_MAX(name, ingested_at) AS name,
    MIN(ingested_at) AS first_seen_at,
    MAX(ingested_at) AS last_seen_at
FROM {{ ref('stg_sec__company_tickers') }}
GROUP BY ticker, cik
