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
4. `cli.py`: `stockdw` command (add-ticker, ingest, build, add-factor). Calls the layers; no logic of its own.

`data/` is gitignored. One `pyproject.toml` (uv, Python 3.12).

## dbt layers
- **staging** (views): 1:1 with raw. Renames, casts types, light filters.
- **foundation** (tables): shared source facts, versioned with `known_as_of` / `known_until` plus `ingested_at`. `fnd_security`, `fnd_price_daily`, `fnd_corporate_action`, `fnd_fundamental`.
- **marts**: what people and serving read. `mart_security`, `mart_daily_price`, `mart_eps_annual`, the factor library `mart_factor_value`, and its wide read view `mart_factors_daily`.

## Adjusted prices
Never stored. `mart_daily_price.split_index` is the running product of split factors. Split-adjusted close for day d as seen on date A = `close_d * split_index_d / split_index_A`. Using A = today reproduces what a naive dataset shows.

## Factor library (`mart_factor_value`)
- **"Factor"** is the hedge fund term for a feature: a number per stock per day expected to help explain returns (momentum, value, volatility, size). A fund's shared collection of them is its factor library.
- **Owned by its users, in marts.** Foundation holds only shared source facts. Teams own their factor logic, versions and bug fixes.
- **Long and append-only:** `security_key, about_date, factor, factor_version, value, known_as_of, computed_at`.
  - Rows are never updated or deleted, and the table is never rebuilt (`full_refresh: false`).
  - Each run appends a row only when a value changed, at the same or an earlier `known_as_of`: new days, a late filing, a restatement, a price correction, or a formula fix without a version bump.
  - Long fits append-only: a new factor or version appends only its own rows, with no new columns and no repeated unchanged values.
  - Values are `DOUBLE`. A rare text or category factor would get its own small table.
- **Two dates on every row:**
  - `known_as_of`: when the inputs were public.
  - `computed_at`: when our pipeline produced the row.
  - "What was knowable on A?" filters `known_as_of`. "What did our system show on A?" also filters `computed_at`, so a bug that was later fixed still shows up.
- **`factor_version`:** bumped in the PR that changes a formula. Old versions' rows stay. Readers get the latest version unless they pin one.
- **Factors (v1):**
  - Price: `ret_1d/21d/63d/252d` (total return), `mom_12_1`, `vol_21d/63d` (annualised), `beta_252d` vs SPY, `drawdown_252d`, `avg_dollar_volume_21d`.
  - Fundamental: `eps_fy`, `pe_ratio`, `earnings_yield`, `shares_outstanding`, `market_cap`.
- **How `known_as_of` is set:**
  - **Price factors:** the latest `known_as_of` among the prices in that factor's window. A correction only re-dates the factors whose window it touches. Splits never change them, because they're built from daily returns.
  - **Fundamental factors:** for day d as known at K, the latest fiscal year ended before d, from filings made by K. K is d itself plus every filing in the 3 years after d, so late 10-Ks and restated comparatives create new rows for past days.
- **Code:**
  - Each family is a macro of readable CTEs: `macros/price_factors.sql`, `macros/fundamental_factors.sql`.
  - Adding a factor is one line in the family's `VALUES` list.
- **Reading it:**
  - `mart_factors_daily`: wide, as known on each row's own day, for ML and backtests. Built by the `factors_wide(factors, versions)` macro.
  - `marts.factor_values_as_of(as_of [, computed_by := ts])`: DuckDB table macro for any as-of date, created after each build.
- **Incremental:** a run recomputes from the last `known_as_of` minus 10 days (prices read 400 days back for windows; fundamentals 3 years back for late filings) and compares with stored rows. A rerun with no new data appends nothing. Window sums over shorter inputs differ in the last bits, so the comparison uses a 1e-9 relative tolerance.
- **Tests:** `tests/assert_factors_no_lookahead.sql` fails if any value is known before its day.
- **Rejected:**
  - wide tables per family: append-only would repeat unchanged columns
  - a YAML registry
  - auto-bumped versions: text and compiled-SQL hashes change on non-logic edits

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

- **Fresh builds only know the corrected price.** A price corrected before the first build gives factors only the corrected value (known from the correction date). Live append-only runs record both.
- **Annual EPS, not trailing-12-month.** P/E uses the latest 10-K's diluted EPS. TTM needs quarter math (Q4 = FY minus 9 months), which is left for later.
- **Share basis.** EPS and share counts are filed on the share basis of their filing date. Both are moved onto each day's basis with `split_index` (EPS ÷ splits since filing, shares × splits since filing).
- **"Naive" = as known today.** `factor_values_as_of(today)` gives what a look-ahead dataset shows (final restated values, no filing delay), so no separate naive columns.
- **Split/dividend known on the ex-date.** Tiingo has no announcement date.
- **Rolling factors need a full window**, e.g. `vol_63d` is null for the first 63 days.

## Known gaps
- **Survivorship bias:** the list is today's big companies. Showing the bias would need delisted stocks, which free sources don't cover well.
- **Real price corrections** are rare, so a demo of one would have to be staged.
- **Multi-class companies:** V has no plain diluted EPS (it reports per class), so no P/E. GOOGL and META have no single cover-page share count, so no market cap. MA's share counts are sparse.
- **XOM fundamentals** only start in Aug 2026 (new CIK, see above).

## Demo highlights
Questions where naive data gives the wrong answer:
- **Splits:** NVDA (2021, 2024), AAPL (2014, 2020), TSLA, AMZN, GOOGL, AVGO, WMT. Adjusted prices in naive data show values nobody saw at the time.
- **EPS restated after a split:** NVDA's fiscal-2021 diluted EPS was first filed as 6.90 (2021-02-26) and later as 1.73 (2022-03-18). This changes the P/E.
- **Filing delay and restatement, one row:** NVDA's P/E for 2021-02-01 has three versions in `mart_factor_value`:
  - 117.1, known 2021-02-01: FY2020 EPS, the latest filed.
  - 76.7, known 2021-02-26: the FY2021 10-K was filed.
  - 76.5, known 2022-03-18: FY2021 EPS restated (1.73 post-split vs 6.90 pre-split, a rounding difference).
  - `factor_values_as_of('2021-02-01' / '2021-03-01' / today)` returns each in turn.
- **Split basis:** on 2021-08-02, after NVDA's 4:1 split, the stale EPS of 6.90 becomes 1.725 on the new basis. P/E stays continuous (about 114) instead of jumping 4×.
- **Different fiscal years:** NVDA's ends in January, AAPL's in September, MSFT's in June.
- **Dividends:** price return vs total return.

## Open
MCP client, demo questions, TTM EPS.
