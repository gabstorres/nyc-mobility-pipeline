-- ============================================================
-- Analytics gate
--
-- Stage:     06 Analytics validation
-- Runs after: the three analytics datasets
-- Target:    `ftw-week-08`.`01-control`.data_quality_results
-- Grain:     one row per check per run
-- Contract:  docs/validation.md (shared result contract, D17)
--
-- Dashboards use validated Analytics results only.
--
-- The spot checks recompute a single cell straight from fact_taxi_trip and
-- compare it with what the dataset published. That is the hand-calculation
-- the acceptance evidence asks for, written so it reruns on every load
-- instead of being done once by hand and trusted afterwards.
-- ============================================================

-- The Gold gate reports one dataset per table, not a single 'gold' dataset, so
-- this requires at least one Gold row to exist and none of them to be failing.
-- Zero rows means the gate never ran, which is not the same as passing.
SELECT CASE
         WHEN (SELECT COUNT(*) FROM `ftw-week-08`.`01-control`.gate_status
               WHERE layer = 'gold') = 0
           OR (SELECT COUNT_IF(status = 'FAIL') FROM `ftw-week-08`.`01-control`.gate_status
               WHERE layer = 'gold') > 0
         THEN raise_error('Analytics requires a passing Gold gate for every Gold dataset')
       END;

DECLARE OR REPLACE VARIABLE dq_run_id STRING;
SET VARIABLE dq_run_id = uuid();

DECLARE OR REPLACE VARIABLE code_revision STRING;
SET VARIABLE code_revision = 'UNSET';

-- Ownership is reference data, not code. It lives in gate_owners so that
-- reassigning an owner is an UPDATE, not a code change plus a review and a
-- deploy. NULL until that table is populated -- honestly unknown beats a
-- name checked into source that nobody remembers to change.
DECLARE OR REPLACE VARIABLE gate_owner STRING;
SET VARIABLE gate_owner = (
    SELECT owner
    FROM `ftw-week-08`.`01-control`.gate_owners
    WHERE layer = 'analytics' AND dataset = 'business_questions'
);


INSERT INTO `ftw-week-08`.`01-control`.data_quality_results

WITH gold AS (
    SELECT
        SUM(trip_count) AS gold_trips,
        SUM(CASE WHEN pickup_weather_classification_key IS NOT NULL
                 THEN trip_count END) AS gold_weather_attributed_trips
    FROM `ftw-week-08`.`05-gold`.fact_taxi_trip
),

q1 AS (SELECT * FROM `ftw-week-08`.`06-analytics`.activity_by_time_and_zone),
q2 AS (SELECT * FROM `ftw-week-08`.`06-analytics`.trip_behavior_by_weather),
q3 AS (SELECT * FROM `ftw-week-08`.`06-analytics`.mobility_patterns_by_zone),

-- ---- spot check 1: one date / hour / zone cell, recomputed from the fact ----
-- The busiest published cell is chosen deterministically so the check targets
-- the same row on every run rather than an arbitrary one.
q1_target AS (
    SELECT pickup_date, pickup_hour, pickup_zone_name, trip_count AS published_trips
    FROM q1
    ORDER BY trip_count DESC, pickup_date, pickup_hour, pickup_zone_name
    LIMIT 1
),
q1_recomputed AS (
    SELECT
        tgt.published_trips,
        SUM(f.trip_count) AS recomputed_trips
    FROM q1_target AS tgt
    JOIN `ftw-week-08`.`05-gold`.fact_taxi_trip AS f
      ON TRUE
    JOIN `ftw-week-08`.`05-gold`.dim_date AS d ON f.pickup_date_key = d.date_key
    JOIN `ftw-week-08`.`05-gold`.dim_hour AS h ON f.pickup_hour_key = h.hour_key
    LEFT JOIN `ftw-week-08`.`05-gold`.dim_taxi_zone AS z ON f.pickup_zone_key = z.zone_key
    WHERE d.full_date = tgt.pickup_date
      AND h.hour_of_day = tgt.pickup_hour
      AND z.zone_name <=> tgt.pickup_zone_name
    GROUP BY tgt.published_trips
),

-- ---- spot check 2: one weather classification, recomputed ----
q2_target AS (
    SELECT weather_condition, precipitation_band, trip_count AS published_trips, covered_hours
    FROM q2
    ORDER BY trip_count DESC, weather_condition, precipitation_band
    LIMIT 1
),
-- Trips and hours are recomputed as two separate aggregates and joined. A
-- correlated scalar subquery for the hours alongside SUM() is not resolvable
-- in Spark: it is neither grouped nor aggregated.
q2_recomputed_trips AS (
    SELECT
        tgt.weather_condition,
        tgt.precipitation_band,
        tgt.published_trips,
        tgt.covered_hours,
        SUM(f.trip_count) AS recomputed_trips
    FROM q2_target AS tgt
    JOIN `ftw-week-08`.`05-gold`.dim_weather_classification AS c
      ON c.weather_condition  = tgt.weather_condition
     AND c.precipitation_band = tgt.precipitation_band
    JOIN `ftw-week-08`.`05-gold`.fact_taxi_trip AS f
      ON f.pickup_weather_classification_key = c.weather_classification_key
    GROUP BY tgt.weather_condition, tgt.precipitation_band,
             tgt.published_trips, tgt.covered_hours
),

