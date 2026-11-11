-- One row per security. Latest ticker wins after a rename.
SELECT
    {{ security_key('cik') }} AS security_key,
    cik,
    ticker,
    name
FROM {{ ref('stg_sec__company_tickers') }}
QUALIFY ROW_NUMBER() OVER (PARTITION BY cik ORDER BY ingested_at DESC) = 1
