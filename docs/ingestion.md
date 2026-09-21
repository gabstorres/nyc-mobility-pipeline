This document defines each source, ingestion method, incremental signal, batch identity, provenance, failure recovery, and rerun behavior.

# Sources and ingestion contracts

Status: implemented. All three sources (Green Taxi, Open-Meteo weather, Taxi Zones) are ingesting real data into Bronze.

## Official sources

- [TLC source index](https://www.nyc.gov/site/tlc/about/tlc-trip-record-data.page)
- [March 2026 Green Taxi Parquet](https://d37ci6vzurychx.cloudfront.net/trip-data/green_tripdata_2026-03.parquet)
- [April 2026 Green Taxi Parquet](https://d37ci6vzurychx.cloudfront.net/trip-data/green_tripdata_2026-04.parquet)
- [May 2026 Green Taxi Parquet](https://d37ci6vzurychx.cloudfront.net/trip-data/green_tripdata_2026-05.parquet)
- [Taxi-zone CSV](https://d37ci6vzurychx.cloudfront.net/misc/taxi_zone_lookup.csv)
- [Green Taxi dictionary](https://www.nyc.gov/assets/tlc/downloads/pdf/data_dictionary_trip_records_green.pdf)
- [Open-Meteo historical API](https://open-meteo.com/en/docs/historical-weather-api)

Weather endpoint: `https://archive-api.open-meteo.com/v1/archive`. Use date-bounded historical requests, not the current-weather classroom example. Initial proposed variables: temperature_2m, precipitation, weather_code. Proposed coordinates 40.7128, -74.0060 are a city-level representative point, subject to team review. Preserve returned grid coordinates, units and model metadata. Select and pin a model after confirming variable support.

For a first profile request use 2026-03-01 through 2026-03-02 with the proposed coordinates, hourly variables and explicit timezone UTC. A sample is only a response-profile check, not the required monthly coverage. For final coverage, derive UTC bounds from the approved NYC local-time interval and retain enough boundary hours. The API start/end dates are date windows; filter the intended interval explicitly downstream without deleting raw responses.

## Acquisition and shared storage

One source owner acquires each immutable input; everyone uses the same recorded source versions. Store source files and JSON under the team's confirmed R2 prefix, not GitHub. Record a checksum and retrieval metadata before promotion. Download all taxi months for profiling; release/process March, then April, then May for the incremental proof.

## Control table

Every ingestion attempt, across all three sources, is tracked in one shared table:

```text
`ftw-week-08`.`01-control`.ingestion_batches
```

One row per batch attempt. Lifecycle: `DISCOVERED → STARTED → SUCCESS / FAILED`.

- `DISCOVERED` — the batch/file was found, not yet loaded.
- `STARTED` — written immediately before the load begins, so a crash mid-load still leaves a record.
- `SUCCESS` — written only after the load lands *and* passes validation (e.g. row-count reconciliation), not merely after the write succeeds.
- `FAILED` — the attempt did not complete. The batch stays eligible for retry; a retry registers a new `batch_id`, preserving the failed attempt's history.

`content_sha256` is what actually decides "have I already processed this" — not the filename. A file can be re-delivered under the same name with different content and still be correctly treated as new.

## Contracts

| Source | Incremental/change signal | Rerun/revision policy |
|---|---|---|
| Taxi | Source logical month + content checksum | Identical successful version is a no-op; different content is a revision. Preserve raw history; replace only that source contribution if it is confirmed a full replacement snapshot |
| Weather | Canonical request parameters/window + response content version | Fetch missing windows. Replay stored input for deterministic reruns. Refresh history explicitly; compare normalized weather content, since volatile response metadata can change raw checksums |
| Zones | Source file version / approved snapshot | Full-refresh the Taxi Zones reference table from the approved source snapshot. Rerunning the same source file produces the same row count and business content. Incremental processing and snapshot-history management are intentionally not used because Taxi Zones is a small static reference dataset (265 rows). |

Keep input identity separate from execution attempts. Proposed manifest fields: source_system, source_object, source_period, request_parameters, content_sha256, source_version_id, batch_id, raw_uri, status, discovered_at, ingested_at, row_count, schema_fingerprint. Proposed run/checkpoint fields: run_id, batch_id, layer, code_revision, configuration_version, status, timestamps, target_commit_reference, counts and error.

Skip only completed work for the applicable layer and code/configuration version. Bronze success must not skip a failed Silver step. A code change may require an explicit replay even if the source checksum is unchanged.

## Green Taxi Trip ingestion

Source: `green_tripdata_2026-03.parquet`, `-04.parquet`, `-05.parquet`

Target table: `` `ftw-week-08`.`02-bronze`.green_taxi_raw ``

Entry point: `10_load_green_taxi.sql`.

Load strategy: SQL, one `INSERT` per run covering every unprocessed file. The
folder is the source; no filename is hardcoded.

1. Read every Parquet file in the landing folder, tagging each row with the file
   it came from via `_metadata`.
2. Hash each file's content: a per-row digest, sorted and hashed per file, so the
   result does not depend on read order.
3. Select the files to process — those whose content hash has no `SUCCESS` batch,
   or whose rows are not present in the target. The second condition matters when
   Bronze is dropped but the control row survives.
4. Demote any prior `SUCCESS` batch for that content to `SUPERSEDED` (D24), then
   register one batch per file as `STARTED`.
5. Delete any orphaned rows for that content. The insert and the reconciliation
   below are separate statements, so a run can commit rows and then fail before
   its batch closes; without this a restart would append a second copy.
6. Insert the new files' rows in one statement, joined to their batch by content
   hash.
7. Reconcile: rows landed per file must equal rows in the source file, or the
   stage raises and the batches stay `STARTED`.
8. Close each batch as `SUCCESS` with the count actually landed.

Rerun behavior: a second run against the same files reports zero new files,
registers no batch and writes no rows. Proven in
`evidence/proof/2026-09-19-idempotency.md`.

Incremental behavior: files arriving one month at a time are each loaded once,
and earlier months' batch records are never rewritten. Proven in
`evidence/proof/2026-09-19-incremental.md`.

Known limitation: the landing path is a literal inside `read_files`, which cannot
take a variable, so staging a subset of files for a test means moving files in
the Volume rather than pointing the loader elsewhere.

## Weather ingestion

Source: Open-Meteo historical API response, landed as JSON.

Target table: `` `ftw-week-08`.`02-bronze`.open_meteo_weather_raw ``

Entry point: `20_load_open_meteo.sql`.

Load strategy: SQL `MERGE INTO`. Bronze preserves response-grain — one row per API response, with the hourly arrays kept intact rather than exploded into one row per hour.

Business key (what makes a response "new"): `(coordinate_id, requested_start_date, requested_end_date, weather_model)`. A response matching an existing key on all four is treated as already loaded and is not re-inserted.

Two separate hashes are recorded, deliberately different:
- `content_sha256` — hash of the entire landed payload, including `generationtime_ms`. This is an immutable identity for the raw file as received.
- `source_response_version` — hash of everything that describes the actual weather content and its request context (coordinates, elevation, timezone fields, hourly data), **excluding** `generationtime_ms`. This is the field used to detect a genuine content change, since `generationtime_ms` varies between otherwise-identical requests and would make `content_sha256` alone unreliable for that purpose.

`weather_model` defaults to `'api_default_unpinned'` when no model has been explicitly requested, rather than assuming one.

Rerun behavior: re-running against the same response is a no-op on the business key — no duplicate rows.

## Taxi Zones ingestion

Source:
- taxi_zone_lookup.csv

Target table:
- `ftw-week-08`.`02-bronze`.`taxi_zones_raw`

Load strategy:
- Full refresh (`CREATE OR REPLACE TABLE`)

Entry point: 
- `30_load_taxi_zones.sql`.

Reason:

The Taxi Zones dataset is a small static reference lookup containing 265 rows and delivered as a complete source snapshot rather than a transactional or append-only source.

A full refresh is intentionally chosen because:

1. The complete dataset is available in a single file.
2. The dataset is small and inexpensive to reload.
3. Full refresh produces deterministic rerun behavior.
4. Incremental processing would introduce unnecessary complexity without meaningful performance benefits.

Rerun behavior:

Rerunning the same source file produces:

- The same row count.
- The same business content.
- No duplicate business records.

Operational metadata such as `ingested_at` is expected to change between runs because it records the timestamp of the ingestion execution.

`batch_id` for this source is a manually set date stamp (e.g. `'20260916'`), not a generated UUID like the other two sources — consistent with there being no incremental logic to track here.

Known limitation: the current `CREATE OR REPLACE TABLE` rebuilds the table from the `SELECT`, so the types pinned in the earlier `CREATE TABLE IF NOT EXISTS` statement do not actually hold once the replace runs. Tracked as a follow-up (switch to `INSERT OVERWRITE` instead).

Validation:

- Expected row count: 265
- LocationID must be unique
- No duplicate LocationID values
- Source metadata retained

## Failures and recovery

Mark a layer complete only after its load and validation both succeed — a technically-successful write is not enough on its own.

**Green Taxi specific**: the insert and the row-count reconciliation are separate
statements, so a run can commit rows and then fail before its batch reaches
`SUCCESS`. On the next run that file correctly looks unprocessed again, so the
loader deletes any orphaned rows for that content before inserting. Without that
step a restart would append a second copy of every row.

Restart point on failure: re-run the same file for that source, or use **Repair
run** on the failed job run. Proven in
`evidence/proof/2026-09-19-failure-restart.md`. Each source's own change-detection logic (content hash for Taxi, business key for Weather, always-on-full-refresh for Zones) determines what actually gets reloaded — already-successful work is not redone.

Bronze success does not imply Silver success. A failed Silver step does not get silently skipped just because its Bronze batch succeeded.

Surface schema or structure changes (new columns, missing fields, type changes) rather than silently coercing them — see the schema drift check (`src/ingestion/schema_drift_check.py`) for Green Taxi.

----

Download to staging; check status, completeness, parsability and contract; preserve immutable raw inputs; validate before publishing layer output. Mark a layer complete only after its corresponding commit and required checks succeed. Use atomic publication supported by the chosen table/storage system; confirm exact behavior before implementation. If a commit succeeds but its checkpoint fails, a retry must recognize or safely replay the same commit without duplication. Use one coordinated shared writer or explicit concurrency protection.

On critical schema/quality failure retain diagnostic evidence, mark the attempt failed, leave the previous good published result intact, and stop dependent layers. Resume from the failed layer. Persist warnings with explanations. Surface new columns, missing fields, type changes and structure changes rather than silently coercing them.

Discovery follows arrival/source versions, not maximum event time. Late records remain eligible even if their event month is older. A revised source batch can affect multiple event-date aggregates; recompute every affected downstream contribution and preserve unaffected data.