q2_recomputed_hours AS (
    SELECT
        tgt.weather_condition,
        tgt.precipitation_band,
        COUNT(*) AS recomputed_hours
    FROM q2_target AS tgt
    JOIN `ftw-week-08`.`05-gold`.dim_weather_classification AS c
      ON c.weather_condition  = tgt.weather_condition
     AND c.precipitation_band = tgt.precipitation_band
    JOIN `ftw-week-08`.`05-gold`.fact_weather_hourly AS w
      ON w.weather_classification_key = c.weather_classification_key
    GROUP BY tgt.weather_condition, tgt.precipitation_band
),

q2_recomputed AS (
    SELECT
        t.published_trips,
        t.covered_hours,
        t.recomputed_trips,
        h.recomputed_hours
    FROM q2_recomputed_trips AS t
    JOIN q2_recomputed_hours AS h
      ON t.weather_condition  = h.weather_condition
     AND t.precipitation_band = h.precipitation_band
),

-- ---- spot check 3: one zone's pickup count and average fare, recomputed ----
q3_target AS (
    SELECT zone_name, pickup_count AS published_pickups, avg_fare_amount_usd AS published_avg_fare
    FROM q3
    WHERE pickup_count > 0
    ORDER BY pickup_count DESC, zone_name
    LIMIT 1
),
q3_recomputed AS (
    SELECT
        tgt.published_pickups,
        tgt.published_avg_fare,
        SUM(f.trip_count) AS recomputed_pickups,
        -- Summed measure over summed eligible trips, the same weighting the
        -- dataset uses. An AVG() here would be the averages-of-averages error
        -- this check exists to catch.
        ROUND(SUM(CASE WHEN NOT f.negative_fare_amount_flag THEN f.fare_amount_usd END)
              / NULLIF(COUNT_IF(NOT f.negative_fare_amount_flag), 0), 2) AS recomputed_avg_fare
    FROM q3_target AS tgt
    JOIN `ftw-week-08`.`05-gold`.dim_taxi_zone AS z ON z.zone_name = tgt.zone_name
    JOIN `ftw-week-08`.`05-gold`.fact_taxi_trip AS f ON f.pickup_zone_key = z.zone_key
    GROUP BY tgt.published_pickups, tgt.published_avg_fare
),

