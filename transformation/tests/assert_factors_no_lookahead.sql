-- A value can't be known before the day it describes.
SELECT *
FROM {{ ref('mart_factor_value') }}
WHERE known_as_of < about_date
