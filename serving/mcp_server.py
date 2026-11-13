"""Read-only MCP server over the warehouse marts. Every tool takes as_of, so no look-ahead."""
import logging
import os
from datetime import date, datetime
from pathlib import Path

import duckdb
from mcp.server.mcpserver import MCPServer

DB = Path(os.getenv("STOCK_DW_DB", Path(__file__).resolve().parents[1] / "data/warehouse.duckdb"))
MAX_ROWS = 5000

log = logging.getLogger("serving")
mcp = MCPServer(
    "stock_dw",
    instructions=(
        "Point-in-time US stock data (30 stocks + SPY, daily since 2010). "
        "Every tool needs as_of (YYYY-MM-DD) and returns only what was known on that date. "
        "Use today's date for the latest view."
    ),
)


def query(sql, params):
    # Connect per call so dbt can still write between calls.
    with duckdb.connect(str(DB), read_only=True) as con:
        cur = con.execute(sql, params)
        cols = [c[0] for c in cur.description]
        rows = cur.fetchmany(MAX_ROWS + 1)
    if len(rows) > MAX_ROWS:
        log.warning("result cut to %d rows", MAX_ROWS)
        rows = rows[:MAX_ROWS]
    return [{c: v.isoformat() if isinstance(v, (date, datetime)) else v for c, v in zip(cols, r)} for r in rows]


@mcp.tool()
def list_securities(as_of: str) -> list[dict]:
    """Securities with price data on or before as_of."""
    return query(
        """
        SELECT ticker, name, cik, data_available_from
        FROM marts.mart_security
        WHERE data_available_from <= CAST(? AS DATE)
        ORDER BY ticker
        """,
        [as_of],
    )


@mcp.tool()
def get_prices(ticker: str, start: str, end: str, as_of: str) -> list[dict]:
    """Daily prices for one ticker. adj_close is split-adjusted as someone on as_of would have seen it."""
    return query(
        """
        WITH px AS (
            SELECT *
            FROM marts.mart_daily_price
            WHERE ticker = UPPER(?) AND about_date <= CAST(? AS DATE) AND known_as_of <= CAST(? AS DATE)
        ),
        asof_index AS (
            SELECT split_index FROM px ORDER BY about_date DESC LIMIT 1
        )
        SELECT
            px.about_date, px.open, px.high, px.low, px.close, px.volume,
            px.dividend_cash, px.split_factor,
            px.close * px.split_index / asof_index.split_index AS adj_close,
            px.total_return, px.known_as_of
        FROM px, asof_index
        WHERE px.about_date BETWEEN CAST(? AS DATE) AND CAST(? AS DATE)
        ORDER BY px.about_date
        """,
        [ticker, as_of, as_of, start, end],
    )


@mcp.tool()
def get_factors(
    tickers: list[str],
    start: str,
    end: str,
    as_of: str,
    factors: list[str] | None = None,
    computed_by: str | None = None,
) -> list[dict]:
    """Factor values (long: one row per ticker, day, factor) as known on as_of.
    computed_by (timestamp) also hides rows our pipeline produced after it.
    Factors: ret_1d, ret_21d, ret_63d, ret_252d, mom_12_1, vol_21d, vol_63d, beta_252d, drawdown_252d,
    avg_dollar_volume_21d, eps_fy, pe_ratio, earnings_yield, shares_outstanding, market_cap."""
    return query(
        """
        SELECT sec.ticker, fct.about_date, fct.factor, fct.factor_version, fct.value, fct.known_as_of, CAST(fct.computed_at AS VARCHAR) AS computed_at
        FROM marts.factor_values_as_of(
            CAST(? AS DATE), computed_by := COALESCE(CAST(? AS TIMESTAMPTZ), TIMESTAMPTZ '9999-12-31')
        ) AS fct
        INNER JOIN marts.mart_security AS sec ON fct.security_key = sec.security_key
        WHERE sec.ticker IN (SELECT UPPER(UNNEST(?)))
            AND fct.about_date BETWEEN CAST(? AS DATE) AND CAST(? AS DATE)
            AND (? IS NULL OR fct.factor IN (SELECT UNNEST(?)))
        ORDER BY sec.ticker, fct.about_date, fct.factor, fct.factor_version
        """,
        [as_of, computed_by, tickers, start, end, factors, factors],
    )


@mcp.tool()
def compare_as_of(ticker: str, factor: str, about_date: str, as_of: str) -> list[dict]:
    """Every version of one factor value for one day, known by as_of, oldest first.
    Shows how the value changed as filings, restatements or fixes arrived."""
    return query(
        """
        SELECT fct.factor_version, fct.value, fct.known_as_of, CAST(fct.computed_at AS VARCHAR) AS computed_at
        FROM marts.mart_factor_value AS fct
        INNER JOIN marts.mart_security AS sec ON fct.security_key = sec.security_key
        WHERE sec.ticker = UPPER(?) AND fct.factor = ? AND fct.about_date = CAST(? AS DATE)
            AND fct.known_as_of <= CAST(? AS DATE)
        ORDER BY fct.factor_version, fct.known_as_of, fct.computed_at
        """,
        [ticker, factor, about_date, as_of],
    )


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
    log.info("serving %s", DB)
    mcp.run()
