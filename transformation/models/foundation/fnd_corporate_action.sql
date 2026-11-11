-- Splits and dividends as dated events. Known on the ex-date (no announcement date in Tiingo).
SELECT
    security_key,
    about_date AS event_date,
    'split' AS action_type,
    split_factor AS action_value,
    known_as_of,
    known_until
FROM {{ ref('fnd_price_daily') }}
WHERE split_factor != 1

UNION ALL

SELECT
    security_key,
    about_date AS event_date,
    'dividend' AS action_type,
    dividend_cash AS action_value,
    known_as_of,
    known_until
FROM {{ ref('fnd_price_daily') }}
WHERE dividend_cash != 0
