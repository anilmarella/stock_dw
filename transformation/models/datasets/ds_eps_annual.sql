-- Annual diluted EPS from every 10-K, including restated values for earlier years.
-- split_index_at_filed lets us move each value onto any later share basis.
-- Incremental: appends facts ingested since the last run (each filing's fact is stored once upstream).
{{ config(materialized='incremental', incremental_strategy='append') }}

WITH eps AS (
    SELECT
        security_key,
        period_start,
        period_end,
        fact_value AS eps,
        form,
        accession_no,
        filed_date,
        ingested_at
    FROM {{ ref('int_sec_facts') }}
    WHERE
        concept = 'EarningsPerShareDiluted'
        AND unit = 'USD/shares'
        AND form IN ('10-K', '10-K/A')
        AND DATE_DIFF('day', period_start, period_end) BETWEEN 340 AND 380
        {% if is_incremental() %}
            AND ingested_at > (SELECT MAX(ingested_at) FROM {{ this }})
        {% endif %}
)

SELECT
    eps.*,
    COALESCE(spl.split_index, 1) AS split_index_at_filed
FROM eps
ASOF LEFT JOIN {{ ref('int_splits') }} AS spl
    ON eps.security_key = spl.security_key AND eps.filed_date >= spl.about_date
