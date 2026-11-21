{#
    The feature registry: the one place features are defined.
    Adding a feature = one entry here + dbt build. Changing a formula = a new name (vol_21d_v2).
    lookback_days = calendar days of history needed before the first output day.
#}
{% macro feature_registry() %}
{{ return([
    {'name': 'ret_1d', 'category': 'price', 'lookback_days': 7,
     'description': 'Daily total return (dividends included).',
     'sql': 'total_return'},
    {'name': 'ret_21d', 'category': 'price', 'lookback_days': 40,
     'description': '1-month total return (21 trading days).',
     'sql': period_return('tr_index', 21)},
    {'name': 'ret_63d', 'category': 'price', 'lookback_days': 100,
     'description': '3-month total return.',
     'sql': period_return('tr_index', 63)},
    {'name': 'ret_252d', 'category': 'price', 'lookback_days': 380,
     'description': '12-month total return.',
     'sql': period_return('tr_index', 252)},
    {'name': 'mom_12_1', 'category': 'price', 'lookback_days': 380,
     'description': 'Return from 12 months ago to 1 month ago (momentum).',
     'sql': period_return('tr_index', 252, skip=21)},
    {'name': 'vol_21d', 'category': 'price', 'lookback_days': 40,
     'description': 'Annualised volatility of daily returns, 1 month.',
     'sql': rolling_vol('total_return', 21)},
    {'name': 'vol_63d', 'category': 'price', 'lookback_days': 100,
     'description': 'Annualised volatility of daily returns, 3 months.',
     'sql': rolling_vol('total_return', 63)},
    {'name': 'beta_252d', 'category': 'price', 'lookback_days': 380,
     'description': 'How much the stock moves when SPY moves 1%, over 1 year.',
     'sql': rolling_beta('total_return', 'spy_return', 252)},
    {'name': 'drawdown_252d', 'category': 'price', 'lookback_days': 380,
     'description': 'Drop from the 1-year high, dividends included.',
     'sql': drawdown('tr_index', 252)},
    {'name': 'avg_dollar_volume_21d', 'category': 'price', 'lookback_days': 40,
     'description': 'Average dollars traded per day over 1 month (liquidity).',
     'sql': rolling_avg('close * volume', 21)},
]) }}
{% endmacro %}


{#
    One DuckDB table function per category, built from the registry.
    SELECT * FROM features.price_features(DATE '2026-01-01', tickers := ['NVDA'], start_date := DATE '2016-01-01')
    Uses only price versions known on as_of. end_date defaults to as_of.
#}
{% macro create_feature_functions(schema) %}
{% set feats = feature_registry() | selectattr('category', 'equalto', 'price') | list %}
{% set lookback = feats | map(attribute='lookback_days') | max %}
CREATE OR REPLACE MACRO {{ schema }}.price_features(
    as_of, tickers := NULL, start_date := DATE '1900-01-01', end_date := NULL
) AS TABLE
WITH known AS (
    SELECT
        sec.ticker,
        prc.*
    FROM {{ ref('ds_price_daily') }} AS prc
    INNER JOIN {{ ref('ds_security') }} AS sec ON prc.security_key = sec.security_key
    WHERE
        prc.known_as_of <= as_of
        AND (prc.known_until IS NULL OR prc.known_until > as_of)
        AND prc.about_date <= LEAST(as_of, COALESCE(end_date, as_of))
        AND prc.about_date >= start_date - INTERVAL {{ lookback }} DAY
        AND (tickers IS NULL OR sec.ticker IN (SELECT UNNEST(tickers)) OR sec.ticker = 'SPY')
),

-- Daily return with dividends. split_factor stops a split looking like a crash.
returns AS (
    SELECT
        *,
        (close + dividend_cash) * split_factor
        / LAG(close) OVER (PARTITION BY security_key ORDER BY about_date) - 1 AS total_return
    FROM known
),

-- tr_index = growth of $1 with dividends reinvested. A return over n days = today / n days ago - 1.
base AS (
    SELECT
        ret.*,
        spy.total_return AS spy_return,
        PRODUCT(1 + COALESCE(ret.total_return, 0)) OVER (
            PARTITION BY ret.security_key ORDER BY ret.about_date ROWS UNBOUNDED PRECEDING
        ) AS tr_index
    FROM returns AS ret
    LEFT JOIN returns AS spy ON spy.ticker = 'SPY' AND ret.about_date = spy.about_date
)

SELECT
    ticker,
    about_date,
    {%- for f in feats %}
    {{ f.sql }} AS {{ f.name }}{{ "," if not loop.last }}
    {%- endfor %}
FROM base
WINDOW w AS (PARTITION BY security_key ORDER BY about_date)
-- Filter after the formulas run, so the lookback days feed them but aren't returned.
QUALIFY about_date >= start_date AND (tickers IS NULL OR ticker IN (SELECT UNNEST(tickers)))
{% endmacro %}
