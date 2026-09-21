-- ============================================================
-- Silver gate: Taxi Zones
--
-- Stage:     03 Silver validation
-- Runs after: etl/03_silver/30_clean_taxi_zones.sql
-- Target:    `ftw-week-08`.`01-control`.data_quality_results
-- Grain:     one row per check per run
-- Contract:  docs/validation.md (shared result contract, D17)
--
-- Integration runs only when this passes, together with the green_taxi
-- and weather Silver gates.
--
-- Replaces eleven bare SELECTs whose expectations lived in comments: they
-- recorded nothing, could not block, and three of them had gone stale
-- against the loader without anything noticing.
-- ============================================================

DECLARE OR REPLACE VARIABLE dq_run_id STRING;
SET VARIABLE dq_run_id = uuid();

DECLARE OR REPLACE VARIABLE code_revision STRING;
SET VARIABLE code_revision = 'UNSET';


INSERT INTO `ftw-week-08`.`01-control`.data_quality_results

WITH silver AS (
    SELECT * FROM `ftw-week-08`.`03-silver`.taxi_zones_clean
),

bronze AS (
    SELECT * FROM `ftw-week-08`.`02-bronze`.taxi_zones_raw
),

-- Silver now deletes rows the snapshot dropped, so the two key sets must
-- be identical in both directions. A one-sided count would not notice a
-- row that Silver kept after Bronze let it go.
key_set AS (
    SELECT
        (SELECT COUNT(*) FROM (
            SELECT location_id FROM bronze EXCEPT SELECT location_id FROM silver)) AS in_bronze_not_silver,
        (SELECT COUNT(*) FROM (
            SELECT location_id FROM silver EXCEPT SELECT location_id FROM bronze)) AS in_silver_not_bronze
),

-- Row-level comparison against Bronze, joined on the key. The previous
-- gate asked only whether each Silver borough appeared SOMEWHERE in
-- Bronze, which would pass even if every value were attached to the
-- wrong zone.
value_drift AS (
    SELECT
        COUNT(*) AS compared,
        COUNT_IF(NOT (s.borough   <=> TRIM(b.borough))) AS borough_drift,
        COUNT_IF(NOT (s.zone_name <=> TRIM(b.zone)))    AS zone_name_drift
    FROM silver s
    JOIN bronze b ON s.location_id = b.location_id
),

schema_expected AS (
    SELECT * FROM VALUES
        ('location_id', 0), ('borough', 1), ('zone_name', 2),
        ('service_zone', 3), ('zone_classification', 4),
        ('source_system', 5), ('source_file', 6),
        ('source_file_version', 7), ('content_sha256', 8),
        ('batch_id', 9), ('ingested_at', 10), ('silver_processed_at', 11)
    AS expected(column_name, ordinal_position)
),

