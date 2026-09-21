-- Gold dimension: dim_taxi_zone (issue #36).
--
-- Grain: one row per Taxi Zone LocationID.
--
-- SCD: Type 0 / full refresh.
--
-- Built from Silver taxi_zones_clean.
--
-- D07 approved no SCD Type 2 behaviour.
--
-- Borough values are passed through exactly as supplied by Silver.
-- Any source-value corrections belong upstream in Silver.
--
-- Classification rules are applied in the approved order:
--
-- 1. 264 -> unknown
-- 2. 265 -> outside_nyc
-- 3. EWR -> ewr
-- 4. NYC boroughs -> nyc_borough
-- 5. Everything else -> other_special
--
-- zone_key uses a deterministic cast of location_id because
-- LocationID is already a stable unique business key.

CREATE OR REPLACE TABLE `ftw-week-08`.`05-gold`.dim_taxi_zone AS

SELECT

    CAST(location_id AS BIGINT) AS zone_key,

    location_id,

    zone_name,

    borough,

    service_zone,

    CASE
        WHEN location_id = 264 THEN 'unknown'

        WHEN location_id = 265 THEN 'outside_nyc'

        WHEN UPPER(TRIM(borough)) = 'EWR'
            THEN 'ewr'

        WHEN UPPER(TRIM(borough)) IN (
            'BRONX',
            'BROOKLYN',
            'MANHATTAN',
            'QUEENS',
            'STATEN ISLAND'
        )
            THEN 'nyc_borough'

        ELSE 'other_special'
    END AS zone_classification,

    source_system,

    source_file,

    source_file_version,

    batch_id,

    ingested_at

FROM `ftw-week-08`.`03-silver`.taxi_zones_clean;