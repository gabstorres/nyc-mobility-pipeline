-- ============================================================
-- Gold validation gate
--
-- Grain of the result table: one row per check per validation run.
-- Any FAIL row at the end raises an error and blocks Analytics.
-- ============================================================

DECLARE OR REPLACE VARIABLE dq_run_id STRING;
SET VARIABLE dq_run_id = uuid();

-- Supply the Git commit in the Databricks job when available. Keeping an
-- explicit placeholder is preferable to silently claiming an unknown revision.
DECLARE OR REPLACE VARIABLE gold_code_revision STRING;
SET VARIABLE gold_code_revision = 'not_provided';

-- The results table is created once in etl/01_control/00_create_control_tables.sql.
-- This file used to declare its own copy, which diverged: it carried an extra
-- metric_value column, and because CREATE TABLE IF NOT EXISTS is a no-op the
-- declaration never applied while the INSERT below still named that column.

CREATE OR REPLACE TEMP VIEW gold_validation_context AS
WITH batch_ids AS (
    SELECT batch_id
    FROM `ftw-week-08`.`05-gold`.fact_taxi_trip
    UNION ALL
    SELECT batch_id
    FROM `ftw-week-08`.`05-gold`.fact_weather_hourly
),
source_versions AS (
    SELECT source_file_version AS source_version_id
    FROM `ftw-week-08`.`05-gold`.fact_taxi_trip
    UNION ALL
    SELECT source_response_version AS source_version_id
    FROM `ftw-week-08`.`05-gold`.fact_weather_hourly
)
SELECT
    CASE
        WHEN (SELECT COUNT(DISTINCT batch_id) FROM batch_ids) = 1
            THEN (SELECT MAX(batch_id) FROM batch_ids)
        ELSE CONCAT(
            'MULTI_BATCH:',
            CAST((SELECT COUNT(DISTINCT batch_id) FROM batch_ids) AS STRING)
        )
    END AS batch_id,
    CONCAT(
        'MULTI_VERSION:',
        CAST((SELECT COUNT(DISTINCT source_version_id) FROM source_versions) AS STRING)
    ) AS source_version_id;

-- Every SELECT below returns the same compact check contract:
-- dataset, name, type, failures, population, threshold, severity, metric, detail.
CREATE OR REPLACE TEMP VIEW gold_validation_checks AS

-- ------------------------------------------------------------
-- Non-empty outputs and fixed dimension domains
-- ------------------------------------------------------------
SELECT
    'dim_date' AS dataset,
    'table_not_empty' AS check_name,
    'completeness' AS check_type,
    CAST(CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END AS BIGINT) AS fail_count,
    COUNT(*) AS total_count,
    0.0 AS threshold_pct,
    'FAIL' AS severity,
    CAST(COUNT(*) AS DOUBLE) AS metric_value,
    'dim_date must contain the reporting calendar.' AS details
FROM `ftw-week-08`.`05-gold`.dim_date

UNION ALL

SELECT
    'dim_hour', 'exactly_24_hours', 'domain',
    CAST(ABS(COUNT(*) - 24) AS BIGINT), COUNT(*), 0.0, 'FAIL',
    CAST(COUNT(*) AS DOUBLE),
    'dim_hour must contain one row for each hour 0 through 23.'
FROM `ftw-week-08`.`05-gold`.dim_hour

UNION ALL

SELECT
    'dim_weather_classification', 'complete_known_wmo_band_matrix', 'domain',
    CAST(ABS(COUNT(*) - 112) AS BIGINT), COUNT(*), 0.0, 'FAIL',
    CAST(COUNT(*) AS DOUBLE),
    'The 28 approved WMO codes crossed with four precipitation bands produce 112 rows.'
FROM `ftw-week-08`.`05-gold`.dim_weather_classification

UNION ALL

SELECT
    'fact_taxi_trip', 'table_not_empty', 'completeness',
    CAST(CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END AS BIGINT), COUNT(*),
    0.0, 'FAIL', CAST(COUNT(*) AS DOUBLE),
    'An empty trip fact never passes silently.'
FROM `ftw-week-08`.`05-gold`.fact_taxi_trip

UNION ALL

SELECT
    'fact_weather_hourly', 'table_not_empty', 'completeness',
    CAST(CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END AS BIGINT), COUNT(*),
    0.0, 'FAIL', CAST(COUNT(*) AS DOUBLE),
    'An empty weather fact never passes silently.'
