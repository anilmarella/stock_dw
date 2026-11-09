from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "raw"
TICKERS = ROOT / "ingestion" / "tickers.txt"


def load_tickers():
    return [t.strip().upper() for t in TICKERS.read_text().splitlines() if t.strip()]


def raw_files(source, dataset):
    return list((RAW / f"source={source}" / f"dataset={dataset}").glob("*/*.parquet"))


def write_raw(rows, source, dataset, name, ingested_at):
    out = RAW / f"source={source}" / f"dataset={dataset}" / f"ingest_date={ingested_at.date()}"
    out.mkdir(parents=True, exist_ok=True)
    path = out / f"{name}_{ingested_at:%H%M%S}.parquet"
    pq.write_table(pa.Table.from_pylist(rows), path)
    return path.relative_to(ROOT)
