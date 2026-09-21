-- ============================================================
-- Silver: Taxi Zones reference
--
-- Stage:     03 Silver
-- Runs after: etl/02_bronze/90_validate_taxi_zones.sql
-- Target:    `ftw-week-08`.`03-silver`.taxi_zones_clean
-- Grain:     one row per source LocationID
--
-- Bronze columns: location_id, borough, zone, service_zone.
--
-- Bronze is a full refresh of the snapshot (D11): it updates rows whose
-- content changed and deletes rows the snapshot no longer contains. This
-- file mirrors all three branches. An insert-only MERGE would leave a
-- renamed zone showing its old name in Silver forever and a withdrawn
-- zone still present as a dimension member.
--
-- Sentinels 264 and 265 stay explicit members (D16), classified by
-- location_id rather than by borough -- the source is not symmetric
-- about them: 264 is Unknown / N/A / N/A while 265 is N/A / Outside of
-- NYC / N/A.
--
-- Casing rule, because "standardize" means two different things here and
-- the two are deliberate:
--   * borough and zone_name are PROPER NAMES. Trim whitespace, keep the
--     source's casing, so 'Manhattan' stays 'Manhattan' and can be shown
--     to a reader without re-capitalising it.
--   * service_zone is a CODED CATEGORY over a small fixed domain, so it
--     is lower-cased and 'N/A' becomes 'na'.
--   * zone_classification is the canonical coded form, always lower case.
-- Anything that needs a case-insensitive comparison should use
-- zone_classification rather than lower-casing borough at the point of use.
-- ============================================================

CREATE TABLE IF NOT EXISTS `ftw-week-08`.`03-silver`.taxi_zones_clean (

    location_id INT,

    borough STRING,
    zone_name STRING,
    service_zone STRING,

    zone_classification STRING,

    source_system STRING,
    source_file STRING,
    source_file_version STRING,
    content_sha256 STRING,
    batch_id STRING,
    ingested_at TIMESTAMP,

    silver_processed_at TIMESTAMP
);


DECLARE OR REPLACE VARIABLE silver_run_at TIMESTAMP;
SET VARIABLE silver_run_at = current_timestamp();


MERGE INTO `ftw-week-08`.`03-silver`.taxi_zones_clean AS target

USING (

    SELECT

        CAST(location_id AS INT) AS location_id,

        TRIM(borough) AS borough,

        TRIM(zone) AS zone_name,

        CASE
            WHEN service_zone = 'N/A' THEN 'na'
            ELSE LOWER(TRIM(service_zone))
        END AS service_zone,

        -- TRIM(borough) here too, not the raw column: line 57 trims it for
        -- storage, so an untrimmed comparison would classify a padded
        -- 'Queens ' as other_special while storing it as 'Queens'.
        CASE
            WHEN location_id = 264 THEN 'unknown'
            WHEN location_id = 265 THEN 'outside_nyc'
            WHEN TRIM(borough) = 'EWR' THEN 'ewr'
            WHEN TRIM(borough) IN (
                'Bronx',
                'Brooklyn',
                'Manhattan',
                'Queens',
                'Staten Island'
            ) THEN 'nyc_borough'
            ELSE 'other_special'
        END AS zone_classification,

        -- Carried from Bronze, not relabelled. Bronze and
        -- ingestion_batches both record this source as 'taxi_zones'; the
        -- previous literal 'nyc_tlc_taxi_zones' meant a Silver row could
        -- not be joined back to its own batch on source_system.
        source_system,

        source_file,
        source_file_version,
        content_sha256,
        batch_id,
        ingested_at,

        silver_run_at AS silver_processed_at

    FROM `ftw-week-08`.`02-bronze`.taxi_zones_raw

) AS source

ON target.location_id = source.location_id

-- Business content changed in the snapshot. <=> is null-safe; = would
-- treat null <> null as a change and rewrite the row every run.
-- Business content OR lineage. Comparing business values alone left Silver
-- pointing at a batch Bronze had since demoted, which
-- batch_registered_in_control rejects. batch_id is safe to compare because
-- Bronze only issues a new one when something genuinely changed.
WHEN MATCHED AND NOT (
         target.borough             <=> source.borough
     AND target.zone_name           <=> source.zone_name
     AND target.service_zone        <=> source.service_zone
     AND target.zone_classification <=> source.zone_classification
     AND target.source_system       <=> source.source_system
     AND target.content_sha256      <=> source.content_sha256
     AND target.batch_id            <=> source.batch_id
)
THEN UPDATE SET
    borough             = source.borough,
    zone_name           = source.zone_name,
    service_zone        = source.service_zone,
    zone_classification = source.zone_classification,
    source_system       = source.source_system,
    source_file         = source.source_file,
    source_file_version = source.source_file_version,
    content_sha256      = source.content_sha256,
    batch_id            = source.batch_id,
    ingested_at         = source.ingested_at,
    silver_processed_at = source.silver_processed_at

WHEN NOT MATCHED THEN INSERT (
    location_id,
    borough,
    zone_name,
    service_zone,
    zone_classification,
    source_system,
    source_file,
    source_file_version,
    content_sha256,
    batch_id,
    ingested_at,
    silver_processed_at
)
VALUES (
    source.location_id,
    source.borough,
    source.zone_name,
    source.service_zone,
    source.zone_classification,
    source.source_system,
    source.source_file,
    source.source_file_version,
    source.content_sha256,
    source.batch_id,
    source.ingested_at,
    source.silver_processed_at
)

-- A zone withdrawn from the snapshot leaves Silver, so Silver stays equal
-- to the snapshot Bronze holds. Trips referencing a withdrawn zone then
-- surface as unmatched in the Integration gate rather than silently
-- resolving to a zone the source no longer publishes.
WHEN NOT MATCHED BY SOURCE THEN DELETE;
