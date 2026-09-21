-- ============================================================
-- Control gate
--
-- Stage:     01 Control validation
-- Runs after: etl/01_control/00_create_control_tables.sql
-- Target:    `ftw-week-08`.`01-control`.data_quality_results
-- Grain:     one row per check per run
-- Contract:  docs/validation.md (shared result contract)
--
-- Validates the control tables themselves. Bronze loads read
-- ingestion_batches to decide what to skip, so a corrupt control table
-- silently breaks every downstream skip decision.
-- ============================================================

DECLARE OR REPLACE VARIABLE dq_run_id STRING;
SET VARIABLE dq_run_id = uuid();

-- Set from the job parameter or `git rev-parse --short HEAD` before running.
DECLARE OR REPLACE VARIABLE code_revision STRING;
SET VARIABLE code_revision = 'UNSET';

-- A batch still DISCOVERED or STARTED after this many hours is abandoned,
-- not in flight. Sized to be longer than the slowest expected load, not
-- tuned to any observed run.
DECLARE OR REPLACE VARIABLE stuck_after_hours INT;
SET VARIABLE stuck_after_hours = 6;

INSERT INTO `ftw-week-08`.`01-control`.pipeline_runs
SELECT dq_run_id, code_revision, 'manual', current_timestamp(), NULL, 'STARTED';


-- ------------------------------------------------------------
-- Each check produces exactly one row: a name, a type, a severity,
-- a fail_count, a total_count and a tolerance. Status is derived by
-- the shared function so it cannot drift between gates.
-- ------------------------------------------------------------
INSERT INTO `ftw-week-08`.`01-control`.data_quality_results
WITH checks AS (

    -- 1. Empty control table. Runs first: if ingestion_batches is empty,
    --    every check below reports fail_count = 0 and would pass silently.
    SELECT
        'ingestion_batches_not_empty'      AS check_name,
        'completeness'                     AS check_type,
        'FAIL'                             AS severity,
        CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END AS fail_count,
        GREATEST(COUNT(*), 1)              AS total_count,
        0.0                                AS threshold_pct,
        CONCAT('rows in ingestion_batches: ', CAST(COUNT(*) AS STRING)) AS details
    FROM `ftw-week-08`.`01-control`.ingestion_batches

    UNION ALL

    -- 2. batch_id uniqueness. Delta cannot enforce this, and every skip,
    --    update and rollback in batch_tracking.py keys on batch_id.
    SELECT
        'batch_id_unique',
        'uniqueness',
        'FAIL',
        COUNT(*) - COUNT(DISTINCT batch_id),
        COUNT(*),
        0.0,
        CONCAT('distinct batch_ids: ', CAST(COUNT(DISTINCT batch_id) AS STRING))
    FROM `ftw-week-08`.`01-control`.ingestion_batches

    UNION ALL

    -- 3. The idempotency check. Two SUCCESS rows for the same content under
    --    the same source system means the same bytes were processed twice —
    --    exactly what already_succeeded() exists to prevent. Grouped on
    --    (source_system, content_sha256) to mirror that function's own key,
    --    NOT on source_object: a retry legitimately reuses a filename.
    --    Multiple attempts are healthy; multiple SUCCESSES are not.
    SELECT
        'no_duplicate_successful_batches',
        'idempotency',
        'FAIL',
        COUNT_IF(success_count > 1),
        COUNT(*),
        0.0,
        CONCAT('content groups with >1 SUCCESS: ', CAST(COUNT_IF(success_count > 1) AS STRING))
    FROM (
        SELECT
            source_system,
            content_sha256,
            SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END) AS success_count
        FROM `ftw-week-08`.`01-control`.ingestion_batches
        WHERE content_sha256 IS NOT NULL
        GROUP BY source_system, content_sha256
    )

    UNION ALL

    -- 4. Abandoned batches. A crash between mark_batch_started and the
    --    success/failure update leaves a row that blocks nothing and
    --    explains nothing. Age-based so a batch running right now is not
    --    flagged; threshold 0 so any genuinely stuck batch fails the gate.
    SELECT
        'no_stuck_batches',
        'lifecycle',
        'WARN',
        COUNT_IF(
            status IN ('DISCOVERED', 'STARTED')
            AND discovered_at < current_timestamp() - MAKE_INTERVAL(0, 0, 0, 0, stuck_after_hours)
        ),
        COUNT(*),
        0.0,
        CONCAT('stuck threshold (hours): ', CAST(stuck_after_hours AS STRING))
    FROM `ftw-week-08`.`01-control`.ingestion_batches

    UNION ALL

    -- 5. Lifecycle consistency. Catches a partially applied UPDATE, which
    --    would otherwise look like a healthy SUCCESS with no evidence
    --    behind it.
    SELECT
        'batch_lifecycle_consistent',
        'lifecycle',
        'FAIL',
        COUNT_IF(
            (status = 'SUCCESS' AND (row_count IS NULL OR completed_at IS NULL OR started_at IS NULL))
            OR (status IN ('STARTED', 'SUCCESS', 'FAILED') AND started_at IS NULL)
            OR (completed_at IS NOT NULL AND started_at IS NOT NULL AND completed_at < started_at)
            OR discovered_at IS NULL
        ),
        COUNT(*),
        0.0,
        'SUCCESS needs row_count/started_at/completed_at; completed_at cannot precede started_at'
    FROM `ftw-week-08`.`01-control`.ingestion_batches

    UNION ALL

    -- 6. Status domain. A typo'd status is invisible to the skip query,
    --    which matches on 'SUCCESS' exactly, so the file would be
    --    silently reprocessed.
    SELECT
        'status_in_allowed_domain',
        'validity',
        'FAIL',
        -- SUPERSEDED is a batch whose content was later reloaded, usually
        -- because its Bronze table was dropped. It keeps its own evidence
        -- but no longer counts as a live SUCCESS, which is what stops
        -- no_duplicate_successful_batches firing on a legitimate reload.
        COUNT_IF(status IS NULL OR status NOT IN
                 ('DISCOVERED', 'STARTED', 'SUCCESS', 'FAILED', 'SUPERSEDED')),
        COUNT(*),
        0.0,
        'allowed: DISCOVERED / STARTED / SUCCESS / FAILED'
    FROM `ftw-week-08`.`01-control`.ingestion_batches

    UNION ALL

    -- 7. Source coverage. Measurement, not a pass/fail rule: the number of
    --    sources registering batches should equal the number of sources
    --    being ingested. Currently only green_taxi registers, so this is
    --    the row that makes that visible on every run.
    SELECT
        'source_systems_registering_batches',
        'coverage',
        'INFO',
        0,
        COUNT(DISTINCT source_system),
        NULL,
        CONCAT('sources with a SUCCESS batch: ',
               COALESCE(ARRAY_JOIN(ARRAY_SORT(COLLECT_SET(source_system)), ', '), '(none)'))
    FROM `ftw-week-08`.`01-control`.ingestion_batches
    WHERE status = 'SUCCESS'
)
SELECT
    dq_run_id,
    current_timestamp(),
    'control',
    'ingestion_batches',
    check_name,
    check_type,
    severity,
    `ftw-week-08`.`01-control`.dq_status(
        severity,
        fail_count,
        CASE WHEN total_count = 0 THEN 0.0
             ELSE fail_count * 100.0 / total_count END,
        threshold_pct
    ),
    fail_count,
    total_count,
    CASE WHEN total_count = 0 THEN 0.0
         ELSE fail_count * 100.0 / total_count END,
    threshold_pct,
    NULL,              -- batch_id: this gate checks the whole table, not one batch
    NULL,              -- source_version_id: same
    code_revision,
    'TODO',            -- owner
    NULL,              -- evidence_location
    details
