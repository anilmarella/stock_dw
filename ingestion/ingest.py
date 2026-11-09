import logging
import os
from datetime import date, datetime, timezone
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq
import requests
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "raw"
TICKERS = ROOT / "ingestion" / "tickers.txt"
HISTORY_START = "2010-01-01"

log = logging.getLogger("ingest")


def load_tickers():
    return [t.strip().upper() for t in TICKERS.read_text().splitlines() if t.strip()]


def known_cik_tickers():
    files = list((RAW / "source=sec" / "dataset=company_tickers").glob("*/*.parquet"))
    if not files:
        return set()
    return {t for f in files for t in pq.read_table(f, columns=["ticker"])["ticker"].to_pylist()}


def ingest_ciks(tickers):
    new = [t for t in tickers if t not in known_cik_tickers()]
    if not new:
        log.info("CIKs already known for all tickers")
        return
    resp = requests.get(
        "https://www.sec.gov/files/company_tickers.json",
        headers={"User-Agent": os.environ["SEC_USER_AGENT"]},
        timeout=30,
    )
    resp.raise_for_status()
    sec = {r["ticker"]: r for r in resp.json().values()}
    ingested_at = datetime.now(timezone.utc)
    rows = []
    for t in new:
        if t not in sec:
            log.warning("%s: not in SEC ticker list, no CIK", t)
            continue
        rows.append({"ticker": t, "cik": sec[t]["cik_str"], "name": sec[t]["title"], "ingested_at": ingested_at})
    if rows:
        path = write_raw(rows, "sec", "company_tickers", f"ciks_{ingested_at:%H%M%S}", ingested_at)
        log.info("CIKs for %d new tickers -> %s", len(rows), path.relative_to(ROOT))


def fetch_prices(ticker, start, end):
    resp = requests.get(
        f"https://api.tiingo.com/tiingo/daily/{ticker}/prices",
        params={"startDate": start, "endDate": end, "format": "json"},
        headers={"Authorization": f"Token {os.environ['TIINGO_API_KEY']}"},
        timeout=30,
    )
    resp.raise_for_status()
    return resp.json()


def write_raw(rows, source, dataset, name, ingested_at):
    out = RAW / f"source={source}" / f"dataset={dataset}" / f"ingest_date={ingested_at.date()}"
    out.mkdir(parents=True, exist_ok=True)
    path = out / f"{name}.parquet"
    pq.write_table(pa.Table.from_pylist(rows), path)
    return path


def ingest_prices(tickers, start, end):
    ingested_at = datetime.now(timezone.utc)
    for ticker in tickers:
        try:
            rows = fetch_prices(ticker, start, end)
        except requests.HTTPError as e:
            log.error("%s: fetch failed: %s", ticker, e)
            continue
        if not rows:
            log.warning("%s: no rows for %s..%s", ticker, start, end)
            continue
        for r in rows:
            r["ticker"] = ticker
            r["ingested_at"] = ingested_at
        path = write_raw(rows, "tiingo", "prices", ticker, ingested_at)
        log.info("%s: %d rows -> %s", ticker, len(rows), path.relative_to(ROOT))


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    load_dotenv(ROOT / ".env")
    tickers = load_tickers()
    log.info("%d tickers in registry", len(tickers))
    ingest_ciks(tickers)
    ingest_prices(tickers, HISTORY_START, date.today().isoformat())
