-- ============================================================
-- Bronze: Green Taxi monthly trip files
--
-- Stage: 02 Bronze
-- Runs after: etl/01_control/00_create_control_tables.sql
-- Target: `ftw-week-08`.`02-bronze`.green_taxi_raw
-- Grain: one row per source trip record, as received
--
-- Processes every unprocessed file in the landing folder. No filename is
-- hardcoded: the folder is the source. A file is "already processed" when
-- its CONTENT hash has a SUCCESS batch and its rows are present in the
-- target -- not when its name matches, and not when the control table
-- alone says so.
--
-- The landing path appears exactly ONCE, inside read_files. File name,
-- size, modification time and uri are derived from _metadata.
--
-- Known gap vs the Python loader this replaces: an EXTRA column appearing
-- in a future source file is ignored by the explicit column list below
-- rather than raising. A missing column still fails loudly. Column-count
-- drift is checked in 90_validate_green_taxi.
-- ============================================================

CREATE TABLE IF NOT EXISTS `ftw-week-08`.`02-bronze`.green_taxi_raw (
    VendorID INT,
    lpep_pickup_datetime TIMESTAMP_NTZ,
    lpep_dropoff_datetime TIMESTAMP_NTZ,
    store_and_fwd_flag STRING,
    RatecodeID BIGINT,
    PULocationID INT,
    DOLocationID INT,
    passenger_count BIGINT,
    trip_distance DOUBLE,
    fare_amount DOUBLE,
    extra DOUBLE,
    mta_tax DOUBLE,
    tip_amount DOUBLE,
    tolls_amount DOUBLE,
    ehail_fee DOUBLE,
    improvement_surcharge DOUBLE,
    total_amount DOUBLE,
    payment_type BIGINT,
    trip_type BIGINT,
    congestion_surcharge DOUBLE,
    cbd_congestion_fee DOUBLE,

    -- provenance
    source_system STRING,
    source_file STRING,
    content_sha256 STRING,   -- identifies the file version this row came from
    batch_id STRING,
    ingested_at TIMESTAMP
)
USING DELTA;


-- ------------------------------------------------------------
-- Every row in the landing folder, tagged with its file.
-- ------------------------------------------------------------
CREATE OR REPLACE TEMP VIEW green_taxi_source_rows AS
SELECT
    *,
    _metadata.file_name              AS source_object,
    _metadata.file_path              AS raw_uri,
    _metadata.file_size              AS file_size,
    _metadata.file_modification_time AS file_modified_time,
    -- Row digest. ignoreNullFields=false keeps nulls explicit, so two rows
    -- that differ only by which column is null cannot produce one digest.
    sha2(to_json(struct(
        VendorID, lpep_pickup_datetime, lpep_dropoff_datetime, store_and_fwd_flag,
        RatecodeID, PULocationID, DOLocationID, passenger_count, trip_distance,
        fare_amount, extra, mta_tax, tip_amount, tolls_amount, ehail_fee,
        improvement_surcharge, total_amount, payment_type, trip_type,
        congestion_surcharge, cbd_congestion_fee
    ), map('ignoreNullFields', 'false')), 256) AS row_digest
FROM read_files(
    '/Volumes/ftw-week-08/00-source/group_a_source/green_taxi/',
    format => 'parquet'
);


-- ------------------------------------------------------------
-- One row per file: its content hash and its metadata. Sorting the row
-- digests makes the hash independent of read order, so the same file
-- always produces the same hash.
--
-- source_period is derived from the file name, and is NULL when the name
-- does not carry a YYYY-MM. The old loader stripped a fixed prefix, so an
-- unexpected filename silently became a source_period of the whole name.
-- ------------------------------------------------------------
CREATE OR REPLACE TEMP VIEW green_taxi_files AS
SELECT
    source_object,
    MAX(raw_uri)            AS raw_uri,
    MAX(file_size)          AS file_size,
    MAX(file_modified_time) AS file_modified_time,
    COUNT(*)                AS source_row_count,
    REGEXP_EXTRACT(source_object, '(\\d{4}-\\d{2})', 1) AS source_period,
    sha2(ARRAY_JOIN(ARRAY_SORT(COLLECT_LIST(row_digest)), ''), 256) AS content_sha256
