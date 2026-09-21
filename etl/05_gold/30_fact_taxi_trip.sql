-- ============================================================
-- Gold: fact_taxi_trip
-- Grain: one row per accepted Green Taxi trip after the D10 duplicate policy.
-- The fact keeps anomalous measures as flagged rows; only duplicate collision
-- groups quarantined in Silver are excluded.
-- ============================================================

CREATE TABLE IF NOT EXISTS `ftw-week-08`.`05-gold`.fact_taxi_trip (
    trip_key STRING NOT NULL,
    pickup_date_key INT,
    dropoff_date_key INT,
    pickup_hour_key INT,
    dropoff_hour_key INT,
    pickup_zone_key BIGINT,
    dropoff_zone_key BIGINT,
    pickup_weather_classification_key STRING,
    vendor_id INT,
    -- TIMESTAMP_NTZ, matching Silver and Integration. A plain TIMESTAMP here
    -- would convert those values through the cluster's session timezone on
    -- insert, undoing the determinism fix one layer down.
    pickup_datetime_local TIMESTAMP_NTZ,
    dropoff_datetime_local TIMESTAMP_NTZ,
    pickup_timestamp_utc TIMESTAMP_NTZ,
    dropoff_timestamp_utc TIMESTAMP_NTZ,
    store_and_fwd_flag STRING,
    rate_code_id INT,
    pickup_location_id INT,
    dropoff_location_id INT,
    passenger_count DECIMAL(10,2),
    trip_distance_miles DECIMAL(18,3),
    fare_amount_usd DECIMAL(18,2),
    extra_amount_usd DECIMAL(18,2),
    mta_tax_amount_usd DECIMAL(18,2),
    tip_amount_usd DECIMAL(18,2),
    tolls_amount_usd DECIMAL(18,2),
    ehail_fee_amount_usd DECIMAL(18,2),
    improvement_surcharge_amount_usd DECIMAL(18,2),
    total_amount_usd DECIMAL(18,2),
    payment_type_id INT,
    trip_type_id INT,
    congestion_surcharge_amount_usd DECIMAL(18,2),
    cbd_congestion_fee_amount_usd DECIMAL(18,2),
    trip_duration_seconds BIGINT,
    trip_count INT,
    pickup_in_reporting_window_flag BOOLEAN,
    out_of_source_file_month_flag BOOLEAN,
    dropoff_before_pickup_flag BOOLEAN,
    negative_trip_distance_flag BOOLEAN,
    negative_fare_amount_flag BOOLEAN,
    negative_total_amount_flag BOOLEAN,
    zero_distance_high_fare_flag BOOLEAN,
    passenger_count_zero_flag BOOLEAN,
    passenger_count_over_8_flag BOOLEAN,
    pickup_zone_match_status STRING,
    dropoff_zone_match_status STRING,
    weather_match_status STRING,
    source_system STRING,
    source_file STRING,
    source_file_version STRING,
    source_row_locator STRING,
    batch_id STRING,
    run_id STRING,
    ingested_at TIMESTAMP,
    gold_processed_at TIMESTAMP
)
USING DELTA;

-- One run identifier is evaluated once for the entire fact build.
DECLARE OR REPLACE VARIABLE gold_run_id STRING;
SET VARIABLE gold_run_id = uuid();

