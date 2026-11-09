# Design

## Goal
30 well-known US stocks + SPY (benchmark), daily history from 2010, then daily updates.
Descriptive analytics only. Runs locally. Free data and tools.

## Point-in-time rules
- Every row has `about_date` (what day it describes), `known_as_of` (when the world knew it) and `ingested_at` (when we got it).
- Raw data is append-only. Corrections arrive as new versions.
- Queries take an `as_of` date and only see rows with `known_as_of <= as_of`.

## Sources
- **Tiingo**: raw (unadjusted) daily prices, split factor, dividends. Free API key.
- **SEC EDGAR companyfacts**: fundamentals. The `filed` date is `known_as_of`. Needs a User-Agent with contact info.

## Identity
- `ingestion/tickers.txt` is the only hand-edited list.
- Ingestion fetches each new ticker's CIK from SEC (`company_tickers.json`).
- dbt builds `dim_security`: surrogate `security_key`, `ticker`, `cik`, `name`. CIK joins prices to fundamentals.

## Layers
1. `ingestion/`: Python pulls → Parquet in `data/raw/source=<src>/dataset=<ds>/ingest_date=<date>/<name>_<HHMMSS UTC>.parquet`
   - `ingest.py` (entry), `common.py`, `sec.py` (CIKs + fundamentals), `tiingo.py` (prices). One file per source, an exception to the few-files rule.
2. `transformation/`: dbt v2 (Rust engine, built-in DuckDB adapter) → `data/warehouse.duckdb`
3. `serving/`: MCP server, dashboards. Read-only.
4. `cli.py`: `stockdw` command (add-ticker, ingest, build, add-feature). Calls the layers; no logic of its own.

`data/` is gitignored. One `pyproject.toml` (uv, Python 3.12).

## Adjusted prices
Computed from raw prices + split/dividend events known as of the query date. Never written over raw prices.

## Features
- YAML config using a few templates (return, volatility, drawdown, ratio) plus custom SQL.
- Versioned by name + version.
- One dbt test checks that no feature uses data from the future.

## AI layer
Local MCP server. Read-only DuckDB connection. Every tool takes `as_of`.

## Decisions and compromises
- **Surrogate `security_key`, not FIGI.** None of our sources use FIGI, so it would only be a label. CIK is stored as an attribute, but it can't be the key because one company can have several share classes (GOOG/GOOGL).
- **No ticker history.** FB → META is the only case in our set. Tiingo files all history under META, and EDGAR uses the CIK, which didn't change. Only typing "FB" fails.
- **SPY is prices only.** It's a fund with no company financials (companyfacts returns 404), so it's used purely as a benchmark.
- **Incremental prices.** New tickers backfill from 2010. Existing tickers re-pull the last 7 days to catch late corrections, and dbt removes the overlap.
- **Fundamentals are a full re-pull.** SEC only serves the whole file per company. dbt keeps one row per fact and filing, so repeats cost nothing.
- **Raw files carry a time suffix**, so same-day runs never overwrite each other.
- **Skipped GOOG and BRK-B.** GOOG would duplicate GOOGL. BRK-B reports EPS per Class A share, which would need a conversion.
- **Restructured companies:** GOOGL (2015) and DIS (2019) got new CIKs. Fundamentals before that sit under the old CIK and aren't fetched. The fix, if needed, is a small hand-made `predecessor_ciks.csv`.

## Known gaps
- **Survivorship bias:** the list is today's big companies. Showing the bias would need delisted stocks, which free sources don't cover well.
- **Real price corrections** are rare, so a demo of one would have to be staged.

## Demo highlights
Questions where naive data gives the wrong answer:
- **Splits:** NVDA (2021, 2024), AAPL (2014, 2020), TSLA, AMZN, GOOGL, AVGO, WMT. Adjusted prices in naive data show values nobody saw at the time.
- **EPS restated after a split:** NVDA's fiscal-2021 diluted EPS was first filed as 6.90 (2021-02-26) and later as 1.73 (2022-03-18). This changes the P/E.
- **Filing delay:** annual reports come out 1–2 months after the year ends, so naive P/E uses earnings before they were public.
- **Different fiscal years:** NVDA's ends in January, AAPL's in September, MSFT's in June.
- **Dividends:** price return vs total return.

## Open
MCP client, build staging, feature list, demo questions.
