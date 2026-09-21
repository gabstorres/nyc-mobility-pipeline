-- ============================================================
-- Q2: How is weather associated with taxi activity and trip behaviour?
--
-- Stage:     06 Analytics
-- Runs after: etl/05_gold/90_validate_gold.sql
-- Target:    `ftw-week-08`.`06-analytics`.trip_behavior_by_weather
-- Grain:     one row per weather condition and precipitation band
-- Source:    Gold only.
--
-- ASSOCIATION, NOT CAUSATION, and the weather series is one citywide
-- coordinate rather than a reading per zone (docs/data_model.md).
--
-- Two things decide whether this answer is honest:
--
-- 1. The denominator is COVERED HOURS, not trips. Raw trip counts across
--    conditions are not comparable, because conditions differ in how many
--    hours they occupied: 'overcast' looking busier than 'snow' may only mean
--    there were more overcast hours. trips_per_covered_hour is the comparable
--    measure.
--
-- 2. Hours with weather but NO trips are counted, not dropped. Starting from
--    the weather fact and left-joining trips keeps a zero-trip hour in the
--    denominator, which is the whole point when asking whether bad weather
--    suppresses activity.
--
-- 180 accepted trips have no weather match and are reported separately rather
-- than being distributed across conditions (D20).
-- ============================================================

CREATE SCHEMA IF NOT EXISTS `ftw-week-08`.`06-analytics`;

CREATE OR REPLACE TABLE `ftw-week-08`.`06-analytics`.trip_behavior_by_weather AS

-- Hours per classification, from the weather fact. This is the denominator and
-- it exists independently of whether any trip happened.
WITH covered_hours AS (
    SELECT
        weather_classification_key,
        COUNT(*) AS covered_hours,
        ROUND(AVG(temperature_2m_c), 2) AS avg_temperature_c,
        ROUND(SUM(precipitation_mm), 2) AS total_precipitation_mm
    FROM `ftw-week-08`.`05-gold`.fact_weather_hourly
    GROUP BY weather_classification_key
),

-- Trips per classification, aggregated separately and joined on the key.
-- Joining hours to trips row-by-row first would multiply every hour by its
-- trips and destroy both counts.
trips AS (
    SELECT
        pickup_weather_classification_key AS weather_classification_key,
        SUM(trip_count) AS trip_count,

        SUM(CASE WHEN NOT dropoff_before_pickup_flag
                  AND trip_duration_seconds > 0
                  AND trip_duration_seconds <= 86400
                 THEN trip_duration_seconds END) AS total_duration_seconds,
        COUNT_IF(NOT dropoff_before_pickup_flag
                 AND trip_duration_seconds > 0
                 AND trip_duration_seconds <= 86400) AS trips_with_eligible_duration,

        SUM(CASE WHEN NOT negative_trip_distance_flag
                 THEN trip_distance_miles END) AS total_trip_distance_miles,
        COUNT_IF(NOT negative_trip_distance_flag) AS trips_with_eligible_distance,

        SUM(CASE WHEN NOT negative_fare_amount_flag
                 THEN fare_amount_usd END) AS total_fare_amount_usd,
        COUNT_IF(NOT negative_fare_amount_flag) AS trips_with_eligible_fare
    FROM `ftw-week-08`.`05-gold`.fact_taxi_trip
    WHERE pickup_weather_classification_key IS NOT NULL
    GROUP BY pickup_weather_classification_key
)

SELECT
    c.weather_condition,
    c.precipitation_band,

    h.covered_hours,
    h.avg_temperature_c,
    h.total_precipitation_mm,

    COALESCE(t.trip_count, 0) AS trip_count,

    -- The comparable activity measure.
    ROUND(COALESCE(t.trip_count, 0) / NULLIF(h.covered_hours, 0), 2)
        AS trips_per_covered_hour,

    -- Every average is summed-measure over summed-eligible-trips.
    t.trips_with_eligible_duration,
    ROUND(t.total_duration_seconds / NULLIF(t.trips_with_eligible_duration, 0) / 60.0, 2)
        AS avg_trip_duration_minutes,

    t.trips_with_eligible_distance,
    ROUND(t.total_trip_distance_miles / NULLIF(t.trips_with_eligible_distance, 0), 3)
        AS avg_trip_distance_miles,

    t.trips_with_eligible_fare,
    ROUND(t.total_fare_amount_usd / NULLIF(t.trips_with_eligible_fare, 0), 2)
        AS avg_fare_amount_usd,

    DENSE_RANK() OVER (
        ORDER BY COALESCE(t.trip_count, 0) / NULLIF(h.covered_hours, 0) DESC
    ) AS activity_rank_by_trips_per_hour

-- Driven by the weather fact: a classification that occurred but saw no trips
-- is a real observation and keeps its row with trip_count = 0.
FROM covered_hours AS h
JOIN `ftw-week-08`.`05-gold`.dim_weather_classification AS c
    ON h.weather_classification_key = c.weather_classification_key
LEFT JOIN trips AS t
    ON h.weather_classification_key = t.weather_classification_key;


-- Trips excluded from the answer above, quantified rather than left implicit
-- (D20). weather_match_status carries the reason per trip.
CREATE OR REPLACE TABLE `ftw-week-08`.`06-analytics`.trip_weather_coverage AS
SELECT
    weather_match_status,
    SUM(trip_count) AS trip_count,
    ROUND(100.0 * SUM(trip_count)
          / SUM(SUM(trip_count)) OVER (), 4) AS pct_of_all_trips
FROM `ftw-week-08`.`05-gold`.fact_taxi_trip
GROUP BY weather_match_status;


SELECT
    (SELECT SUM(trip_count) FROM `ftw-week-08`.`06-analytics`.trip_behavior_by_weather)
        AS weather_attributed_trips,
    (SELECT SUM(trip_count) FROM `ftw-week-08`.`05-gold`.fact_taxi_trip)
        AS gold_trip_count,
    (SELECT SUM(covered_hours) FROM `ftw-week-08`.`06-analytics`.trip_behavior_by_weather)
        AS covered_hours,
    (SELECT COUNT(*) FROM `ftw-week-08`.`05-gold`.fact_weather_hourly)
        AS gold_weather_hours;
