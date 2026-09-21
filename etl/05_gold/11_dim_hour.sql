-- Gold dimension: dim_hour (issue #36). Hour-of-day seed dimension -- a
-- fixed, constant 24-row domain, independent of any Bronze/Silver data.
-- Full rebuild (CREATE OR REPLACE): nothing here can ever need history.
--
-- Grain: one row per hour of the local day (0-23).
-- SCD: Type 0 / full rebuild -- static reference data.
CREATE OR REPLACE TABLE `ftw-week-08`.`05-gold`.dim_hour AS
WITH hour_seed AS (
    SELECT explode(sequence(0, 23)) AS hour_of_day
)
SELECT
    hour_of_day AS hour_key, -- deterministic PK, equal to hour_of_day per mapping doc
    hour_of_day,
    concat(lpad(CAST(hour_of_day AS STRING), 2, '0'), ':00') AS hour_label,
    CASE
        WHEN hour_of_day BETWEEN 0 AND 5  THEN 'overnight'
        WHEN hour_of_day BETWEEN 6 AND 11 THEN 'morning'
        WHEN hour_of_day BETWEEN 12 AND 17 THEN 'afternoon'
        ELSE 'evening' -- 18-23
    END AS time_of_day_band
FROM hour_seed;