schema_actual AS (
    SELECT column_name, data_type, ordinal_position
    FROM `system`.information_schema.columns
    WHERE table_catalog = 'ftw-week-08'
      AND table_schema  = '03-silver'
      AND table_name    = 'taxi_zones_clean'
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

    SELECT 'silver_table_not_empty' AS check_name, 'VOLUME' AS check_type,
           'FAIL' AS severity, 0.0 AS threshold_pct,
           CAST(CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END AS BIGINT) AS fail_count,
           1 AS total_count,
           CONCAT('rows in taxi_zones_clean: ', CAST(COUNT(*) AS STRING)) AS details
    FROM silver

    UNION ALL
    SELECT 'silver_schema', 'SCHEMA', 'FAIL', 0.0,
           CAST(fail_count AS BIGINT), 12,
           'Silver column names and order must match the expected signature.'
    FROM schema_mismatches

    -- ---- key integrity ----

    UNION ALL
    SELECT 'location_id_not_null', 'NOT_NULL', 'FAIL', 0.0,
           COUNT_IF(location_id IS NULL), COUNT(*),
           'location_id is the join key for every trip.'
    FROM silver

    UNION ALL
    SELECT 'location_id_unique', 'UNIQUE', 'FAIL', 0.0,
           COUNT(*) - COUNT(DISTINCT location_id), COUNT(*),
           'A duplicate location_id would fan out both zone joins in Integration.'
    FROM silver

    -- ---- reconciliation against Bronze ----

    UNION ALL
    SELECT 'bronze_to_silver_row_reconciliation', 'RECONCILIATION', 'FAIL', 0.0,
           CAST(ABS((SELECT COUNT(*) FROM bronze) - (SELECT COUNT(*) FROM silver)) AS BIGINT),
           (SELECT COUNT(*) FROM bronze),
           CONCAT('bronze: ', CAST((SELECT COUNT(*) FROM bronze) AS STRING),
                  ', silver: ', CAST((SELECT COUNT(*) FROM silver) AS STRING))
    FROM (SELECT 1)

    UNION ALL
    SELECT 'bronze_to_silver_key_set_identical', 'RECONCILIATION', 'FAIL', 0.0,
           CAST(in_bronze_not_silver + in_silver_not_bronze AS BIGINT),
           GREATEST((SELECT COUNT(*) FROM bronze), 1),
           CONCAT('missing from silver: ', CAST(in_bronze_not_silver AS STRING),
                  ', left behind in silver: ', CAST(in_silver_not_bronze AS STRING))
    FROM key_set

    UNION ALL
    SELECT 'borough_matches_bronze', 'RECONCILIATION', 'FAIL', 0.0,
           CAST(borough_drift AS BIGINT), compared,
           'Each zone must keep its own Bronze borough, trimmed.'
    FROM value_drift

    UNION ALL
    SELECT 'zone_name_matches_bronze', 'RECONCILIATION', 'FAIL', 0.0,
           CAST(zone_name_drift AS BIGINT), compared,
           'Each zone must keep its own Bronze zone name, trimmed.'
    FROM value_drift

    -- ---- sentinels (D16) ----

    UNION ALL
    SELECT 'sentinel_locations_present', 'COMPLETENESS', 'FAIL', 0.0,
           CAST(2 - COUNT(DISTINCT location_id) AS BIGINT), 2,
           'LocationIDs 264 and 265 are required members, not failures.'
    FROM silver WHERE location_id IN (264, 265)

    UNION ALL
    SELECT 'sentinel_classification_correct', 'CONSISTENCY', 'FAIL', 0.0,
           COUNT_IF((location_id = 264 AND zone_classification <> 'unknown')
                 OR (location_id = 265 AND zone_classification <> 'outside_nyc')),
           GREATEST(COUNT(*), 1),
           '264 classifies as unknown and 265 as outside_nyc.'
    FROM silver WHERE location_id IN (264, 265)

    -- ---- standardisation ----

    UNION ALL
    SELECT 'zone_classification_domain', 'DOMAIN', 'FAIL', 0.0,
           COUNT_IF(zone_classification IS NULL OR zone_classification NOT IN
                    ('nyc_borough', 'ewr', 'unknown', 'outside_nyc', 'other_special')),
           COUNT(*),
           'zone_classification must use one of the five defined values.'
    FROM silver

    -- other_special is the catch-all branch of the classification CASE. It
    -- should be empty: a row landing there means the source published a
    -- borough the mapping does not recognise.
    UNION ALL
    SELECT 'no_unclassified_zones', 'CONSISTENCY', 'WARN', 0.0,
           COUNT_IF(zone_classification = 'other_special'), COUNT(*),
           'A zone fell through to other_special, so its borough is not one the mapping knows.'
    FROM silver

    UNION ALL
    SELECT 'service_zone_lowercase', 'FORMAT', 'FAIL', 0.0,
           COUNT_IF(service_zone IS NOT NULL AND service_zone <> LOWER(service_zone)),
           COUNT(*),
           'service_zone is standardised to lower case by the cleaner.'
    FROM silver

    UNION ALL
    SELECT 'business_fields_not_null', 'NOT_NULL', 'WARN', 0.0,
           COUNT_IF(borough IS NULL OR zone_name IS NULL OR service_zone IS NULL),
           COUNT(*),
           'Borough, zone name and service zone are expected on every zone.'
    FROM silver

    -- ---- provenance ----

    UNION ALL
    SELECT 'provenance_completeness', 'PROVENANCE', 'FAIL', 0.0,
           COUNT_IF(source_system IS NULL OR source_file IS NULL
                 OR source_file_version IS NULL OR content_sha256 IS NULL
                 OR batch_id IS NULL OR ingested_at IS NULL
                 OR silver_processed_at IS NULL), COUNT(*),
           'Every Silver row must carry Bronze provenance plus its Silver processing stamp.'
    FROM silver

    -- The vocabulary is settled: 'taxi_zones' everywhere, matching
    -- ingestion_batches so a Silver row can be joined back to the batch
    -- that loaded it.
    UNION ALL
    SELECT 'source_system_domain', 'DOMAIN', 'FAIL', 0.0,
           COUNT_IF(source_system <> 'taxi_zones'), COUNT(*),
           'source_system must match the value registered in ingestion_batches.'
    FROM silver

    UNION ALL
    SELECT 'single_content_version', 'CONSISTENCY', 'FAIL', 0.0,
           CAST(GREATEST(COUNT(DISTINCT content_sha256) - 1, 0) AS BIGINT), 1,
           'A complete snapshot is one version: all rows share one content_sha256.'
    FROM silver

    UNION ALL
    SELECT 'batch_registered_in_control', 'PROVENANCE', 'FAIL', 0.0,
           COUNT_IF(b.batch_id IS NULL), COUNT(*),
           'Every batch_id in Silver must have a SUCCESS row in ingestion_batches.'
    FROM silver s
    LEFT JOIN `ftw-week-08`.`01-control`.ingestion_batches b
           ON s.batch_id = b.batch_id AND b.status = 'SUCCESS'

    -- ---- measurements ----

    UNION ALL
    SELECT 'silver_column_types_observed', 'MEASURE', 'INFO', NULL,
           0, COUNT(*),
           CONCAT('types: ', ARRAY_JOIN(ARRAY_SORT(
               COLLECT_LIST(CONCAT(column_name, '=', data_type))), ', '))
    FROM schema_actual

    UNION ALL
    SELECT 'zone_classification_distribution', 'MEASURE', 'INFO', NULL,
           0, COUNT(*),
           CONCAT('classification counts: ', ARRAY_JOIN(ARRAY_SORT(COLLECT_LIST(
               CONCAT(zone_classification, '=', CAST(n AS STRING)))), ', '))
    FROM (SELECT zone_classification, COUNT(*) AS n FROM silver GROUP BY zone_classification)

    UNION ALL
    SELECT 'standardised_values_observed', 'MEASURE', 'INFO', NULL,
           0, COUNT(*),
           CONCAT('source_system: ', COALESCE(ARRAY_JOIN(ARRAY_SORT(COLLECT_SET(source_system)), '/'), '<none>'),
                  '; source_file_version: ', COALESCE(ARRAY_JOIN(ARRAY_SORT(COLLECT_SET(source_file_version)), '/'), '<none>'),
                  '; boroughs: ', COALESCE(ARRAY_JOIN(ARRAY_SORT(COLLECT_SET(borough)), ', '), '<none>'),
                  '; service_zones: ', COALESCE(ARRAY_JOIN(ARRAY_SORT(COLLECT_SET(service_zone)), ', '), '<none>'))
    FROM silver
)

SELECT
    dq_run_id,
    current_timestamp(),
    'silver',
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
    (SELECT MAX(batch_id) FROM silver),
    (SELECT MAX(source_file_version) FROM silver),
    code_revision,
    'TODO',
    NULL,
    details
FROM checks;


-- Gate result. Integration runs only when this returns cleanly.
SELECT CASE
         WHEN COUNT_IF(status = 'FAIL') > 0
         THEN raise_error(concat('Silver taxi_zones gate BLOCKED: ',
                                 CAST(COUNT_IF(status = 'FAIL') AS STRING),
                                 ' failed checks'))
       END
FROM `ftw-week-08`.`01-control`.data_quality_results
WHERE run_id = dq_run_id;


-- Review the run:
-- SELECT check_name, status, severity, fail_count, total_count,
--        ROUND(fail_pct, 4) AS fail_pct, threshold_pct, details
-- FROM `ftw-week-08`.`01-control`.data_quality_results
-- WHERE run_id = (SELECT run_id FROM `ftw-week-08`.`01-control`.gate_status
--                 WHERE layer = 'silver' AND dataset = 'taxi_zones')
-- ORDER BY status DESC, check_name;
