-- Latest-known daily prices with point-in-time returns and running indexes.
-- Split-adjusted close as seen on date A: close * split_index / split_index on A.
WITH px AS (
    SELECT
        prc.security_key,
        sec.ticker,
        prc.about_date,
        prc.open,
        prc.high,
        prc.low,
        prc.close,
        prc.volume,
        prc.dividend_cash,
        prc.split_factor,
        LAG(prc.close) OVER (PARTITION BY prc.security_key ORDER BY prc.about_date) AS prev_close
    FROM {{ ref('fnd_price_daily') }} AS prc
    INNER JOIN {{ ref('fnd_security') }} AS sec ON prc.security_key = sec.security_key
    WHERE prc.known_until IS NULL
),

rets AS (
    SELECT
        *,
        close * split_factor / prev_close - 1 AS price_return,
        (close + dividend_cash) * split_factor / prev_close - 1 AS total_return
    FROM px
)

SELECT
    security_key,
    ticker,
    about_date,
    open,
    high,
    low,
    close,
    volume,
    dividend_cash,
    split_factor,
    price_return,
    total_return,
    PRODUCT(split_factor) OVER w AS split_index,
    PRODUCT(1 + COALESCE(total_return, 0)) OVER w AS tr_index
FROM rets
WINDOW w AS (PARTITION BY security_key ORDER BY about_date ROWS UNBOUNDED PRECEDING)