-- Step 1: trip identity, UTC conversions, measures and flags.
--
-- trip_key is Silver's published trip_hash (D19), not a hash recomputed here.
-- The old version serialized the TYPED Silver columns, which is a different
-- string over rounded values, so one identity had two definitions with
-- nothing keeping them in step.
--
-- Trip attributes come from Silver and match outcomes from the two
-- Integration maps, joined on trip_hash. Stage 04 owns only the match
-- outcome, so trip columns exist in exactly one place.
CREATE OR REPLACE TEMP VIEW gold_trip_base AS
SELECT
    t.trip_hash AS trip_key,
    t.vendor_id,
    t.pickup_datetime_local,
    t.dropoff_datetime_local,
    wx.pickup_timestamp_utc,
    -- convert_timezone, not to_utc_timestamp: the latter resolves a
    -- TIMESTAMP_NTZ through the session timezone, the same defect fixed in
    -- Silver weather.
    convert_timezone('America/New_York', 'UTC', t.dropoff_datetime_local) AS dropoff_timestamp_utc,
    t.store_and_fwd_flag,
    t.rate_code_id,
    t.pickup_location_id,
    t.dropoff_location_id,
    CAST(t.passenger_count AS DECIMAL(10,2)) AS passenger_count,
    t.trip_distance_miles,
    t.fare_amount_usd,
    t.extra_amount_usd,
    t.mta_tax_amount_usd,
    t.tip_amount_usd,
    t.tolls_amount_usd,
    t.ehail_fee_amount_usd,
    t.improvement_surcharge_amount_usd,
    t.total_amount_usd,
    t.payment_type_id,
    t.trip_type_id,
    t.congestion_surcharge_amount_usd,
    t.cbd_congestion_fee_amount_usd,
    t.trip_duration_seconds,
    COALESCE(
        t.pickup_datetime_local >= TIMESTAMP '2026-03-01 00:00:00'
        AND t.pickup_datetime_local < TIMESTAMP '2026-06-01 00:00:00',
        FALSE
    ) AS pickup_in_reporting_window_flag,
    COALESCE(
        date_format(t.pickup_datetime_local, 'yyyy-MM')
        <> regexp_extract(t.source_file, 'green_tripdata_([0-9]{4}-[0-9]{2})', 1),
        FALSE
    ) AS out_of_source_file_month_flag,
    COALESCE(t.dropoff_before_pickup_flag, FALSE) AS dropoff_before_pickup_flag,
    COALESCE(t.negative_distance_flag, FALSE) AS negative_trip_distance_flag,
    COALESCE(t.negative_fare_flag, FALSE) AS negative_fare_amount_flag,
    COALESCE(t.total_amount_usd < 0, FALSE) AS negative_total_amount_flag,
    COALESCE(t.trip_distance_miles = 0 AND t.fare_amount_usd > 20, FALSE)
        AS zero_distance_high_fare_flag,
    COALESCE(t.passenger_count = 0, FALSE) AS passenger_count_zero_flag,
    COALESCE(t.passenger_count > 8, FALSE) AS passenger_count_over_8_flag,
    z.pickup_zone_match_status,
    z.dropoff_zone_match_status,
    wx.pickup_weather_observation_key,
    wx.pickup_weather_match_status,
    t.source_system,
    t.source_file,
    t.batch_id,
    t.ingested_at
FROM `ftw-week-08`.`03-silver`.green_taxi_clean AS t
-- Inner joins on purpose: the Integration gate has already proven both maps
-- cover every accepted trip exactly once, so a missing row is a broken
-- invariant that the guard below should catch, not a trip to carry forward.
JOIN `ftw-week-08`.`04-integration`.trip_zone_map    AS z  ON z.trip_hash  = t.trip_hash
JOIN `ftw-week-08`.`04-integration`.trip_weather_map AS wx ON wx.trip_hash = t.trip_hash;

-- Step 2: resolve both role-playing Taxi Zone keys only against the built Gold
-- dimension. The match statuses were already assigned and validated in Stage 04.
CREATE OR REPLACE TEMP VIEW gold_trip_zones AS
SELECT
    b.*,
    pz.zone_key AS pickup_zone_key,
    dz.zone_key AS dropoff_zone_key
FROM gold_trip_base AS b
LEFT JOIN `ftw-week-08`.`05-gold`.dim_taxi_zone AS pz
    ON b.pickup_location_id = pz.location_id
LEFT JOIN `ftw-week-08`.`05-gold`.dim_taxi_zone AS dz
    ON b.dropoff_location_id = dz.location_id;

-- Every grain guard now measures against Silver's accepted-trip count, which
-- is the grain the whole chain is supposed to preserve.
SELECT CASE
         WHEN (SELECT COUNT(*) FROM gold_trip_base)
              <> (SELECT COUNT(*) FROM `ftw-week-08`.`03-silver`.green_taxi_clean)
         THEN raise_error('fact_taxi_trip: Integration map joins changed the trip grain')
       END;

