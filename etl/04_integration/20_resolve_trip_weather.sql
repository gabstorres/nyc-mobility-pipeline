-- ============================================================
-- Resolve trips to the pickup weather hour
--
-- Stage:     04 Integration
-- Runs after: etl/04_integration/10_resolve_trip_zones.sql
-- Target:    `ftw-week-08`.`04-integration`.trip_weather_map
-- Grain:     one row per accepted trip, unchanged from Silver
-- Contract:  docs/data_model.md, docs/source_to_target_mapping.md
--
-- Carries only the weather OBSERVATION key. Temperature and precipitation
-- stay on fact_weather_hourly (D12); Gold copies the classification key
-- from there rather than duplicating measures onto every trip.
--
-- pickup_timestamp_utc is computed here, not in Gold, because it is the
-- value the weather match is keyed on -- deriving it twice would let the
-- match and the stored timestamp disagree.
--
-- The join deliberately matches on the observation hour ALONE, with no
-- coordinate or model literal. D06 pins one representative coordinate
-- today, but hardcoding it would silently pick one row if that ever
-- changes; matching on the hour and requiring at most one match makes a
-- second coordinate or model fail loudly instead.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS `ftw-week-08`.`04-integration`;

CREATE TABLE IF NOT EXISTS `ftw-week-08`.`04-integration`.trip_weather_map (
    trip_hash STRING NOT NULL,

    pickup_timestamp_utc TIMESTAMP_NTZ,
    pickup_weather_observation_key STRING,
    pickup_weather_match_status STRING,

    integration_processed_at TIMESTAMP
)
USING DELTA;


DECLARE OR REPLACE VARIABLE integration_run_at TIMESTAMP;
SET VARIABLE integration_run_at = current_timestamp();


INSERT OVERWRITE `ftw-week-08`.`04-integration`.trip_weather_map

WITH trips AS (
    SELECT
        trip_hash,
        pickup_datetime_local,
        -- DST-aware both ways (D09). A local time inside the spring-forward
        -- gap does not exist, which surfaces below as
        -- invalid_pickup_timestamp rather than as a wrong hour.
        convert_timezone('America/New_York', 'UTC', pickup_datetime_local) AS pickup_timestamp_utc
    FROM `ftw-week-08`.`03-silver`.green_taxi_clean
),

matched AS (
    SELECT
        t.trip_hash,
        t.pickup_datetime_local,
        t.pickup_timestamp_utc,
        COUNT(w.weather_observation_key) AS match_count,
        -- Safe because match_count > 1 is rejected by the gate: at most one
        -- key can survive, so MAX is not an arbitrary pick between rivals.
        MAX(w.weather_observation_key)   AS weather_observation_key
    FROM trips AS t
    LEFT JOIN `ftw-week-08`.`03-silver`.weather_hourly AS w
        ON w.observation_timestamp_utc = date_trunc('HOUR', t.pickup_timestamp_utc)
    GROUP BY t.trip_hash, t.pickup_datetime_local, t.pickup_timestamp_utc
)

SELECT
    trip_hash,
    pickup_timestamp_utc,

    -- Null unless exactly one hour matched. An ambiguous match invents
    -- nothing; it is recorded and the gate stops the stage.
    CASE WHEN match_count = 1 THEN weather_observation_key END AS pickup_weather_observation_key,

    CASE
        WHEN pickup_datetime_local IS NULL
          OR pickup_timestamp_utc IS NULL THEN 'invalid_pickup_timestamp'
        WHEN match_count = 0              THEN 'no_match'
        WHEN match_count = 1              THEN 'matched_unique'
        ELSE                                   'ambiguous_match'
    END AS pickup_weather_match_status,

    integration_run_at AS integration_processed_at
FROM matched;


-- Grain guard. The GROUP BY above collapses back to one row per trip, so a
-- multi-hour match cannot fan out -- but if this ever differs, the trip
-- count is wrong and nothing downstream should read the table.
SELECT CASE
         WHEN (SELECT COUNT(*) FROM `ftw-week-08`.`04-integration`.trip_weather_map)
              <> (SELECT COUNT(*) FROM `ftw-week-08`.`03-silver`.green_taxi_clean)
         THEN raise_error('trip_weather_map: weather resolution changed the trip grain')
       END;


-- What this run resolved.
SELECT
    pickup_weather_match_status,
    COUNT(*) AS trips,
    MIN(pickup_timestamp_utc) AS earliest_pickup_utc,
    MAX(pickup_timestamp_utc) AS latest_pickup_utc
FROM `ftw-week-08`.`04-integration`.trip_weather_map
GROUP BY pickup_weather_match_status
ORDER BY trips DESC;
