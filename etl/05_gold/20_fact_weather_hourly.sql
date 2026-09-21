-- ============================================================
-- Gold: fact_weather_hourly
--
-- Grain: one row per coordinate, UTC observation hour and weather model.
-- Business key: (coordinate_id, observation_timestamp_utc, weather_model).
-- The deterministic weather_observation_key is produced in Silver from that
-- business key and is reused here.
-- ============================================================

CREATE TABLE IF NOT EXISTS `ftw-week-08`.`05-gold`.fact_weather_hourly (
    weather_observation_key STRING NOT NULL,
    observation_date_key INT,
    observation_hour_key INT,
    weather_classification_key STRING,
    coordinate_id STRING,
    -- TIMESTAMP_NTZ, matching Silver. A plain TIMESTAMP would resolve Silver's
    -- values through the cluster's session timezone on insert, undoing the
    -- conversion fix in 20_clean_weather_hourly.sql.
    observation_timestamp_utc TIMESTAMP_NTZ,
    observation_timestamp_local TIMESTAMP_NTZ,
    weather_model STRING,
    temperature_2m_c DECIMAL(8,3),
    precipitation_mm DECIMAL(10,3),
    weather_code INT,
    requested_latitude DECIMAL(9,6),
    requested_longitude DECIMAL(9,6),
    returned_latitude DECIMAL(9,6),
    returned_longitude DECIMAL(9,6),
    elevation_m DECIMAL(10,3),
    source_system STRING,
    source_url STRING,
    source_response_version STRING,
    batch_id STRING,
    run_id STRING,
    ingested_at TIMESTAMP,
    gold_processed_at TIMESTAMP
)
USING DELTA;

-- Negative precipitation is invalid upstream. Keeping its band null makes the
-- missing classification visible to the blocking Gold gate instead of silently
-- assigning the observation to the light band.
CREATE OR REPLACE TEMP VIEW gold_weather_banded AS
SELECT
    s.*,
    CASE
        WHEN s.precipitation_mm IS NULL OR s.precipitation_mm < 0 THEN NULL
        WHEN s.precipitation_mm = 0 THEN 'dry'
        WHEN s.precipitation_mm <= 2.5 THEN 'light'
        WHEN s.precipitation_mm <= 7.5 THEN 'moderate'
        ELSE 'heavy'
    END AS precipitation_band
FROM `ftw-week-08`.`03-silver`.weather_hourly AS s;

-- Date, hour and weather-classification keys are resolved only against the
-- built Gold dimensions. LEFT JOIN preserves a bad row so validation can
-- report it; the pre-write guard below prevents publishing missing required FKs.
CREATE OR REPLACE TEMP VIEW gold_weather_resolved AS
SELECT
    w.weather_observation_key,
    d.date_key AS observation_date_key,
    h.hour_key AS observation_hour_key,
    c.weather_classification_key,
    w.coordinate_id,
    w.observation_timestamp_utc,
    w.observation_timestamp_local,
    w.weather_model,
    w.temperature_2m_c,
    w.precipitation_mm,
    w.weather_code,
    w.requested_latitude,
    w.requested_longitude,
    w.returned_latitude,
    w.returned_longitude,
    w.elevation_m,
    w.source_system,
    w.source_url,
    w.source_response_version,
    w.batch_id,
    w.run_id,
    w.ingested_at,
    current_timestamp() AS gold_processed_at
FROM gold_weather_banded AS w
LEFT JOIN `ftw-week-08`.`05-gold`.dim_date AS d
    ON w.observation_date_local = d.full_date
LEFT JOIN `ftw-week-08`.`05-gold`.dim_hour AS h
    ON w.observation_hour_local = h.hour_of_day
LEFT JOIN `ftw-week-08`.`05-gold`.dim_weather_classification AS c
    ON w.weather_code = c.weather_code
   AND w.precipitation_band = c.precipitation_band;

-- A dimension duplicate would fan out the fact. A missing required dimension
-- member would create an invalid published FK. Both conditions block the write.
SELECT CASE
         WHEN (SELECT COUNT(*) FROM gold_weather_resolved)
              <> (SELECT COUNT(*) FROM `ftw-week-08`.`03-silver`.weather_hourly)
         THEN raise_error('fact_weather_hourly: dimension join changed the Silver grain')
       END;

SELECT CASE
         WHEN COUNT_IF(
             observation_date_key IS NULL
             OR observation_hour_key IS NULL
             OR weather_classification_key IS NULL
         ) > 0
         THEN raise_error('fact_weather_hourly: one or more required dimension keys did not resolve')
       END
FROM gold_weather_resolved;

-- Silver is currently rebuilt as a complete accepted snapshot. The delete arm
-- therefore removes observations that disappeared from a revised source
-- contribution and makes the rerun converge to the same fact state.
MERGE INTO `ftw-week-08`.`05-gold`.fact_weather_hourly AS target
USING gold_weather_resolved AS source
ON target.weather_observation_key = source.weather_observation_key
WHEN MATCHED THEN UPDATE SET *
WHEN NOT MATCHED THEN INSERT *
WHEN NOT MATCHED BY SOURCE THEN DELETE;

SELECT
    (SELECT COUNT(*)
     FROM `ftw-week-08`.`03-silver`.weather_hourly) AS silver_rows,
    (SELECT COUNT(*)
     FROM `ftw-week-08`.`05-gold`.fact_weather_hourly) AS gold_rows,
    (SELECT COUNT_IF(weather_classification_key IS NULL)
     FROM `ftw-week-08`.`05-gold`.fact_weather_hourly) AS unresolved_classification_rows;