SELECT CASE
         WHEN (SELECT COUNT(*) FROM gold_trip_zones)
              <> (SELECT COUNT(*) FROM `ftw-week-08`.`03-silver`.green_taxi_clean)
         THEN raise_error('fact_taxi_trip: Taxi Zone joins changed the trip grain')
       END;

-- Step 3: resolve Integration's unique pickup weather-observation key to the
-- weather fact, then copy only its classification key. Weather measures remain
-- on fact_weather_hourly.
CREATE OR REPLACE TEMP VIEW gold_trip_weather AS
SELECT
    z.*,
    w.weather_classification_key AS pickup_weather_classification_key
FROM gold_trip_zones AS z
LEFT JOIN `ftw-week-08`.`05-gold`.fact_weather_hourly AS w
    ON z.pickup_weather_observation_key = w.weather_observation_key;

SELECT CASE
         WHEN (SELECT COUNT(*) FROM gold_trip_weather)
              <> (SELECT COUNT(*) FROM gold_trip_zones)
         THEN raise_error('fact_taxi_trip: ambiguous weather match changed the trip grain')
       END;

SELECT CASE
         WHEN COUNT_IF(
             pickup_weather_match_status = 'matched_unique'
             AND pickup_weather_classification_key IS NULL
         ) > 0
         THEN raise_error('fact_taxi_trip: Integration weather key did not resolve to fact_weather_hourly')
       END
FROM gold_trip_weather;

-- Step 4: resolve Date and Hour FKs from the built role-playing dimensions.
CREATE OR REPLACE TEMP VIEW gold_trip_dimensions AS
SELECT
    w.*,
    pd.date_key AS pickup_date_key,
    dd.date_key AS dropoff_date_key,
    ph.hour_key AS pickup_hour_key,
    dh.hour_key AS dropoff_hour_key
FROM gold_trip_weather AS w
LEFT JOIN `ftw-week-08`.`05-gold`.dim_date AS pd
    ON CAST(w.pickup_datetime_local AS DATE) = pd.full_date
LEFT JOIN `ftw-week-08`.`05-gold`.dim_date AS dd
    ON CAST(w.dropoff_datetime_local AS DATE) = dd.full_date
LEFT JOIN `ftw-week-08`.`05-gold`.dim_hour AS ph
    ON HOUR(w.pickup_datetime_local) = ph.hour_of_day
LEFT JOIN `ftw-week-08`.`05-gold`.dim_hour AS dh
    ON HOUR(w.dropoff_datetime_local) = dh.hour_of_day;

SELECT CASE
         WHEN (SELECT COUNT(*) FROM gold_trip_dimensions)
              <> (SELECT COUNT(*) FROM gold_trip_weather)
         THEN raise_error('fact_taxi_trip: Date or Hour joins changed the trip grain')
       END;

SELECT CASE
         WHEN COUNT_IF(
             pickup_date_key IS NULL
             OR dropoff_date_key IS NULL
             OR pickup_hour_key IS NULL
             OR dropoff_hour_key IS NULL
         ) > 0
         THEN raise_error('fact_taxi_trip: one or more required Date/Hour keys did not resolve')
       END
FROM gold_trip_dimensions;

-- The control table supplies the immutable source version. Grouping by batch
-- prevents an accidental duplicate control row from fanning out the fact; the
-- control_row_count guard still blocks publication if that invariant is broken.
CREATE OR REPLACE TEMP VIEW gold_taxi_batch_versions AS
SELECT
    batch_id,
    MAX(source_version_id) AS source_file_version,
    COUNT(*) AS control_row_count
FROM `ftw-week-08`.`01-control`.ingestion_batches
WHERE source_system = 'green_taxi'
  AND status = 'SUCCESS'
GROUP BY batch_id;

