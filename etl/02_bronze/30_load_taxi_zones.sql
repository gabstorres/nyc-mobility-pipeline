-- ============================================================
-- Bronze: NYC Taxi Zones reference snapshot
--
-- Stage: 02 Bronze
-- Runs after: etl/01_control/00_create_control_tables.sql
-- Target: `ftw-week-08`.`02-bronze`.taxi_zones_raw
-- Grain: one row per source LocationID
--
-- D11 keeps this a full-refresh reference snapshot: 265 rows, delivered complete, no incremental row logic. It is implemented as a MERGE rather than CREATE OR REPLACE so that rerunning an unchanged snapshot changes nothing at all -- an overwrite would reset ingested_at on every row,  which validation.md's repeat-run proof forbids. The end state is identical to a full refresh: the target mirrors the snapshot exactly, including rows removed from it.
--
-- The source path appears exactly ONCE, inside read_files. Everything else, file name, size, modification time, uri, is derived from _metadata, so provenance cannot drift from the file actually read.
-- ============================================================

CREATE TABLE IF NOT EXISTS `ftw-week-08`.`02-bronze`.taxi_zones_raw (
    location_id INT,
    borough STRING,
    zone STRING,
    service_zone STRING,

    -- provenance
    source_system STRING,
    source_file STRING,
    source_file_version STRING,   -- content-derived; see zones_version_id below
    content_sha256 STRING,
    batch_id STRING,
    ingested_at TIMESTAMP
)
USING DELTA;


-- ------------------------------------------------------------
-- Read the snapshot once. Business columns and file metadata together.
-- ------------------------------------------------------------
CREATE OR REPLACE TEMP VIEW taxi_zones_source AS
SELECT
    CAST(LocationID AS INT) AS location_id,
    Borough                 AS borough,
    Zone                    AS zone,
    service_zone,
    _metadata.file_path              AS raw_uri,
    _metadata.file_name              AS source_object,
    _metadata.file_size              AS file_size,
    _metadata.file_modification_time AS file_modified_time
FROM read_files(
    '/Volumes/ftw-week-08/00-source/group_a_source/taxi_zones/taxi_zone_lookup.csv',
    format => 'csv',
    header => true
);


-- ------------------------------------------------------------
-- Content identity. Hashed over the parsed business columns in a stable
-- order, so the same snapshot always produces the same hash regardless of
-- row order. Nulls are rendered explicitly rather than skipped: CONCAT_WS
-- drops null arguments, which would let two different rows produce the
-- same string.
--
-- Note this is a hash of parsed content, not of the raw file bytes, so it
-- is not comparable with green_taxi's byte-level hash from
-- src/ingestion/batch_tracking.py. Comparison is only ever within a source.
-- ------------------------------------------------------------
DECLARE OR REPLACE VARIABLE zones_content_sha256 STRING;
SET VARIABLE zones_content_sha256 = (
    SELECT sha2(
        ARRAY_JOIN(
            ARRAY_SORT(
                COLLECT_LIST(
                    CONCAT_WS('|',
                        COALESCE(CAST(location_id AS STRING), '<null>'),
                        COALESCE(borough,      '<null>'),
                        COALESCE(zone,         '<null>'),
                        COALESCE(service_zone, '<null>')
                    )
                )
            ), '\n'
        ), 256)
    FROM taxi_zones_source
);

DECLARE OR REPLACE VARIABLE zones_version_id STRING;
SET VARIABLE zones_version_id = CONCAT('taxi_zones_', SUBSTRING(zones_content_sha256, 1, 12));

DECLARE OR REPLACE VARIABLE zones_batch_id STRING;
SET VARIABLE zones_batch_id = uuid();

-- New work exists if this content has never succeeded, OR if the target is
-- empty (someone dropped the Bronze table but the control row survived).
-- Without the second clause the loader would consider the snapshot already
-- processed and merge 265 rows under a batch_id that was never registered.
DECLARE OR REPLACE VARIABLE zones_is_new BOOLEAN;
SET VARIABLE zones_is_new = (
    SELECT
        (SELECT COUNT(*) FROM `ftw-week-08`.`01-control`.ingestion_batches
          WHERE source_system = 'taxi_zones'
            AND content_sha256 = zones_content_sha256
            AND status = 'SUCCESS') = 0
     OR (SELECT COUNT(*) FROM `ftw-week-08`.`02-bronze`.taxi_zones_raw) = 0
     -- Rows whose batch_id is no longer a live SUCCESS batch. The snapshot
     -- content never changes, so without this the rows keep the batch_id they
     -- were first inserted under while later runs register and demote batches
     -- around them, and batch_registered_in_control fails on every row.
     OR (SELECT COUNT(*)
         FROM `ftw-week-08`.`02-bronze`.taxi_zones_raw t
         WHERE NOT EXISTS (
             SELECT 1 FROM `ftw-week-08`.`01-control`.ingestion_batches b
             WHERE b.batch_id = t.batch_id AND b.status = 'SUCCESS')) > 0
);


