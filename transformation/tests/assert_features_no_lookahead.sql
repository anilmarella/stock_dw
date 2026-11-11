-- Fails if any feature row uses a filing made after its date.
SELECT *
FROM {{ ref('mart_daily_features') }}
WHERE eps_filed_date > about_date OR shares_filed_date > about_date
