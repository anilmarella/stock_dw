-- Every SEC XBRL fact from 10-K and 10-Q filings (and amendments), one row per fact per filing.
-- Building block: datasets like ds_eps pull one concept out of it and format it.
-- Incremental: reads rows ingested since the last run and appends facts not stored yet.
-- Repeats from daily SEC pulls collapse to the first one ingested.
{{ config(materialized='incremental', incremental_strategy='append') }}

WITH new_facts AS (
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
    {% if is_incremental() %}
        WHERE ingested_at > (SELECT MAX(ingested_at) FROM {{ this }})
    {% endif %}
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY cik, taxonomy, concept, unit, period_start, period_end, accession_no
        ORDER BY ingested_at
    ) = 1
)

SELECT *
FROM new_facts
{% if is_incremental() %}
    WHERE NOT EXISTS (
        SELECT 1
        FROM {{ this }} AS old
        WHERE
            old.cik = new_facts.cik
            AND old.accession_no = new_facts.accession_no
            AND old.taxonomy = new_facts.taxonomy
            AND old.concept = new_facts.concept
            AND old.unit = new_facts.unit
            AND old.period_start IS NOT DISTINCT FROM new_facts.period_start
            AND old.period_end = new_facts.period_end
    )
{% endif %}
