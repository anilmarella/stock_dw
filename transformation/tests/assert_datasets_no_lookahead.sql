-- A value can't be known before the period it describes.
SELECT 'ds_price_daily' AS dataset, security_key, about_date AS period_end, known_as_of
FROM {{ ref('ds_price_daily') }}
WHERE known_as_of < about_date

UNION ALL

SELECT 'ds_eps_annual', security_key, period_end, filed_date
FROM {{ ref('ds_eps_annual') }}
WHERE filed_date <= period_end

UNION ALL

SELECT 'ds_eps_quarterly', security_key, period_end, filed_date
FROM {{ ref('ds_eps_quarterly') }}
WHERE filed_date <= period_end
