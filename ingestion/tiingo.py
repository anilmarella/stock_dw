import logging
import os
from datetime import date, datetime, timedelta, timezone

import pyarrow.parquet as pq
import requests

from common import raw_files, write_raw

HISTORY_START = date(2010, 1, 1)
LOOKBACK_DAYS = 7

log = logging.getLogger("tiingo")


def last_price_dates():
    last = {}
    for f in raw_files("tiingo", "prices"):
        t = pq.read_table(f, columns=["ticker", "date"])
        d = date.fromisoformat(max(t["date"].to_pylist())[:10])
        ticker = t["ticker"][0].as_py()
        last[ticker] = max(last.get(ticker, d), d)
    return last


def fetch_prices(ticker, start, end):
    resp = requests.get(
        f"https://api.tiingo.com/tiingo/daily/{ticker}/prices",
        params={"startDate": start.isoformat(), "endDate": end.isoformat(), "format": "json"},
        headers={"Authorization": f"Token {os.environ['TIINGO_API_KEY']}"},
        timeout=30,
    )
    resp.raise_for_status()
    return resp.json()


def ingest_prices(tickers):
    last = last_price_dates()
    today = date.today()
    ingested_at = datetime.now(timezone.utc)
    for ticker in tickers:
        if ticker in last:
            start = last[ticker] - timedelta(days=LOOKBACK_DAYS)
        else:
            start = HISTORY_START
            log.info("%s: new ticker, backfilling from %s", ticker, start)
        try:
            rows = fetch_prices(ticker, start, today)
        except requests.HTTPError as e:
            log.error("%s: fetch failed: %s", ticker, e)
            continue
        if not rows:
            log.warning("%s: no rows for %s..%s", ticker, start, today)
            continue
        for r in rows:
            r["ticker"] = ticker
            r["ingested_at"] = ingested_at
        path = write_raw(rows, "tiingo", "prices", ticker, ingested_at)
        log.info("%s: %d rows (%s..%s) -> %s", ticker, len(rows), start, today, path)
