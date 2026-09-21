-- ============================================================
-- Bronze gate: Green Taxi
--
-- Stage: 02 Bronze validation
-- Runs after: etl/02_bronze/10_load_green_taxi.sql
-- Target: `ftw-week-08`.`01-control`.data_quality_results
-- Grain: one row per check per run
-- Contract: docs/validation.md (shared result contract, D17)
--
-- Replaces both notebooks/90.validate_green_taxi.py and the 84-line
-- SELECT-only file of the same name. Silver green_taxi runs only when
-- this passes.
--
-- The landing path is repeated here on purpose. Reconciliation must re-read the source independently; reading the path back from the loader's own control rows would make the check circular.
-- ============================================================

DECLARE OR REPLACE VARIABLE dq_run_id STRING;
SET VARIABLE dq_run_id = uuid();

-- Set from the job parameter or `git rev-parse --short HEAD` before running.
DECLARE OR REPLACE VARIABLE code_revision STRING;
SET VARIABLE code_revision = 'UNSET';


-- Independent re-read of the landing folder, for source -> Bronze
-- reconciliation. Counts and the fare total come from the files
-- themselves, not from what ingestion recorded about them.
CREATE OR REPLACE TEMP VIEW gt_source_totals AS
SELECT
    _metadata.file_name AS source_object,
    COUNT(*)            AS source_rows,
    ROUND(SUM(CAST(fare_amount AS DECIMAL(18,2))), 2) AS source_fare_total
FROM read_files(
    '/Volumes/ftw-week-08/00-source/group_a_source/green_taxi/',
    format => 'parquet'
)
GROUP BY _metadata.file_name;

CREATE OR REPLACE TEMP VIEW gt_bronze_totals AS
SELECT
    source_file AS source_object,
    COUNT(*)    AS bronze_rows,
    ROUND(SUM(CAST(fare_amount AS DECIMAL(18,2))), 2) AS bronze_fare_total
FROM `ftw-week-08`.`02-bronze`.green_taxi_raw
GROUP BY source_file;


INSERT INTO `ftw-week-08`.`01-control`.data_quality_results

WITH total AS (
    SELECT COUNT(*) AS total_count
    FROM `ftw-week-08`.`02-bronze`.green_taxi_raw
),

-- Expected Bronze column signature. Ordinals are 0-based and the BIGINT
-- columns are named LONG, matching what this workspace's
-- information_schema returns -- both carried over unchanged from the
-- notebook this replaces. content_sha256 is new, from the SQL loader.
schema_expected AS (
    SELECT * FROM VALUES
        ('VendorID',              'INT',            0),
        ('lpep_pickup_datetime',  'TIMESTAMP_NTZ',  1),
        ('lpep_dropoff_datetime', 'TIMESTAMP_NTZ',  2),
        ('store_and_fwd_flag',    'STRING',         3),
        ('RatecodeID',            'LONG',           4),
        ('PULocationID',          'INT',            5),
        ('DOLocationID',          'INT',            6),
        ('passenger_count',       'LONG',           7),
        ('trip_distance',         'DOUBLE',         8),
        ('fare_amount',           'DOUBLE',         9),
        ('extra',                 'DOUBLE',        10),
        ('mta_tax',               'DOUBLE',        11),
        ('tip_amount',            'DOUBLE',        12),
        ('tolls_amount',          'DOUBLE',        13),
        ('ehail_fee',             'DOUBLE',        14),
        ('improvement_surcharge', 'DOUBLE',        15),
        ('total_amount',          'DOUBLE',        16),
        ('payment_type',          'LONG',          17),
        ('trip_type',             'LONG',          18),
        ('congestion_surcharge',  'DOUBLE',        19),
        ('cbd_congestion_fee',    'DOUBLE',        20),
        ('source_system',         'STRING',        21),
        ('source_file',           'STRING',        22),
        ('content_sha256',        'STRING',        23),
        ('batch_id',              'STRING',        24),
        ('ingested_at',           'TIMESTAMP',     25)
    AS expected(column_name, data_type, ordinal_position)
),

schema_actual AS (
    SELECT column_name, data_type, ordinal_position
    FROM `system`.information_schema.columns
    WHERE table_catalog = 'ftw-week-08'
      AND table_schema  = '02-bronze'
      AND table_name    = 'green_taxi_raw'
),

