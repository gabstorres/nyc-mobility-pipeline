-- ============================================================
-- Silver gate: Green Taxi
--
-- Stage:     03 Silver validation
-- Runs after: etl/03_silver/10_clean_green_taxi.sql
-- Target:    `ftw-week-08`.`01-control`.data_quality_results
-- Grain:     one row per check per run
-- Contract:  docs/validation.md (shared result contract, D17)
--
-- Integration runs only when this passes, together with the weather and
-- Taxi Zones Silver gates.
--
-- Replaces the seven separate INSERTs that wrote to
-- `01-control`.green_taxi_silver_dq_results with one statement on the
-- shared contract, and replaces the soft exit gate -- which printed a
-- status string and let the pipeline continue -- with raise_error.
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
    WHERE layer = 'silver' AND dataset = 'green_taxi'
);


INSERT INTO `ftw-week-08`.`01-control`.data_quality_results

WITH clean AS (
    SELECT * FROM `ftw-week-08`.`03-silver`.green_taxi_clean
),

quarantine AS (
    SELECT * FROM `ftw-week-08`.`03-silver`.green_taxi_quarantine
),

-- ------------------------------------------------------------
-- Independent recomputation of the identity hash straight from Bronze.
-- This deliberately duplicates the formula in 10_clean_green_taxi.sql:
-- the point of the check is to decide, without trusting the cleaner,
-- which rows SHOULD have been quarantined. It must be kept in step with
-- the cleaner by hand, and schema_signature below will not catch a drift
-- between the two -- only the quarantine counts will.
-- ------------------------------------------------------------
bronze_hashes AS (
    SELECT sha2(to_json(struct(
        VendorID,
        lpep_pickup_datetime,
        lpep_dropoff_datetime,
        PULocationID,
        DOLocationID,
        trip_distance,
        fare_amount
    ), map('ignoreNullFields', 'false')), 256) AS trip_hash
    FROM `ftw-week-08`.`02-bronze`.green_taxi_raw
),

expected_quarantine AS (
    SELECT COALESCE(SUM(hash_count), 0) AS expected_quarantine_rows
    FROM (
        SELECT COUNT(*) AS hash_count
        FROM bronze_hashes
        GROUP BY trip_hash
        HAVING COUNT(*) > 1
    )
),

counts AS (
    SELECT
        (SELECT COUNT(*) FROM `ftw-week-08`.`02-bronze`.green_taxi_raw) AS bronze_rows,
        (SELECT COUNT(*) FROM clean)      AS clean_rows,
        (SELECT COUNT(*) FROM quarantine) AS quarantine_rows
),

-- Money reconciled across every disposition: a row is either clean or
-- quarantined, so the two fare totals together must equal Bronze exactly.
-- Cast to DECIMAL before summing so the comparison is not at the mercy of
-- floating-point addition order.
measures AS (
    SELECT
        ROUND((SELECT SUM(CAST(fare_amount AS DECIMAL(18,2)))
               FROM `ftw-week-08`.`02-bronze`.green_taxi_raw), 2) AS bronze_fare_total,
        ROUND(COALESCE((SELECT SUM(fare_amount_usd) FROM clean), 0)
            + COALESCE((SELECT SUM(fare_amount_usd) FROM quarantine), 0), 2) AS silver_fare_total
),

-- ------------------------------------------------------------
-- Column signature. Names and positions only for now: trip_duration_seconds
-- comes from timestampdiff and the exact integer width it returns is not
-- something to guess at. The INFO check at the bottom reports every column's
-- actual type, so this can be tightened to name+type+position next run --
-- the same way the open_meteo gate was.
-- ------------------------------------------------------------
schema_expected AS (
    SELECT * FROM VALUES
        ('trip_hash', 0), ('vendor_id', 1), ('pickup_datetime_local', 2),
        ('dropoff_datetime_local', 3), ('trip_duration_seconds', 4), ('store_and_fwd_flag', 5),
        ('rate_code_id', 6), ('pickup_location_id', 7), ('dropoff_location_id', 8),
        ('passenger_count', 9), ('trip_distance_miles', 10), ('fare_amount_usd', 11),
        ('extra_amount_usd', 12), ('mta_tax_amount_usd', 13), ('tip_amount_usd', 14),
        ('tolls_amount_usd', 15), ('ehail_fee_amount_usd', 16), ('improvement_surcharge_amount_usd', 17),
        ('total_amount_usd', 18), ('payment_type_id', 19), ('trip_type_id', 20),
        ('congestion_surcharge_amount_usd', 21), ('cbd_congestion_fee_amount_usd', 22), ('source_system', 23),
        ('source_file', 24), ('content_sha256', 25), ('ingested_at', 26),
        ('batch_id', 27), ('silver_processed_at', 28), ('negative_fare_flag', 29),
        ('negative_distance_flag', 30), ('dropoff_before_pickup_flag', 31), ('implausible_duration_flag', 32),
        ('implausible_passenger_count_flag', 33), ('passenger_count_missing_flag', 34)
    AS expected(column_name, ordinal_position)
),

