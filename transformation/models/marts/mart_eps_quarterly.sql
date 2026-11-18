-- Quarterly diluted EPS. One row per quarter per distinct value; a restatement adds a row.
-- A quarter is identified by period_end (period_start can drift by a day between filings).
-- Q4 is often not filed on its own, so when a 10-K leaves it out: Q4 = full year - first 9 months.
-- eps_base = EPS x split_index at filing, so values filed before and after a split compare.
WITH facts AS (
    SELECT
        fnd.security_key,
        fnd.period_start,
        fnd.period_end,
        DATE_DIFF('day', fnd.period_start, fnd.period_end) AS period_days,
        fnd.form,
        fnd.accession_no,
        fnd.filed_date,
        COALESCE(prc.split_index, 1) AS split_index_at_filed,
        fnd.fact_value * COALESCE(prc.split_index, 1) AS eps_base
    FROM {{ ref('fnd_fundamental') }} AS fnd
    ASOF LEFT JOIN {{ ref('mart_daily_price') }} AS prc
        ON fnd.security_key = prc.security_key AND fnd.filed_date >= prc.about_date
    WHERE fnd.concept = 'EarningsPerShareDiluted' AND fnd.unit = 'USD/shares'
),

reported AS (
    SELECT * EXCLUDE (period_days), FALSE AS is_derived
    FROM facts
    WHERE period_days BETWEEN 80 AND 100
),

nine_month AS (
    SELECT *
    FROM facts
    WHERE period_days BETWEEN 250 AND 290
),

-- Each 10-K's full-year value minus the latest 9-month value filed by then.
-- Skipped once the quarter itself has been filed: EPS doesn't add up exactly (share counts change
-- during the year), so mixing both would look like restatements that never happened.
-- Only from the year's own 10-K, not a 10-K/A or a later 10-K's comparison column: those can
-- restate the full year while the only 9-month value available is still the old one.
derived_q4 AS (
    SELECT
        ann.security_key,
        ytd.period_end + 1 AS period_start,
        ann.period_end,
        ann.form,
        ann.accession_no,
        ann.filed_date,
        ann.split_index_at_filed,
        ann.eps * ann.split_index_at_filed - ytd.eps_base AS eps_base,
        TRUE AS is_derived
    FROM {{ ref('mart_eps_annual') }} AS ann
    INNER JOIN nine_month AS ytd
        ON
            ann.security_key = ytd.security_key
            AND ABS(DATE_DIFF('day', ann.period_start, ytd.period_start)) <= 7
            AND ytd.period_end < ann.period_end
            AND ytd.filed_date <= ann.filed_date
    WHERE
        ann.form = '10-K'
        AND ann.filed_date < ann.period_end + INTERVAL 6 MONTH
        AND NOT EXISTS (
            SELECT 1
            FROM reported AS rep
            WHERE
                rep.security_key = ann.security_key
                AND rep.period_end = ann.period_end
                AND rep.filed_date <= ann.filed_date
        )
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY ann.security_key, ann.accession_no, ann.period_end
        ORDER BY ytd.filed_date DESC, ytd.accession_no DESC
    ) = 1
),

sightings AS (
    SELECT
        *,
        -- Filed values are rounded to the cent; a derived one combines two rounded values.
        CASE WHEN is_derived THEN 0.01 ELSE 0.005 END * split_index_at_filed AS rounding_base
    FROM (
        SELECT * FROM reported
        UNION ALL BY NAME
        SELECT * FROM derived_q4
    )
),

-- Later filings repeat a quarter as last year's comparison. Same value (up to rounding) is not news.
with_prev AS (
    SELECT
        *,
        LAG(eps_base) OVER (
            PARTITION BY security_key, period_end ORDER BY filed_date, is_derived, accession_no
        ) AS prev_eps_base,
        LAG(rounding_base) OVER (
            PARTITION BY security_key, period_end ORDER BY filed_date, is_derived, accession_no
        ) AS prev_rounding_base
    FROM sightings
),

versions AS (
    SELECT *
    FROM with_prev
    WHERE
        prev_eps_base IS NULL
        OR ABS(eps_base - prev_eps_base) > rounding_base + prev_rounding_base + 1e-9
)

SELECT
    security_key,
    period_start,
    period_end,
    ROUND(eps_base / split_index_at_filed, 6) AS eps,
    is_derived,
    form,
    accession_no,
    filed_date,
    split_index_at_filed
FROM versions
