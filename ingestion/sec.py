import logging
import os
import time
from datetime import datetime, timezone

import pyarrow.parquet as pq
import requests

from common import raw_files, write_raw

log = logging.getLogger("sec")


def get(url):
    resp = requests.get(url, headers={"User-Agent": os.environ["SEC_USER_AGENT"]}, timeout=60)
    resp.raise_for_status()
    return resp.json()


def load_ciks():
    ciks = {}
    for f in raw_files("sec", "company_tickers"):
        for r in pq.read_table(f, columns=["ticker", "cik"]).to_pylist():
            ciks[r["ticker"]] = r["cik"]
    return ciks


def ingest_ciks(tickers):
    known = load_ciks()
    new = [t for t in tickers if t not in known]
    if not new:
        log.info("CIKs already known for all tickers")
        return
    sec = {r["ticker"]: r for r in get("https://www.sec.gov/files/company_tickers.json").values()}
    ingested_at = datetime.now(timezone.utc)
    rows = []
    for t in new:
        if t not in sec:
            log.warning("%s: not in SEC ticker list, no CIK", t)
            continue
        rows.append({"ticker": t, "cik": sec[t]["cik_str"], "name": sec[t]["title"], "ingested_at": ingested_at})
    if rows:
        path = write_raw(rows, "sec", "company_tickers", "ciks", ingested_at)
        log.info("CIKs for %d new tickers -> %s", len(rows), path)


def ingest_fundamentals(tickers):
    ciks = load_ciks()
    ingested_at = datetime.now(timezone.utc)
    for ticker in tickers:
        if ticker not in ciks:
            log.warning("%s: no CIK, skipping fundamentals", ticker)
            continue
        try:
            data = get(f"https://data.sec.gov/api/xbrl/companyfacts/CIK{ciks[ticker]:010d}.json")
        except requests.HTTPError as e:
            log.error("%s: companyfacts fetch failed: %s", ticker, e)
            continue
        rows = []
        for taxonomy, concepts in data.get("facts", {}).items():
            for concept, body in concepts.items():
                for unit, facts in body["units"].items():
                    for f in facts:
                        rows.append({
                            "cik": ciks[ticker], "ticker": ticker,
                            "taxonomy": taxonomy, "concept": concept, "unit": unit,
                            "start": f.get("start"), "end": f["end"], "val": float(f["val"]),
                            "accn": f["accn"], "fy": f.get("fy"), "fp": f.get("fp"),
                            "form": f.get("form"), "filed": f["filed"], "frame": f.get("frame"),
                            "ingested_at": ingested_at,
                        })
        if not rows:
            log.warning("%s: no facts in companyfacts", ticker)
            continue
        path = write_raw(rows, "sec", "companyfacts", ticker, ingested_at)
        log.info("%s: %d facts -> %s", ticker, len(rows), path)
        time.sleep(0.2)
