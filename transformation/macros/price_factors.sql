{#
    Price factors from daily returns. Rows have about_date >= since.
    known_as_of = latest known_as_of among the prices in each factor's window,
    so a price correction only re-dates the factors whose window it touches.
#}
{% macro price_factors(since) %}
WITH prices AS (
    SELECT *
    FROM {{ ref('mart_daily_price') }}
    WHERE about_date >= {{ since }} - INTERVAL 400 DAY
),

spy AS (
    SELECT
        about_date,
        total_return AS spy_return,
        known_as_of AS spy_known_as_of
    FROM prices
    WHERE ticker = 'SPY'
),

base AS (
    SELECT
        prc.*,
        spy.spy_return,
        GREATEST(prc.known_as_of, spy.spy_known_as_of) AS pair_known_as_of,
        ROW_NUMBER() OVER (PARTITION BY prc.security_key ORDER BY prc.about_date) AS day_no
    FROM prices AS prc
    LEFT JOIN spy ON prc.about_date = spy.about_date
),

wide AS (
    SELECT
        security_key,
        about_date,
        total_return AS ret_1d,
        tr_index / LAG(tr_index, 21) OVER w - 1 AS ret_21d,
        tr_index / LAG(tr_index, 63) OVER w - 1 AS ret_63d,
        tr_index / LAG(tr_index, 252) OVER w - 1 AS ret_252d,
        LAG(tr_index, 21) OVER w / LAG(tr_index, 252) OVER w - 1 AS mom_12_1,
        CASE WHEN day_no > 21 THEN {{ rolling_vol('total_return', 21) }} END AS vol_21d,
        CASE WHEN day_no > 63 THEN {{ rolling_vol('total_return', 63) }} END AS vol_63d,
        CASE
            WHEN day_no > 252
                THEN REGR_SLOPE(total_return, spy_return) OVER (w ROWS BETWEEN 251 PRECEDING AND CURRENT ROW)
        END AS beta_252d,
        tr_index / MAX(tr_index) OVER (w ROWS BETWEEN 251 PRECEDING AND CURRENT ROW) - 1 AS drawdown_252d,
        CASE
            WHEN day_no >= 21
                THEN AVG(close * volume) OVER (w ROWS BETWEEN 20 PRECEDING AND CURRENT ROW)
        END AS avg_dollar_volume_21d,
        MAX(known_as_of) OVER (w ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) AS kao_1d,
        MAX(known_as_of) OVER (w ROWS BETWEEN 21 PRECEDING AND CURRENT ROW) AS kao_21d,
        MAX(known_as_of) OVER (w ROWS BETWEEN 63 PRECEDING AND CURRENT ROW) AS kao_63d,
        MAX(known_as_of) OVER (w ROWS BETWEEN 252 PRECEDING AND CURRENT ROW) AS kao_252d,
        MAX(pair_known_as_of) OVER (w ROWS BETWEEN 252 PRECEDING AND CURRENT ROW) AS kao_beta
    FROM base
    WINDOW w AS (PARTITION BY security_key ORDER BY about_date)
)

SELECT
    wide.security_key,
    wide.about_date,
    fct.factor,
    fct.factor_version,
    CAST(fct.value AS DOUBLE) AS value,
    fct.known_as_of
FROM wide,
    LATERAL (VALUES
        ('ret_1d', 1, wide.ret_1d, wide.kao_1d),
        ('ret_21d', 1, wide.ret_21d, wide.kao_21d),
        ('ret_63d', 1, wide.ret_63d, wide.kao_63d),
        ('ret_252d', 1, wide.ret_252d, wide.kao_252d),
        ('mom_12_1', 1, wide.mom_12_1, wide.kao_252d),
        ('vol_21d', 1, wide.vol_21d, wide.kao_21d),
        ('vol_63d', 1, wide.vol_63d, wide.kao_63d),
        ('beta_252d', 1, wide.beta_252d, wide.kao_beta),
        ('drawdown_252d', 1, wide.drawdown_252d, wide.kao_252d),
        ('avg_dollar_volume_21d', 1, wide.avg_dollar_volume_21d, wide.kao_21d)
    ) AS fct (factor, factor_version, value, known_as_of)
WHERE wide.about_date >= {{ since }} AND fct.value IS NOT NULL
{% endmacro %}


{% macro rolling_vol(col, days) -%}
    STDDEV_SAMP({{ col }}) OVER (w ROWS BETWEEN {{ days - 1 }} PRECEDING AND CURRENT ROW) * SQRT(252)
{%- endmacro %}
