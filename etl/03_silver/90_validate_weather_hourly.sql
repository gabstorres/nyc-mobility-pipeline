-- ============================================================
-- Silver gate: weather_hourly
--
-- Stage:     03 Silver validation
-- Runs after: etl/03_silver/20_clean_weather_hourly.sql
-- Target:    `ftw-week-08`.`01-control`.data_quality_results
-- Grain:     one row per check per run
-- Contract:  docs/validation.md (shared result contract, D17)
--
-- Integration runs only when this passes, together with the green_taxi
-- and Taxi Zones Silver gates.
--
-- Replaces the seven INSERTs into `01-control`.open_meteo_silver_dq_results
-- with one statement on the shared contract. The hard exit gate is kept --
-- this file already raised, unlike the green_taxi one.
-- ============================================================

DECLARE OR REPLACE VARIABLE dq_run_id STRING;
SET VARIABLE dq_run_id = uuid();

DECLARE OR REPLACE VARIABLE code_revision STRING;
SET VARIABLE code_revision = 'UNSET';


INSERT INTO `ftw-week-08`.`01-control`.data_quality_results

WITH silver AS (
    SELECT * FROM `ftw-week-08`.`03-silver`.weather_hourly
),

-- Ordered by the UTC instant, which is strictly increasing regardless of
-- what local time does across a DST transition.
ordered AS (
    SELECT
        observation_timestamp_utc,
        observation_timestamp_local,
        LAG(observation_timestamp_utc) OVER (
            PARTITION BY coordinate_id, weather_model
            ORDER BY observation_timestamp_utc) AS prev_utc,
        LAG(observation_timestamp_local) OVER (
            PARTITION BY coordinate_id, weather_model
            ORDER BY observation_timestamp_utc) AS prev_local
    FROM silver
),

-- Distinct local hours per local calendar day. A normal day has 24. The
-- spring-forward day has 23, the autumn fall-back day has 25. Asserting
-- the 23..25 band rather than naming a date keeps this working when 2027
-- data arrives -- the previous version hardcoded 2026-03-08, and on any
-- other year's data it would have matched no rows and passed silently.
hours_per_local_date AS (
    SELECT
        coordinate_id,
        weather_model,
        observation_date_local,
        COUNT(DISTINCT observation_hour_local) AS distinct_hours
    FROM silver
    GROUP BY coordinate_id, weather_model, observation_date_local
),

-- The request window is expressed in UTC, so the first and last LOCAL
-- days are partial by construction: 2026-03-01T00:00Z is 19:00 on 28 Feb
-- in New York, leaving that local date with 5 hours, and the final local
-- date is cut short the same way. Only interior days are whole, so only
-- they can be held to the 23-25 bound.
local_date_bounds AS (
    SELECT
        coordinate_id,
        weather_model,
        MIN(observation_date_local) AS first_local_date,
        MAX(observation_date_local) AS last_local_date
    FROM silver
    GROUP BY coordinate_id, weather_model
),

interior_local_dates AS (
    SELECT h.*
    FROM hours_per_local_date h
    JOIN local_date_bounds b
      ON h.coordinate_id = b.coordinate_id
     AND h.weather_model = b.weather_model
    WHERE h.observation_date_local > b.first_local_date
      AND h.observation_date_local < b.last_local_date
),

-- Bronze holds one row per response with the hourly arrays intact, so the
-- total array length is how many Silver rows there should be. This only
-- holds while no two responses cover the same coordinate, model and hour;
-- if that changes, Silver legitimately merges them and this must become a
-- distinct-key comparison.
recon AS (
    SELECT
        (SELECT SUM(size(hourly_time))
         FROM `ftw-week-08`.`02-bronze`.open_meteo_weather_raw) AS bronze_hours,
        (SELECT COUNT(*) FROM silver) AS silver_rows
),

