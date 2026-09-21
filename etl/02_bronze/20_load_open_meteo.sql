-- ============================================================
-- Bronze: Open-Meteo historical weather
--
-- Stage: 02 Bronze
-- Runs after: etl/01_control/00_create_control_tables.sql
-- Target: `ftw-week-08`.`02-bronze`.open_meteo_weather_raw
-- Grain: one row per API response, hourly arrays intact
--
-- Business key: (coordinate_id, requested_start_date, requested_end_date,
-- weather_model). A response matching on all four is the same logical
-- request; whether its CONTENT changed is decided by
-- source_response_version, and a changed response REPLACES the stored one
-- (D04: revised contributions replace, they do not sit beside stale rows).
--
-- The source path appears exactly ONCE, inside read_files. source_file is
-- taken from _metadata, so provenance cannot claim a file that was not read.
-- ============================================================

CREATE TABLE IF NOT EXISTS `ftw-week-08`.`02-bronze`.open_meteo_weather_raw (
    coordinate_id STRING,
    requested_latitude DOUBLE,
    requested_longitude DOUBLE,
    requested_start_date STRING,
    requested_end_date STRING,
    weather_model STRING,
    returned_latitude DOUBLE,
    returned_longitude DOUBLE,
    elevation_m DOUBLE,
    utc_offset_seconds INT,
    timezone STRING,
    timezone_abbreviation STRING,
    generationtime_ms DOUBLE,

    hourly_time ARRAY<STRING>,
    hourly_temperature_2m ARRAY<DOUBLE>,
    hourly_precipitation ARRAY<DOUBLE>,
    hourly_weather_code ARRAY<LONG>,

    hourly_units_time STRING,
    hourly_units_temperature_2m STRING,
    hourly_units_precipitation STRING,
    hourly_units_weather_code STRING,

    source_system STRING,
    source_url STRING,
    source_file STRING,
    content_sha256 STRING,
    source_response_version STRING,
    run_id STRING,
    batch_id STRING,
    ingested_at TIMESTAMP
)
USING DELTA;


-- ---------------------------------------------------------------------
-- Request config. These describe the API call that produced the landed
-- payload; they are genuinely injected values, not copies of something
-- readable from the file. Set requested_weather_model to NULL for an
-- unpinned request and the COALESCE below records that honestly.
-- ---------------------------------------------------------------------
DECLARE OR REPLACE VARIABLE weather_coordinate_id STRING;
SET VARIABLE weather_coordinate_id = 'nyc_approved_point';

DECLARE OR REPLACE VARIABLE weather_requested_latitude DOUBLE;
SET VARIABLE weather_requested_latitude = CAST(40.7128 AS DOUBLE);

DECLARE OR REPLACE VARIABLE weather_requested_longitude DOUBLE;
SET VARIABLE weather_requested_longitude = CAST(-74.0060 AS DOUBLE);

DECLARE OR REPLACE VARIABLE weather_requested_start_date STRING;
SET VARIABLE weather_requested_start_date = '2026-03-01';

DECLARE OR REPLACE VARIABLE weather_requested_end_date STRING;
SET VARIABLE weather_requested_end_date = '2026-05-31';

DECLARE OR REPLACE VARIABLE requested_weather_model STRING;
SET VARIABLE requested_weather_model = 'era5';

-- One run_id and one batch_id per run, not per row.
DECLARE OR REPLACE VARIABLE weather_run_id STRING;
SET VARIABLE weather_run_id = uuid();

DECLARE OR REPLACE VARIABLE weather_batch_id STRING;
SET VARIABLE weather_batch_id = uuid();


-- ------------------------------------------------------------
-- The landed response, with request config attached and both hashes
-- computed. content_sha256 is the immutable identity of the payload as
-- received, including generationtime_ms. source_response_version excludes
-- only generationtime_ms, which the API documents as varying between
-- otherwise identical requests -- so it is the field that can honestly
-- answer "did the weather content change?".
-- ------------------------------------------------------------
CREATE OR REPLACE TEMP VIEW open_meteo_source AS
SELECT
    weather_coordinate_id       AS coordinate_id,
    weather_requested_latitude  AS requested_latitude,
    weather_requested_longitude AS requested_longitude,
    weather_requested_start_date AS requested_start_date,
    weather_requested_end_date   AS requested_end_date,
    COALESCE(requested_weather_model, 'api_default_unpinned') AS weather_model,

    latitude  AS returned_latitude,
    longitude AS returned_longitude,
    elevation AS elevation_m,
    CAST(utc_offset_seconds AS INT) AS utc_offset_seconds,
    timezone,
    timezone_abbreviation,
    generationtime_ms,

    hourly.time           AS hourly_time,
    hourly.temperature_2m AS hourly_temperature_2m,
    hourly.precipitation  AS hourly_precipitation,
    hourly.weather_code   AS hourly_weather_code,

    hourly_units.time           AS hourly_units_time,
    hourly_units.temperature_2m AS hourly_units_temperature_2m,
    hourly_units.precipitation  AS hourly_units_precipitation,
    hourly_units.weather_code   AS hourly_units_weather_code,

    'open_meteo' AS source_system,
    'https://archive-api.open-meteo.com/v1/archive' AS source_url,
    _metadata.file_path              AS source_file,
    _metadata.file_size              AS file_size,
    _metadata.file_modification_time AS file_modified_time,

    sha2(to_json(struct(*), map('ignoreNullFields', 'false')), 256) AS content_sha256,

    sha2(to_json(named_struct(
        'latitude', latitude,
        'longitude', longitude,
        'elevation', elevation,
        'utc_offset_seconds', utc_offset_seconds,
        'timezone', timezone,
        'timezone_abbreviation', timezone_abbreviation,
        'hourly_units', hourly_units,
        'hourly', hourly
    ), map('ignoreNullFields', 'false')), 256) AS source_response_version
