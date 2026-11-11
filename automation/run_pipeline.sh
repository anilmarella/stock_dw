#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
TARGET="${TARGET:-dev}"

echo "==> ingest"
uv run python ingestion/ingest.py

echo "==> dbt build (target: $TARGET)"
cd transformation
uv run dbt build --select staging foundation marts --target "$TARGET" --threads 4
