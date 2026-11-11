SELECT
    ticker,
    CAST(LEFT(date, 10) AS DATE) AS about_date,
    open,
    high,
    low,
    close,
    volume,
    divcash AS dividend_cash,
    splitfactor AS split_factor,
    ingested_at,
    ingest_date
FROM READ_PARQUET(
    '{{ var("raw_path") }}/source=tiingo/dataset=prices/*/*.parquet',
    hive_partitioning = TRUE, union_by_name = TRUE
)
