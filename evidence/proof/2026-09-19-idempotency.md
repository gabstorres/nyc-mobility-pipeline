# Proof: repeated ingestion leaves the dataset unchanged

Issue #46 · captured 2026-09-19

## What was demonstrated

The complete pipeline was run a second time against unchanged sources. Every
count, the reconciled fare total, and every row of `ingestion_batches` were
identical afterwards. No batch was registered, no row was rewritten.

## The rerun

| | |
|---|---|
| Job ID | `247151548292923` |
| Job run ID | `623357194732568` |
| Git branch | `main` |
| Started | 2026-09-19 06:47 |
| Ended | 2026-09-19 06:52 |
| Duration | 5m 46s |
| Status | **Succeeded** |

Nothing was moved, dropped or edited between the two snapshots. The sources in
the Volume were untouched.
## Before
<img width="1330" height="683" alt="image" src="https://github.com/user-attachments/assets/d2c470af-12f3-4c86-93c4-012df6138351" />
<img width="1325" height="572" alt="image" src="https://github.com/user-attachments/assets/67810b9c-030c-489c-b7a9-e1cc537027d9" />

## After
<img width="1915" height="644" alt="image" src="https://github.com/user-attachments/assets/bacee320-0977-4849-b600-e9314de80a49" />
<img width="1330" height="681" alt="image" src="https://github.com/user-attachments/assets/0173b0bf-7219-48c6-a10a-e6271edb9ff7" />
<img width="1329" height="573" alt="image" src="https://github.com/user-attachments/assets/bf527901-661c-4f72-89eb-7ed3f48ab8dd" />


## Snapshot comparison

| Object | Before | After | Same |
|---|---:|---:|:---:|
| `bronze_green_taxi` | 133,367 | 133,367 | ✓ |
| `bronze_weather_responses` | 1 | 1 | ✓ |
| `bronze_taxi_zones` | 265 | 265 | ✓ |
| `silver_clean` | 133,353 | 133,353 | ✓ |
| `silver_quarantine` | 14 | 14 | ✓ |
| `silver_weather_hourly` | 2,208 | 2,208 | ✓ |
| `integration_zone_map` | 133,353 | 133,353 | ✓ |
| `integration_weather_map` | 133,353 | 133,353 | ✓ |
| `gold_fact_taxi_trip` | 133,353 | 133,353 | ✓ |
| `gold_fact_weather_hourly` | 2,208 | 2,208 | ✓ |
| `analytics_q1_rows` | 46,156 | 46,156 | ✓ |
| **`fare_total_cents`** | **224,845,030** | **224,845,030** | ✓ |

The fare total is the measure check, not a count: a rebuild that dropped and
re-inserted the same number of rows with different values would pass every count
comparison above and fail this one. $2,248,450.30 — the same figure that
reconciles back to the source Parquet files.

## Batch log comparison

All 14 rows identical before and after, including `batch_id`, `status`,
`row_count` and `completed_at`. **No new batch was registered.**

Five batches hold `SUCCESS`, one per distinct content version:

| source_system | source_object | batch_id | row_count | completed_at |
|---|---|---|---:|---|
| green_taxi | `green_tripdata_2026-03.parquet` | `6208d6d3…` | 44,208 | 2026-09-18 12:51:49 |
| green_taxi | `green_tripdata_2026-04.parquet` | `68f24461…` | 44,238 | 2026-09-18 12:51:49 |
| green_taxi | `green_tripdata_2026-05.parquet` | `01dfeacb…` | 44,921 | 2026-09-18 12:51:49 |
| open_meteo | `open_meteo_mar_may_2026.json` | `ea7f205d…` | 1 | 2026-09-18 17:00:45 |
| taxi_zones | `taxi_zone_lookup.csv` | `578f3122…` | 265 | 2026-09-18 22:06:38 |

`completed_at` on every one is from **18 September**. The rerun on 19 September
did not touch them, which is the point: a batch closes once and is never
reopened by a repeat run.

The remaining nine rows are `SUPERSEDED` or `FAILED` — the audit trail of the
18 September rebuild session, retained rather than deleted (D24). Exactly one
`SUCCESS` exists per content hash, so `no_duplicate_successful_batches` passes.

## Acceptance evidence, against issue #46

| Required | Met |
|---|---|
| Capture Bronze, Silver, Gold and Analytics counts before the rerun | Yes — table above |
| Run the identical May batch again | Yes — whole job, sources unchanged |
| Batch guard identifies the repeated source | Yes — no new batch registered |
| No duplicate records at any declared grain | Yes — every count unchanged |
| Counts after equal counts before | Yes — all 12 values |
| Important measures remain unchanged | Yes — fare total identical to the cent |
| Processing state is not incorrectly advanced | Yes — `completed_at` unchanged on every batch |
| Batch-log behaviour for the duplicate request documented | Yes — below |
| Content hash or source-version comparison included | Yes — `sha` unchanged per source |
| Before/after evidence saved under `evidence/proof/` | This file |

## Batch-log behaviour on a repeat request

Nothing is written. Green Taxi hashes each file's content and skips any whose
hash already has a `SUCCESS` batch, so no batch is registered and no rows are
inserted. Weather and Taxi Zones merge on a business key and write only when
content or lineage differs; neither did. Everything above Bronze is a
deterministic full rebuild from Bronze (D22), so identical Bronze produces
identical Silver, Integration, Gold and Analytics.

`ingested_at` is unchanged on every row because no row was rewritten. A loader
using `CREATE OR REPLACE TABLE` would reset that column on every run, which is
why D11's implementation uses `MERGE` instead.
