import logging
import os
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import pyarrow.parquet as pq
import requests

from common import http_session, load_state, raw_files, save_state, write_raw

HISTORY_START = date(2010, 1, 1)
LOOKBACK_DAYS = 7
CLOSE_CUTOFF_HOUR_ET = 18

log = logging.getLogger("tiingo")


def last_complete_day():
    now = datetime.now(ZoneInfo("America/New_York"))
    return now.date() if now.hour >= CLOSE_CUTOFF_HOUR_ET else now.date() - timedelta(days=1)


def last_price_dates():
    last = {}
    for f in raw_files("tiingo", "prices"):
        t = pq.read_table(f, columns=["ticker", "date"])
        d = date.fromisoformat(max(t["date"].to_pylist())[:10])
        ticker = t["ticker"][0].as_py()
        last[ticker] = max(last.get(ticker, d), d)
    return last


def ingest_prices(tickers):
    end = last_complete_day()
    state = load_state()
    done = state.setdefault("tiingo_prices", {})
    todo = [t for t in tickers if done.get(t) != end.isoformat()]
    log.info("prices up to %s: %d to fetch, %d already done", end, len(todo), len(tickers) - len(todo))
    if not todo:
        return 0

    session = http_session({"Authorization": f"Token {os.environ['TIINGO_API_KEY']}"})
    last = last_price_dates()
    ingested_at = datetime.now(timezone.utc)
    failures = 0
    for ticker in todo:
        if ticker in last:
            start = last[ticker] - timedelta(days=LOOKBACK_DAYS)
        else:
            start = HISTORY_START
            log.info("%s: new ticker, backfilling from %s", ticker, start)
        try:
            resp = session.get(
                f"https://api.tiingo.com/tiingo/daily/{ticker}/prices",
                params={"startDate": start.isoformat(), "endDate": end.isoformat(), "format": "json"},
                timeout=30,
            )
            resp.raise_for_status()
            rows = resp.json()
        except requests.RequestException as e:
            log.error("%s: fetch failed: %s", ticker, e)
            failures += 1
            continue
        if rows:
            for r in rows:
                r["ticker"] = ticker
                r["ingested_at"] = ingested_at
            path = write_raw(rows, "tiingo", "prices", ticker, ingested_at)
            log.info("%s: %d rows (%s..%s) -> %s", ticker, len(rows), start, end, path)
        else:
            log.warning("%s: no rows for %s..%s", ticker, start, end)
        done[ticker] = end.isoformat()
        save_state(state)
    return failures
