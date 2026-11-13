{#
    Fundamental factors, one row per (security, day, knowledge date) where the value changed.
    For day d as known at date K: latest fiscal year ended before d, from filings made by K.
    Knowledge dates for d are d itself plus every filing in the 3 years after d
    (a late 10-K or a restated comparative can change what we know about d).
    EPS and share counts are stored on a split-free basis, then put on day d's basis.
#}
{% macro fundamental_factors(since) %}
WITH days AS (
    SELECT
        security_key,
        about_date,
        close,
        split_index
    FROM {{ ref('mart_daily_price') }}
    WHERE about_date >= {{ since }} - INTERVAL 3 YEAR
),

eps AS (
    SELECT
        security_key,
        period_end,
        filed_date,
        eps * split_index_at_filed AS eps_base
    FROM {{ ref('mart_eps_annual') }}
),

shares AS (
    SELECT
        fnd.security_key,
        fnd.period_end,
        fnd.filed_date,
        fnd.fact_value / COALESCE(prc.split_index, 1) AS shares_base
    FROM {{ ref('fnd_fundamental') }} AS fnd
    ASOF LEFT JOIN {{ ref('mart_daily_price') }} AS prc
        ON fnd.security_key = prc.security_key AND fnd.filed_date >= prc.about_date
    WHERE fnd.concept = 'EntityCommonStockSharesOutstanding' AND fnd.unit = 'shares'
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY fnd.security_key, fnd.filed_date, fnd.period_end ORDER BY fnd.fact_value DESC
    ) = 1
),

events AS (
    SELECT
        security_key,
        filed_date AS event_date
    FROM eps
    UNION
    SELECT
        security_key,
        filed_date AS event_date
    FROM shares
),

knowledge AS (
    SELECT *
    FROM (
        SELECT
            security_key,
            about_date,
            about_date AS known_as_of
        FROM days
        UNION
        SELECT
            days.security_key,
            days.about_date,
            events.event_date AS known_as_of
        FROM days
        INNER JOIN events
            ON
                days.security_key = events.security_key
                AND events.event_date > days.about_date
                AND events.event_date <= days.about_date + INTERVAL 3 YEAR
    )
    WHERE known_as_of >= {{ since }}
),

eps_value AS (
    SELECT
        kno.security_key,
        kno.about_date,
        kno.known_as_of,
        eps.eps_base
    FROM knowledge AS kno
    INNER JOIN eps
        ON
            kno.security_key = eps.security_key
            AND eps.period_end < kno.about_date
            AND eps.filed_date <= kno.known_as_of
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY kno.security_key, kno.about_date, kno.known_as_of
        ORDER BY eps.period_end DESC, eps.filed_date DESC
    ) = 1
),

shares_value AS (
    SELECT
        kno.security_key,
        kno.about_date,
        kno.known_as_of,
        shr.shares_base
    FROM knowledge AS kno
    INNER JOIN shares AS shr
        ON
            kno.security_key = shr.security_key
            AND shr.period_end <= kno.about_date
            AND shr.filed_date <= kno.known_as_of
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY kno.security_key, kno.about_date, kno.known_as_of
        ORDER BY shr.period_end DESC, shr.filed_date DESC
    ) = 1
),

wide AS (
    SELECT
        kno.security_key,
        kno.about_date,
        kno.known_as_of,
        days.close,
        epv.eps_base / days.split_index AS eps_fy,
        shv.shares_base * days.split_index AS shares_outstanding
    FROM knowledge AS kno
    INNER JOIN days ON kno.security_key = days.security_key AND kno.about_date = days.about_date
    LEFT JOIN eps_value AS epv
        ON
            kno.security_key = epv.security_key
            AND kno.about_date = epv.about_date
            AND kno.known_as_of = epv.known_as_of
    LEFT JOIN shares_value AS shv
        ON
            kno.security_key = shv.security_key
            AND kno.about_date = shv.about_date
            AND kno.known_as_of = shv.known_as_of
),

long AS (
    SELECT
        wide.security_key,
        wide.about_date,
        fct.factor,
        fct.factor_version,
        CAST(fct.value AS DOUBLE) AS value,
        wide.known_as_of
    FROM wide,
        LATERAL (VALUES
            ('eps_fy', 1, wide.eps_fy),
            ('pe_ratio', 1, CASE WHEN wide.eps_fy > 0 THEN wide.close / wide.eps_fy END),
            ('earnings_yield', 1, wide.eps_fy / wide.close),
            ('shares_outstanding', 1, wide.shares_outstanding),
            ('market_cap', 1, wide.close * wide.shares_outstanding)
        ) AS fct (factor, factor_version, value)
    WHERE fct.value IS NOT NULL
)

SELECT *
FROM long
QUALIFY value IS DISTINCT FROM LAG(value) OVER (
    PARTITION BY security_key, about_date, factor, factor_version ORDER BY known_as_of
)
{% endmacro %}