checks AS (

    SELECT 'q1_not_empty' AS check_name, 'VOLUME' AS check_type,
           'FAIL' AS severity, 0.0 AS threshold_pct,
           CAST(CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END AS BIGINT) AS fail_count,
           1 AS total_count,
           CONCAT('rows in activity_by_time_and_zone: ', CAST(COUNT(*) AS STRING)) AS details
    FROM q1

    UNION ALL
    SELECT 'q2_not_empty', 'VOLUME', 'FAIL', 0.0,
           CAST(CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END AS BIGINT), 1,
           CONCAT('rows in trip_behavior_by_weather: ', CAST(COUNT(*) AS STRING))
    FROM q2

    UNION ALL
    SELECT 'q3_not_empty', 'VOLUME', 'FAIL', 0.0,
           CAST(CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END AS BIGINT), 1,
           CONCAT('rows in mobility_patterns_by_zone: ', CAST(COUNT(*) AS STRING))
    FROM q3

    -- ---- reconciliation with Gold ----

    UNION ALL
    SELECT 'q1_trips_reconcile_to_gold', 'RECONCILIATION', 'FAIL', 0.0,
           CAST(CASE WHEN (SELECT SUM(trip_count) FROM q1) = g.gold_trips THEN 0 ELSE 1 END AS BIGINT), 1,
           CONCAT('q1: ', CAST((SELECT SUM(trip_count) FROM q1) AS STRING),
                  ', gold: ', CAST(g.gold_trips AS STRING))
    FROM gold AS g

    UNION ALL
    SELECT 'q3_pickups_reconcile_to_gold', 'RECONCILIATION', 'FAIL', 0.0,
           CAST(CASE WHEN (SELECT SUM(pickup_count) FROM q3) = g.gold_trips THEN 0 ELSE 1 END AS BIGINT), 1,
           CONCAT('q3 pickups: ', CAST((SELECT SUM(pickup_count) FROM q3) AS STRING),
                  ', gold: ', CAST(g.gold_trips AS STRING))
    FROM gold AS g

    UNION ALL
    SELECT 'q3_dropoffs_reconcile_to_gold', 'RECONCILIATION', 'FAIL', 0.0,
           CAST(CASE WHEN (SELECT SUM(dropoff_count) FROM q3) = g.gold_trips THEN 0 ELSE 1 END AS BIGINT), 1,
           CONCAT('q3 drop-offs: ', CAST((SELECT SUM(dropoff_count) FROM q3) AS STRING),
                  ', gold: ', CAST(g.gold_trips AS STRING))
    FROM gold AS g

    -- Q2 covers only weather-attributed trips (D20), so it reconciles to that
    -- subset rather than to every trip.
    UNION ALL
    SELECT 'q2_trips_reconcile_to_weather_attributed', 'RECONCILIATION', 'FAIL', 0.0,
           CAST(CASE WHEN (SELECT SUM(trip_count) FROM q2) = g.gold_weather_attributed_trips
                     THEN 0 ELSE 1 END AS BIGINT), 1,
           CONCAT('q2: ', CAST((SELECT SUM(trip_count) FROM q2) AS STRING),
                  ', gold weather-attributed: ', CAST(g.gold_weather_attributed_trips AS STRING))
    FROM gold AS g

    UNION ALL
    SELECT 'q2_covered_hours_reconcile_to_gold', 'RECONCILIATION', 'FAIL', 0.0,
           CAST(CASE WHEN (SELECT SUM(covered_hours) FROM q2)
                        = (SELECT COUNT(*) FROM `ftw-week-08`.`05-gold`.fact_weather_hourly)
                     THEN 0 ELSE 1 END AS BIGINT), 1,
           CONCAT('q2 covered hours: ', CAST((SELECT SUM(covered_hours) FROM q2) AS STRING),
                  ', gold weather hours: ',
                  CAST((SELECT COUNT(*) FROM `ftw-week-08`.`05-gold`.fact_weather_hourly) AS STRING))
    FROM (SELECT 1)

    -- ---- spot checks against an independent recomputation ----

    UNION ALL
    SELECT 'q1_spot_check_date_hour_zone', 'SPOT_CHECK', 'FAIL', 0.0,
           CAST(CASE WHEN published_trips = recomputed_trips THEN 0 ELSE 1 END AS BIGINT), 1,
           CONCAT('published: ', CAST(published_trips AS STRING),
                  ', recomputed from fact: ', CAST(recomputed_trips AS STRING))
    FROM q1_recomputed

    UNION ALL
    SELECT 'q2_spot_check_classification', 'SPOT_CHECK', 'FAIL', 0.0,
           CAST(CASE WHEN published_trips = recomputed_trips
                      AND covered_hours = recomputed_hours THEN 0 ELSE 1 END AS BIGINT), 1,
           CONCAT('trips published/recomputed: ', CAST(published_trips AS STRING), '/',
                  CAST(recomputed_trips AS STRING),
                  ', hours: ', CAST(covered_hours AS STRING), '/', CAST(recomputed_hours AS STRING))
    FROM q2_recomputed

    UNION ALL
    SELECT 'q3_spot_check_zone_pickups_and_fare', 'SPOT_CHECK', 'FAIL', 0.0,
           CAST(CASE WHEN published_pickups = recomputed_pickups
                      AND published_avg_fare = recomputed_avg_fare THEN 0 ELSE 1 END AS BIGINT), 1,
           CONCAT('pickups published/recomputed: ', CAST(published_pickups AS STRING), '/',
                  CAST(recomputed_pickups AS STRING),
                  ', avg fare: ', CAST(published_avg_fare AS STRING), '/',
                  CAST(recomputed_avg_fare AS STRING))
    FROM q3_recomputed

    -- ---- weighted metrics must come from totals ----
    -- Recomputes each published average from its own stored totals. A dataset
    -- that averaged per-group averages would disagree here.

    UNION ALL
    SELECT 'q1_averages_derived_from_totals', 'CONSISTENCY', 'FAIL', 0.0,
           COUNT_IF(trips_with_eligible_fare > 0
                AND avg_fare_amount_usd
                    <> ROUND(total_fare_amount_usd / trips_with_eligible_fare, 2)), COUNT(*),
           'Average fare must equal summed fare over summed eligible trips.'
    FROM q1

    UNION ALL
    SELECT 'q3_averages_derived_from_totals', 'CONSISTENCY', 'FAIL', 0.0,
           COUNT_IF(pickup_trips_eligible_fare > 0
                AND avg_fare_amount_usd
                    <> ROUND(pickup_total_fare_usd / pickup_trips_eligible_fare, 2)), COUNT(*),
           'Average fare must equal summed fare over summed eligible trips.'
    FROM q3

    -- ---- ranks share ties ----
    -- DENSE_RANK produces contiguous ranks, so the highest rank equals the
    -- number of distinct ranks. ROW_NUMBER would break tied groups apart and
    -- push the maximum up to the row count.

    UNION ALL
    SELECT 'q3_ranks_share_ties', 'CONSISTENCY', 'FAIL', 0.0,
           CAST(CASE WHEN MAX(pickup_rank) = COUNT(DISTINCT pickup_rank) THEN 0 ELSE 1 END AS BIGINT), 1,
           CONCAT('max rank ', CAST(MAX(pickup_rank) AS STRING),
                  ' over ', CAST(COUNT(DISTINCT pickup_rank) AS STRING), ' distinct ranks')
    FROM q3

    -- ---- unknown and zero categories stay visible ----

    UNION ALL
    SELECT 'q1_unresolved_zones_visible', 'MEASURE', 'INFO', NULL,
           0, COUNT(*),
           CONCAT('q1 rows with an unresolved pickup zone: ',
                  CAST(COUNT_IF(pickup_zone_name IS NULL) AS STRING))
    FROM q1

    UNION ALL
    SELECT 'q1_special_zone_activity', 'MEASURE', 'INFO', NULL,
           0, COUNT(*),
           CONCAT('trips by pickup zone classification: ',
                  ARRAY_JOIN(ARRAY_SORT(COLLECT_LIST(
                      CONCAT(COALESCE(pickup_zone_classification, '<unresolved>'),
                             '=', CAST(n AS STRING)))), ', '))
    FROM (SELECT pickup_zone_classification, SUM(trip_count) AS n FROM q1
          GROUP BY pickup_zone_classification)

    UNION ALL
    SELECT 'q2_zero_trip_classifications', 'MEASURE', 'INFO', NULL,
           0, COUNT(*),
           CONCAT('weather classifications observed with zero trips: ',
                  CAST(COUNT_IF(trip_count = 0) AS STRING),
                  ' of ', CAST(COUNT(*) AS STRING))
    FROM q2

    UNION ALL
    SELECT 'q2_weather_coverage', 'MEASURE', 'INFO', NULL,
           0, COUNT(*),
           CONCAT('trips by weather match status: ',
                  ARRAY_JOIN(ARRAY_SORT(COLLECT_LIST(
                      CONCAT(weather_match_status, '=', CAST(trip_count AS STRING)))), ', '))
    FROM `ftw-week-08`.`06-analytics`.trip_weather_coverage

    UNION ALL
    SELECT 'q3_zones_without_activity', 'MEASURE', 'INFO', NULL,
           0, COUNT(*),
           CONCAT('zones with no pickups and no drop-offs: ',
                  CAST(COUNT_IF(pickup_count = 0 AND dropoff_count = 0) AS STRING),
                  ' of ', CAST(COUNT(*) AS STRING))
    FROM q3

    UNION ALL
    SELECT 'q1_date_coverage', 'MEASURE', 'INFO', NULL,
           0, COUNT(*),
           CONCAT('pickup dates from ', CAST(MIN(pickup_date) AS STRING),
                  ' to ', CAST(MAX(pickup_date) AS STRING),
                  '; outside Mar-May 2026: ',
                  CAST(COUNT_IF(pickup_date < DATE '2026-03-01'
                             OR pickup_date >= DATE '2026-06-01') AS STRING), ' rows')
    FROM q1
)