FROM `ftw-week-08`.`05-gold`.fact_weather_hourly

UNION ALL

SELECT
    'fact_taxi_trip', 'required_business_fields_not_null', 'completeness',
    COUNT_IF(
        trip_key IS NULL
        OR vendor_id IS NULL
        OR pickup_datetime_local IS NULL
        OR dropoff_datetime_local IS NULL
        OR pickup_timestamp_utc IS NULL
        OR dropoff_timestamp_utc IS NULL
        OR pickup_location_id IS NULL
        OR dropoff_location_id IS NULL
        OR trip_distance_miles IS NULL
        OR fare_amount_usd IS NULL
        OR total_amount_usd IS NULL
        OR trip_duration_seconds IS NULL
        OR trip_count IS NULL
    ),
    COUNT(*), 0.0, 'FAIL', NULL,
    'Required trip identity, timestamp and measure fields must be populated.'
FROM `ftw-week-08`.`05-gold`.fact_taxi_trip

UNION ALL

SELECT
    'fact_weather_hourly', 'required_business_fields_not_null', 'completeness',
    COUNT_IF(
        weather_observation_key IS NULL
        OR coordinate_id IS NULL
        OR observation_timestamp_utc IS NULL
        OR observation_timestamp_local IS NULL
        OR weather_model IS NULL
        OR weather_code IS NULL
        OR temperature_2m_c IS NULL
        OR precipitation_mm IS NULL
        OR requested_latitude IS NULL
        OR requested_longitude IS NULL
        OR returned_latitude IS NULL
        OR returned_longitude IS NULL
        OR elevation_m IS NULL
    ),
    COUNT(*), 0.0, 'FAIL', NULL,
    'Required weather grain, measure and coordinate fields must be populated.'
FROM `ftw-week-08`.`05-gold`.fact_weather_hourly

-- ------------------------------------------------------------
-- Primary keys and business-grain uniqueness
-- COUNT(*) - COUNT(DISTINCT key) counts both null keys and duplicate extras.
-- ------------------------------------------------------------
UNION ALL

SELECT
    'dim_date', 'date_key_primary_key', 'uniqueness',
    COUNT(*) - COUNT(DISTINCT date_key), COUNT(*), 0.0, 'FAIL', NULL,
    'date_key must be non-null and unique.'
FROM `ftw-week-08`.`05-gold`.dim_date

UNION ALL

SELECT
    'dim_hour', 'hour_key_primary_key', 'uniqueness',
    COUNT(*) - COUNT(DISTINCT hour_key), COUNT(*), 0.0, 'FAIL', NULL,
    'hour_key must be non-null and unique.'
FROM `ftw-week-08`.`05-gold`.dim_hour

UNION ALL

SELECT
    'dim_taxi_zone', 'zone_key_primary_key', 'uniqueness',
    COUNT(*) - COUNT(DISTINCT zone_key), COUNT(*), 0.0, 'FAIL', NULL,
    'zone_key must be non-null and unique.'
FROM `ftw-week-08`.`05-gold`.dim_taxi_zone

UNION ALL

SELECT
    'dim_weather_classification', 'weather_classification_key_primary_key', 'uniqueness',
    COUNT(*) - COUNT(DISTINCT weather_classification_key), COUNT(*),
    0.0, 'FAIL', NULL,
    'weather_classification_key must be non-null and unique.'
FROM `ftw-week-08`.`05-gold`.dim_weather_classification

UNION ALL

SELECT
    'fact_taxi_trip', 'trip_key_primary_key', 'uniqueness',
    COUNT(*) - COUNT(DISTINCT trip_key), COUNT(*), 0.0, 'FAIL', NULL,
    'trip_key must be non-null and unique at the accepted-trip grain.'
FROM `ftw-week-08`.`05-gold`.fact_taxi_trip

UNION ALL

SELECT
    'fact_weather_hourly', 'weather_observation_key_primary_key', 'uniqueness',
    COUNT(*) - COUNT(DISTINCT weather_observation_key), COUNT(*),
    0.0, 'FAIL', NULL,
    'weather_observation_key must be non-null and unique.'
FROM `ftw-week-08`.`05-gold`.fact_weather_hourly

UNION ALL

