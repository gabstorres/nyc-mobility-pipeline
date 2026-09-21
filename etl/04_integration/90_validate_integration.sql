-- ============================================================
-- Integration gate
--
-- Stage:     04 Integration validation
-- Runs after: etl/04_integration/20_resolve_trip_weather.sql
-- Target:    `ftw-week-08`.`01-control`.data_quality_results
-- Grain:     one row per check per run
-- Contract:  docs/validation.md (shared result contract, D17)
--
-- The first stage that needs every source, so it opens by asserting all
-- three Silver gates passed rather than trusting run order. Gold runs only
-- when this passes.
--
-- Unmatched counts are recorded as INFO measurements, not failures: a trip
-- to an unknown zone or an hour with no weather is a real fact about the
-- data, and the requirement is that it be COUNTED before a join type is
-- chosen, not that it be zero. What blocks is fan-out, a changed grain, an
-- ambiguous weather match, or a status outside its documented domain.
-- ============================================================

-- Dependency assertion. COALESCE matters: a gate that has never run has no
-- row in gate_status at all, and without it NULL <> 'PASS' is NULL, so the
-- check would pass silently on a source that was never validated.
SELECT CASE
         WHEN COALESCE((SELECT status FROM `ftw-week-08`.`01-control`.gate_status
                        WHERE layer = 'silver' AND dataset = 'green_taxi'), 'NEVER_RUN') <> 'PASS'
           OR COALESCE((SELECT status FROM `ftw-week-08`.`01-control`.gate_status
                        WHERE layer = 'silver' AND dataset = 'weather_hourly'), 'NEVER_RUN') <> 'PASS'
           OR COALESCE((SELECT status FROM `ftw-week-08`.`01-control`.gate_status
                        WHERE layer = 'silver' AND dataset = 'taxi_zones'), 'NEVER_RUN') <> 'PASS'
         THEN raise_error('Integration requires passing Silver gates for green_taxi, weather_hourly and taxi_zones')
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
    WHERE layer = 'integration' AND dataset = 'trip_maps'
);


INSERT INTO `ftw-week-08`.`01-control`.data_quality_results

WITH trips AS (
    SELECT * FROM `ftw-week-08`.`03-silver`.green_taxi_clean
),

zone_map AS (
    SELECT * FROM `ftw-week-08`.`04-integration`.trip_zone_map
),

weather_map AS (
    SELECT * FROM `ftw-week-08`.`04-integration`.trip_weather_map
),

counts AS (
    SELECT
        (SELECT COUNT(*) FROM trips)       AS trip_rows,
        (SELECT COUNT(*) FROM zone_map)    AS zone_rows,
        (SELECT COUNT(*) FROM weather_map) AS weather_rows
),

-- Every trip mapped exactly once, and nothing mapped that is not a trip.
-- Checked in both directions: equal row counts alone would not notice a
-- simultaneous drop and spurious insert.
coverage AS (
    SELECT
        (SELECT COUNT(*) FROM (
            SELECT trip_hash FROM trips EXCEPT SELECT trip_hash FROM zone_map))    AS trips_without_zone_row,
        (SELECT COUNT(*) FROM (
            SELECT trip_hash FROM zone_map EXCEPT SELECT trip_hash FROM trips))    AS zone_rows_without_trip,
        (SELECT COUNT(*) FROM (
            SELECT trip_hash FROM trips EXCEPT SELECT trip_hash FROM weather_map)) AS trips_without_weather_row,
        (SELECT COUNT(*) FROM (
            SELECT trip_hash FROM weather_map EXCEPT SELECT trip_hash FROM trips)) AS weather_rows_without_trip
),