CREATE OR REPLACE TEMP VIEW gold_trip_final AS
SELECT
    d.trip_key,
    d.pickup_date_key,
    d.dropoff_date_key,
    d.pickup_hour_key,
    d.dropoff_hour_key,
    d.pickup_zone_key,
    d.dropoff_zone_key,
    d.pickup_weather_classification_key,
    d.vendor_id,
    d.pickup_datetime_local,
    d.dropoff_datetime_local,
    d.pickup_timestamp_utc,
    d.dropoff_timestamp_utc,
    d.store_and_fwd_flag,
    d.rate_code_id,
    d.pickup_location_id,
    d.dropoff_location_id,
    d.passenger_count,
    d.trip_distance_miles,
    d.fare_amount_usd,
    d.extra_amount_usd,
    d.mta_tax_amount_usd,
    d.tip_amount_usd,
    d.tolls_amount_usd,
    d.ehail_fee_amount_usd,
    d.improvement_surcharge_amount_usd,
    d.total_amount_usd,
    d.payment_type_id,
    d.trip_type_id,
    d.congestion_surcharge_amount_usd,
    d.cbd_congestion_fee_amount_usd,
    d.trip_duration_seconds,
    1 AS trip_count,
    d.pickup_in_reporting_window_flag,
    d.out_of_source_file_month_flag,
    d.dropoff_before_pickup_flag,
    d.negative_trip_distance_flag,
    d.negative_fare_amount_flag,
    d.negative_total_amount_flag,
    d.zero_distance_high_fare_flag,
    d.passenger_count_zero_flag,
    d.passenger_count_over_8_flag,
    d.pickup_zone_match_status,
    d.dropoff_zone_match_status,
    d.pickup_weather_match_status AS weather_match_status,
    d.source_system,
    d.source_file,
    b.source_file_version,
    CAST(NULL AS STRING) AS source_row_locator,
    d.batch_id,
    gold_run_id AS run_id,
    d.ingested_at,
    current_timestamp() AS gold_processed_at,
    b.control_row_count
FROM gold_trip_dimensions AS d
LEFT JOIN gold_taxi_batch_versions AS b
    ON d.batch_id = b.batch_id;

-- Pre-publication grain and lineage guards.
SELECT CASE
         WHEN COUNT(*) > 0
         THEN raise_error('fact_taxi_trip: duplicate deterministic trip_key values in staged rows')
       END
FROM (
    SELECT trip_key
    FROM gold_trip_final
    GROUP BY trip_key
    HAVING COUNT(*) > 1
);

SELECT CASE
         WHEN COUNT_IF(
             source_file_version IS NULL
             OR control_row_count IS NULL
             OR control_row_count <> 1
         ) > 0
         THEN raise_error('fact_taxi_trip: source version did not resolve uniquely from ingestion_batches')
       END
FROM gold_trip_final;

MERGE INTO `ftw-week-08`.`05-gold`.fact_taxi_trip AS target
USING (
    SELECT * EXCEPT (control_row_count)
    FROM gold_trip_final
) AS source
ON target.trip_key = source.trip_key
WHEN MATCHED THEN UPDATE SET *
WHEN NOT MATCHED THEN INSERT *
WHEN NOT MATCHED BY SOURCE THEN DELETE;

SELECT
    (SELECT COUNT(*)
     FROM `ftw-week-08`.`03-silver`.green_taxi_clean) AS silver_clean_rows,
    (SELECT SUM(trip_count)
     FROM `ftw-week-08`.`05-gold`.fact_taxi_trip) AS gold_trip_count,
    (SELECT ROUND(SUM(fare_amount_usd), 2)
     FROM `ftw-week-08`.`03-silver`.green_taxi_clean) AS silver_fare_total,
    (SELECT ROUND(SUM(fare_amount_usd), 2)
     FROM `ftw-week-08`.`05-gold`.fact_taxi_trip) AS gold_fare_total,
    (SELECT COUNT_IF(pickup_zone_key IS NULL)
     FROM `ftw-week-08`.`05-gold`.fact_taxi_trip) AS null_pickup_zone_keys,
    (SELECT COUNT_IF(weather_match_status = 'no_match')
     FROM `ftw-week-08`.`05-gold`.fact_taxi_trip) AS weather_no_match_rows;