FROM read_files(
    '/Volumes/ftw-week-08/00-source/group_a_source/weather/open_meteo_mar_may_2026.json',
    format => 'json',
    multiLine => true
);


-- There is work to do when this content has never succeeded, when the target
-- is empty (Bronze dropped but the control row survived), or when the stored
-- row differs from what this loader now produces. That last clause keeps the
-- batch registration in step with the MERGE below: if the MERGE is going to
-- write, a batch must exist to attribute the write to, or the gate's
-- batch_registered_in_control check fails on a batch_id nothing registered.
DECLARE OR REPLACE VARIABLE weather_is_new BOOLEAN;
SET VARIABLE weather_is_new = (
    SELECT
        (SELECT COUNT(*) FROM `ftw-week-08`.`01-control`.ingestion_batches b
          JOIN open_meteo_source s ON b.content_sha256 = s.content_sha256
          WHERE b.source_system = 'open_meteo' AND b.status = 'SUCCESS') = 0
     OR (SELECT COUNT(*) FROM `ftw-week-08`.`02-bronze`.open_meteo_weather_raw) = 0
     OR (SELECT COUNT(*)
         FROM `ftw-week-08`.`02-bronze`.open_meteo_weather_raw t
         JOIN open_meteo_source s
           ON t.coordinate_id        = s.coordinate_id
          AND t.requested_start_date = s.requested_start_date
          AND t.requested_end_date   = s.requested_end_date
          AND t.weather_model        = s.weather_model
         WHERE NOT (t.source_response_version <=> s.source_response_version)
            OR NOT (t.source_system           <=> s.source_system)
            OR NOT (t.source_url              <=> s.source_url)) > 0
     -- Rows pointing at a batch that is no longer a live SUCCESS.
     OR (SELECT COUNT(*)
         FROM `ftw-week-08`.`02-bronze`.open_meteo_weather_raw t
         WHERE NOT EXISTS (
             SELECT 1 FROM `ftw-week-08`.`01-control`.ingestion_batches b
             WHERE b.batch_id = t.batch_id AND b.status = 'SUCCESS')) > 0
);


-- ------------------------------------------------------------
-- Register the batch. request_parameters records the call that produced
-- this payload, which is the whole reason that column exists.
-- ------------------------------------------------------------
-- A reload of content that already succeeded means the earlier batch's rows
-- are gone (the target was dropped) or are being replaced. Demote it rather
-- than leaving two SUCCESS rows for one content hash, which is what
-- no_duplicate_successful_batches flags as double processing. The demoted
-- row keeps its own batch_id, row_count and timestamps, so the earlier
-- attempt stays auditable rather than being deleted.
UPDATE `ftw-week-08`.`01-control`.ingestion_batches
SET status = 'SUPERSEDED'
WHERE source_system = 'open_meteo'
  AND status = 'SUCCESS'
  AND content_sha256 IN ((SELECT content_sha256 FROM open_meteo_source))
  -- Only when this run will actually register a replacement; see the note
  -- in 30_load_taxi_zones.sql.
  AND weather_is_new;

INSERT INTO `ftw-week-08`.`01-control`.ingestion_batches (
    batch_id, source_system, source_object, source_period, request_parameters,
    content_sha256, source_version_id, schema_fingerprint, raw_uri,
    status, discovered_at, started_at, completed_at,
    error_message, supersedes_batch_id,
    row_count, file_size, file_modified_time
)
SELECT
    weather_batch_id, 'open_meteo', source_file,
    CONCAT(requested_start_date, '..', requested_end_date),
    to_json(named_struct(
        'coordinate_id', coordinate_id,
        'latitude',      requested_latitude,
        'longitude',     requested_longitude,
        'start_date',    requested_start_date,
        'end_date',      requested_end_date,
        'weather_model', weather_model
    )),
    content_sha256,
    CONCAT('open_meteo_', requested_start_date, '_', SUBSTRING(source_response_version, 1, 12)),
    NULL, source_file,
    'STARTED', current_timestamp(), current_timestamp(), NULL,
    NULL, NULL,
    NULL, file_size, file_modified_time
