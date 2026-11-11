SELECT
    sec.security_key,
    sec.ticker,
    sec.cik,
    sec.name,
    MIN(prc.about_date) AS data_available_from,
    MAX(prc.about_date) AS data_available_to
FROM {{ ref('fnd_security') }} AS sec
LEFT JOIN {{ ref('fnd_price_daily') }} AS prc ON sec.security_key = prc.security_key
GROUP BY ALL