schema_expected AS (
    SELECT * FROM VALUES
        ('weather_observation_key', 0), ('coordinate_id', 1),
        ('observation_timestamp_utc', 2), ('weather_model', 3),
        ('observation_timestamp_local', 4), ('observation_date_local', 5),
        ('observation_hour_local', 6), ('temperature_2m_c', 7),
        ('precipitation_mm', 8), ('weather_code', 9),
        ('weather_condition_category', 10), ('returned_latitude', 11),
        ('returned_longitude', 12), ('elevation_m', 13),
        ('requested_latitude', 14), ('requested_longitude', 15),
        ('source_system', 16), ('source_file', 17), ('source_url', 18),
        ('content_sha256', 19), ('source_response_version', 20),
        ('run_id', 21), ('batch_id', 22), ('ingested_at', 23),
        ('silver_processed_at', 24)
    AS expected(column_name, ordinal_position)
),

schema_actual AS (
    SELECT column_name, data_type, ordinal_position
    FROM `system`.information_schema.columns
    WHERE table_catalog = 'ftw-week-08'
      AND table_schema  = '03-silver'
      AND table_name    = 'weather_hourly'
),

schema_mismatches AS (
    SELECT COUNT(*) AS fail_count
    FROM (
        SELECT expected.column_name
        FROM schema_expected expected
        FULL OUTER JOIN schema_actual actual
          ON expected.column_name      = actual.column_name
         AND expected.ordinal_position = actual.ordinal_position
        WHERE expected.column_name IS NULL OR actual.column_name IS NULL
    )
),

