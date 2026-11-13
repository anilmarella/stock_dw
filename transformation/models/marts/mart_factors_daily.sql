-- One row per security per day, one column per factor, as known on that day.
-- What ML training and backtests read. Rebuilt from the factor library on every run.
WITH wide AS (
    {{ factors_wide([
        'ret_1d', 'ret_21d', 'ret_63d', 'ret_252d', 'mom_12_1',
        'vol_21d', 'vol_63d', 'beta_252d', 'drawdown_252d', 'avg_dollar_volume_21d',
        'eps_fy', 'pe_ratio', 'earnings_yield', 'shares_outstanding', 'market_cap'
    ]) }}
)

SELECT
    wide.*,
    sec.ticker
FROM wide
INNER JOIN {{ ref('mart_security') }} AS sec ON wide.security_key = sec.security_key