schema_mismatches AS (
    SELECT COUNT(*) AS fail_count
    FROM (
        SELECT expected.column_name
        FROM schema_expected expected
        FULL OUTER JOIN schema_actual actual
          ON expected.column_name     = actual.column_name
         AND expected.data_type       = actual.data_type
         AND expected.ordinal_position = actual.ordinal_position
        WHERE expected.column_name IS NULL
           OR actual.column_name IS NULL
    )
),

duplicate_rows AS (
    SELECT COALESCE(SUM(duplicate_count - 1), 0) AS fail_count
    FROM (
        SELECT COUNT(*) AS duplicate_count
        FROM `ftw-week-08`.`02-bronze`.green_taxi_raw
        GROUP BY
            VendorID, lpep_pickup_datetime, lpep_dropoff_datetime,
            store_and_fwd_flag, RatecodeID, PULocationID, DOLocationID,
            passenger_count, trip_distance, fare_amount, extra, mta_tax,
            tip_amount, tolls_amount, ehail_fee, improvement_surcharge,
            total_amount, payment_type, trip_type, congestion_surcharge,
            cbd_congestion_fee
        HAVING COUNT(*) > 1
    )
),

-- Source -> Bronze, per file, with no filename list and no literal
-- totals: a fourth month reconciles the same way a third did.
reconciliation AS (
    SELECT
        COUNT(*)                                                   AS files_compared,
        COUNT_IF(COALESCE(b.bronze_rows, -1) <> s.source_rows)     AS row_mismatches,
        COUNT_IF(COALESCE(b.bronze_fare_total, -1) <> s.source_fare_total) AS fare_mismatches
    FROM gt_source_totals s
    LEFT JOIN gt_bronze_totals b USING (source_object)
),

