-- ============================================================
-- Bronze gate: Open-Meteo weather
--
-- Stage:     02 Bronze validation
-- Runs after: etl/02_bronze/20_load_open_meteo.sql
-- Target:    `ftw-week-08`.`01-control`.data_quality_results
-- Grain:     one row per check per run
-- Contract:  docs/validation.md (shared result contract, D17)
--
-- Two families of check in one gate: response-level (the landed API
-- response, its metadata and array shape) and observation-level (the
-- hourly arrays flattened temporarily for inspection). Bronze is never
-- modified. Silver weather_hourly runs only when this passes.
--
-- The source path is repeated here on purpose: reconciliation must
-- re-read the payload independently of what the loader recorded.
-- ============================================================

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
    WHERE layer = 'bronze' AND dataset = 'open_meteo'
);


-- Independent re-read. The response-version hash must stay identical to
-- the one in 20_load_open_meteo.sql or the reconciliation below compares
-- two different things.
CREATE OR REPLACE TEMP VIEW om_source_identity AS
SELECT
    size(hourly.time) AS source_hourly_count,
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


-- Flatten the hourly arrays for observation-level checks. The requested
-- window is carried through from the same row rather than joined back:
-- the previous version re-joined Bronze on (coordinate_id,
-- source_response_version), which fans out the moment a second response
-- shares those values.
CREATE OR REPLACE TEMP VIEW om_observations AS
SELECT
    t.coordinate_id,
    t.weather_model,
    t.batch_id,
    t.source_response_version,
    t.requested_start_date,
    t.requested_end_date,
    p.pos,
    CAST(t.hourly_time[p.pos] AS TIMESTAMP) AS observation_timestamp,
    t.hourly_temperature_2m[p.pos]          AS temperature_2m,
    t.hourly_precipitation[p.pos]           AS precipitation,
    t.hourly_weather_code[p.pos]            AS weather_code
FROM `ftw-week-08`.`02-bronze`.open_meteo_weather_raw t
LATERAL VIEW posexplode(t.hourly_time) p AS pos, hourly_timestamp;


INSERT INTO `ftw-week-08`.`01-control`.data_quality_results

WITH bronze AS (
    SELECT * FROM `ftw-week-08`.`02-bronze`.open_meteo_weather_raw
),

-- Types confirmed from the first run's bronze_column_types_observed
-- measurement: information_schema renders the four complex columns as
-- plain ARRAY, not ARRAY<STRING>.
schema_expected AS (
    SELECT * FROM VALUES
        ('coordinate_id',               'STRING',    0),
        ('requested_latitude',          'DOUBLE',    1),
        ('requested_longitude',         'DOUBLE',    2),
        ('requested_start_date',        'STRING',    3),
        ('requested_end_date',          'STRING',    4),
        ('weather_model',               'STRING',    5),
        ('returned_latitude',           'DOUBLE',    6),
        ('returned_longitude',          'DOUBLE',    7),
        ('elevation_m',                 'DOUBLE',    8),
        ('utc_offset_seconds',          'INT',       9),
        ('timezone',                    'STRING',   10),
        ('timezone_abbreviation',       'STRING',   11),
        ('generationtime_ms',           'DOUBLE',   12),
        ('hourly_time',                 'ARRAY',    13),
        ('hourly_temperature_2m',       'ARRAY',    14),
        ('hourly_precipitation',        'ARRAY',    15),
        ('hourly_weather_code',         'ARRAY',    16),
        ('hourly_units_time',           'STRING',   17),
        ('hourly_units_temperature_2m', 'STRING',   18),
        ('hourly_units_precipitation',  'STRING',   19),
        ('hourly_units_weather_code',   'STRING',   20),
        ('source_system',               'STRING',   21),
        ('source_url',                  'STRING',   22),
        ('source_file',                 'STRING',   23),
        ('content_sha256',              'STRING',   24),
        ('source_response_version',     'STRING',   25),
        ('run_id',                      'STRING',   26),
        ('batch_id',                    'STRING',   27),
        ('ingested_at',                 'TIMESTAMP', 28)
    AS expected(column_name, data_type, ordinal_position)
),

schema_actual AS (
    SELECT column_name, data_type, ordinal_position
    FROM `system`.information_schema.columns
    WHERE table_catalog = 'ftw-week-08'
      AND table_schema  = '02-bronze'
      AND table_name    = 'open_meteo_weather_raw'
),

