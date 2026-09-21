-- ============================================================
-- Q1: When and where is recorded Green Taxi activity highest?
--
-- Stage:     06 Analytics
-- Runs after: etl/05_gold/90_validate_gold.sql
-- Target:    `ftw-week-08`.`06-analytics`.activity_by_time_and_zone
-- Grain:     one row per pickup date, hour of day and PICKUP zone
-- Source:    Gold only. Analytics never reads Silver or Bronze.
--
-- Pickup and drop-off are separate questions, so this dataset answers the
-- pickup side only; 30_mobility_patterns_by_zone reports both roles side by
-- side. Mixing them in one row would double-count a trip.
--
-- Trip count measures RECORDED activity and is a proxy for demand, not a
-- measurement of it (docs/data_model.md).
-- ============================================================

CREATE SCHEMA IF NOT EXISTS `ftw-week-08`.`06-analytics`;

CREATE OR REPLACE TABLE `ftw-week-08`.`06-analytics`.activity_by_time_and_zone AS

WITH trips AS (
    SELECT
        f.pickup_date_key,
        f.pickup_hour_key,
        f.pickup_zone_key,
        f.trip_count,
        f.trip_duration_seconds,
        f.trip_distance_miles,
        f.fare_amount_usd,
        -- Measure eligibility, per D15: a row with an implausible duration
        -- still counts as a trip, it just cannot contribute to the duration
        -- average. Excluding the whole row would understate trip counts.
        NOT f.dropoff_before_pickup_flag
            AND f.trip_duration_seconds > 0
            AND f.trip_duration_seconds <= 86400 AS duration_eligible,
        NOT f.negative_trip_distance_flag AS distance_eligible,
        NOT f.negative_fare_amount_flag   AS fare_eligible
    FROM `ftw-week-08`.`05-gold`.fact_taxi_trip AS f
)

SELECT
    d.full_date            AS pickup_date,
    d.day_of_week_name     AS pickup_day_of_week,
    d.weekend_flag         AS pickup_is_weekend,
    h.hour_of_day          AS pickup_hour,
    h.time_of_day_band     AS pickup_time_of_day_band,

    -- The zone columns are kept even when the zone is a sentinel, so unknown
    -- and outside-NYC activity stays visible and countable rather than being
    -- filtered out of the answer.
    z.zone_name            AS pickup_zone_name,
    z.borough              AS pickup_borough,
    z.service_zone         AS pickup_service_zone,
    z.zone_classification  AS pickup_zone_classification,

    SUM(t.trip_count) AS trip_count,

    -- Weighted from totals, never an average of averages: dividing summed
    -- measure by summed eligible trips gives every trip equal weight.
    SUM(CASE WHEN t.duration_eligible THEN t.trip_duration_seconds END)
        AS total_duration_seconds,
    COUNT_IF(t.duration_eligible) AS trips_with_eligible_duration,
    ROUND(SUM(CASE WHEN t.duration_eligible THEN t.trip_duration_seconds END)
          / NULLIF(COUNT_IF(t.duration_eligible), 0) / 60.0, 2) AS avg_trip_duration_minutes,

    SUM(CASE WHEN t.distance_eligible THEN t.trip_distance_miles END)
        AS total_trip_distance_miles,
    COUNT_IF(t.distance_eligible) AS trips_with_eligible_distance,
    ROUND(SUM(CASE WHEN t.distance_eligible THEN t.trip_distance_miles END)
          / NULLIF(COUNT_IF(t.distance_eligible), 0), 3) AS avg_trip_distance_miles,

    SUM(CASE WHEN t.fare_eligible THEN t.fare_amount_usd END)
        AS total_fare_amount_usd,
    COUNT_IF(t.fare_eligible) AS trips_with_eligible_fare,
    ROUND(SUM(CASE WHEN t.fare_eligible THEN t.fare_amount_usd END)
          / NULLIF(COUNT_IF(t.fare_eligible), 0), 2) AS avg_fare_amount_usd,

    -- DENSE_RANK, not ROW_NUMBER: two zones with the same trip count share a
    -- rank rather than one being put above the other arbitrarily.
    DENSE_RANK() OVER (ORDER BY SUM(t.trip_count) DESC) AS activity_rank_overall,
    DENSE_RANK() OVER (PARTITION BY h.hour_of_day ORDER BY SUM(t.trip_count) DESC)
        AS activity_rank_within_hour

FROM trips AS t
JOIN `ftw-week-08`.`05-gold`.dim_date AS d ON t.pickup_date_key = d.date_key
JOIN `ftw-week-08`.`05-gold`.dim_hour AS h ON t.pickup_hour_key = h.hour_key
-- LEFT JOIN on the zone: a trip whose zone key did not resolve still counts as
-- activity at that date and hour. It would silently vanish from the totals
-- under an inner join.
LEFT JOIN `ftw-week-08`.`05-gold`.dim_taxi_zone AS z ON t.pickup_zone_key = z.zone_key

GROUP BY
    d.full_date, d.day_of_week_name, d.weekend_flag,
    h.hour_of_day, h.time_of_day_band,
    z.zone_name, z.borough, z.service_zone, z.zone_classification;


-- Grain and reconciliation, reported at build time.
SELECT
    (SELECT SUM(trip_count) FROM `ftw-week-08`.`06-analytics`.activity_by_time_and_zone)
        AS analytics_trip_count,
    (SELECT SUM(trip_count) FROM `ftw-week-08`.`05-gold`.fact_taxi_trip)
        AS gold_trip_count,
    (SELECT COUNT(*) FROM `ftw-week-08`.`06-analytics`.activity_by_time_and_zone)
        AS result_rows,
    (SELECT COUNT_IF(pickup_zone_name IS NULL)
     FROM `ftw-week-08`.`06-analytics`.activity_by_time_and_zone)
        AS rows_with_unresolved_zone;