checks AS (

    -- 1. Bronze is populated. Runs first: every count-based check below
    --    reports 0 failures on an empty table and would pass silently.
    SELECT 'row_count_not_empty' AS check_name, 'VOLUME' AS check_type,
           'FAIL' AS severity, 0.0 AS threshold_pct,
           CAST(CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END AS BIGINT) AS fail_count,
           GREATEST(COUNT(*), 1) AS total_count,
           'Bronze table must contain rows.' AS details
    FROM `ftw-week-08`.`02-bronze`.green_taxi_raw

    UNION ALL
    SELECT 'source_schema', 'SCHEMA', 'FAIL', 0.0,
           CAST(fail_count AS BIGINT), 26,
           'Bronze column names, types and order must match the expected signature.'
    FROM schema_mismatches

    UNION ALL
    SELECT 'source_to_bronze_row_count', 'RECONCILIATION', 'FAIL', 0.0,
           CAST(row_mismatches AS BIGINT), files_compared,
           'Rows landed per file must equal rows in the source file.'
    FROM reconciliation

    UNION ALL
    SELECT 'source_to_bronze_fare_total', 'RECONCILIATION', 'FAIL', 0.0,
           CAST(fare_mismatches AS BIGINT), files_compared,
           'SUM(fare_amount) per file must equal the source file total, to the cent.'
    FROM reconciliation

    UNION ALL
    SELECT 'pickup_timestamp_not_null', 'NOT_NULL', 'FAIL', 0.0,
           SUM(CASE WHEN lpep_pickup_datetime IS NULL THEN 1 ELSE 0 END), COUNT(*),
           'Pickup timestamp is required.'
    FROM `ftw-week-08`.`02-bronze`.green_taxi_raw

    UNION ALL
    SELECT 'dropoff_timestamp_not_null', 'NOT_NULL', 'FAIL', 0.0,
           SUM(CASE WHEN lpep_dropoff_datetime IS NULL THEN 1 ELSE 0 END), COUNT(*),
           'Dropoff timestamp is required.'
    FROM `ftw-week-08`.`02-bronze`.green_taxi_raw

    UNION ALL
    SELECT 'trip_distance_non_negative', 'RANGE', 'FAIL', 0.0,
           SUM(CASE WHEN trip_distance < 0 THEN 1 ELSE 0 END), COUNT(*),
           'Trip distance must be zero or greater.'
    FROM `ftw-week-08`.`02-bronze`.green_taxi_raw

    UNION ALL
    SELECT 'provenance_completeness', 'PROVENANCE', 'FAIL', 0.0,
           SUM(CASE WHEN source_system IS NULL OR source_file IS NULL
                      OR batch_id IS NULL OR ingested_at IS NULL
                      OR content_sha256 IS NULL THEN 1 ELSE 0 END), COUNT(*),
           'Every Bronze row must carry full provenance.'
    FROM `ftw-week-08`.`02-bronze`.green_taxi_raw

    UNION ALL
    SELECT 'source_system_domain', 'DOMAIN', 'FAIL', 0.0,
           SUM(CASE WHEN source_system <> 'green_taxi' THEN 1 ELSE 0 END), COUNT(*),
           'All rows in this table must be tagged green_taxi.'
    FROM `ftw-week-08`.`02-bronze`.green_taxi_raw

    UNION ALL
    SELECT 'batch_registered_in_control', 'PROVENANCE', 'FAIL', 0.0,
           SUM(CASE WHEN b.batch_id IS NULL THEN 1 ELSE 0 END), COUNT(*),
           'Every batch_id in Bronze must have a SUCCESS row in ingestion_batches.'
    FROM `ftw-week-08`.`02-bronze`.green_taxi_raw t
    LEFT JOIN `ftw-week-08`.`01-control`.ingestion_batches b
           ON t.batch_id = b.batch_id AND b.status = 'SUCCESS'

    -- ---- tolerances: rare anomalies that should stay rare ----

    UNION ALL
    SELECT 'dropoff_after_pickup', 'CONSISTENCY', 'WARN', 0.1,
           SUM(CASE WHEN lpep_pickup_datetime IS NOT NULL
                      AND lpep_dropoff_datetime IS NOT NULL
                      AND lpep_dropoff_datetime <= lpep_pickup_datetime
                    THEN 1 ELSE 0 END), COUNT(*),
           'Dropoff should be later than pickup. Retained for Silver handling.'
    FROM `ftw-week-08`.`02-bronze`.green_taxi_raw

    UNION ALL
    SELECT 'expected_month_coverage', 'DATE_COVERAGE', 'WARN', 0.1,
           SUM(CASE WHEN lpep_pickup_datetime <  TIMESTAMP('2026-03-01 00:00:00')
                      OR lpep_pickup_datetime >= TIMESTAMP('2026-06-01 00:00:00')
                    THEN 1 ELSE 0 END), COUNT(*),
           'Pickups outside the reporting period are retained and flagged.'
    FROM `ftw-week-08`.`02-bronze`.green_taxi_raw

    UNION ALL
    SELECT 'passenger_count_gt_8', 'RANGE', 'WARN', 0.1,
           SUM(CASE WHEN passenger_count > 8 THEN 1 ELSE 0 END), COUNT(*),
           'Passenger counts above 8 are flagged, not removed.'
    FROM `ftw-week-08`.`02-bronze`.green_taxi_raw

    UNION ALL
    SELECT 'vendor_id_domain', 'DOMAIN', 'WARN', 0.1,
           SUM(CASE WHEN VendorID IS NOT NULL AND VendorID NOT IN (1, 2, 6)
                    THEN 1 ELSE 0 END), COUNT(*),
           'Profiled VendorID values are 1, 2 and 6.'
    FROM `ftw-week-08`.`02-bronze`.green_taxi_raw

    UNION ALL
    SELECT 'payment_type_domain', 'DOMAIN', 'WARN', 0.1,
           SUM(CASE WHEN payment_type IS NOT NULL AND payment_type NOT IN (0,1,2,3,4,5,6)
                    THEN 1 ELSE 0 END), COUNT(*),
           'Profiled payment_type values are 0-6.'
    FROM `ftw-week-08`.`02-bronze`.green_taxi_raw

    UNION ALL
    SELECT 'ratecode_id_domain', 'DOMAIN', 'WARN', 0.1,
           SUM(CASE WHEN RatecodeID IS NOT NULL AND RatecodeID NOT IN (1,2,3,4,5,6,99)
                    THEN 1 ELSE 0 END), COUNT(*),
           'Profiled RatecodeID values are 1-6 and 99.'
    FROM `ftw-week-08`.`02-bronze`.green_taxi_raw

    UNION ALL
    SELECT 'pickup_location_id_range', 'RANGE', 'WARN', 0.1,
           SUM(CASE WHEN PULocationID IS NOT NULL
                      AND (PULocationID < 1 OR PULocationID > 265)
                    THEN 1 ELSE 0 END), COUNT(*),
           'Pickup LocationID must fall within the Taxi Zone range 1-265.'
    FROM `ftw-week-08`.`02-bronze`.green_taxi_raw

    UNION ALL
    SELECT 'dropoff_location_id_range', 'RANGE', 'WARN', 0.1,
           SUM(CASE WHEN DOLocationID IS NOT NULL
                      AND (DOLocationID < 1 OR DOLocationID > 265)
                    THEN 1 ELSE 0 END), COUNT(*),
           'Drop-off LocationID must fall within the Taxi Zone range 1-265.'
    FROM `ftw-week-08`.`02-bronze`.green_taxi_raw

    UNION ALL
    SELECT 'full_source_row_duplicate', 'DUPLICATE', 'WARN', 0.1,
           CAST(fail_count AS BIGINT), (SELECT total_count FROM total),
           'Identical source rows across all business columns. Duplicate policy is applied in Silver (D10).'
    FROM duplicate_rows

    -- ---- known source traits: measured every run, never blocking ----

    UNION ALL
    SELECT 'passenger_count_zero', 'MEASURE', 'INFO', NULL,
           SUM(CASE WHEN passenger_count = 0 THEN 1 ELSE 0 END), COUNT(*),
           'Zero passenger counts are a known source trait. Retained, flagged in Silver (D15).'
    FROM `ftw-week-08`.`02-bronze`.green_taxi_raw

    UNION ALL
    SELECT 'passenger_count_null', 'MEASURE', 'INFO', NULL,
           SUM(CASE WHEN passenger_count IS NULL THEN 1 ELSE 0 END), COUNT(*),
           'Null passenger counts are retained. No Bronze imputation.'
    FROM `ftw-week-08`.`02-bronze`.green_taxi_raw

    UNION ALL
    SELECT 'negative_fare_amount', 'MEASURE', 'INFO', NULL,
           SUM(CASE WHEN fare_amount < 0 THEN 1 ELSE 0 END), COUNT(*),
           'Negative fares are a known source trait. Retained, flagged in Silver (D15).'
    FROM `ftw-week-08`.`02-bronze`.green_taxi_raw

    UNION ALL
    SELECT 'negative_total_amount', 'MEASURE', 'INFO', NULL,
           SUM(CASE WHEN total_amount < 0 THEN 1 ELSE 0 END), COUNT(*),
           'Negative totals are a known source trait. Retained, flagged in Silver (D15).'
    FROM `ftw-week-08`.`02-bronze`.green_taxi_raw

    UNION ALL
    SELECT 'zero_distance_high_fare', 'MEASURE', 'INFO', NULL,
           SUM(CASE WHEN trip_distance = 0 AND fare_amount > 20 THEN 1 ELSE 0 END), COUNT(*),
           'Sensitivity-review condition. Rows remain in Bronze.'
    FROM `ftw-week-08`.`02-bronze`.green_taxi_raw
)

