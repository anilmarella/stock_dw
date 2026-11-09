# Design

## Goal
~30 well-known US stocks + SPY, 15 years of daily history, then daily updates.
Descriptive analytics only. Runs locally. Free data and tools.

## Point-in-time rules
- Every row has `about_date` (what day it describes), `known_as_of` (when the world knew it) and `ingested_at` (when we got it).
- Raw data is append-only. Corrections arrive as new versions.
- Queries take an `as_of` date and only see rows with `known_as_of <= as_of`.

## Sources
- **Tiingo**: raw daily prices, split factor, dividends. Free API key.
- **SEC EDGAR companyfacts**: fundamentals. The `filed` date is `known_as_of`. Needs a User-Agent with contact info.

## Identity
- `ingestion/tickers.txt` is the only hand-edited list.
- Ingestion fetches each new ticker's CIK from SEC (`company_tickers.json`).
- dbt builds `dim_security`: surrogate `security_key`, `ticker`, `cik`, `name`. CIK joins prices to fundamentals.
- No ticker history for now (FB → META). Add later if needed.

## Layers
1. `ingestion/`: Python pulls → Parquet in `data/raw/source=<src>/dataset=<ds>/ingest_date=<date>/`
2. `transformation/`: dbt-duckdb (staging → point-in-time core → features) → `data/warehouse.duckdb`
3. `serving/`: MCP server, dashboards. Read-only.
4. `cli.py`: `stockdw` command (add-ticker, ingest, build, add-feature). Calls the layers; no logic of its own.

`data/` is gitignored. One `pyproject.toml` (uv, Python 3.12). Ticker list lives only in `ingestion/tickers.txt`.

## Adjusted prices
Computed from raw prices + split/dividend events known as of the query date. Never written over raw prices.

## Features
- YAML config using a few templates (return, volatility, drawdown, ratio) plus custom SQL.
- Versioned by name + version.
- One dbt test checks that no feature uses data from the future.

## AI layer
Local MCP server. Read-only DuckDB connection. Every tool takes `as_of`.

## Demo
Questions where naive data gives the wrong answer:
- NVDA price before the 2024 split
- P/E before the 10-K was filed
- Restated earnings

## Stack notes
Python 3.12 via uv (dbt may not support 3.14 yet).

## Open
MCP client, build staging, feature list, demo questions.