-- Name, type and position, matching the other two Bronze gates.
schema_mismatches AS (
    SELECT COUNT(*) AS fail_count
    FROM (
        SELECT expected.column_name
        FROM schema_expected expected
        FULL OUTER JOIN schema_actual actual
          ON expected.column_name      = actual.column_name
         AND expected.data_type        = actual.data_type
         AND expected.ordinal_position = actual.ordinal_position
        WHERE expected.column_name IS NULL OR actual.column_name IS NULL
    )
),

response_key_counts AS (
    SELECT COUNT(*) AS row_count
    FROM bronze
    GROUP BY coordinate_id, requested_start_date, requested_end_date, weather_model
),

response_profile AS (
    SELECT
        COUNT(*) AS total_count,
        SUM(CASE WHEN requested_latitude IS NULL
                   OR requested_latitude NOT BETWEEN -90 AND 90 THEN 1 ELSE 0 END) AS invalid_latitude,
        SUM(CASE WHEN requested_longitude IS NULL
                   OR requested_longitude NOT BETWEEN -180 AND 180 THEN 1 ELSE 0 END) AS invalid_longitude,
        SUM(CASE WHEN requested_start_date IS NULL
                   OR requested_end_date IS NULL THEN 1 ELSE 0 END) AS missing_dates,
        SUM(CASE WHEN weather_model IS NULL
                   OR TRIM(weather_model) = '' THEN 1 ELSE 0 END) AS missing_weather_model,
        SUM(CASE WHEN hourly_time IS NULL OR hourly_temperature_2m IS NULL
                   OR hourly_precipitation IS NULL OR hourly_weather_code IS NULL
                 THEN 1 ELSE 0 END) AS missing_arrays,
        SUM(CASE WHEN hourly_time IS NULL OR hourly_temperature_2m IS NULL
                   OR hourly_precipitation IS NULL OR hourly_weather_code IS NULL
                   OR size(hourly_time) <> size(hourly_temperature_2m)
                   OR size(hourly_time) <> size(hourly_precipitation)
                   OR size(hourly_time) <> size(hourly_weather_code)
                 THEN 1 ELSE 0 END) AS misaligned_arrays,
        SUM(CASE
                WHEN requested_start_date IS NULL OR requested_end_date IS NULL THEN 0
                WHEN hourly_time IS NULL THEN 1
                WHEN size(hourly_time) <> datediff(
                        date_add(to_date(requested_end_date), 1),
                        to_date(requested_start_date)) * 24 THEN 1
                ELSE 0 END) AS unexpected_hourly_volume,
        SUM(CASE WHEN source_system IS NULL OR source_url IS NULL OR source_file IS NULL
                   OR content_sha256 IS NULL OR source_response_version IS NULL
                   OR batch_id IS NULL OR run_id IS NULL OR ingested_at IS NULL
                 THEN 1 ELSE 0 END) AS missing_provenance
    FROM bronze
),

obs AS (
    SELECT o.*,
           LAG(o.observation_timestamp) OVER (
               PARTITION BY o.coordinate_id, o.source_response_version
               ORDER BY o.pos
           ) AS previous_timestamp
    FROM om_observations o
),