SELECT
    dq_run_id,
    current_timestamp(),
    'bronze',
    'green_taxi',
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
    NULL,                 -- batch_id: this gate checks the table as a whole
    NULL,                 -- source_version_id: same
    code_revision,
    'TODO',               -- owner
    NULL,                 -- evidence_location
    details
FROM checks;


-- Gate result. Silver green_taxi runs only when this returns cleanly.
SELECT CASE
         WHEN COUNT_IF(status = 'FAIL') > 0
         THEN raise_error(concat('Bronze green_taxi gate BLOCKED: ',
                                 CAST(COUNT_IF(status = 'FAIL') AS STRING),
                                 ' failed checks'))
       END
FROM `ftw-week-08`.`01-control`.data_quality_results
WHERE run_id = dq_run_id;


-- Review the run:
 SELECT check_name, status, severity, fail_count, total_count,
       ROUND(fail_pct, 4) AS fail_pct, threshold_pct, details
FROM `ftw-week-08`.`01-control`.data_quality_results
WHERE layer = 'bronze' AND dataset = 'green_taxi'
  AND run_id = (SELECT run_id FROM `ftw-week-08`.`01-control`.data_quality_results
                WHERE layer = 'bronze' AND dataset = 'green_taxi'
                ORDER BY executed_at DESC LIMIT 1)
ORDER BY status DESC, check_name;