SELECT
    'fact_weather_hourly', 'coordinate_hour_model_business_key_unique', 'uniqueness',
    COUNT(*) - COUNT(DISTINCT coordinate_id, observation_timestamp_utc, weather_model),
    COUNT(*), 0.0, 'FAIL', NULL,
    'The declared weather business key must be unique.'
FROM `ftw-week-08`.`05-gold`.fact_weather_hourly

UNION ALL

SELECT
    'dim_taxi_zone', 'location_id_business_key_unique', 'uniqueness',
    COUNT(*) - COUNT(DISTINCT location_id), COUNT(*), 0.0, 'FAIL', NULL,
    'Taxi Zone LocationID must be unique.'
FROM `ftw-week-08`.`05-gold`.dim_taxi_zone

UNION ALL

SELECT
    'dim_weather_classification', 'code_band_business_key_unique', 'uniqueness',
    COUNT(*) - COUNT(DISTINCT weather_code, precipitation_band), COUNT(*),
    0.0, 'FAIL', NULL,
    'The weather-code and precipitation-band pair must be unique.'
FROM `ftw-week-08`.`05-gold`.dim_weather_classification

-- ------------------------------------------------------------
-- Dimension reconciliation
-- ------------------------------------------------------------
UNION ALL

SELECT
    'dim_taxi_zone', 'row_count_reconciles_to_silver', 'reconciliation',
    CAST(ABS(
        (SELECT COUNT(*) FROM `ftw-week-08`.`05-gold`.dim_taxi_zone)
        - (SELECT COUNT(*) FROM `ftw-week-08`.`03-silver`.taxi_zones_clean)
    ) AS BIGINT),
    (SELECT COUNT(*) FROM `ftw-week-08`.`03-silver`.taxi_zones_clean),
    0.0, 'FAIL',
    CAST((SELECT COUNT(*) FROM `ftw-week-08`.`05-gold`.dim_taxi_zone) AS DOUBLE),
    'Gold Taxi Zone rows must reconcile to the validated Silver snapshot.'

-- ------------------------------------------------------------
-- Required and nullable foreign-key rules
-- ------------------------------------------------------------
UNION ALL

SELECT
    'fact_weather_hourly', 'required_foreign_keys_resolve', 'referential_integrity',
    COUNT(*),
    (SELECT COUNT(*) FROM `ftw-week-08`.`05-gold`.fact_weather_hourly),
    0.0, 'FAIL', NULL,
    'Every weather row must resolve Date, Hour and Weather Classification FKs.'
FROM `ftw-week-08`.`05-gold`.fact_weather_hourly AS f
LEFT JOIN `ftw-week-08`.`05-gold`.dim_date AS d
    ON f.observation_date_key = d.date_key
LEFT JOIN `ftw-week-08`.`05-gold`.dim_hour AS h
    ON f.observation_hour_key = h.hour_key
LEFT JOIN `ftw-week-08`.`05-gold`.dim_weather_classification AS c
    ON f.weather_classification_key = c.weather_classification_key
WHERE d.date_key IS NULL
   OR h.hour_key IS NULL
   OR c.weather_classification_key IS NULL

UNION ALL

SELECT
    'fact_taxi_trip', 'required_date_hour_foreign_keys_resolve', 'referential_integrity',
    COUNT(*),
    (SELECT COUNT(*) FROM `ftw-week-08`.`05-gold`.fact_taxi_trip),
    0.0, 'FAIL', NULL,
    'Every trip must resolve both role-playing Date and Hour FKs.'
FROM `ftw-week-08`.`05-gold`.fact_taxi_trip AS f
LEFT JOIN `ftw-week-08`.`05-gold`.dim_date AS pd
    ON f.pickup_date_key = pd.date_key
LEFT JOIN `ftw-week-08`.`05-gold`.dim_date AS dd
    ON f.dropoff_date_key = dd.date_key
LEFT JOIN `ftw-week-08`.`05-gold`.dim_hour AS ph
    ON f.pickup_hour_key = ph.hour_key
LEFT JOIN `ftw-week-08`.`05-gold`.dim_hour AS dh
    ON f.dropoff_hour_key = dh.hour_key
WHERE pd.date_key IS NULL
   OR dd.date_key IS NULL
   OR ph.hour_key IS NULL
   OR dh.hour_key IS NULL