SELECT
    dq_run_id,
    current_timestamp(),
    'analytics',
    'business_questions',
    check_name,
    check_type,
    severity,
    `ftw-week-08`.`01-control`.dq_status(
        severity, fail_count,
        CASE WHEN total_count = 0 THEN 0.0 ELSE fail_count * 100.0 / total_count END,
        threshold_pct
    ),
    fail_count,
    total_count,
    CASE WHEN total_count = 0 THEN 0.0 ELSE fail_count * 100.0 / total_count END,
    threshold_pct,
    NULL,
    NULL,
    code_revision,
    gate_owner,
    NULL,
    details
FROM checks;


-- Gate result. The dashboards use validated Analytics results only.
SELECT CASE
         WHEN COUNT_IF(status = 'FAIL') > 0
         THEN raise_error(concat('Analytics gate BLOCKED: ',
                                 CAST(COUNT_IF(status = 'FAIL') AS STRING),
                                 ' failed checks'))
       END
FROM `ftw-week-08`.`01-control`.data_quality_results
WHERE run_id = dq_run_id;


-- Review the run:
-- SELECT check_name, status, severity, fail_count, total_count, details
-- FROM `ftw-week-08`.`01-control`.data_quality_results
-- WHERE run_id = (SELECT run_id FROM `ftw-week-08`.`01-control`.gate_status
--                 WHERE layer = 'analytics' AND dataset = 'business_questions')
-- ORDER BY status DESC, check_name;