schema_actual AS (
    SELECT column_name, data_type, ordinal_position
    FROM `system`.information_schema.columns
    WHERE table_catalog = 'ftw-week-08'
      AND table_schema  = '03-silver'
      AND table_name    = 'green_taxi_clean'
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

    -- 1. Populated. First, so nothing below passes vacuously.
    SELECT 'clean_table_not_empty' AS check_name, 'VOLUME' AS check_type,
           'FAIL' AS severity, 0.0 AS threshold_pct,
           CAST(CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END AS BIGINT) AS fail_count,
           1 AS total_count,
           CONCAT('rows in green_taxi_clean: ', CAST(COUNT(*) AS STRING)) AS details
    FROM clean

    UNION ALL
    SELECT 'silver_schema', 'SCHEMA', 'FAIL', 0.0,
           CAST(fail_count AS BIGINT), 35,
           'Silver column names and order must match the expected signature.'
    FROM schema_mismatches

    -- ---- published trip identity (D19) ----
    --
    -- trip_hash is now the key Integration hangs its maps on and Gold
    -- carries as trip_key, so Silver has to prove it is a usable key
    -- rather than leaving Gold to discover it isn't.

    UNION ALL
    SELECT 'trip_hash_not_null', 'NOT_NULL', 'FAIL', 0.0,
           COUNT_IF(trip_hash IS NULL), COUNT(*),
           'trip_hash is the published trip identity.'
    FROM clean

    UNION ALL
    SELECT 'trip_hash_unique', 'UNIQUE', 'FAIL', 0.0,
           COUNT(*) - COUNT(DISTINCT trip_hash), COUNT(*),
           'Unique within the clean set by construction: collision groups go to quarantine. A duplicate here means the duplicate policy did not hold.'
    FROM clean

    UNION ALL
    SELECT 'trip_hash_length', 'FORMAT', 'FAIL', 0.0,
           COUNT_IF(LENGTH(trip_hash) <> 64), COUNT(*),
           'sha2(..., 256) renders as 64 hex characters.'
    FROM clean

    UNION ALL
    SELECT 'trip_hash_disjoint_from_quarantine', 'CONSISTENCY', 'FAIL', 0.0,
           CAST((SELECT COUNT(*) FROM (
                SELECT trip_hash FROM clean INTERSECT SELECT trip_hash FROM quarantine)) AS BIGINT),
           GREATEST((SELECT COUNT(*) FROM quarantine), 1),
           'No quarantined identity may also appear in the clean table.'
    FROM (SELECT 1)

    -- ---- required fields ----

    UNION ALL
    SELECT 'vendor_id_not_null', 'NOT_NULL', 'FAIL', 0.0,
           COUNT_IF(vendor_id IS NULL), COUNT(*),
           'vendor_id must not be NULL.'
    FROM clean

    UNION ALL
    SELECT 'pickup_datetime_not_null', 'NOT_NULL', 'FAIL', 0.0,
           COUNT_IF(pickup_datetime_local IS NULL), COUNT(*),
           'pickup_datetime_local must not be NULL.'
    FROM clean

    UNION ALL
    SELECT 'dropoff_datetime_not_null', 'NOT_NULL', 'FAIL', 0.0,
           COUNT_IF(dropoff_datetime_local IS NULL), COUNT(*),
           'dropoff_datetime_local must not be NULL.'
    FROM clean

    UNION ALL
    SELECT 'pickup_location_not_null', 'NOT_NULL', 'FAIL', 0.0,
           COUNT_IF(pickup_location_id IS NULL), COUNT(*),
           'pickup_location_id must not be NULL; it is the zone join key.'
    FROM clean

    UNION ALL
    SELECT 'dropoff_location_not_null', 'NOT_NULL', 'FAIL', 0.0,
           COUNT_IF(dropoff_location_id IS NULL), COUNT(*),
           'dropoff_location_id must not be NULL; it is the zone join key.'
    FROM clean

    UNION ALL
    SELECT 'trip_duration_not_null_when_timestamps_present', 'COMPLETENESS', 'FAIL', 0.0,
           COUNT_IF(trip_duration_seconds IS NULL
                AND pickup_datetime_local IS NOT NULL
                AND dropoff_datetime_local IS NOT NULL), COUNT(*),
           'A trip with both timestamps must have a duration.'
    FROM clean

    -- ---- provenance, including the two columns Silver now carries ----

    UNION ALL
    SELECT 'provenance_completeness', 'PROVENANCE', 'FAIL', 0.0,
           COUNT_IF(source_system IS NULL OR TRIM(source_system) = ''
                 OR source_file IS NULL   OR TRIM(source_file) = ''
                 OR batch_id IS NULL      OR TRIM(batch_id) = ''
                 OR content_sha256 IS NULL
                 OR ingested_at IS NULL
                 OR silver_processed_at IS NULL), COUNT(*),
           'Every Silver row must carry Bronze provenance plus its Silver processing stamp.'
    FROM clean

    UNION ALL
    SELECT 'batch_registered_in_control', 'PROVENANCE', 'FAIL', 0.0,
           COUNT_IF(b.batch_id IS NULL), COUNT(*),
           'Every batch_id in Silver must have a SUCCESS row in ingestion_batches.'
    FROM clean t
    LEFT JOIN `ftw-week-08`.`01-control`.ingestion_batches b
           ON t.batch_id = b.batch_id AND b.status = 'SUCCESS'

    -- ---- duplicate policy (D10) ----

    UNION ALL
    SELECT 'duplicate_rows_quarantined', 'DUPLICATE_HANDLING', 'FAIL', 0.0,
           ABS(c.quarantine_rows - e.expected_quarantine_rows),
           GREATEST(e.expected_quarantine_rows, 1),
           CONCAT('quarantined: ', CAST(c.quarantine_rows AS STRING),
                  ', collision rows in Bronze: ', CAST(e.expected_quarantine_rows AS STRING))
    FROM counts c CROSS JOIN expected_quarantine e

    UNION ALL
    SELECT 'quarantine_reason_correct', 'DUPLICATE_HANDLING', 'FAIL', 0.0,
           COUNT_IF(quarantine_reasons IS NULL
                 OR NOT array_contains(quarantine_reasons, 'duplicate_hash_collision')),
           GREATEST(COUNT(*), 1),
           'Every quarantined row must record duplicate_hash_collision as its reason.'
    FROM quarantine

    -- ---- reconciliation ----
    --
    -- One check, not three. The old gate asserted bronze = clean +
    -- quarantine under three different names in three different blocks.

    UNION ALL
    SELECT 'bronze_to_silver_row_reconciliation', 'RECONCILIATION', 'FAIL', 0.0,
           ABS(bronze_rows - clean_rows - quarantine_rows), bronze_rows,
           CONCAT('bronze: ', CAST(bronze_rows AS STRING),
                  ' = clean: ', CAST(clean_rows AS STRING),
                  ' + quarantine: ', CAST(quarantine_rows AS STRING))
    FROM counts

    UNION ALL
    SELECT 'bronze_to_silver_fare_reconciliation', 'RECONCILIATION', 'FAIL', 0.0,
           CAST(CASE WHEN bronze_fare_total = silver_fare_total THEN 0 ELSE 1 END AS BIGINT), 1,
           CONCAT('bronze SUM(fare_amount): ', CAST(bronze_fare_total AS STRING),
                  ', silver clean+quarantine: ', CAST(silver_fare_total AS STRING))
    FROM measures

    -- ---- quality flags ----
    --
    -- IS NOT TRUE, never <> TRUE. `<> TRUE` evaluates to NULL for a null
    -- flag, so those rows are not counted -- which is how the previous
    -- gate reported zero failures across 18,754 null flags. IS NOT TRUE
    -- is true for both false and null, so the check survives the COALESCE
    -- in the cleaner being removed.

    UNION ALL
    SELECT 'flags_never_null', 'FLAG_VALIDATION', 'FAIL', 0.0,
           COUNT_IF(negative_fare_flag IS NULL
                 OR negative_distance_flag IS NULL
                 OR dropoff_before_pickup_flag IS NULL
                 OR implausible_duration_flag IS NULL
                 OR implausible_passenger_count_flag IS NULL
                 OR passenger_count_missing_flag IS NULL), COUNT(*),
           'Flags are two-valued by contract. A null flag makes WHERE NOT flag drop rows silently.'
    FROM clean

    UNION ALL
    SELECT 'negative_fare_flag_logic', 'FLAG_VALIDATION', 'FAIL', 0.0,
           COUNT_IF(fare_amount_usd IS NOT NULL AND fare_amount_usd < 0
                AND negative_fare_flag IS NOT TRUE), COUNT(*),
           'A negative fare must set negative_fare_flag.'
    FROM clean

    UNION ALL
    SELECT 'negative_distance_flag_logic', 'FLAG_VALIDATION', 'FAIL', 0.0,
           COUNT_IF(trip_distance_miles IS NOT NULL AND trip_distance_miles < 0
                AND negative_distance_flag IS NOT TRUE), COUNT(*),
           'A negative distance must set negative_distance_flag.'
    FROM clean

    UNION ALL
    SELECT 'dropoff_before_pickup_flag_logic', 'FLAG_VALIDATION', 'FAIL', 0.0,
           COUNT_IF(dropoff_datetime_local < pickup_datetime_local
                AND dropoff_before_pickup_flag IS NOT TRUE), COUNT(*),
           'A dropoff before its pickup must set dropoff_before_pickup_flag.'
    FROM clean

    UNION ALL
    SELECT 'implausible_duration_flag_logic', 'FLAG_VALIDATION', 'FAIL', 0.0,
           COUNT_IF((trip_duration_seconds <= 0 OR trip_duration_seconds > 86400)
                AND implausible_duration_flag IS NOT TRUE), COUNT(*),
           'A duration of zero or over 24h must set implausible_duration_flag.'
    FROM clean

    UNION ALL
    SELECT 'implausible_passenger_count_flag_logic', 'FLAG_VALIDATION', 'FAIL', 0.0,
           COUNT_IF(passenger_count IS NOT NULL
                AND (passenger_count < 0 OR passenger_count > 8)
                AND implausible_passenger_count_flag IS NOT TRUE), COUNT(*),
           'A passenger count below 0 or above 8 must set implausible_passenger_count_flag.'
    FROM clean

    -- Zero counts as missing, not implausible: it is a vendor reporting
    -- convention, not a data error. See the decision recorded alongside
    -- passenger_count_missing_flag in 10_clean_green_taxi.sql.
    UNION ALL
    SELECT 'passenger_count_missing_flag_logic', 'FLAG_VALIDATION', 'FAIL', 0.0,
           COUNT_IF((passenger_count IS NULL OR passenger_count = 0)
                AND passenger_count_missing_flag IS NOT TRUE), COUNT(*),
           'A null or zero passenger count must set passenger_count_missing_flag.'
    FROM clean

    UNION ALL
    SELECT 'passenger_count_flags_exclusive', 'FLAG_VALIDATION', 'FAIL', 0.0,
           COUNT_IF(passenger_count_missing_flag AND implausible_passenger_count_flag), COUNT(*),
           'A passenger count cannot be both missing and implausible.'
    FROM clean

    -- ---- measurements ----

    UNION ALL
    SELECT 'silver_column_types_observed', 'MEASURE', 'INFO', NULL,
           0, COUNT(*),
           CONCAT('types: ', ARRAY_JOIN(ARRAY_SORT(
               COLLECT_LIST(CONCAT(column_name, '=', data_type))), ', '))
    FROM schema_actual

    UNION ALL
    SELECT 'quality_flag_populations', 'MEASURE', 'INFO', NULL,
           0, COUNT(*),
           CONCAT('negative_fare: ',      CAST(COUNT_IF(negative_fare_flag) AS STRING),
                  ', negative_distance: ', CAST(COUNT_IF(negative_distance_flag) AS STRING),
                  ', dropoff_before_pickup: ', CAST(COUNT_IF(dropoff_before_pickup_flag) AS STRING),
                  ', implausible_duration: ',  CAST(COUNT_IF(implausible_duration_flag) AS STRING),
                  ', implausible_passengers: ', CAST(COUNT_IF(implausible_passenger_count_flag) AS STRING),
                  ', missing_passengers: ',     CAST(COUNT_IF(passenger_count_missing_flag) AS STRING))
    FROM clean

    UNION ALL
    SELECT 'pickup_date_range', 'MEASURE', 'INFO', NULL,
           0, COUNT(*),
           CONCAT('pickups from ', COALESCE(CAST(MIN(pickup_datetime_local) AS STRING), '<none>'),
                  ' to ',          COALESCE(CAST(MAX(pickup_datetime_local) AS STRING), '<none>'))
    FROM clean
)

SELECT
    dq_run_id,
    current_timestamp(),
    'silver',
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
    NULL,
    NULL,
    code_revision,
    gate_owner,
    NULL,
    details
FROM checks;


-- Gate result. Integration runs only when this returns cleanly.
SELECT CASE
         WHEN COUNT_IF(status = 'FAIL') > 0
         THEN raise_error(concat('Silver green_taxi gate BLOCKED: ',
                                 CAST(COUNT_IF(status = 'FAIL') AS STRING),
                                 ' failed checks'))
       END
FROM `ftw-week-08`.`01-control`.data_quality_results
WHERE run_id = dq_run_id;


-- Review the run:
-- SELECT check_name, status, severity, fail_count, total_count,
--        ROUND(fail_pct, 4) AS fail_pct, threshold_pct, details
-- FROM `ftw-week-08`.`01-control`.data_quality_results
-- WHERE layer = 'silver' AND dataset = 'green_taxi'
--   AND run_id = (SELECT run_id FROM `ftw-week-08`.`01-control`.data_quality_results
--                 WHERE layer = 'silver' AND dataset = 'green_taxi'
--                 ORDER BY executed_at DESC LIMIT 1)
-- ORDER BY status DESC, check_name;
