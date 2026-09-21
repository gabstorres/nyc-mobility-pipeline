-- ============================================================
-- Bronze gate: Taxi Zones
--
-- Stage:     02 Bronze validation
-- Runs after: etl/02_bronze/30_load_taxi_zones.sql
-- Target:    `ftw-week-08`.`01-control`.data_quality_results
-- Grain:     one row per check per run
-- Contract:  docs/validation.md (shared result contract, D17)
--
-- Replaces the results table `02-bronze`.90_validate_taxi_zones, which
-- began with a digit (D13) and sat in a business schema. Silver
-- taxi_zones runs only when this passes.
--
-- The source path is repeated here on purpose: reconciliation must
-- re-read the file independently of what the loader recorded about it.
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
    WHERE layer = 'bronze' AND dataset = 'taxi_zones'
);


-- Independent re-read of the snapshot. The hash formula must stay
-- identical to the one in 30_load_taxi_zones.sql, or the reconciliation
-- check below compares two different things.
CREATE OR REPLACE TEMP VIEW tz_source AS
SELECT
    CAST(LocationID AS INT) AS location_id,
    Borough                 AS borough,
    Zone                    AS zone,
    service_zone
FROM read_files(
    '/Volumes/ftw-week-08/00-source/group_a_source/taxi_zones/taxi_zone_lookup.csv',
    format => 'csv',
    header => true
);

CREATE OR REPLACE TEMP VIEW tz_source_identity AS
SELECT
    COUNT(*) AS source_rows,
    sha2(
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
        ), 256) AS source_content_sha256
FROM tz_source;


INSERT INTO `ftw-week-08`.`01-control`.data_quality_results

WITH base AS (
    SELECT * FROM `ftw-week-08`.`02-bronze`.taxi_zones_raw
),

total AS (
    SELECT COUNT(*) AS total_count FROM base
),

schema_expected AS (
    SELECT * FROM VALUES
        ('location_id',         'INT',       0),
        ('borough',             'STRING',    1),
        ('zone',                'STRING',    2),
        ('service_zone',        'STRING',    3),
        ('source_system',       'STRING',    4),
        ('source_file',         'STRING',    5),
        ('source_file_version', 'STRING',    6),
        ('content_sha256',      'STRING',    7),
        ('batch_id',            'STRING',    8),
        ('ingested_at',         'TIMESTAMP', 9)
    AS expected(column_name, data_type, ordinal_position)
),

schema_actual AS (
    SELECT column_name, data_type, ordinal_position
    FROM `system`.information_schema.columns
    WHERE table_catalog = 'ftw-week-08'
      AND table_schema  = '02-bronze'
      AND table_name    = 'taxi_zones_raw'
),

schema_mismatches AS (
    SELECT COUNT(*) AS fail_count
    FROM (
        SELECT expected.column_name
        FROM schema_expected expected
        FULL OUTER JOIN schema_actual actual
          ON expected.column_name      = actual.column_name
         AND expected.data_type        = actual.data_type
         AND expected.ordinal_position = actual.ordinal_position
        WHERE expected.column_name IS NULL OR actual.column_name IS NULL
    )
),

