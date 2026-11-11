-- Annual diluted EPS from every 10-K, including restated values for earlier years.
-- split_index_at_filed lets us move each value onto any later share basis.
WITH eps AS (
    SELECT
        security_key,
        period_start,
        period_end,
        fact_value AS eps,
        form,
        accession_no,
        filed_date
    FROM {{ ref('fnd_fundamental') }}
    WHERE
        concept = 'EarningsPerShareDiluted'
        AND unit = 'USD/shares'
        AND form IN ('10-K', '10-K/A')
        AND DATE_DIFF('day', period_start, period_end) BETWEEN 340 AND 380
)

SELECT
    eps.*,
    COALESCE(prc.split_index, 1) AS split_index_at_filed
FROM eps
ASOF LEFT JOIN {{ ref('mart_daily_price') }} AS prc
    ON eps.security_key = prc.security_key AND eps.filed_date >= prc.about_date