FROM green_taxi_source_rows
GROUP BY source_object;


-- ------------------------------------------------------------
-- Files still to do. Two conditions, both required:
--   no SUCCESS batch for this content, AND
--   no rows for this content already in the target
-- The second clause matters: dropping green_taxi_raw while leaving
-- ingestion_batches intact would otherwise make every file look processed,
-- and the load would report success over an empty table.
-- ------------------------------------------------------------
CREATE OR REPLACE TEMP VIEW green_taxi_new_files AS
SELECT f.*
FROM green_taxi_files f
WHERE NOT EXISTS (
        SELECT 1 FROM `ftw-week-08`.`01-control`.ingestion_batches b
        WHERE b.source_system = 'green_taxi'
          AND b.content_sha256 = f.content_sha256
          AND b.status = 'SUCCESS'
      )
   OR NOT EXISTS (
        SELECT 1 FROM `ftw-week-08`.`02-bronze`.green_taxi_raw t
        WHERE t.content_sha256 = f.content_sha256
      );


-- Marks the batches this run created, so the load below picks up only
-- these and not a STARTED row abandoned by an earlier crash.
DECLARE OR REPLACE VARIABLE gt_run_started_at TIMESTAMP;
SET VARIABLE gt_run_started_at = current_timestamp();


-- ------------------------------------------------------------
-- Register one batch per new file, before loading anything.
-- ------------------------------------------------------------
-- A reload of content that already succeeded means the earlier batch's rows
-- are gone (the target was dropped) or are being replaced. Demote it rather
-- than leaving two SUCCESS rows for one content hash, which is what
-- no_duplicate_successful_batches flags as double processing. The demoted
-- row keeps its own batch_id, row_count and timestamps, so the earlier
-- attempt stays auditable rather than being deleted.
UPDATE `ftw-week-08`.`01-control`.ingestion_batches
SET status = 'SUPERSEDED'
WHERE source_system = 'green_taxi'
  AND status = 'SUCCESS'
  AND content_sha256 IN ((SELECT content_sha256 FROM green_taxi_new_files));

INSERT INTO `ftw-week-08`.`01-control`.ingestion_batches (
    batch_id, source_system, source_object, source_period, request_parameters,
    content_sha256, source_version_id, schema_fingerprint, raw_uri,
    status, discovered_at, started_at, completed_at,
    error_message, supersedes_batch_id,
    row_count, file_size, file_modified_time
)
SELECT
    uuid(), 'green_taxi', source_object, NULLIF(source_period, ''), NULL,
    content_sha256,
    CONCAT('green_taxi_', COALESCE(NULLIF(source_period, ''), SUBSTRING(content_sha256, 1, 12))),
    NULL, raw_uri,
    'STARTED', gt_run_started_at, gt_run_started_at, NULL,
    NULL, NULL,
    NULL, file_size, file_modified_time
FROM green_taxi_new_files;


-- ------------------------------------------------------------
-- Load. One atomic commit: if this fails, nothing lands and the batches
-- stay STARTED for the control gate's stuck-batch check to surface.
-- Rows are joined to their batch by content hash.
-- ------------------------------------------------------------
-- Clear any rows for the content about to be loaded. The insert below and
-- the row-count check after it are separate statements, so a run can commit
-- rows and then fail before its batch reaches SUCCESS. On the next run that
-- file looks unprocessed again -- correctly -- and without this delete the
-- restart would append a second copy of every row. The Python loader this
-- replaced did the same cleanup in its exception handler.
DELETE FROM `ftw-week-08`.`02-bronze`.green_taxi_raw
WHERE content_sha256 IN (SELECT content_sha256 FROM green_taxi_new_files);