checks AS (

    -- 1. Populated. First, so nothing below passes vacuously on an empty table.
    SELECT 'row_count_not_empty' AS check_name, 'VOLUME' AS check_type,
           'FAIL' AS severity, 0.0 AS threshold_pct,
           CAST(CASE WHEN total_count = 0 THEN 1 ELSE 0 END AS BIGINT) AS fail_count,
           1 AS total_count,
           CONCAT('rows in taxi_zones_raw: ', CAST(total_count AS STRING)) AS details
    FROM total

    UNION ALL
    SELECT 'source_schema', 'SCHEMA', 'FAIL', 0.0,
           CAST(fail_count AS BIGINT), 10,
           'Bronze column names, types and order must match the expected signature.'
    FROM schema_mismatches

    -- ---- key integrity ----

    UNION ALL
    SELECT 'location_id_not_null', 'NOT_NULL', 'FAIL', 0.0,
           SUM(CASE WHEN location_id IS NULL THEN 1 ELSE 0 END), COUNT(*),
           'Every Taxi Zone record must have a location_id.'
    FROM base

    UNION ALL
    SELECT 'location_id_unique', 'UNIQUE', 'FAIL', 0.0,
           COALESCE((SELECT SUM(cnt - 1) FROM (
                SELECT COUNT(*) AS cnt FROM base
                WHERE location_id IS NOT NULL
                GROUP BY location_id HAVING COUNT(*) > 1)), 0),
           COUNT(*),
           'location_id is the join key for every trip; duplicates would fan out Integration.'
    FROM base

    UNION ALL
    SELECT 'location_id_positive', 'RANGE', 'FAIL', 0.0,
           SUM(CASE WHEN location_id IS NOT NULL AND location_id <= 0 THEN 1 ELSE 0 END),
           COUNT(*),
           'location_id must be a positive identifier.'
    FROM base

    -- ---- sentinel members (D16) ----

    UNION ALL
    SELECT 'sentinel_locations_present', 'COMPLETENESS', 'FAIL', 0.0,
           CAST(2 - COUNT(DISTINCT location_id) AS BIGINT), 2,
           'LocationIDs 264 (unknown) and 265 (outside NYC) are required members, not failures (D16).'
    FROM base WHERE location_id IN (264, 265)

    UNION ALL
    SELECT 'sentinel_borough_consistent', 'CONSISTENCY', 'WARN', 0.0,
           SUM(CASE WHEN UPPER(TRIM(borough)) NOT IN ('UNKNOWN', 'N/A') THEN 1 ELSE 0 END),
           GREATEST(COUNT(*), 1),
           'Sentinel boroughs, as confirmed in the snapshot: 264 is Unknown, 265 is N/A.'
    FROM base WHERE location_id IN (264, 265)

    -- ---- completeness and domains ----

    UNION ALL
    SELECT 'borough_not_null', 'NOT_NULL', 'WARN', 0.0,
           SUM(CASE WHEN borough IS NULL THEN 1 ELSE 0 END), COUNT(*),
           'Borough is expected on every zone.'
    FROM base

    UNION ALL
    SELECT 'zone_not_null', 'NOT_NULL', 'WARN', 0.0,
           SUM(CASE WHEN zone IS NULL THEN 1 ELSE 0 END), COUNT(*),
           'Zone name is expected on every zone.'
    FROM base

    UNION ALL
    SELECT 'service_zone_not_null', 'NOT_NULL', 'WARN', 0.0,
           SUM(CASE WHEN service_zone IS NULL THEN 1 ELSE 0 END), COUNT(*),
           'service_zone is expected on every zone.'
    FROM base

    UNION ALL
    SELECT 'borough_domain', 'DOMAIN', 'WARN', 0.0,
           SUM(CASE WHEN borough IS NOT NULL AND TRIM(borough) NOT IN
                    ('EWR','Queens','Bronx','Manhattan','Staten Island','Brooklyn','Unknown','N/A')
                    THEN 1 ELSE 0 END), COUNT(*),
           'Accepted borough values, including the N/A carried by row 265.'
    FROM base

    UNION ALL
    SELECT 'service_zone_domain', 'DOMAIN', 'WARN', 0.0,
           SUM(CASE WHEN service_zone IS NOT NULL AND TRIM(service_zone) NOT IN
                    ('EWR','Boro Zone','Yellow Zone','Airports','N/A')
                    THEN 1 ELSE 0 END), COUNT(*),
           'Accepted service_zone values, including the N/A carried by the sentinel rows.'
    FROM base

    UNION ALL
    SELECT 'full_row_unique', 'UNIQUE', 'WARN', 0.0,
           COALESCE((SELECT SUM(cnt - 1) FROM (
                SELECT COUNT(*) AS cnt FROM base
                GROUP BY location_id, borough, zone, service_zone
                HAVING COUNT(*) > 1)), 0),
           COUNT(*),
           'Identical business rows should not appear twice in a complete snapshot.'
    FROM base

    UNION ALL
    SELECT 'ewr_consistency', 'CONSISTENCY', 'WARN', 0.0,
           SUM(CASE
                 WHEN UPPER(TRIM(borough)) = 'EWR'
                  AND (COALESCE(UPPER(TRIM(service_zone)), '') <> 'EWR'
                    OR COALESCE(UPPER(TRIM(zone)), '') <> 'NEWARK AIRPORT') THEN 1
                 WHEN UPPER(TRIM(service_zone)) = 'EWR'
                  AND (COALESCE(UPPER(TRIM(borough)), '') <> 'EWR'
                    OR COALESCE(UPPER(TRIM(zone)), '') <> 'NEWARK AIRPORT') THEN 1
                 ELSE 0 END), COUNT(*),
           'EWR records should map consistently to Newark Airport.'
    FROM base

    -- ---- provenance ----

    UNION ALL
    SELECT 'provenance_completeness', 'PROVENANCE', 'FAIL', 0.0,
           SUM(CASE WHEN source_system IS NULL OR source_file IS NULL
                      OR source_file_version IS NULL OR content_sha256 IS NULL
                      OR batch_id IS NULL OR ingested_at IS NULL
                    THEN 1 ELSE 0 END), COUNT(*),
           'Every Bronze row must carry full provenance.'
    FROM base

    UNION ALL
    SELECT 'single_content_version', 'CONSISTENCY', 'FAIL', 0.0,
           CAST(GREATEST(COUNT(DISTINCT content_sha256) - 1, 0) AS BIGINT), 1,
           'A complete snapshot is one version: all rows must share one content_sha256.'
    FROM base

    -- The same literal ingestion_batches is keyed on, so a Bronze row can
    -- always be joined back to the batch that loaded it.
    UNION ALL
    SELECT 'source_system_domain', 'DOMAIN', 'FAIL', 0.0,
           SUM(CASE WHEN source_system <> 'taxi_zones' THEN 1 ELSE 0 END), COUNT(*),
           'source_system must match the value registered in ingestion_batches.'
    FROM base

    UNION ALL
    SELECT 'batch_registered_in_control', 'PROVENANCE', 'FAIL', 0.0,
           SUM(CASE WHEN b.batch_id IS NULL THEN 1 ELSE 0 END), COUNT(*),
           'Every batch_id in Bronze must have a SUCCESS row in ingestion_batches.'
    FROM base t
    LEFT JOIN `ftw-week-08`.`01-control`.ingestion_batches b
           ON t.batch_id = b.batch_id AND b.status = 'SUCCESS'

    -- ---- source -> Bronze reconciliation ----

    UNION ALL
    SELECT 'source_to_bronze_row_count', 'RECONCILIATION', 'FAIL', 0.0,
           CAST(CASE WHEN s.source_rows = (SELECT total_count FROM total) THEN 0 ELSE 1 END AS BIGINT),
           1,
           CONCAT('source rows: ', CAST(s.source_rows AS STRING),
                  ', bronze rows: ', CAST((SELECT total_count FROM total) AS STRING))
    FROM tz_source_identity s

    UNION ALL
    SELECT 'bronze_matches_current_snapshot', 'RECONCILIATION', 'FAIL', 0.0,
           CAST(CASE WHEN s.source_content_sha256 =
                          (SELECT MAX(content_sha256) FROM base) THEN 0 ELSE 1 END AS BIGINT),
           1,
           'Bronze content must equal the current source file. A failure means rerun the loader.'
    FROM tz_source_identity s

    -- ---- measurements ----

    UNION ALL
    SELECT 'row_count_measurement', 'MEASURE', 'INFO', NULL,
           0, COUNT(*),
           CONCAT('rows: ', CAST(COUNT(*) AS STRING))
    FROM base

    UNION ALL
    SELECT 'location_id_range_measurement', 'MEASURE', 'INFO', NULL,
           0, COUNT(*),
           CONCAT('location_id range: ', CAST(MIN(location_id) AS STRING),
                  ' to ', CAST(MAX(location_id) AS STRING))
    FROM base

    UNION ALL
    SELECT 'location_id_coverage_measurement', 'MEASURE', 'INFO', NULL,
           0, COUNT(*),
           CONCAT('distinct location_ids: ', CAST(COUNT(DISTINCT location_id) AS STRING))
    FROM base
)

SELECT
    dq_run_id,
    current_timestamp(),
    'bronze',
    'taxi_zones',
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
    (SELECT MAX(batch_id) FROM base),
    (SELECT MAX(source_file_version) FROM base),
    code_revision,
    gate_owner,
    NULL,
    details
FROM checks;


-- Gate result. Silver taxi_zones runs only when this returns cleanly.
SELECT CASE
         WHEN COUNT_IF(status = 'FAIL') > 0
         THEN raise_error(concat('Bronze taxi_zones gate BLOCKED: ',
                                 CAST(COUNT_IF(status = 'FAIL') AS STRING),
                                 ' failed checks'))
       END
FROM `ftw-week-08`.`01-control`.data_quality_results
WHERE run_id = dq_run_id;


-- Review the run:
 SELECT check_name, status, severity, fail_count, total_count,
         ROUND(fail_pct, 4) AS fail_pct, threshold_pct, details
 FROM `ftw-week-08`.`01-control`.data_quality_results
 WHERE run_id = dq_run_id ORDER BY status DESC, check_name;