UNION ALL

SELECT
    'fact_taxi_trip', 'nullable_foreign_keys_reference_dimensions', 'referential_integrity',
    COUNT(*),
    (SELECT COUNT(*) FROM `ftw-week-08`.`05-gold`.fact_taxi_trip),
    0.0, 'FAIL', NULL,
    'Every non-null Zone or Weather Classification FK must reference its dimension.'
FROM `ftw-week-08`.`05-gold`.fact_taxi_trip AS f
LEFT JOIN `ftw-week-08`.`05-gold`.dim_taxi_zone AS pz
    ON f.pickup_zone_key = pz.zone_key
LEFT JOIN `ftw-week-08`.`05-gold`.dim_taxi_zone AS dz
    ON f.dropoff_zone_key = dz.zone_key
LEFT JOIN `ftw-week-08`.`05-gold`.dim_weather_classification AS wc
    ON f.pickup_weather_classification_key = wc.weather_classification_key
WHERE (f.pickup_zone_key IS NOT NULL AND pz.zone_key IS NULL)
   OR (f.dropoff_zone_key IS NOT NULL AND dz.zone_key IS NULL)
   OR (
       f.pickup_weather_classification_key IS NOT NULL
       AND wc.weather_classification_key IS NULL
   )

UNION ALL

SELECT
    'fact_taxi_trip', 'nullable_fk_status_policy', 'business_rule',
    COUNT_IF(
        pickup_zone_match_status IS NULL
        OR dropoff_zone_match_status IS NULL
        OR weather_match_status IS NULL
        OR NOT (
            (pickup_zone_key IS NULL
             AND pickup_zone_match_status IN ('missing_source_id', 'unmatched_location_id'))
            OR
            (pickup_zone_key IS NOT NULL
             AND pickup_zone_match_status IN ('matched_regular', 'matched_special'))
        )
        OR NOT (
            (dropoff_zone_key IS NULL
             AND dropoff_zone_match_status IN ('missing_source_id', 'unmatched_location_id'))
            OR
            (dropoff_zone_key IS NOT NULL
             AND dropoff_zone_match_status IN ('matched_regular', 'matched_special'))
        )
        OR NOT (
            (pickup_weather_classification_key IS NULL
             AND weather_match_status IN ('no_match', 'invalid_pickup_timestamp'))
            OR
            (pickup_weather_classification_key IS NOT NULL
             AND weather_match_status = 'matched_unique')
        )
    ),
    COUNT(*), 0.0, 'FAIL', NULL,
    'Every nullable FK must be explained by its approved match status.'
FROM `ftw-week-08`.`05-gold`.fact_taxi_trip

-- ------------------------------------------------------------
-- Measures, formulas, flags and quarantine policy
-- ------------------------------------------------------------
UNION ALL

SELECT
    'fact_taxi_trip', 'trip_count_and_flags_valid', 'business_rule',
    COUNT_IF(
        trip_count <> 1
        OR pickup_in_reporting_window_flag IS NULL
        OR out_of_source_file_month_flag IS NULL
        OR dropoff_before_pickup_flag IS NULL
        OR negative_trip_distance_flag IS NULL
        OR negative_fare_amount_flag IS NULL
        OR negative_total_amount_flag IS NULL
        OR zero_distance_high_fare_flag IS NULL
        OR passenger_count_zero_flag IS NULL
        OR passenger_count_over_8_flag IS NULL
    ),
    COUNT(*), 0.0, 'FAIL', NULL,
    'trip_count is one and all objective DQ flags are non-null.'
FROM `ftw-week-08`.`05-gold`.fact_taxi_trip

UNION ALL