obs_profile AS (
    SELECT
        COUNT(*) AS total_count,
        SUM(CASE WHEN observation_timestamp IS NULL THEN 1 ELSE 0 END) AS timestamp_nulls,
        SUM(CASE WHEN temperature_2m       IS NULL THEN 1 ELSE 0 END) AS temperature_nulls,
        SUM(CASE WHEN precipitation        IS NULL THEN 1 ELSE 0 END) AS precipitation_nulls,
        SUM(CASE WHEN weather_code         IS NULL THEN 1 ELSE 0 END) AS weather_code_nulls,
        -- CONCAT_WS with explicit null markers: plain CONCAT returns NULL
        -- when any argument is null, which would collapse null timestamps
        -- into a single distinct value and undercount duplicates.
        COUNT(*) - COUNT(DISTINCT CONCAT_WS('|',
            COALESCE(coordinate_id, '<null>'),
            COALESCE(source_response_version, '<null>'),
            COALESCE(CAST(observation_timestamp AS STRING), '<null>'))) AS duplicate_timestamps,
        SUM(CASE WHEN previous_timestamp IS NOT NULL
                   AND observation_timestamp < previous_timestamp THEN 1 ELSE 0 END) AS chronological_errors,
        SUM(CASE WHEN temperature_2m < -50 OR temperature_2m > 60 THEN 1 ELSE 0 END) AS invalid_temperature,
        SUM(CASE WHEN precipitation < 0 THEN 1 ELSE 0 END) AS negative_precipitation,
        SUM(CASE WHEN weather_code NOT IN (
                    0,1,2,3, 45,48, 51,53,55,56,57, 61,63,65,66,67,
                    71,73,75,77, 80,81,82, 85,86, 95,96,99)
                 THEN 1 ELSE 0 END) AS invalid_weather_code,
        SUM(CASE WHEN observation_timestamp <  CAST(requested_start_date AS TIMESTAMP)
                   OR observation_timestamp >= CAST(date_add(to_date(requested_end_date), 1) AS TIMESTAMP)
                 THEN 1 ELSE 0 END) AS outside_date_window,
        SUM(CASE WHEN previous_timestamp IS NOT NULL
                   AND observation_timestamp <> previous_timestamp + INTERVAL 1 HOUR
                 THEN 1 ELSE 0 END) AS timestamp_gaps
    FROM obs
),

