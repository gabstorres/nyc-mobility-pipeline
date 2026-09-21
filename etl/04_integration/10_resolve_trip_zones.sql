-- ============================================================
-- Resolve trips to pickup and drop-off zones
--
-- Stage:     04 Integration
-- Runs after: Silver gates for green_taxi and taxi_zones
-- Target:    `ftw-week-08`.`04-integration`.trip_zone_map
-- Grain:     one row per accepted trip, unchanged from Silver
-- Contract:  docs/data_model.md, docs/source_to_target_mapping.md
--
-- Adds zone resolution to a trip WITHOUT restating the trip. The output is
-- a narrow map keyed on trip_hash (D19), so trip attributes live in exactly
-- one place -- Silver -- and this stage owns only the match outcome.
--
-- No zone_key here on purpose. zone_key is a Gold surrogate, and facts
-- resolve keys only against built dimensions; this stage decides WHETHER a
-- location resolves and records why, which is the thing that has to be
-- counted before a join type is chosen.
--
-- IDs 264 (unknown) and 265 (outside_nyc) are valid members, not failures
-- (D16), so they get their own status rather than being counted as
-- unmatched.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS `ftw-week-08`.`04-integration`;

CREATE TABLE IF NOT EXISTS `ftw-week-08`.`04-integration`.trip_zone_map (
    trip_hash STRING NOT NULL,

    -- The original source ids are kept even when they resolve to nothing,
    -- so an unmatched trip can still be investigated.
    pickup_location_id INT,
    dropoff_location_id INT,

    pickup_zone_match_status STRING,
    dropoff_zone_match_status STRING,

    integration_processed_at TIMESTAMP
)
USING DELTA;


DECLARE OR REPLACE VARIABLE integration_run_at TIMESTAMP;
SET VARIABLE integration_run_at = current_timestamp();


-- LEFT JOIN, never INNER: an unresolved location must survive as a row with
-- a status, not vanish from the count. The Integration gate quantifies each
-- status before Gold decides what to do about it.
INSERT OVERWRITE `ftw-week-08`.`04-integration`.trip_zone_map
SELECT
    t.trip_hash,
    t.pickup_location_id,
    t.dropoff_location_id,

    CASE
        WHEN t.pickup_location_id IS NULL             THEN 'missing_source_id'
        WHEN t.pickup_location_id IN (264, 265)
             AND pz.location_id IS NOT NULL           THEN 'matched_special'
        WHEN pz.location_id IS NOT NULL               THEN 'matched_regular'
        ELSE                                               'unmatched_location_id'
    END AS pickup_zone_match_status,

    CASE
        WHEN t.dropoff_location_id IS NULL            THEN 'missing_source_id'
        WHEN t.dropoff_location_id IN (264, 265)
             AND dz.location_id IS NOT NULL           THEN 'matched_special'
        WHEN dz.location_id IS NOT NULL               THEN 'matched_regular'
        ELSE                                               'unmatched_location_id'
    END AS dropoff_zone_match_status,

    integration_run_at AS integration_processed_at

FROM `ftw-week-08`.`03-silver`.green_taxi_clean AS t
LEFT JOIN `ftw-week-08`.`03-silver`.taxi_zones_clean AS pz
    ON t.pickup_location_id = pz.location_id
LEFT JOIN `ftw-week-08`.`03-silver`.taxi_zones_clean AS dz
    ON t.dropoff_location_id = dz.location_id;


-- Fan-out guard. location_id is unique in Silver (its gate proves it), so
-- neither join can multiply rows -- but asserting it here means a future
-- change to the zone table cannot silently double the trip count, and it
-- fails before anything downstream reads this table.
SELECT CASE
         WHEN (SELECT COUNT(*) FROM `ftw-week-08`.`04-integration`.trip_zone_map)
              <> (SELECT COUNT(*) FROM `ftw-week-08`.`03-silver`.green_taxi_clean)
         THEN raise_error('trip_zone_map: zone joins changed the trip grain')
       END;


-- What this run resolved.
SELECT
    pickup_zone_match_status,
    dropoff_zone_match_status,
    COUNT(*) AS trips
FROM `ftw-week-08`.`04-integration`.trip_zone_map
GROUP BY pickup_zone_match_status, dropoff_zone_match_status
ORDER BY trips DESC;