SELECT
    'fact_taxi_trip', 'derived_values_match_formulas', 'transformation',
    COUNT_IF(
        NOT (
            trip_duration_seconds <=>
            unix_timestamp(dropoff_datetime_local) - unix_timestamp(pickup_datetime_local)
        )
        OR NOT (
            pickup_timestamp_utc <=>
            to_utc_timestamp(pickup_datetime_local, 'America/New_York')
        )
        OR NOT (
            dropoff_timestamp_utc <=>
            to_utc_timestamp(dropoff_datetime_local, 'America/New_York')
        )
        OR pickup_date_key <> CAST(date_format(pickup_datetime_local, 'yyyyMMdd') AS INT)
        OR dropoff_date_key <> CAST(date_format(dropoff_datetime_local, 'yyyyMMdd') AS INT)
        OR pickup_hour_key <> HOUR(pickup_datetime_local)
        OR dropoff_hour_key <> HOUR(dropoff_datetime_local)
        OR negative_total_amount_flag <> COALESCE(total_amount_usd < 0, FALSE)
        OR zero_distance_high_fare_flag <>
            COALESCE(trip_distance_miles = 0 AND fare_amount_usd > 20, FALSE)
        OR passenger_count_zero_flag <> COALESCE(passenger_count = 0, FALSE)
        OR passenger_count_over_8_flag <> COALESCE(passenger_count > 8, FALSE)
    ),
    COUNT(*), 0.0, 'FAIL', NULL,
    'Duration, UTC timestamps, role-playing keys and derived flags match documented formulas.'
FROM `ftw-week-08`.`05-gold`.fact_taxi_trip

UNION ALL

SELECT
    'fact_taxi_trip', 'quarantined_duplicates_not_published', 'quarantine',
    COUNT(*),
    (SELECT COUNT(*) FROM `ftw-week-08`.`03-silver`.green_taxi_quarantine),
    0.0, 'FAIL', NULL,
    'No Silver duplicate-collision row may appear in Gold.'
FROM `ftw-week-08`.`03-silver`.green_taxi_quarantine AS q
-- Joined on the identity Silver publishes (D19). This used to recompute a
-- hash of the typed columns here, a second copy of a formula that had to be
-- kept in step with the fact build by hand.
INNER JOIN `ftw-week-08`.`05-gold`.fact_taxi_trip AS f
    ON f.trip_key = q.trip_hash

-- ------------------------------------------------------------
-- Lineage and Silver-to-Gold reconciliation
-- ------------------------------------------------------------
UNION ALL

SELECT
    'fact_taxi_trip', 'required_lineage_present', 'lineage',
    COUNT_IF(
        source_system IS NULL
        OR source_file IS NULL
        OR source_file_version IS NULL
        OR batch_id IS NULL
        OR run_id IS NULL
        OR ingested_at IS NULL
    ),
    COUNT(*), 0.0, 'FAIL', NULL,
    'Every trip retains source batch, version and execution provenance.'
FROM `ftw-week-08`.`05-gold`.fact_taxi_trip

UNION ALL

SELECT
    'fact_weather_hourly', 'required_lineage_present', 'lineage',
    COUNT_IF(
        source_system IS NULL
        OR source_url IS NULL
        OR source_response_version IS NULL
        OR batch_id IS NULL
        OR run_id IS NULL
        OR ingested_at IS NULL
    ),
    COUNT(*), 0.0, 'FAIL', NULL,
    'Every weather row retains response version, batch and execution provenance.'
FROM `ftw-week-08`.`05-gold`.fact_weather_hourly

UNION ALL

SELECT
    'fact_taxi_trip', 'row_count_reconciles_to_silver', 'reconciliation',
    CAST(ABS(
        (SELECT COUNT(*) FROM `ftw-week-08`.`05-gold`.fact_taxi_trip)
        - (SELECT COUNT(*) FROM `ftw-week-08`.`03-silver`.green_taxi_clean)
    ) AS BIGINT),
    (SELECT COUNT(*) FROM `ftw-week-08`.`03-silver`.green_taxi_clean),
    0.0, 'FAIL',
    CAST((SELECT COUNT(*) FROM `ftw-week-08`.`05-gold`.fact_taxi_trip) AS DOUBLE),
    'Gold trip rows must equal accepted Silver trip rows; no fan-out or silent loss.'

UNION ALL

SELECT
    'fact_weather_hourly', 'row_count_reconciles_to_silver', 'reconciliation',
    CAST(ABS(
        (SELECT COUNT(*) FROM `ftw-week-08`.`05-gold`.fact_weather_hourly)
        - (SELECT COUNT(*) FROM `ftw-week-08`.`03-silver`.weather_hourly)
    ) AS BIGINT),
    (SELECT COUNT(*) FROM `ftw-week-08`.`03-silver`.weather_hourly),
    0.0, 'FAIL',
    CAST((SELECT COUNT(*) FROM `ftw-week-08`.`05-gold`.fact_weather_hourly) AS DOUBLE),
    'Gold weather rows must equal validated Silver hourly rows.'

