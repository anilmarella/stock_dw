import json
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "raw"
STATE = ROOT / "data" / "ingest_state.json"
TICKERS = ROOT / "ingestion" / "tickers.txt"


def load_tickers():
    return [t.strip().upper() for t in TICKERS.read_text().splitlines() if t.strip()]


def http_session(headers):
    retry = Retry(total=5, backoff_factor=2, status_forcelist=[429, 500, 502, 503, 504])
    session = requests.Session()
    session.headers.update(headers)
    session.mount("https://", HTTPAdapter(max_retries=retry))
    return session


def load_state():
    return json.loads(STATE.read_text()) if STATE.exists() else {}


def save_state(state):
    STATE.write_text(json.dumps(state, indent=2, sort_keys=True))


def raw_files(source, dataset):
    return list((RAW / f"source={source}" / f"dataset={dataset}").glob("*/*.parquet"))


def write_raw(rows, source, dataset, name, ingested_at):
    out = RAW / f"source={source}" / f"dataset={dataset}" / f"ingest_date={ingested_at.date()}"
    out.mkdir(parents=True, exist_ok=True)
    path = out / f"{name}_{ingested_at:%H%M%S}.parquet"
    pq.write_table(pa.Table.from_pylist(rows), path)
    return path.relative_to(ROOT)
