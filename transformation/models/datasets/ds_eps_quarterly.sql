-- Quarterly diluted EPS. One row per quarter per distinct value; a restatement adds a row.
-- A quarter is identified by period_end (period_start can drift by a day between filings).
-- Q4 is often not filed on its own, so when a 10-K leaves it out: Q4 = full year - first 9 months.
-- eps_base = EPS x split_index at filing, so values filed before and after a split compare.
-- Incremental: facts ingested since the last run are compared with the latest stored value
-- of their quarter; only new values (restatements, new quarters) are appended.
{{ config(materialized='incremental', incremental_strategy='append') }}

WITH facts AS (
    SELECT
        fnd.security_key,
        fnd.period_start,
        fnd.period_end,
        DATE_DIFF('day', fnd.period_start, fnd.period_end) AS period_days,
        fnd.form,
        fnd.accession_no,
        fnd.filed_date,
        fnd.ingested_at,
        COALESCE(spl.split_index, 1) AS split_index_at_filed,
        fnd.fact_value * COALESCE(spl.split_index, 1) AS eps_base
    FROM {{ ref('int_sec_facts') }} AS fnd
    ASOF LEFT JOIN {{ ref('int_splits') }} AS spl
        ON fnd.security_key = spl.security_key AND fnd.filed_date >= spl.about_date
    WHERE fnd.concept = 'EarningsPerShareDiluted' AND fnd.unit = 'USD/shares'
),

new_facts AS (
    SELECT *
    FROM facts
    {% if is_incremental() %}
        WHERE ingested_at > (SELECT MAX(ingested_at) FROM {{ this }})
    {% endif %}
),

{% if is_incremental() %}
    -- Latest stored value of each quarter: what new facts are compared against.
    stored_last AS (
        SELECT
            security_key,
            period_end,
            filed_date,
            is_derived,
            accession_no,
            eps * split_index_at_filed AS eps_base,
            CASE WHEN is_derived THEN 0.01 ELSE 0.005 END * split_index_at_filed AS rounding_base,
            TRUE AS is_seed
        FROM {{ this }}
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY security_key, period_end ORDER BY filed_date DESC, is_derived DESC, accession_no DESC
        ) = 1
    ),
{% endif %}

reported AS (
    SELECT * EXCLUDE (period_days), FALSE AS is_derived
    FROM new_facts
    WHERE
        period_days BETWEEN 80 AND 100
        {% if is_incremental() %}
            AND NOT EXISTS (
                SELECT 1
                FROM stored_last AS sto
                WHERE
                    sto.security_key = new_facts.security_key
                    AND sto.period_end = new_facts.period_end
                    AND sto.filed_date >= new_facts.filed_date
            )
        {% endif %}
),

-- Every quarter actually filed so far (new or stored), to know when Q4 doesn't need deriving.
reported_all AS (
    SELECT security_key, period_end, filed_date FROM reported
    {% if is_incremental() %}
        UNION ALL
        SELECT security_key, period_end, filed_date FROM {{ this }} WHERE NOT is_derived
    {% endif %}
),

nine_month AS (
    SELECT *
    FROM facts
    WHERE period_days BETWEEN 250 AND 290
),

full_year AS (
    SELECT *
    FROM new_facts
    WHERE period_days BETWEEN 340 AND 380 AND form = '10-K'
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
        ann.ingested_at,
        ann.eps_base - ytd.eps_base AS eps_base,
        TRUE AS is_derived
    FROM full_year AS ann
    INNER JOIN nine_month AS ytd
        ON
            ann.security_key = ytd.security_key
            AND ABS(DATE_DIFF('day', ann.period_start, ytd.period_start)) <= 7
            AND ytd.period_end < ann.period_end
            AND ytd.filed_date <= ann.filed_date
    WHERE
        ann.filed_date < ann.period_end + INTERVAL 6 MONTH
        AND NOT EXISTS (
            SELECT 1
            FROM reported_all AS rep
            WHERE
                rep.security_key = ann.security_key
                AND rep.period_end = ann.period_end
                AND rep.filed_date <= ann.filed_date
        )
        {% if is_incremental() %}
            AND NOT EXISTS (
                SELECT 1
                FROM stored_last AS sto
                WHERE
                    sto.security_key = ann.security_key
                    AND sto.period_end = ann.period_end
                    AND sto.filed_date >= ann.filed_date
            )
        {% endif %}
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY ann.security_key, ann.accession_no, ann.period_end
        ORDER BY ytd.filed_date DESC, ytd.accession_no DESC
    ) = 1
),

sightings AS (
    SELECT
        *,
        -- Filed values are rounded to the cent; a derived one combines two rounded values.
        CASE WHEN is_derived THEN 0.01 ELSE 0.005 END * split_index_at_filed AS rounding_base,
        FALSE AS is_seed
    FROM (
        SELECT * FROM reported
        UNION ALL BY NAME
        SELECT * FROM derived_q4
    )
    {% if is_incremental() %}
        UNION ALL BY NAME
        SELECT * FROM stored_last
    {% endif %}
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
        NOT is_seed
        AND (prev_eps_base IS NULL OR ABS(eps_base - prev_eps_base) > rounding_base + prev_rounding_base + 1e-9)
)

SELECT
    security_key,
    period_start,
    period_end,
    -- From the middle of the period: a quarter ending on Jan 1 still counts as Q4.
    YEAR(period_end - INTERVAL 45 DAY) || '-Q' || QUARTER(period_end - INTERVAL 45 DAY) AS calendar_quarter,
    ROUND(eps_base / split_index_at_filed, 6) AS eps,
    is_derived,
    form,
    accession_no,
    filed_date,
    split_index_at_filed,
    ingested_at
FROM versions