checks AS (

    SELECT 'zone_map_not_empty' AS check_name, 'VOLUME' AS check_type,
           'FAIL' AS severity, 0.0 AS threshold_pct,
           CAST(CASE WHEN zone_rows = 0 THEN 1 ELSE 0 END AS BIGINT) AS fail_count,
           1 AS total_count,
           CONCAT('rows in trip_zone_map: ', CAST(zone_rows AS STRING)) AS details
    FROM counts

    UNION ALL
    SELECT 'weather_map_not_empty', 'VOLUME', 'FAIL', 0.0,
           CAST(CASE WHEN weather_rows = 0 THEN 1 ELSE 0 END AS BIGINT), 1,
           CONCAT('rows in trip_weather_map: ', CAST(weather_rows AS STRING))
    FROM counts

    -- ---- grain: no fan-out, no loss ----

    UNION ALL
    SELECT 'zone_map_grain_unchanged', 'RECONCILIATION', 'FAIL', 0.0,
           CAST(ABS(zone_rows - trip_rows) AS BIGINT), trip_rows,
           CONCAT('accepted trips: ', CAST(trip_rows AS STRING),
                  ', zone map rows: ', CAST(zone_rows AS STRING))
    FROM counts

    UNION ALL
    SELECT 'weather_map_grain_unchanged', 'RECONCILIATION', 'FAIL', 0.0,
           CAST(ABS(weather_rows - trip_rows) AS BIGINT), trip_rows,
           CONCAT('accepted trips: ', CAST(trip_rows AS STRING),
                  ', weather map rows: ', CAST(weather_rows AS STRING))
    FROM counts

    UNION ALL
    SELECT 'zone_map_trip_hash_unique', 'UNIQUE', 'FAIL', 0.0,
           COUNT(*) - COUNT(DISTINCT trip_hash), COUNT(*),
           'One zone row per trip; a duplicate would fan out the fact.'
    FROM zone_map

    UNION ALL
    SELECT 'weather_map_trip_hash_unique', 'UNIQUE', 'FAIL', 0.0,
           COUNT(*) - COUNT(DISTINCT trip_hash), COUNT(*),
           'One weather row per trip; a duplicate would fan out the fact.'
    FROM weather_map

    UNION ALL
    SELECT 'zone_map_covers_every_trip', 'RECONCILIATION', 'FAIL', 0.0,
           CAST(trips_without_zone_row + zone_rows_without_trip AS BIGINT),
           (SELECT trip_rows FROM counts),
           CONCAT('trips with no zone row: ', CAST(trips_without_zone_row AS STRING),
                  ', zone rows with no trip: ', CAST(zone_rows_without_trip AS STRING))
    FROM coverage

    UNION ALL
    SELECT 'weather_map_covers_every_trip', 'RECONCILIATION', 'FAIL', 0.0,
           CAST(trips_without_weather_row + weather_rows_without_trip AS BIGINT),
           (SELECT trip_rows FROM counts),
           CONCAT('trips with no weather row: ', CAST(trips_without_weather_row AS STRING),
                  ', weather rows with no trip: ', CAST(weather_rows_without_trip AS STRING))
    FROM coverage

    -- ---- status domains ----

    UNION ALL
    SELECT 'zone_match_status_domain', 'DOMAIN', 'FAIL', 0.0,
           COUNT_IF(pickup_zone_match_status NOT IN
                    ('matched_regular','matched_special','missing_source_id','unmatched_location_id')
                 OR dropoff_zone_match_status NOT IN
                    ('matched_regular','matched_special','missing_source_id','unmatched_location_id')),
           COUNT(*),
           'Zone match statuses must use the four documented values.'
    FROM zone_map

    UNION ALL
    SELECT 'weather_match_status_domain', 'DOMAIN', 'FAIL', 0.0,
           COUNT_IF(pickup_weather_match_status NOT IN
                    ('matched_unique','no_match','invalid_pickup_timestamp','ambiguous_match')),
           COUNT(*),
           'Weather match status must use the four documented values.'
    FROM weather_map

    -- ---- the one unmatched case that blocks ----

    UNION ALL
    SELECT 'no_ambiguous_weather_match', 'CONSISTENCY', 'FAIL', 0.0,
           COUNT_IF(pickup_weather_match_status = 'ambiguous_match'), COUNT(*),
           'A trip matching more than one weather hour cannot be published: the choice would be arbitrary.'
    FROM weather_map

    UNION ALL
    SELECT 'weather_key_present_iff_matched', 'CONSISTENCY', 'FAIL', 0.0,
           COUNT_IF((pickup_weather_match_status = 'matched_unique'
                     AND pickup_weather_observation_key IS NULL)
                 OR (pickup_weather_match_status <> 'matched_unique'
                     AND pickup_weather_observation_key IS NOT NULL)), COUNT(*),
           'A key exists exactly when the status says a unique hour matched; no invented members.'
    FROM weather_map

    UNION ALL
    SELECT 'weather_key_resolves_to_silver', 'REFERENTIAL', 'FAIL', 0.0,
           COUNT_IF(m.pickup_weather_observation_key IS NOT NULL AND w.weather_observation_key IS NULL),
           COUNT(*),
           'Every recorded weather key must exist in Silver weather_hourly.'
    FROM weather_map m
    LEFT JOIN `ftw-week-08`.`03-silver`.weather_hourly w
           ON m.pickup_weather_observation_key = w.weather_observation_key

    UNION ALL
    SELECT 'zone_status_agrees_with_source_id', 'CONSISTENCY', 'FAIL', 0.0,
           COUNT_IF((pickup_location_id IS NULL) <> (pickup_zone_match_status = 'missing_source_id')
                 OR (dropoff_location_id IS NULL) <> (dropoff_zone_match_status = 'missing_source_id')),
           COUNT(*),
           'missing_source_id is recorded exactly when the source location id is null.'
    FROM zone_map

    -- ---- unmatched volumes: counted, not failed ----

    UNION ALL
    SELECT 'pickup_zone_unmatched', 'MEASURE', 'INFO', NULL,
           0, COUNT(*),
           CONCAT('pickup zone status: ', ARRAY_JOIN(ARRAY_SORT(COLLECT_LIST(
               CONCAT(pickup_zone_match_status, '=', CAST(n AS STRING)))), ', '))
    FROM (SELECT pickup_zone_match_status, COUNT(*) AS n FROM zone_map GROUP BY pickup_zone_match_status)

    UNION ALL
    SELECT 'dropoff_zone_unmatched', 'MEASURE', 'INFO', NULL,
           0, COUNT(*),
           CONCAT('drop-off zone status: ', ARRAY_JOIN(ARRAY_SORT(COLLECT_LIST(
               CONCAT(dropoff_zone_match_status, '=', CAST(n AS STRING)))), ', '))
    FROM (SELECT dropoff_zone_match_status, COUNT(*) AS n FROM zone_map GROUP BY dropoff_zone_match_status)

    UNION ALL
    SELECT 'weather_unmatched', 'MEASURE', 'INFO', NULL,
           0, COUNT(*),
           CONCAT('weather status: ', ARRAY_JOIN(ARRAY_SORT(COLLECT_LIST(
               CONCAT(pickup_weather_match_status, '=', CAST(n AS STRING)))), ', '))
    FROM (SELECT pickup_weather_match_status, COUNT(*) AS n FROM weather_map GROUP BY pickup_weather_match_status)

    UNION ALL
    SELECT 'pickup_utc_window', 'MEASURE', 'INFO', NULL,
           0, COUNT(*),
           CONCAT('pickup UTC from ', COALESCE(CAST(MIN(pickup_timestamp_utc) AS STRING), '<none>'),
                  ' to ', COALESCE(CAST(MAX(pickup_timestamp_utc) AS STRING), '<none>'))
    FROM weather_map
)

SELECT
    dq_run_id,
    current_timestamp(),
    'integration',
    'trip_maps',
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


-- Gate result. Gold runs only when this returns cleanly.
SELECT CASE
         WHEN COUNT_IF(status = 'FAIL') > 0
         THEN raise_error(concat('Integration gate BLOCKED: ',
                                 CAST(COUNT_IF(status = 'FAIL') AS STRING),
                                 ' failed checks'))
       END
FROM `ftw-week-08`.`01-control`.data_quality_results
WHERE run_id = dq_run_id;


-- Review the run:
-- SELECT check_name, status, severity, fail_count, total_count,
--        ROUND(fail_pct, 4) AS fail_pct, threshold_pct, details
-- FROM `ftw-week-08`.`01-control`.data_quality_results
-- WHERE run_id = (SELECT run_id FROM `ftw-week-08`.`01-control`.gate_status
--                 WHERE layer = 'integration' AND dataset = 'trip_maps')
-- ORDER BY status DESC, check_name;
