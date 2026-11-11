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
- dbt builds `fnd_security` / `mart_security`: `security_key`, `ticker`, `cik`, `name`. CIK joins prices to fundamentals.

## Layers
1. `ingestion/`: Python pulls → Parquet in `data/raw/source=<src>/dataset=<ds>/ingest_date=<date>/<name>_<HHMMSS UTC>.parquet`
   - `ingest.py` (entry), `common.py`, `sec.py` (CIKs + fundamentals), `tiingo.py` (prices). One file per source, an exception to the few-files rule.
2. `transformation/`: dbt v2 (Rust engine, built-in DuckDB adapter) → `data/warehouse.duckdb`
3. `serving/`: MCP server, dashboards. Read-only.
4. `cli.py`: `stockdw` command (add-ticker, ingest, build, add-feature). Calls the layers; no logic of its own.

`data/` is gitignored. One `pyproject.toml` (uv, Python 3.12).

## dbt layers
- **staging** (views): 1:1 with raw. Renames, casts types, light filters.
- **foundation** (tables): one table per concept, versioned with `known_as_of` / `known_until`. `fnd_security`, `fnd_price_daily`, `fnd_corporate_action`, `fnd_fundamental`.
- **marts** (tables): what serving reads. `mart_security`, `mart_daily_price`, `mart_eps_annual`, `mart_daily_features`.

## Adjusted prices
Never stored. `mart_daily_price.split_index` is the running product of split factors. Split-adjusted close for day d as seen on date A = `close_d * split_index_d / split_index_A`. Using A = today reproduces what a naive dataset shows.

## Features (`mart_daily_features`)
- **Price:** `ret_1d/21d/63d/252d` (total return), `mom_12_1`, `vol_21d/63d` (annualised), `beta_252d` vs SPY, `drawdown_252d`, `avg_dollar_volume_21d`.
- **Fundamental:** `eps_fy`, `pe_ratio`, `earnings_yield`, `shares_outstanding`, `market_cap`.
- **Naive twins for the demo:** `eps_fy_naive`, `pe_ratio_naive`.
- All built from daily returns that only use that day's split/dividend, so they're point-in-time by construction.
- `tests/assert_features_no_lookahead.sql` fails if any row uses a filing made after its date.
- Hand-written SQL for now. The YAML feature config is still open.

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

- **Marts use the latest price version.** Price corrections are rare, so features use the current version of history. Foundation still keeps every version for as-of queries.
- **Annual EPS, not trailing-12-month.** P/E uses the latest 10-K's diluted EPS. TTM needs quarter math (Q4 = FY minus 9 months), which is left for later.
- **Share basis.** EPS and share counts are filed on the share basis of their filing date. Both are moved onto each day's basis with `split_index` (EPS ÷ splits since filing, shares × splits since filing).
- **Naive P/E** = final restated EPS for the latest fiscal year ended, available from year end (no filing delay).
- **Split/dividend known on the ex-date.** Tiingo has no announcement date.
- **Rolling features need a full window**, e.g. `vol_63d` is null for the first 63 days.

## Known gaps
- **Survivorship bias:** the list is today's big companies. Showing the bias would need delisted stocks, which free sources don't cover well.
- **Real price corrections** are rare, so a demo of one would have to be staged.
- **Multi-class companies:** V has no plain diluted EPS (it reports per class), so no P/E. GOOGL and META have no single cover-page share count, so no market cap. MA's share counts are sparse.
- **XOM fundamentals** only start in Aug 2026 (new CIK, see above).

## Demo highlights
Questions where naive data gives the wrong answer:
- **Splits:** NVDA (2021, 2024), AAPL (2014, 2020), TSLA, AMZN, GOOGL, AVGO, WMT. Adjusted prices in naive data show values nobody saw at the time.
- **EPS restated after a split:** NVDA's fiscal-2021 diluted EPS was first filed as 6.90 (2021-02-26) and later as 1.73 (2022-03-18). This changes the P/E.
- **Filing delay:** annual reports come out 1–2 months after the year ends, so naive P/E uses earnings before they were public. NVDA on 2021-02-01: point-in-time P/E 117 (FY2020 EPS 4.52, the latest filed) vs naive 76.5 (FY2021 EPS 6.92, not filed until 2021-02-26).
- **Split basis:** on 2021-08-02, after NVDA's 4:1 split, the stale EPS of 6.90 becomes 1.725 on the new basis. P/E stays continuous (about 114) instead of jumping 4×.
- **Different fiscal years:** NVDA's ends in January, AAPL's in September, MSFT's in June.
- **Dividends:** price return vs total return.

## Open
MCP client, build staging, feature list, demo questions.
