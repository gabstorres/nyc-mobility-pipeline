-- ============================================================
-- Silver: Green Taxi trips
-- typed, validated, deduplicated at the declared grain
--
-- trip_hash is computed from raw Bronze values BEFORE any casting,
-- so rounding during typing (e.g. trip_distance, fare_amount to
-- DECIMAL) can never change the hash and silently create false
-- collisions or diverge from the hash tested in Issue #14.
--
-- Quarantine policy (D10 + D15): only duplicate hash collisions are
-- quarantined. Negative fares/distances, dropoff-before-pickup,
-- implausible durations, and implausible passenger counts stay in
-- the clean table, tagged with flag columns instead — an ineligible
-- value for one measure must not exclude the row from unrelated
-- measures.
-- ============================================================

-- One timestamp for the whole run, so the clean and quarantine tables
-- carry the same silver_processed_at rather than two evaluations of
-- current_timestamp().
DECLARE OR REPLACE VARIABLE silver_run_at TIMESTAMP;
SET VARIABLE silver_run_at = current_timestamp();


CREATE OR REPLACE TEMP VIEW silver_typed AS
SELECT
    -- to_json with ignoreNullFields=false rather than concat_ws: concat_ws
    -- silently DROPS null arguments, so a null in any identity input
    -- shifts the remaining values left and lets two genuinely different
    -- trips produce one hash -- which would quarantine real trips. There
    -- are no nulls in these seven columns today, so this changes hash
    -- values without changing the collision outcome (still 7 groups,
    -- 14 rows), and it is cheapest to change now, before anything
    -- downstream persists the hash.
    sha2(to_json(struct(
        VendorID,
        lpep_pickup_datetime,
        lpep_dropoff_datetime,
        PULocationID,
        DOLocationID,
        trip_distance,
        fare_amount
    ), map('ignoreNullFields', 'false')), 256) AS trip_hash,

    CAST(VendorID AS INT) AS vendor_id,
    lpep_pickup_datetime AS pickup_datetime_local,
    lpep_dropoff_datetime AS dropoff_datetime_local,
    -- timestampdiff, not unix_timestamp: unix_timestamp resolves a
    -- TIMESTAMP_NTZ through the SESSION timezone, so a trip crossing
    -- 02:00 on 8 March 2026 (NYC DST start) gets a different duration on
    -- a UTC cluster than on an America/New_York one. This is wall-clock
    -- elapsed time, independent of session state.
    timestampdiff(SECOND, lpep_pickup_datetime, lpep_dropoff_datetime) AS trip_duration_seconds,
    store_and_fwd_flag,
    CAST(RatecodeID AS INT) AS rate_code_id,
    CAST(PULocationID AS INT) AS pickup_location_id,
    CAST(DOLocationID AS INT) AS dropoff_location_id,
    CAST(passenger_count AS INT) AS passenger_count,
    CAST(trip_distance AS DECIMAL(18,3)) AS trip_distance_miles,
    CAST(fare_amount AS DECIMAL(18,2)) AS fare_amount_usd,
    CAST(extra AS DECIMAL(18,2)) AS extra_amount_usd,
    CAST(mta_tax AS DECIMAL(18,2)) AS mta_tax_amount_usd,
    CAST(tip_amount AS DECIMAL(18,2)) AS tip_amount_usd,
    CAST(tolls_amount AS DECIMAL(18,2)) AS tolls_amount_usd,
    CAST(ehail_fee AS DECIMAL(18,2)) AS ehail_fee_amount_usd,
    CAST(improvement_surcharge AS DECIMAL(18,2)) AS improvement_surcharge_amount_usd,
    CAST(total_amount AS DECIMAL(18,2)) AS total_amount_usd,
    CAST(payment_type AS INT) AS payment_type_id,
    CAST(trip_type AS INT) AS trip_type_id,
    CAST(congestion_surcharge AS DECIMAL(18,2)) AS congestion_surcharge_amount_usd,
    CAST(cbd_congestion_fee AS DECIMAL(18,2)) AS cbd_congestion_fee_amount_usd,
    -- content_sha256 identifies WHICH VERSION of the source file this row
    -- came from, so a Silver row stays traceable to a specific landed file
    -- rather than only to the batch that loaded it.
    source_system, source_file, content_sha256, ingested_at, batch_id,
    silver_run_at AS silver_processed_at
FROM `ftw-week-08`.`02-bronze`.green_taxi_raw;


-- Step 2: quality flags + collision count (trip_hash computed above, untouched)
-- Every flag is COALESCEd to false so it is strictly two-valued. Without
-- it, a null input makes the flag null, and a downstream
-- `WHERE NOT some_flag` silently drops those rows -- NOT NULL is NULL,
-- not true. This is not hypothetical: 18,754 rows (14%) have a null
-- passenger_count, as the Bronze gate measures every run.
--
-- A flag therefore means "we know this row has this problem". Not knowing
-- is a different statement, so passenger_count_missing_flag carries it
-- explicitly instead of being collapsed into false.
--
-- passenger_count = 0 counts as MISSING, not implausible. Profiling the
-- three source files shows it is a vendor reporting convention rather
-- than a data error: vendor 6 reports null for 100% of its 14,181 trips
-- and vendor 1 writes 0 on 14.28% of its trips, while the trips
-- themselves are ordinary (median fare $14.90 against $14.20 for trips
-- with a recorded count). Leaving 0 unflagged would let AVG and SUM over
-- passenger_count average those zeros in while dropping the nulls, which
-- biases every passenger measure low.
CREATE OR REPLACE TEMP VIEW silver_decided AS
SELECT *,
    COUNT(*) OVER (PARTITION BY trip_hash) AS collision_count,
    COALESCE(fare_amount_usd < 0, false) AS negative_fare_flag,
    COALESCE(trip_distance_miles < 0, false) AS negative_distance_flag,
    COALESCE(dropoff_datetime_local < pickup_datetime_local, false) AS dropoff_before_pickup_flag,
    COALESCE(trip_duration_seconds <= 0 OR trip_duration_seconds > 86400, false) AS implausible_duration_flag,
    COALESCE(passenger_count < 0 OR passenger_count > 8, false) AS implausible_passenger_count_flag,
    (passenger_count IS NULL OR passenger_count = 0) AS passenger_count_missing_flag
FROM silver_typed;


-- Step 3: split by DUPLICATE STATUS ONLY (per D10/D15).
-- All quality flags above stay on green_taxi_clean regardless of value —
-- they inform downstream measure eligibility, they don't exclude the row.
--
-- trip_hash is PUBLISHED, not dropped (D19). It is unique within the clean
-- set by construction -- that is exactly what collision_count = 1 means --
-- so it is the trip's identity for every downstream layer: Integration
-- hangs its key maps on it and Gold carries it as trip_key. Dropping it
-- used to force Gold to recompute a hash of its own over the TYPED
-- columns, which is a different serialization over rounded values, so two
-- definitions of one identity existed with nothing keeping them in step.
CREATE OR REPLACE TABLE `ftw-week-08`.`03-silver`.green_taxi_clean AS
SELECT * EXCEPT (collision_count)
FROM silver_decided
WHERE collision_count = 1;

CREATE OR REPLACE TABLE `ftw-week-08`.`03-silver`.green_taxi_quarantine AS
SELECT *,
    array('duplicate_hash_collision') AS quarantine_reasons
FROM silver_decided
WHERE collision_count > 1;