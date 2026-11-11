-- One row per security per trading day. Every feature uses only data known on that day.
WITH spy AS (
    SELECT
        about_date,
        total_return AS spy_return
    FROM {{ ref('mart_daily_price') }}
    WHERE ticker = 'SPY'
),

base AS (
    SELECT
        prc.*,
        spy.spy_return,
        ROW_NUMBER() OVER (PARTITION BY prc.security_key ORDER BY prc.about_date) AS day_no
    FROM {{ ref('mart_daily_price') }} AS prc
    LEFT JOIN spy ON prc.about_date = spy.about_date
),

price_features AS (
    SELECT
        security_key,
        ticker,
        about_date,
        close,
        split_index,
        total_return AS ret_1d,
        tr_index / LAG(tr_index, 21) OVER w - 1 AS ret_21d,
        tr_index / LAG(tr_index, 63) OVER w - 1 AS ret_63d,
        tr_index / LAG(tr_index, 252) OVER w - 1 AS ret_252d,
        LAG(tr_index, 21) OVER w / LAG(tr_index, 252) OVER w - 1 AS mom_12_1,
        CASE
            WHEN day_no > 21
                THEN STDDEV_SAMP(total_return) OVER (w ROWS BETWEEN 20 PRECEDING AND CURRENT ROW) * SQRT(252)
        END AS vol_21d,
        CASE
            WHEN day_no > 63
                THEN STDDEV_SAMP(total_return) OVER (w ROWS BETWEEN 62 PRECEDING AND CURRENT ROW) * SQRT(252)
        END AS vol_63d,
        CASE
            WHEN day_no > 252
                THEN REGR_SLOPE(total_return, spy_return) OVER (w ROWS BETWEEN 251 PRECEDING AND CURRENT ROW)
        END AS beta_252d,
        tr_index / MAX(tr_index) OVER (w ROWS BETWEEN 251 PRECEDING AND CURRENT ROW) - 1 AS drawdown_252d,
        CASE
            WHEN day_no >= 21
                THEN AVG(close * volume) OVER (w ROWS BETWEEN 20 PRECEDING AND CURRENT ROW)
        END AS avg_dollar_volume_21d
    FROM base
    WINDOW w AS (PARTITION BY security_key ORDER BY about_date)
),

-- Newest fiscal year in each 10-K; once a newer year is known, amendments of older years are ignored.
eps_pit AS (
    SELECT *
    FROM {{ ref('mart_eps_annual') }}
    QUALIFY
        ROW_NUMBER() OVER (PARTITION BY security_key, accession_no ORDER BY period_end DESC) = 1
),

eps_pit_current AS (
    SELECT *
    FROM eps_pit
    QUALIFY period_end >= MAX(period_end) OVER (
        PARTITION BY security_key ORDER BY filed_date ROWS UNBOUNDED PRECEDING
    )
),

-- What a naive dataset shows: the final restated value, usable from fiscal year end.
eps_naive AS (
    SELECT *
    FROM {{ ref('mart_eps_annual') }}
    QUALIFY ROW_NUMBER() OVER (PARTITION BY security_key, period_end ORDER BY filed_date DESC) = 1
),

shares AS (
    SELECT
        fnd.security_key,
        fnd.filed_date,
        fnd.fact_value AS shares_outstanding,
        COALESCE(prc.split_index, 1) AS split_index_at_filed
    FROM {{ ref('fnd_fundamental') }} AS fnd
    ASOF LEFT JOIN {{ ref('mart_daily_price') }} AS prc
        ON fnd.security_key = prc.security_key AND fnd.filed_date >= prc.about_date
    WHERE fnd.concept = 'EntityCommonStockSharesOutstanding' AND fnd.unit = 'shares'
    QUALIFY
        ROW_NUMBER() OVER (PARTITION BY fnd.security_key, fnd.filed_date ORDER BY fnd.period_end DESC) = 1
),

joined AS (
    SELECT
        pxf.*,
        eps.period_end AS eps_period_end,
        eps.filed_date AS eps_filed_date,
        shr.filed_date AS shares_filed_date,
        eps.eps * eps.split_index_at_filed / pxf.split_index AS eps_fy,
        naive.eps * naive.split_index_at_filed / pxf.split_index AS eps_fy_naive,
        shr.shares_outstanding * pxf.split_index / shr.split_index_at_filed AS shares_outstanding
    FROM price_features AS pxf
    ASOF LEFT JOIN eps_pit_current AS eps
        ON pxf.security_key = eps.security_key AND pxf.about_date >= eps.filed_date
    ASOF LEFT JOIN eps_naive AS naive
        ON pxf.security_key = naive.security_key AND pxf.about_date > naive.period_end
    ASOF LEFT JOIN shares AS shr
        ON pxf.security_key = shr.security_key AND pxf.about_date >= shr.filed_date
)

SELECT
    security_key,
    ticker,
    about_date,
    close,
    ret_1d,
    ret_21d,
    ret_63d,
    ret_252d,
    mom_12_1,
    vol_21d,
    vol_63d,
    beta_252d,
    drawdown_252d,
    avg_dollar_volume_21d,
    eps_fy,
    eps_period_end,
    eps_filed_date,
    eps_fy_naive,
    shares_outstanding,
    shares_filed_date,
    CASE WHEN eps_fy > 0 THEN close / eps_fy END AS pe_ratio,
    CASE WHEN eps_fy_naive > 0 THEN close / eps_fy_naive END AS pe_ratio_naive,
    eps_fy / close AS earnings_yield,
    close * shares_outstanding AS market_cap
FROM joined
