SELECT
    cik,
    ticker,
    taxonomy,
    concept,
    unit,
    CAST(start AS DATE) AS period_start,
    CAST("end" AS DATE) AS period_end,
    CAST("end" AS DATE) AS about_date,
    val AS fact_value,
    accn AS accession_no,
    fy AS fiscal_year,
    fp AS fiscal_period,
    form,
    CAST(filed AS DATE) AS filed_date,
    CAST(filed AS DATE) AS known_as_of,
    frame,
    ingested_at,
    ingest_date
FROM
    READ_PARQUET(
        '{{ var("raw_path") }}/source=sec/dataset=companyfacts/*/*.parquet',
        hive_partitioning = TRUE, union_by_name = TRUE
    )
WHERE form IN ('10-K', '10-Q', '10-K/A', '10-Q/A')
