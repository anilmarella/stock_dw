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
- **`security_key` = md5(CIK).** Not FIGI (no source uses it). CIK survives ticker renames. It breaks if a second share class (GOOG + GOOGL) is added, so a `unique` test on `security_key` guards against that.
- **Ticker renames:** edit `tickers.txt` (FB → META). The new ticker resolves to the same CIK, so it gets the same `security_key`. Prices from both tickers merge into one history, and `fnd_security` shows the latest ticker.
- **SPY is prices only.** It's a fund with no company financials (companyfacts returns 404), so it's used purely as a benchmark.
- **Incremental prices, completed days only.** New tickers backfill from 2010. Existing tickers re-pull the last 7 days to catch late corrections. The end date is the last completed day: today only after 6 pm ET, else yesterday, so partial bars never land. Weekends and holidays just return no rows. A ticker is skipped if it was already fetched up to that end date (`data/ingest_state.json`).
- **Fundamentals: once a day, new filings only.** SEC only serves the whole file per company, so each company is fetched at most once a day, and only facts from filings not already in raw are written. Raw grows by new filings, not full copies.
- **Retries and exit code.** HTTP 429/5xx retry with backoff. Ingestion exits non-zero if any ticker fails, so CI shows red.
- **Raw files carry a time suffix**, so same-day runs never overwrite each other.
- **Skipped GOOG and BRK-B.** GOOG would duplicate GOOGL. BRK-B reports EPS per Class A share, which would need a conversion.
- **Staging is views, 1:1 with raw.** It renames, casts types and filters to 10-K/10-Q filings (plus amendments). No joins.
- **Tiingo's adjusted columns are dropped.** They're adjusted as of today, which is look-ahead. We compute our own.
- **Price `known_as_of` is set in foundation.** First seen = the trading day; a later changed value = the day we saw it.
- **Price versions:** a hash of the values is compared between ingests, and a new version appears only when it changes (a revert also counts as a change). `known_until` = the next version's `known_as_of`, so an as-of query is a simple range check.
- **Prices need a CIK.** They join to their security through the CIK lookup, so a ticker missing from SEC's list is dropped from foundation.
- **Fundamentals:** repeated facts collapse to the first one ingested. SEC filings never change, and a correction comes as a new filing (10-K/A).
- **Restructured companies:** GOOGL (2015), DIS (2019) and XOM (2026, new parent ExxonMobil Holdings Corp, CIK 2115436; old CIK 34088) got new CIKs. Fundamentals before that sit under the old CIK and aren't fetched. XOM is the worst case, with only filings since Aug 2026. The fix, if needed, is a small hand-made `predecessor_ciks.csv`.

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