INSERT INTO `ftw-week-08`.`02-bronze`.green_taxi_raw (
    VendorID, lpep_pickup_datetime, lpep_dropoff_datetime, store_and_fwd_flag,
    RatecodeID, PULocationID, DOLocationID, passenger_count, trip_distance,
    fare_amount, extra, mta_tax, tip_amount, tolls_amount, ehail_fee,
    improvement_surcharge, total_amount, payment_type, trip_type,
    congestion_surcharge, cbd_congestion_fee,
    source_system, source_file, content_sha256, batch_id, ingested_at
)
SELECT
    r.VendorID, r.lpep_pickup_datetime, r.lpep_dropoff_datetime, r.store_and_fwd_flag,
    r.RatecodeID, r.PULocationID, r.DOLocationID, r.passenger_count, r.trip_distance,
    r.fare_amount, r.extra, r.mta_tax, r.tip_amount, r.tolls_amount, r.ehail_fee,
    r.improvement_surcharge, r.total_amount, r.payment_type, r.trip_type,
    r.congestion_surcharge, r.cbd_congestion_fee,
    'green_taxi', r.source_object, f.content_sha256, b.batch_id, current_timestamp()
FROM green_taxi_source_rows r
JOIN green_taxi_new_files f
  ON r.source_object = f.source_object
JOIN `ftw-week-08`.`01-control`.ingestion_batches b
  ON b.content_sha256 = f.content_sha256
 AND b.source_system  = 'green_taxi'
 AND b.status         = 'STARTED'
 AND b.started_at     = gt_run_started_at;


-- ------------------------------------------------------------
-- Reconcile before closing. Landed rows must equal source rows for every
-- batch this run created; anything else stops the stage with the batches
-- still STARTED.
-- ------------------------------------------------------------
SELECT CASE
         WHEN COUNT(*) > 0
         THEN raise_error(concat('Green Taxi load MISMATCH on ',
                                 CAST(COUNT(*) AS STRING), ' file(s)'))
       END
FROM (
    SELECT f.source_object
    FROM green_taxi_new_files f
    JOIN `ftw-week-08`.`01-control`.ingestion_batches b
      ON b.content_sha256 = f.content_sha256
     AND b.source_system  = 'green_taxi'
     AND b.started_at     = gt_run_started_at
    LEFT JOIN `ftw-week-08`.`02-bronze`.green_taxi_raw t
      ON t.batch_id = b.batch_id
    GROUP BY f.source_object, f.source_row_count
    HAVING COUNT(t.batch_id) <> f.source_row_count
);


-- ------------------------------------------------------------
-- Close the batches, with the count actually landed.
-- ------------------------------------------------------------
MERGE INTO `ftw-week-08`.`01-control`.ingestion_batches AS b
USING (
    SELECT batch_id, COUNT(*) AS landed_rows
    FROM `ftw-week-08`.`02-bronze`.green_taxi_raw
    GROUP BY batch_id
) AS loaded
ON b.batch_id = loaded.batch_id
WHEN MATCHED AND b.status = 'STARTED' AND b.started_at = gt_run_started_at
THEN UPDATE SET
    status       = 'SUCCESS',
    row_count    = loaded.landed_rows,
    completed_at = current_timestamp();


-- What this run did.
SELECT
    source_object,
    source_period,
    source_row_count,
    SUBSTRING(content_sha256, 1, 12) AS content_sha256_short
FROM green_taxi_new_files
ORDER BY source_object;

SELECT COUNT(*) AS bronze_rows,
       COUNT(DISTINCT batch_id) AS batches,
       COUNT(DISTINCT content_sha256) AS file_versions
FROM `ftw-week-08`.`02-bronze`.green_taxi_raw;

SELECT source_object, source_period, status, row_count,
       SUBSTRING(content_sha256, 1, 12) AS sha_short
FROM `ftw-week-08`.`01-control`.ingestion_batches
WHERE source_system = 'green_taxi'
ORDER BY source_object;