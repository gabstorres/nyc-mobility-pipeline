# Proof: complete pipeline run and final reconciliation

Issue #48 · captured 2026-09-19

## The run

| | |
|---|---|
| Job ID | `247151548292923` |
| Job run ID | `114035396640679` |
| Git branch | `main` |
| Started | 2026-09-19 07:47 |
| Ended | 2026-09-19 07:55 |
| Duration | 8m 28s |
| Status | **Succeeded** |
| Launched | Manually |

Every task green, from `00_create_control_tables` through both dashboard tasks.
No task was repaired, skipped or re-run.

## Execution order

The job ran the order defined in `databricks.yml`, which is the same order
`docs/job_setup.md` describes. Dependencies enforce it: a gate that fails its
task blocks everything after it.

```
control setup
  → three Bronze loads (parallel)     → three Bronze gates + control gate
  → three Silver cleaners (parallel)  → three Silver gates
  → Integration maps                  → Integration gate
  → four Gold dimensions (parallel)   → weather fact → trip fact → Gold gate
  → three Analytics datasets          → Analytics gate
  → both dashboards
```

The three sources run independently until Integration, so an unfinished source
never blocks a finished one (D17).

## Final reconciliation

| Layer | Object | Rows |
|---|---|---:|
| Source | three Parquet files | 133,367 |
| Bronze | `green_taxi_raw` | 133,367 |
| Bronze | `open_meteo_weather_raw` | 1 response |
| Bronze | `taxi_zones_raw` | 265 |
| Silver | `green_taxi_clean` | 133,353 |
| Silver | `green_taxi_quarantine` | 14 |
| Silver | `weather_hourly` | 2,208 |
| Integration | `trip_zone_map` | 133,353 |
| Integration | `trip_weather_map` | 133,353 |
| Gold | `fact_taxi_trip` | 133,353 |
| Gold | `fact_weather_hourly` | 2,208 |
| Analytics | `activity_by_time_and_zone` | 46,156 |

The identities that must hold, and do:

| | |
|---|---|
| Source = Bronze | 44,208 + 44,238 + 44,921 = 133,367 |
| Bronze = clean + quarantine | 133,353 + 14 = 133,367 |
| Silver clean = both Integration maps = trip fact | 133,353 |
| Silver weather = Gold weather fact | 2,208 |
| `SUM(fare_amount)` end to end | **2,248,450.30** |

The fare total is the measure reconciliation. It is identical in Bronze, in
Silver clean plus quarantine, and in `fact_taxi_trip`, and it matches an
independent DuckDB pass over the three source Parquet files — so the figure is
verified against the sources themselves, not only against the pipeline's own
record.

## Gates

Every gate passed before the layer after it published. Current state:

```sql
SELECT layer, dataset, status, checks_run, fail_count, executed_at
FROM `ftw-week-08`.`01-control`.gate_status ORDER BY layer, dataset;
```

| Layer | Datasets |
|---|---|
| control | `ingestion_batches` |
| bronze | `green_taxi`, `open_meteo`, `taxi_zones` |
| silver | `green_taxi`, `weather_hourly`, `taxi_zones` |
| integration | `trip_maps` |
| gold | one row per dimension and fact |
| analytics | `business_questions` |

## No hidden state

Every table reference in `etl/` is fully qualified with catalog and schema, so a
file runs the same from a job task, a SQL editor cell, or a fresh session.
Checked mechanically by `tests/test_repo_policy.py::test_schema_references_include_the_catalog`.

The job is GIT-sourced from `main`, so a run uses reviewed, committed code rather
than whatever is in anyone's workspace.

## Provenance: a Gold row back to its source

Every Gold trip carries `source_file`, `batch_id` and `content_sha256`. Tracing
one record back:

```sql
SELECT f.trip_key, f.source_file, f.batch_id,
       b.source_object, b.status, b.row_count, b.content_sha256, b.completed_at
FROM `ftw-week-08`.`05-gold`.fact_taxi_trip AS f
JOIN `ftw-week-08`.`01-control`.ingestion_batches AS b ON f.batch_id = b.batch_id
LIMIT 1;
```

`content_sha256` identifies which *version* of that file the row came from, so a
revised source file is distinguishable from the original rather than silently
replacing it.

## Runtime parameters and secrets

No secrets. The pipeline reads from a Unity Catalog Volume and writes to Unity
Catalog schemas, both governed by workspace permissions — nothing in the
repository holds a credential, and `tests/test_repo_policy.py` checks that
configuration files parse and contain no committed secrets.

The only runtime value is the SQL warehouse id in `databricks.yml`, which is an
identifier rather than a credential. Weather request parameters (coordinate,
date range, model) are declared at the top of `20_load_open_meteo.sql`.

## Acceptance evidence, against issue #48

| Required | State |
|---|---|
| Pipeline runs in the documented execution order | Yes — run `114035396640679` |
| No hidden notebook or session state required | Yes — GIT-sourced, fully qualified references |
| All table references fully qualified | Yes — enforced by a repo test |
| Every gate passes before the next layer publishes | Yes — all green in this run |
| Final counts reconcile across layers | Yes — table above |
| Provenance traces Gold back to source and batch | Yes — query above |
| Final evidence saved under `evidence/proof/` | This file |
| Final dashboard measures match Analytics | **Not verified in this file** — see below |
| A different team member follows the runbook successfully | **Not yet done** — see below |

## What this run does not prove

**Dashboard figures were not reconciled against Analytics here.** Both dashboard
tasks completed, which means they refreshed without error — it does not mean a
human compared a number on a dashboard with the same number in
`06-analytics`. That check is still outstanding.

**Nobody has followed the runbook cold.** The acceptance criterion is that a
different team member can run the project without asking its authors. Until
someone actually does that, it is untested.

Both are honest gaps rather than oversights, and both need a person rather than
another run.