checks AS (

    -- ---- response level ----

    SELECT 'bronze_row_count' AS check_name, 'STRUCTURAL' AS check_type,
           'FAIL' AS severity, 0.0 AS threshold_pct,
           CAST(CASE WHEN total_count >= 1 THEN 0 ELSE 1 END AS BIGINT) AS fail_count,
           1 AS total_count,
           CONCAT('responses in Bronze: ', CAST(total_count AS STRING)) AS details
    FROM response_profile

    UNION ALL
    SELECT 'observation_count_not_empty', 'STRUCTURAL', 'FAIL', 0.0,
           CAST(CASE WHEN total_count = 0 THEN 1 ELSE 0 END AS BIGINT), 1,
           CONCAT('flattened hourly observations: ', CAST(total_count AS STRING))
    FROM obs_profile

    UNION ALL
    SELECT 'source_schema', 'SCHEMA', 'FAIL', 0.0,
           CAST(fail_count AS BIGINT), 29,
           'Bronze column names and order must match the expected signature.'
    FROM schema_mismatches

    UNION ALL
    SELECT 'bronze_response_key_unique', 'STRUCTURAL', 'FAIL', 0.0,
           COALESCE(SUM(CASE WHEN row_count > 1 THEN row_count - 1 ELSE 0 END), 0),
           COUNT(*),
           'One row per (coordinate_id, start, end, model). Excess rows mean the MERGE key failed.'
    FROM response_key_counts

    UNION ALL
    SELECT 'requested_latitude', 'DOMAIN', 'FAIL', 0.0,
           CAST(invalid_latitude AS BIGINT), total_count,
           'Requested latitude must be between -90 and 90.'
    FROM response_profile

    UNION ALL
    SELECT 'requested_longitude', 'DOMAIN', 'FAIL', 0.0,
           CAST(invalid_longitude AS BIGINT), total_count,
           'Requested longitude must be between -180 and 180.'
    FROM response_profile

    UNION ALL
    SELECT 'requested_dates', 'COMPLETENESS', 'FAIL', 0.0,
           CAST(missing_dates AS BIGINT), total_count,
           'Requested start and end dates must be populated.'
    FROM response_profile

    UNION ALL
    SELECT 'weather_model_not_null', 'COMPLETENESS', 'WARN', 0.0,
           CAST(missing_weather_model AS BIGINT), total_count,
           'weather_model must be populated; the loader records api_default_unpinned when none was requested.'
    FROM response_profile

    UNION ALL
    SELECT 'hourly_arrays_not_null', 'COMPLETENESS', 'FAIL', 0.0,
           CAST(missing_arrays AS BIGINT), total_count,
           'All four hourly arrays must be populated.'
    FROM response_profile

    UNION ALL
    SELECT 'hourly_array_alignment', 'STRUCTURAL', 'FAIL', 0.0,
           CAST(misaligned_arrays AS BIGINT), total_count,
           'Hourly arrays are zipped by position downstream; lengths must match.'
    FROM response_profile

    UNION ALL
    SELECT 'hourly_volume', 'MEASUREMENT', 'FAIL', 0.0,
           CAST(unexpected_hourly_volume AS BIGINT), total_count,
           'Hourly observation count must equal the requested range in days x 24.'
    FROM response_profile

    UNION ALL
    SELECT 'provenance_completeness', 'PROVENANCE', 'FAIL', 0.0,
           CAST(missing_provenance AS BIGINT), total_count,
           'Every Bronze response must carry full provenance.'
    FROM response_profile

    -- The same literal ingestion_batches is keyed on. These drifted apart
    -- once already: Bronze rows said open_meteo_archive while their own
    -- batch row said open_meteo, so a row could not be joined back to the
    -- batch that loaded it.
    UNION ALL
    SELECT 'source_system_domain', 'DOMAIN', 'FAIL', 0.0,
           SUM(CASE WHEN source_system <> 'open_meteo' THEN 1 ELSE 0 END), COUNT(*),
           'source_system must match the value registered in ingestion_batches.'
    FROM bronze

    UNION ALL
    SELECT 'batch_registered_in_control', 'PROVENANCE', 'FAIL', 0.0,
           SUM(CASE WHEN b.batch_id IS NULL THEN 1 ELSE 0 END), COUNT(*),
           'Every batch_id in Bronze must have a SUCCESS row in ingestion_batches.'
    FROM bronze t
    LEFT JOIN `ftw-week-08`.`01-control`.ingestion_batches b
           ON t.batch_id = b.batch_id AND b.status = 'SUCCESS'

    -- ---- source -> Bronze reconciliation ----

    UNION ALL
    SELECT 'source_to_bronze_hourly_count', 'RECONCILIATION', 'FAIL', 0.0,
           CAST(CASE WHEN s.source_hourly_count =
                          (SELECT MAX(size(hourly_time)) FROM bronze) THEN 0 ELSE 1 END AS BIGINT),
           1,
           CONCAT('source hours: ', CAST(s.source_hourly_count AS STRING),
                  ', bronze hours: ', CAST((SELECT MAX(size(hourly_time)) FROM bronze) AS STRING))
    FROM om_source_identity s

    UNION ALL
    SELECT 'bronze_matches_current_response', 'RECONCILIATION', 'FAIL', 0.0,
           CAST(CASE WHEN s.source_response_version =
                          (SELECT MAX(source_response_version) FROM bronze) THEN 0 ELSE 1 END AS BIGINT),
           1,
           'Bronze content must equal the current payload. A failure means rerun the loader.'
    FROM om_source_identity s

    -- ---- observation level ----

    UNION ALL
    SELECT 'timestamp_not_null', 'COMPLETENESS', 'FAIL', 0.0,
           CAST(timestamp_nulls AS BIGINT), total_count,
           'Observation timestamps must not be null.'
    FROM obs_profile

    UNION ALL
    SELECT 'temperature_not_null', 'COMPLETENESS', 'FAIL', 0.0,
           CAST(temperature_nulls AS BIGINT), total_count,
           'Temperature observations must not be null.'
    FROM obs_profile

    UNION ALL
    SELECT 'precipitation_not_null', 'COMPLETENESS', 'FAIL', 0.0,
           CAST(precipitation_nulls AS BIGINT), total_count,
           'Precipitation observations must not be null.'
    FROM obs_profile

    UNION ALL
    SELECT 'weather_code_not_null', 'COMPLETENESS', 'FAIL', 0.0,
           CAST(weather_code_nulls AS BIGINT), total_count,
           'Weather code observations must not be null.'
    FROM obs_profile

    UNION ALL
    SELECT 'duplicate_timestamps', 'UNIQUENESS', 'FAIL', 0.0,
           CAST(duplicate_timestamps AS BIGINT), total_count,
           'One observation per coordinate, response version and hour.'
    FROM obs_profile

    UNION ALL
    SELECT 'timestamp_chronological_order', 'CONSISTENCY', 'FAIL', 0.0,
           CAST(chronological_errors AS BIGINT), total_count,
           'Array order must be chronological; Silver zips by position.'
    FROM obs_profile

    UNION ALL
    SELECT 'temperature_range', 'DOMAIN', 'FAIL', 0.0,
           CAST(invalid_temperature AS BIGINT), total_count,
           'Temperature outside -50..60 C almost certainly means a units change, not an outlier.'
    FROM obs_profile

    UNION ALL
    SELECT 'precipitation_non_negative', 'DOMAIN', 'FAIL', 0.0,
           CAST(negative_precipitation AS BIGINT), total_count,
           'Precipitation must not be negative.'
    FROM obs_profile

    UNION ALL
    SELECT 'weather_code_domain', 'DOMAIN', 'FAIL', 0.0,
           CAST(invalid_weather_code AS BIGINT), total_count,
           'Weather codes must use the WMO code set Silver maps to categories.'
    FROM obs_profile

    UNION ALL
    SELECT 'observation_date_window', 'CONSISTENCY', 'FAIL', 0.0,
           CAST(outside_date_window AS BIGINT), total_count,
           'Observations must fall within the requested date range.'
    FROM obs_profile

    UNION ALL
    SELECT 'hourly_continuity', 'CONSISTENCY', 'FAIL', 0.0,
           CAST(timestamp_gaps AS BIGINT), total_count,
           'Hourly observations must be continuous at one-hour intervals (UTC, so no DST gaps).'
    FROM obs_profile

    -- Units confirmed from the first run's hourly_units_observed
    -- measurement. This is the check that catches Open-Meteo switching to
    -- Fahrenheit or inches: temperature_range only notices a units change
    -- once a value leaves the -50..60 window, and most of the year it
    -- would not. A change here invalidates every stored measure.
    UNION ALL
    SELECT 'hourly_units_expected', 'DOMAIN', 'FAIL', 0.0,
           SUM(CASE WHEN hourly_units_time           <> 'iso8601'
                      OR hourly_units_temperature_2m <> '°C'
                      OR hourly_units_precipitation  <> 'mm'
                      OR hourly_units_weather_code   <> 'wmo code'
                    THEN 1 ELSE 0 END), COUNT(*),
           'Landed units must match those the stored measures were validated against.'
    FROM bronze

    -- ---- measurements ----

    UNION ALL
    SELECT 'hourly_units_observed', 'MEASURE', 'INFO', NULL,
           0, COUNT(*),
           CONCAT('units - time: ', COALESCE(MAX(hourly_units_time), '<null>'),
                  ', temp: ',       COALESCE(MAX(hourly_units_temperature_2m), '<null>'),
                  ', precip: ',     COALESCE(MAX(hourly_units_precipitation), '<null>'),
                  ', code: ',       COALESCE(MAX(hourly_units_weather_code), '<null>'))
    FROM bronze

    UNION ALL
    SELECT 'bronze_column_types_observed', 'MEASURE', 'INFO', NULL,
           0, COUNT(*),
           CONCAT('array column types: ',
                  ARRAY_JOIN(ARRAY_SORT(COLLECT_LIST(CONCAT(column_name, '=', data_type))), ', '))
    FROM schema_actual
    WHERE column_name LIKE 'hourly_time'
       OR column_name LIKE 'hourly_temperature_2m'
       OR column_name LIKE 'hourly_precipitation'
       OR column_name LIKE 'hourly_weather_code'

    UNION ALL
    SELECT 'observation_count_measurement', 'MEASURE', 'INFO', NULL,
           0, COUNT(*),
           CONCAT('observations: ', CAST(COUNT(*) AS STRING),
                  ', window: ', COALESCE(MIN(CAST(observation_timestamp AS STRING)), '<none>'),
                  ' to ',       COALESCE(MAX(CAST(observation_timestamp AS STRING)), '<none>'))
    FROM om_observations
)

SELECT
    dq_run_id,
    current_timestamp(),
    'bronze',
    'open_meteo',
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
    (SELECT MAX(batch_id) FROM bronze),
    (SELECT MAX(source_response_version) FROM bronze),
    code_revision,
    gate_owner,
    NULL,
    details
FROM checks;


-- Gate result. Silver weather_hourly runs only when this returns cleanly.
SELECT CASE
         WHEN COUNT_IF(status = 'FAIL') > 0
         THEN raise_error(concat('Bronze open_meteo gate BLOCKED: ',
                                 CAST(COUNT_IF(status = 'FAIL') AS STRING),
                                 ' failed checks'))
       END
FROM `ftw-week-08`.`01-control`.data_quality_results
WHERE run_id = dq_run_id;


-- Review the run:
 SELECT check_name, status, severity, fail_count, total_count,
        ROUND(fail_pct, 4) AS fail_pct, threshold_pct, details
 FROM `ftw-week-08`.`01-control`.data_quality_results
 WHERE run_id = dq_run_id ORDER BY status DESC, check_name;