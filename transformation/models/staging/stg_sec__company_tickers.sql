SELECT
    ticker,
    cik,
    name,
    ingested_at,
    ingest_date
FROM READ_PARQUET(
    '{{ var("raw_path") }}/source=sec/dataset=company_tickers/*/*.parquet',
    hive_partitioning = TRUE, union_by_name = TRUE
)
