-- Gold dimension: dim_date (issue #36). Calendar seed dimension.
--
-- Grain: one row per NYC-local calendar date.
--
-- SCD: Type 0 / full rebuild.
--
-- Deterministic rebuild per D12 and data_model.md.
-- The dimension must cover:
--   1. The approved reporting window (2026-03-01 through 2026-05-31)
--   2. Every retained observed trip date
--
-- The approved reporting window is seeded explicitly so the dimension
-- remains valid even if Silver data is incomplete or temporarily empty.
--
-- No unknown member is created (D12).

CREATE OR REPLACE TABLE `ftw-week-08`.`05-gold`.dim_date AS

WITH date_candidates AS (

    -- Required reporting window boundaries
    SELECT DATE '2026-03-01' AS full_date

    UNION ALL

    SELECT DATE '2026-05-31' AS full_date

    UNION ALL

    SELECT CAST(pickup_datetime_local AS DATE) AS full_date
    FROM `ftw-week-08`.`03-silver`.green_taxi_clean
    WHERE pickup_datetime_local IS NOT NULL

    UNION ALL

    SELECT CAST(dropoff_datetime_local AS DATE) AS full_date
    FROM `ftw-week-08`.`03-silver`.green_taxi_clean
    WHERE dropoff_datetime_local IS NOT NULL
),

date_bounds AS (
    SELECT
        MIN(full_date) AS min_date,
        MAX(full_date) AS max_date
    FROM date_candidates
),

calendar_seed AS (
    SELECT EXPLODE(
        SEQUENCE(
            min_date,
            max_date,
            INTERVAL 1 DAY
        )
    ) AS full_date
    FROM date_bounds
),

calendar_enriched AS (
    SELECT
        full_date,
        WEEKDAY(full_date) + 1 AS day_of_week_number
    FROM calendar_seed
)

SELECT
    CAST(DATE_FORMAT(full_date, 'yyyyMMdd') AS INT) AS date_key,
    full_date,
    YEAR(full_date) AS calendar_year,
    QUARTER(full_date) AS calendar_quarter,
    MONTH(full_date) AS month_number,
    DATE_FORMAT(full_date, 'MMMM') AS month_name,
    DAY(full_date) AS day_of_month,
    day_of_week_number,
    DATE_FORMAT(full_date, 'EEEE') AS day_of_week_name,
    day_of_week_number IN (6, 7) AS weekend_flag
FROM calendar_enriched;