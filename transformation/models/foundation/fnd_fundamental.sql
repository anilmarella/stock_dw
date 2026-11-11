-- One row per fact per filing. Repeats from daily SEC pulls collapse to the first one ingested.
SELECT
    {{ security_key('cik') }} AS security_key,
    cik,
    taxonomy,
    concept,
    unit,
    period_start,
    period_end,
    about_date,
    fact_value,
    accession_no,
    fiscal_year,
    fiscal_period,
    form,
    filed_date,
    known_as_of,
    frame,
    ingested_at
FROM {{ ref('stg_sec__companyfacts') }}
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY cik, taxonomy, concept, unit, period_start, period_end, accession_no
    ORDER BY ingested_at
) = 1