FROM checks;


-- ------------------------------------------------------------
-- Gate result. Blocks Bronze when a blocking check failed.
-- ------------------------------------------------------------
UPDATE `ftw-week-08`.`01-control`.pipeline_runs
SET completed_at = current_timestamp(),
    status = CASE
                WHEN EXISTS (
                    SELECT 1 FROM `ftw-week-08`.`01-control`.data_quality_results
                    WHERE run_id = dq_run_id AND status = 'FAIL'
                ) THEN 'FAILED' ELSE 'SUCCESS'
             END
WHERE run_id = dq_run_id;

SELECT CASE
         WHEN COUNT_IF(status = 'FAIL') > 0
         THEN raise_error(concat('Control gate BLOCKED: ',
                                 CAST(COUNT_IF(status = 'FAIL') AS STRING),
                                 ' failed checks'))
       END
FROM `ftw-week-08`.`01-control`.data_quality_results
WHERE run_id = dq_run_id;


-- Review the run:
-- SELECT check_name, status, fail_count, total_count, ROUND(fail_pct, 2) AS fail_pct, details
-- FROM `ftw-week-08`.`01-control`.data_quality_results
-- WHERE run_id = dq_run_id ORDER BY status DESC, check_name;
SELECT check_name, status, severity, fail_count, total_count, ROUND(fail_pct, 2) AS fail_pct, details
FROM `ftw-week-08`.`01-control`.data_quality_results
WHERE run_id = (
    SELECT run_id FROM `ftw-week-08`.`01-control`.data_quality_results
    ORDER BY executed_at DESC LIMIT 1
)
ORDER BY status DESC, check_name;