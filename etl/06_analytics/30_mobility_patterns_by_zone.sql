-- ============================================================
-- Q3: Which areas show the strongest mobility patterns?
--
-- Stage:     06 Analytics
-- Runs after: etl/05_gold/90_validate_gold.sql
-- Target:    `ftw-week-08`.`06-analytics`.mobility_patterns_by_zone
-- Grain:     one row per Taxi Zone
-- Source:    Gold only.
--
-- Pickup and drop-off stay SEPARATE measures on one zone row. A trip
-- contributes one pickup to its origin zone and one drop-off to its
-- destination; adding them into a single "activity" figure would count the
-- same trip twice and reward zones that are merely passed through.
--
-- Each role is counted from its own aggregate and joined on zone_key, rather
-- than joined row-by-row first, which would multiply one role by the other.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS `ftw-week-08`.`06-analytics`;

CREATE OR REPLACE TABLE `ftw-week-08`.`06-analytics`.mobility_patterns_by_zone AS

WITH pickups AS (
    SELECT
        pickup_zone_key AS zone_key,
        SUM(trip_count) AS pickup_count,

        SUM(CASE WHEN NOT dropoff_before_pickup_flag
                  AND trip_duration_seconds > 0
                  AND trip_duration_seconds <= 86400
                 THEN trip_duration_seconds END) AS pickup_total_duration_seconds,
        COUNT_IF(NOT dropoff_before_pickup_flag
                 AND trip_duration_seconds > 0
                 AND trip_duration_seconds <= 86400) AS pickup_trips_eligible_duration,

        SUM(CASE WHEN NOT negative_trip_distance_flag
                 THEN trip_distance_miles END) AS pickup_total_distance_miles,
        COUNT_IF(NOT negative_trip_distance_flag) AS pickup_trips_eligible_distance,

        SUM(CASE WHEN NOT negative_fare_amount_flag
                 THEN fare_amount_usd END) AS pickup_total_fare_usd,
        COUNT_IF(NOT negative_fare_amount_flag) AS pickup_trips_eligible_fare,

        COUNT(DISTINCT pickup_date_key) AS pickup_active_days
    FROM `ftw-week-08`.`05-gold`.fact_taxi_trip
    GROUP BY pickup_zone_key
),

dropoffs AS (
    SELECT
        dropoff_zone_key AS zone_key,
        SUM(trip_count) AS dropoff_count
    FROM `ftw-week-08`.`05-gold`.fact_taxi_trip
    GROUP BY dropoff_zone_key
)

SELECT
    z.zone_name,
    z.borough,
    z.service_zone,
    z.zone_classification,

    COALESCE(p.pickup_count, 0)  AS pickup_count,
    COALESCE(d.dropoff_count, 0) AS dropoff_count,

    -- Net flow and balance describe the zone's ROLE, which is what "mobility
    -- pattern" means here: a commuter origin and a destination can carry the
    -- same total volume while behaving nothing alike.
    COALESCE(d.dropoff_count, 0) - COALESCE(p.pickup_count, 0) AS net_arrivals,
    ROUND(COALESCE(p.pickup_count, 0)
          / NULLIF(COALESCE(p.pickup_count, 0) + COALESCE(d.dropoff_count, 0), 0), 4)
        AS pickup_share_of_zone_activity,

    -- Trip behaviour is measured on trips STARTING here, so it describes
    -- journeys the zone originates rather than ones it receives.
    --
    -- The totals are published alongside each average, not just used to
    -- compute it: the denominator is then visible to a reader, and the
    -- Analytics gate can verify the average really is summed measure over
    -- summed eligible trips rather than an average of averages.
    p.pickup_total_duration_seconds,
    p.pickup_trips_eligible_duration,
    ROUND(p.pickup_total_duration_seconds
          / NULLIF(p.pickup_trips_eligible_duration, 0) / 60.0, 2) AS avg_trip_duration_minutes,

    p.pickup_total_distance_miles,
    p.pickup_trips_eligible_distance,
    ROUND(p.pickup_total_distance_miles
          / NULLIF(p.pickup_trips_eligible_distance, 0), 3) AS avg_trip_distance_miles,

    p.pickup_total_fare_usd,
    p.pickup_trips_eligible_fare,
    ROUND(p.pickup_total_fare_usd
          / NULLIF(p.pickup_trips_eligible_fare, 0), 2) AS avg_fare_amount_usd,

    p.pickup_active_days,
    ROUND(COALESCE(p.pickup_count, 0) / NULLIF(p.pickup_active_days, 0), 2)
        AS avg_pickups_per_active_day,

    DENSE_RANK() OVER (ORDER BY COALESCE(p.pickup_count, 0) DESC)  AS pickup_rank,
    DENSE_RANK() OVER (ORDER BY COALESCE(d.dropoff_count, 0) DESC) AS dropoff_rank

-- Driven by the dimension: a zone with no recorded activity in the window is a
-- real answer to "which areas are strongest" and keeps its row at zero.
FROM `ftw-week-08`.`05-gold`.dim_taxi_zone AS z
LEFT JOIN pickups  AS p ON z.zone_key = p.zone_key
LEFT JOIN dropoffs AS d ON z.zone_key = d.zone_key;


SELECT
    (SELECT SUM(pickup_count)  FROM `ftw-week-08`.`06-analytics`.mobility_patterns_by_zone)
        AS analytics_pickups,
    (SELECT SUM(dropoff_count) FROM `ftw-week-08`.`06-analytics`.mobility_patterns_by_zone)
        AS analytics_dropoffs,
    (SELECT SUM(trip_count) FROM `ftw-week-08`.`05-gold`.fact_taxi_trip)
        AS gold_trip_count,
    (SELECT COUNT_IF(pickup_count = 0 AND dropoff_count = 0)
     FROM `ftw-week-08`.`06-analytics`.mobility_patterns_by_zone)
        AS zones_with_no_activity;