UNION ALL

SELECT
    'fact_taxi_trip', 'fare_total_reconciles_to_silver', 'measure_reconciliation',
    CAST(
        CASE
            WHEN COALESCE((SELECT SUM(fare_amount_usd)
                           FROM `ftw-week-08`.`05-gold`.fact_taxi_trip), 0)
                 = COALESCE((SELECT SUM(fare_amount_usd)
                             FROM `ftw-week-08`.`03-silver`.green_taxi_clean), 0)
                THEN 0
            ELSE 1
        END
        AS BIGINT
    ),
    (SELECT COUNT(*) FROM `ftw-week-08`.`03-silver`.green_taxi_clean),
    0.0, 'FAIL',
    CAST((SELECT SUM(fare_amount_usd)
          FROM `ftw-week-08`.`05-gold`.fact_taxi_trip) AS DOUBLE),
    'SUM(fare_amount_usd) must reconcile exactly at DECIMAL(18,2) precision.'

UNION ALL

SELECT
    'fact_weather_hourly', 'precipitation_total_reconciles_to_silver',
    'measure_reconciliation',
    CAST(
        CASE
            WHEN COALESCE((SELECT SUM(precipitation_mm)
                           FROM `ftw-week-08`.`05-gold`.fact_weather_hourly), 0)
                 = COALESCE((SELECT SUM(precipitation_mm)
                             FROM `ftw-week-08`.`03-silver`.weather_hourly), 0)
                THEN 0
            ELSE 1
        END
        AS BIGINT
    ),
    (SELECT COUNT(*) FROM `ftw-week-08`.`03-silver`.weather_hourly),
    0.0, 'FAIL',
    CAST((SELECT SUM(precipitation_mm)
          FROM `ftw-week-08`.`05-gold`.fact_weather_hourly) AS DOUBLE),
    'SUM(precipitation_mm) must reconcile exactly at DECIMAL(10,3) precision.';

INSERT INTO `ftw-week-08`.`01-control`.data_quality_results (
    run_id,
    executed_at,
    layer,
    dataset,
    batch_id,
    source_version_id,
    code_revision,
    check_name,
    check_type,
    status,
    severity,
    fail_count,
    total_count,
    fail_pct,
    threshold_pct,
    owner,
    details,
    evidence_location
)
SELECT
    dq_run_id AS run_id,
    current_timestamp() AS executed_at,
    'gold' AS layer,
    checks.dataset,
    context.batch_id,
    context.source_version_id,
    gold_code_revision AS code_revision,
    checks.check_name,
    checks.check_type,
    CASE
        WHEN checks.severity = 'INFO' THEN 'INFO'
        WHEN checks.fail_count = 0 THEN 'PASS'
        WHEN checks.severity = 'FAIL' THEN 'FAIL'
        WHEN checks.total_count = 0 THEN 'FAIL'
        WHEN checks.fail_count * 100.0 / checks.total_count > checks.threshold_pct THEN 'FAIL'
        ELSE 'WARN'
    END AS status,
    checks.severity,
    checks.fail_count,
    checks.total_count,
    CASE
        WHEN checks.total_count = 0 AND checks.fail_count = 0 THEN 0.0
        WHEN checks.total_count = 0 THEN 100.0
        ELSE checks.fail_count * 100.0 / checks.total_count
    END AS fail_pct,
    checks.threshold_pct,
    'ina' AS owner,
    checks.details,
    'etl/05_gold/90_validate_gold.sql' AS evidence_location
FROM gold_validation_checks AS checks
CROSS JOIN gold_validation_context AS context;

SELECT
    dataset,
    check_name,
    status,
    fail_count,
    total_count,
    details
FROM `ftw-week-08`.`01-control`.data_quality_results
WHERE run_id = dq_run_id
ORDER BY dataset, check_name;

SELECT CASE
         WHEN COUNT_IF(status = 'FAIL') > 0
         THEN raise_error(
             CONCAT(
                 'Gold gate BLOCKED: ',
                 CAST(COUNT_IF(status = 'FAIL') AS STRING),
                 ' failed checks; run_id=',
                 dq_run_id
             )
         )
       END
FROM `ftw-week-08`.`01-control`.data_quality_results
WHERE run_id = dq_run_id;