FROM open_meteo_source
WHERE weather_is_new;


-- ------------------------------------------------------------
-- Upsert on the business key.
--   NOT MATCHED                     -> insert a new response
--   MATCHED and content changed     -> replace it (D04)
--   MATCHED and content unchanged   -> nothing, so a rerun is a true no-op
--
-- The old version of this file had no WHEN MATCHED branch, so a revised
-- response was silently discarded and source_response_version was computed
-- and stored but never read by anything.
-- ------------------------------------------------------------
MERGE INTO `ftw-week-08`.`02-bronze`.open_meteo_weather_raw AS target
USING open_meteo_source AS source
ON  target.coordinate_id        = source.coordinate_id
AND target.requested_start_date = source.requested_start_date
AND target.requested_end_date   = source.requested_end_date
AND target.weather_model        = source.weather_model

-- Fires on a content change OR on a provenance change. Gating on
-- source_response_version alone meant a code change to how provenance is
-- recorded could never reach a row already landed: renaming source_system
-- from open_meteo_archive to open_meteo left the stored value stale forever,
-- because the payload itself had not changed. Run-scoped columns
-- (run_id, batch_id, ingested_at) are deliberately not compared, or every
-- run would rewrite every row.
WHEN MATCHED AND NOT (
         target.source_response_version <=> source.source_response_version
     AND target.source_system           <=> source.source_system
     AND target.source_url              <=> source.source_url
)
THEN UPDATE SET
    requested_latitude          = source.requested_latitude,
    requested_longitude         = source.requested_longitude,
    returned_latitude           = source.returned_latitude,
    returned_longitude          = source.returned_longitude,
    elevation_m                 = source.elevation_m,
    utc_offset_seconds          = source.utc_offset_seconds,
    timezone                    = source.timezone,
    timezone_abbreviation       = source.timezone_abbreviation,
    generationtime_ms           = source.generationtime_ms,
    hourly_time                 = source.hourly_time,
    hourly_temperature_2m       = source.hourly_temperature_2m,
    hourly_precipitation        = source.hourly_precipitation,
    hourly_weather_code         = source.hourly_weather_code,
    hourly_units_time           = source.hourly_units_time,
    hourly_units_temperature_2m = source.hourly_units_temperature_2m,
    hourly_units_precipitation  = source.hourly_units_precipitation,
    hourly_units_weather_code   = source.hourly_units_weather_code,
    source_system               = source.source_system,
    source_url                  = source.source_url,
    source_file                 = source.source_file,
    content_sha256              = source.content_sha256,
    source_response_version     = source.source_response_version,
    run_id                      = weather_run_id,
    batch_id                    = weather_batch_id,
    ingested_at                 = current_timestamp()

WHEN NOT MATCHED THEN INSERT (
    coordinate_id, requested_latitude, requested_longitude,
    requested_start_date, requested_end_date, weather_model,
    returned_latitude, returned_longitude, elevation_m,
    utc_offset_seconds, timezone, timezone_abbreviation, generationtime_ms,
    hourly_time, hourly_temperature_2m, hourly_precipitation, hourly_weather_code,
    hourly_units_time, hourly_units_temperature_2m,
    hourly_units_precipitation, hourly_units_weather_code,
    source_system, source_url, source_file,
    content_sha256, source_response_version,
    run_id, batch_id, ingested_at
) VALUES (
    source.coordinate_id, source.requested_latitude, source.requested_longitude,
    source.requested_start_date, source.requested_end_date, source.weather_model,
    source.returned_latitude, source.returned_longitude, source.elevation_m,
    source.utc_offset_seconds, source.timezone, source.timezone_abbreviation,
    source.generationtime_ms,
    source.hourly_time, source.hourly_temperature_2m,
    source.hourly_precipitation, source.hourly_weather_code,
    source.hourly_units_time, source.hourly_units_temperature_2m,
    source.hourly_units_precipitation, source.hourly_units_weather_code,
    source.source_system, source.source_url, source.source_file,
    source.content_sha256, source.source_response_version,
    weather_run_id, weather_batch_id, current_timestamp()
);


-- Close the batch.
UPDATE `ftw-week-08`.`01-control`.ingestion_batches
SET status       = 'SUCCESS',
    row_count    = (SELECT COUNT(*) FROM `ftw-week-08`.`02-bronze`.open_meteo_weather_raw),
    completed_at = current_timestamp()
WHERE batch_id = weather_batch_id;


-- What this run did.
SELECT
    weather_is_new AS loaded_new_content,
    coordinate_id,
    requested_start_date,
    requested_end_date,
    weather_model,
    SUBSTRING(source_response_version, 1, 12) AS response_version_short
FROM open_meteo_source;