checks AS (

    SELECT 'silver_table_not_empty' AS check_name, 'VOLUME' AS check_type,
           'FAIL' AS severity, 0.0 AS threshold_pct,
           CAST(CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END AS BIGINT) AS fail_count,
           1 AS total_count,
           CONCAT('rows in weather_hourly: ', CAST(COUNT(*) AS STRING)) AS details
    FROM silver

    UNION ALL
    SELECT 'silver_schema', 'SCHEMA', 'FAIL', 0.0,
           CAST(fail_count AS BIGINT), 25,
           'Silver column names and order must match the expected signature.'
    FROM schema_mismatches

    -- ---- key integrity ----

    UNION ALL
    SELECT 'weather_observation_key_not_null', 'NOT_NULL', 'FAIL', 0.0,
           COUNT_IF(weather_observation_key IS NULL), COUNT(*),
           'The observation key is the Gold join key; it cannot be null.'
    FROM silver

    UNION ALL
    SELECT 'weather_observation_key_unique', 'UNIQUE', 'FAIL', 0.0,
           COUNT(*) - COUNT(DISTINCT weather_observation_key), COUNT(*),
           'Duplicate observation keys would fan out the weather fact.'
    FROM silver

    UNION ALL
    SELECT 'weather_observation_key_length', 'FORMAT', 'FAIL', 0.0,
           COUNT_IF(LENGTH(weather_observation_key) <> 64), COUNT(*),
           'sha2(..., 256) renders as 64 hex characters.'
    FROM silver

    UNION ALL
    SELECT 'business_key_unique', 'UNIQUE', 'FAIL', 0.0,
           COUNT(*) - COUNT(DISTINCT CONCAT_WS('|',
               COALESCE(coordinate_id, '<null>'),
               COALESCE(CAST(observation_timestamp_utc AS STRING), '<null>'),
               COALESCE(weather_model, '<null>'))), COUNT(*),
           'One row per coordinate, UTC hour and model. Null-safe: plain CONCAT would collapse nulls.'
    FROM silver

    -- ---- required fields ----

    UNION ALL
    SELECT 'coordinate_id_not_null', 'NOT_NULL', 'FAIL', 0.0,
           COUNT_IF(coordinate_id IS NULL), COUNT(*),
           'coordinate_id must not be NULL.'
    FROM silver

    UNION ALL
    SELECT 'observation_timestamp_utc_not_null', 'NOT_NULL', 'FAIL', 0.0,
           COUNT_IF(observation_timestamp_utc IS NULL), COUNT(*),
           'A null UTC timestamp means the ISO8601 string failed to parse.'
    FROM silver

    UNION ALL
    SELECT 'observation_timestamp_local_not_null', 'NOT_NULL', 'FAIL', 0.0,
           COUNT_IF(observation_timestamp_local IS NULL), COUNT(*),
           'A null local timestamp means the timezone conversion failed.'
    FROM silver

    UNION ALL
    SELECT 'weather_model_not_null', 'NOT_NULL', 'FAIL', 0.0,
           COUNT_IF(weather_model IS NULL OR TRIM(weather_model) = ''), COUNT(*),
           'weather_model is part of the business key.'
    FROM silver

    UNION ALL
    SELECT 'weather_code_not_null', 'NOT_NULL', 'FAIL', 0.0,
           COUNT_IF(weather_code IS NULL), COUNT(*),
           'weather_code drives the Gold classification dimension.'
    FROM silver

    -- ---- derived columns agree with the timestamp they came from ----

    UNION ALL
    SELECT 'observation_date_matches_local_timestamp', 'CONSISTENCY', 'FAIL', 0.0,
           COUNT_IF(observation_date_local <> CAST(observation_timestamp_local AS DATE)), COUNT(*),
           'observation_date_local must be the date part of observation_timestamp_local.'
    FROM silver

    UNION ALL
    SELECT 'observation_hour_matches_local_timestamp', 'CONSISTENCY', 'FAIL', 0.0,
           COUNT_IF(observation_hour_local <> HOUR(observation_timestamp_local)), COUNT(*),
           'observation_hour_local must be the hour part of observation_timestamp_local.'
    FROM silver

    UNION ALL
    SELECT 'observation_hour_local_range', 'RANGE', 'FAIL', 0.0,
           COUNT_IF(observation_hour_local < 0 OR observation_hour_local > 23), COUNT(*),
           'Local hour must fall in 0..23.'
    FROM silver

    -- ---- continuity and DST ----
    --
    -- timestampdiff, not unix_timestamp: these columns are TIMESTAMP_NTZ,
    -- and unix_timestamp resolves an NTZ through the session timezone. On
    -- an America/New_York cluster the pair spanning the DST transition
    -- would differ by 0 or 7200 seconds rather than 3600, failing a gate
    -- over a cluster setting rather than over the data.

    UNION ALL
    SELECT 'hourly_utc_continuity', 'CONSISTENCY', 'FAIL', 0.0,
           COUNT_IF(prev_utc IS NOT NULL
                AND timestampdiff(SECOND, prev_utc, observation_timestamp_utc) <> 3600), COUNT(*),
           'Consecutive UTC observations must be exactly one hour apart, with no gaps.'
    FROM ordered

    UNION ALL
    SELECT 'local_timestamp_non_decreasing', 'CONSISTENCY', 'FAIL', 0.0,
           COUNT_IF(prev_local IS NOT NULL
                AND observation_timestamp_local < prev_local), COUNT(*),
           'Local time never runs backwards, even across a DST transition.'
    FROM ordered

    UNION ALL
    SELECT 'local_hours_per_date_within_dst_bounds', 'CONSISTENCY', 'FAIL', 0.0,
           COUNT_IF(distinct_hours < 23 OR distinct_hours > 25), COUNT(*),
           'A whole local day has 24 distinct hours, 23 on spring forward, 25 on fall back. Boundary days are excluded: the UTC request window cuts them short.'
    FROM interior_local_dates

    -- ---- measures ----

    UNION ALL
    SELECT 'temperature_2m_range', 'DOMAIN', 'FAIL', 0.0,
           COUNT_IF(temperature_2m_c IS NULL
                 OR temperature_2m_c < -90 OR temperature_2m_c > 60), COUNT(*),
           'Temperature must be present and physically plausible.'
    FROM silver

    UNION ALL
    SELECT 'precipitation_non_negative', 'DOMAIN', 'FAIL', 0.0,
           COUNT_IF(precipitation_mm IS NULL OR precipitation_mm < 0), COUNT(*),
           'Precipitation must be present and non-negative.'
    FROM silver

    UNION ALL
    SELECT 'weather_code_valid_wmo', 'DOMAIN', 'FAIL', 0.0,
           COUNT_IF(weather_code NOT IN (
               0,1,2,3, 45,48, 51,53,55, 56,57, 61,63,65, 66,67,
               71,73,75, 77, 80,81,82, 85,86, 95, 96,99)), COUNT(*),
           'Weather codes must belong to the WMO set the category mapping handles.'
    FROM silver

    UNION ALL
    SELECT 'weather_code_category_not_null', 'COMPLETENESS', 'FAIL', 0.0,
           COUNT_IF(weather_code IS NOT NULL AND weather_condition_category IS NULL), COUNT(*),
           'Every weather code must map to a category.'
    FROM silver

    UNION ALL
    SELECT 'known_weather_code_not_unknown', 'CONSISTENCY', 'FAIL', 0.0,
           COUNT_IF(weather_code IN (
               0,1,2,3, 45,48, 51,53,55, 56,57, 61,63,65, 66,67,
               71,73,75, 77, 80,81,82, 85,86, 95, 96,99)
             AND weather_condition_category = 'unknown_code'), COUNT(*),
           'A supported code must never fall through to unknown_code.'
    FROM silver

    -- ---- provenance and reconciliation ----

    UNION ALL
    SELECT 'provenance_completeness', 'PROVENANCE', 'FAIL', 0.0,
           COUNT_IF(source_system IS NULL OR source_file IS NULL
                 OR content_sha256 IS NULL OR source_response_version IS NULL
                 OR batch_id IS NULL OR ingested_at IS NULL
                 OR silver_processed_at IS NULL), COUNT(*),
           'Every Silver row must carry Bronze provenance plus its Silver processing stamp.'
    FROM silver

    UNION ALL
    SELECT 'batch_registered_in_control', 'PROVENANCE', 'FAIL', 0.0,
           COUNT_IF(b.batch_id IS NULL), COUNT(*),
           'Every batch_id in Silver must have a SUCCESS row in ingestion_batches.'
    FROM silver s
    LEFT JOIN `ftw-week-08`.`01-control`.ingestion_batches b
           ON s.batch_id = b.batch_id AND b.status = 'SUCCESS'

    UNION ALL
    SELECT 'bronze_to_silver_row_reconciliation', 'RECONCILIATION', 'FAIL', 0.0,
           CAST(CASE WHEN bronze_hours = silver_rows THEN 0 ELSE 1 END AS BIGINT), 1,
           CONCAT('bronze hourly entries: ', CAST(bronze_hours AS STRING),
                  ', silver rows: ', CAST(silver_rows AS STRING))
    FROM recon

    -- ---- measurements ----

    UNION ALL
    SELECT 'silver_column_types_observed', 'MEASURE', 'INFO', NULL,
           0, COUNT(*),
           CONCAT('types: ', ARRAY_JOIN(ARRAY_SORT(
               COLLECT_LIST(CONCAT(column_name, '=', data_type))), ', '))
    FROM schema_actual

    -- Expect exactly three entries for a Mar-May UTC window: the two
    -- partial boundary days and the spring-forward day at 23. If the
    -- spring-forward day is missing, the timezone conversion is not
    -- actually shifting anything.
    UNION ALL
    SELECT 'local_dates_not_24_hours', 'MEASURE', 'INFO', NULL,
           0, COUNT(*),
           CONCAT('local dates without 24 hours: ',
                  COALESCE(ARRAY_JOIN(ARRAY_SORT(COLLECT_LIST(
                      CONCAT(CAST(observation_date_local AS STRING),
                             '=', CAST(distinct_hours AS STRING)))), ', '), '(none)'))
    FROM hours_per_local_date
    WHERE distinct_hours <> 24

    UNION ALL
    SELECT 'observation_window', 'MEASURE', 'INFO', NULL,
           0, COUNT(*),
           CONCAT('utc ', COALESCE(CAST(MIN(observation_timestamp_utc) AS STRING), '<none>'),
                  ' to ', COALESCE(CAST(MAX(observation_timestamp_utc) AS STRING), '<none>'),
                  '; local ', COALESCE(CAST(MIN(observation_timestamp_local) AS STRING), '<none>'),
                  ' to ', COALESCE(CAST(MAX(observation_timestamp_local) AS STRING), '<none>'))
    FROM silver
)

SELECT
    dq_run_id,
    current_timestamp(),
    'silver',
    'weather_hourly',
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
    'TODO',
    NULL,
    details
FROM checks;


-- Gate result. Integration runs only when this returns cleanly.
SELECT CASE
         WHEN COUNT_IF(status = 'FAIL') > 0
         THEN raise_error(concat('Silver weather_hourly gate BLOCKED: ',
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
--                 WHERE layer = 'silver' AND dataset = 'weather_hourly')
-- ORDER BY status DESC, check_name;