-- ------------------------------------------------------------
-- Register the batch before loading. Skipped entirely when this exact
-- content has already succeeded, so a rerun does not create a second
-- SUCCESS row for the same content -- which the control gate fails on.
--
-- schema_fingerprint is left null: unlike the Parquet loader, this file
-- cannot introspect the source column signature in the same statement.
-- Column presence for this source is checked in 90_validate_taxi_zones.
-- ------------------------------------------------------------
-- A reload of content that already succeeded means the earlier batch's rows
-- are gone (the target was dropped) or are being replaced. Demote it rather
-- than leaving two SUCCESS rows for one content hash, which is what
-- no_duplicate_successful_batches flags as double processing. The demoted
-- row keeps its own batch_id, row_count and timestamps, so the earlier
-- attempt stays auditable rather than being deleted.
UPDATE `ftw-week-08`.`01-control`.ingestion_batches
SET status = 'SUPERSEDED'
WHERE source_system = 'taxi_zones'
  AND status = 'SUCCESS'
  AND content_sha256 IN ((SELECT zones_content_sha256))
  -- Only when this run will actually register a replacement. Demoting
  -- unconditionally left the Bronze rows pointing at a SUPERSEDED batch on
  -- any rerun of unchanged content, which batch_registered_in_control
  -- correctly rejects.
  AND zones_is_new;

INSERT INTO `ftw-week-08`.`01-control`.ingestion_batches (
    batch_id, source_system, source_object, source_period, request_parameters,
    content_sha256, source_version_id, schema_fingerprint, raw_uri,
    status, discovered_at, started_at, completed_at,
    error_message, supersedes_batch_id,
    row_count, file_size, file_modified_time
)
SELECT
    zones_batch_id, 'taxi_zones', MAX(source_object), NULL, NULL,
    zones_content_sha256, zones_version_id, NULL, MAX(raw_uri),
    'STARTED', current_timestamp(), current_timestamp(), NULL,
    NULL, NULL,
    NULL, MAX(file_size), MAX(file_modified_time)
FROM taxi_zones_source
WHERE zones_is_new
-- Required, not defensive. This SELECT aggregates (MAX) with no GROUP BY, so
-- it returns ONE row even when the WHERE matches nothing -- a row of NULLs.
-- Without this, every run where zones_is_new is false still registered a
-- batch, with null source_object and null file metadata, and then closed it
-- SUCCESS. That is what produced three SUCCESS batches for one content hash.
HAVING COUNT(*) > 0;


-- ------------------------------------------------------------
-- Full refresh, expressed as a merge.
--   MATCHED + changed -> update, and restamp lineage on that row only
--   NOT MATCHED       -> insert
--   NOT MATCHED BY SOURCE -> delete, so a zone removed from the snapshot
--                            does not linger in Bronze
-- Unchanged rows are not touched, so ingested_at survives a rerun.
-- <=> is null-safe equality; = would treat null <> null as "changed".
-- ------------------------------------------------------------
MERGE INTO `ftw-week-08`.`02-bronze`.taxi_zones_raw AS target
USING (
    SELECT
        location_id,
        borough,
        zone,
        service_zone,
        'taxi_zones'         AS source_system,
        source_object        AS source_file,
        zones_version_id     AS source_file_version,
        zones_content_sha256 AS content_sha256,
        zones_batch_id       AS batch_id
    FROM taxi_zones_source
) AS source
ON target.location_id = source.location_id

-- Business content OR lineage. Comparing business values alone meant a newly
-- registered batch never reached the rows, because a reference snapshot's
-- content is identical every run.
--
-- zones_is_new gates the whole branch. zones_batch_id is a fresh uuid on every
-- run whether or not a batch is registered, so without this guard a rerun of
-- unchanged content compared the stored batch_id against an unused uuid, found
-- them different, and restamped all 265 rows with a batch id that exists
-- nowhere in ingestion_batches. If no batch was registered there is nothing to
-- restamp.
WHEN MATCHED AND zones_is_new AND NOT (
         target.borough             <=> source.borough
     AND target.zone                <=> source.zone
     AND target.service_zone        <=> source.service_zone
     AND target.source_system       <=> source.source_system
     AND target.source_file_version <=> source.source_file_version
     AND target.content_sha256      <=> source.content_sha256
     AND target.batch_id            <=> source.batch_id
) THEN UPDATE SET
    borough             = source.borough,
    zone                = source.zone,
    service_zone        = source.service_zone,
    source_system       = source.source_system,
    source_file         = source.source_file,
    source_file_version = source.source_file_version,
    content_sha256      = source.content_sha256,
    batch_id            = source.batch_id,
    ingested_at         = current_timestamp()

WHEN NOT MATCHED THEN INSERT (
    location_id, borough, zone, service_zone,
    source_system, source_file, source_file_version,
    content_sha256, batch_id, ingested_at
) VALUES (
    source.location_id, source.borough, source.zone, source.service_zone,
    source.source_system, source.source_file, source.source_file_version,
    source.content_sha256, source.batch_id, current_timestamp()
)

WHEN NOT MATCHED BY SOURCE THEN DELETE;


-- ------------------------------------------------------------
-- Close the batch only after the load. Row count is read back from the
-- target, not from the source, so it records what actually landed.
-- ------------------------------------------------------------
UPDATE `ftw-week-08`.`01-control`.ingestion_batches
SET status       = 'SUCCESS',
    row_count    = (SELECT COUNT(*) FROM `ftw-week-08`.`02-bronze`.taxi_zones_raw),
    completed_at = current_timestamp()
WHERE batch_id = zones_batch_id;


-- What this run did.
SELECT
    zones_is_new           AS loaded_new_content,
    zones_version_id       AS source_version_id,
    zones_content_sha256   AS content_sha256,
    (SELECT COUNT(*) FROM `ftw-week-08`.`02-bronze`.taxi_zones_raw) AS bronze_row_count;
