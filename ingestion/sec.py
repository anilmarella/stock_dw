import logging
import os
import time
from datetime import datetime, timezone

import duckdb
import pyarrow.parquet as pq
import requests

from common import RAW, http_session, load_state, raw_files, save_state, write_raw

log = logging.getLogger("sec")


def session():
    return http_session({"User-Agent": os.environ["SEC_USER_AGENT"]})


def load_ciks():
    ciks = {}
    for f in raw_files("sec", "company_tickers"):
        for r in pq.read_table(f, columns=["ticker", "cik"]).to_pylist():
            ciks[r["ticker"]] = r["cik"]
    return ciks


def known_accessions():
    if not raw_files("sec", "companyfacts"):
        return {}
    glob = RAW / "source=sec" / "dataset=companyfacts" / "*" / "*.parquet"
    seen = {}
    for cik, accn in duckdb.sql(f"SELECT DISTINCT cik, accn FROM read_parquet('{glob}')").fetchall():
        seen.setdefault(cik, set()).add(accn)
    return seen


def ingest_ciks(tickers):
    known = load_ciks()
    new = [t for t in tickers if t not in known]
    if not new:
        log.info("CIKs already known for all tickers")
        return 0
    try:
        resp = session().get("https://www.sec.gov/files/company_tickers.json", timeout=60)
        resp.raise_for_status()
    except requests.RequestException as e:
        log.error("ticker list fetch failed: %s", e)
        return 1
    sec = {r["ticker"]: r for r in resp.json().values()}
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
    return 0


def ingest_fundamentals(tickers):
    today = datetime.now(timezone.utc).date().isoformat()
    state = load_state()
    done = state.setdefault("sec_companyfacts", {})
    todo = [t for t in tickers if done.get(t) != today]
    log.info("companyfacts: %d to fetch, %d already fetched today", len(todo), len(tickers) - len(todo))
    if not todo:
        return 0

    ciks = load_ciks()
    seen = known_accessions()
    http = session()
    ingested_at = datetime.now(timezone.utc)
    failures = 0
    for ticker in todo:
        if ticker not in ciks:
            log.warning("%s: no CIK, skipping fundamentals", ticker)
            continue
        cik = ciks[ticker]
        time.sleep(0.2)
        try:
            resp = http.get(f"https://data.sec.gov/api/xbrl/companyfacts/CIK{cik:010d}.json", timeout=60)
            if resp.status_code == 404:
                log.info("%s: no company financials on SEC (fund?), skipping", ticker)
                done[ticker] = today
                save_state(state)
                continue
            resp.raise_for_status()
            data = resp.json()
        except requests.RequestException as e:
            log.error("%s: companyfacts fetch failed: %s", ticker, e)
            failures += 1
            continue

        old = seen.get(cik, set())
        rows = []
        for taxonomy, concepts in data.get("facts", {}).items():
            for concept, body in concepts.items():
                for unit, facts in body["units"].items():
                    for f in facts:
                        if f["accn"] in old:
                            continue
                        rows.append({
                            "cik": cik, "ticker": ticker,
                            "taxonomy": taxonomy, "concept": concept, "unit": unit,
                            "start": f.get("start"), "end": f["end"], "val": float(f["val"]),
                            "accn": f["accn"], "fy": f.get("fy"), "fp": f.get("fp"),
                            "form": f.get("form"), "filed": f["filed"], "frame": f.get("frame"),
                            "ingested_at": ingested_at,
                        })
        if rows:
            filings = len({r["accn"] for r in rows})
            path = write_raw(rows, "sec", "companyfacts", ticker, ingested_at)
            log.info("%s: %d new facts from %d new filings -> %s", ticker, len(rows), filings, path)
        else:
            log.info("%s: no new filings", ticker)
        done[ticker] = today
        save_state(state)
    return failures
