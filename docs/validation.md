This document defines the evidence required to prove every pipeline layer is complete, repeatable, and trustworthy.

# Validation and proof

Status: Bronze and Silver checks have been run for Green Taxi (see the proof table below). Weather and Taxi Zones gates are in progress. A result is accepted only when its evidence is recorded.

## Gates per source (D17)

Bronze and Silver are validated **per source**, not once per layer. Each source defines good data differently, and sources are ingested on different schedules, so one combined gate would block a finished source on an unfinished one.

| Layer | Gate unit | Validation file |
|---|---|---|
| Bronze | One gate per source | `etl/02_bronze/90_validate_<source>` |
| Silver | One gate per source | `etl/03_silver/90_validate_<source>` |
| Integration | One gate for all sources combined | `etl/04_integration/90_validate_integration` |
| Gold | One gate | `etl/05_gold/90_validate_gold` |
| Analytics | One gate | `etl/06_analytics/90_validate_analytics` |

### Gate dependencies

| Step | Requires these gates to pass |
|---|---|
| Silver `green_taxi` | Bronze `green_taxi` |
| Silver `weather_hourly` | Bronze `open_meteo` |
| Silver `taxi_zones` | Bronze `taxi_zones` |
| Integration | Silver `green_taxi`, `weather_hourly` and `taxi_zones` |
| Gold | Integration |
| Analytics | Gold |

A source may advance through Bronze and Silver on its own. Nothing is integrated, modeled or published until every required source's Silver gate passes.

### Shared result contract

Rules for good data are source-specific. How results are recorded and judged is the same for every source, so gates can be compared and combined:

- **Results table:** every check writes one row per check per run to `ftw-week-08`.`01-control`.`data_quality_results`, identified by `layer` and `dataset` (for example `bronze` / `green_taxi`). Table names must not begin with a digit (D13), even though validation filenames start with `90_`.
- **Units:** `fail_pct` and `threshold_pct` are both percentages (0–100).
- **Status:**

  | Condition | Status |
  |---|---|
  | Severity is `INFO` | `INFO` |
  | `fail_count` is 0 | `PASS` |
  | Severity is `FAIL` | `FAIL` |
  | Severity is `WARN` and `fail_pct` is above `threshold_pct` | `FAIL` |
  | Otherwise | `WARN` |

- **Gate result:** a source's gate passes when its latest run for that layer has no `FAIL` rows. `WARN` rows need a written explanation. `INFO` rows are measurements only.
- **Thresholds** are documented tolerances, not values tuned to today's data.
- **Known source traits** that appear on every run (for example the 18,754 Green Taxi rows with nulls in six columns) are `INFO` measurements with a tolerance, not permanent warnings.
- **Empty inputs:** every check defines what happens when its input has zero rows; an empty dataset never passes silently.
- **Lineage:** each result row records `batch_id` or `source_version_id` and `code_revision`, so it can be traced to the data and code it checked.
- **Reconciliation** (row counts and at least one measure against the source) is a `FAIL`-severity check inside the gate, not a separate query outside it.

## Integration join coverage (#37)

Stage 04 resolves each accepted trip to its pickup zone, its drop-off zone and its
pickup-hour weather observation. Both maps are keyed on `trip_hash` and hold
exactly one row per accepted trip, so neither can change the trip grain.

Measured on the full three-month load, 133,353 accepted trips.

### Zone resolution

| Pickup status | Drop-off status | Trips |
|---|---|---:|
| `matched_regular` | `matched_regular` | 131,073 |
| `matched_regular` | `matched_special` | 1,836 |
| `matched_special` | `matched_special` | 355 |
| `matched_special` | `matched_regular` | 89 |
| **Total** | | **133,353** |

Per role:

| Role | `matched_regular` | `matched_special` | `unmatched_location_id` | `missing_source_id` |
|---|---:|---:|---:|---:|
| Pickup | 132,909 | 444 | **0** | **0** |
| Drop-off | 131,162 | 2,191 | **0** | **0** |

Every trip resolved. `matched_special` is LocationID 264 (unknown) or 265 (outside
NYC), which D16 treats as explicit members rather than failures — counted
separately so that "resolved to a sentinel" is never mistaken for "resolved to a
real zone". Drop-offs land on a sentinel about five times as often as pickups,
which is what you would expect: people are taken outside the city more often than
they are collected from there.

### Weather resolution

| Status | Trips |
|---|---:|
| `matched_unique` | 133,173 |
| `no_match` | 180 |
| `ambiguous_match` | **0** |
| **Total** | **133,353** |

The 180 unmatched are the request-window boundary, not a join defect: 175 are late
on 2026-05-31 and 11 fall outside the reporting period entirely. Recorded as D20,
with the denominator carried into every weather measure.

**Zero ambiguous matches** is the one that blocks. A trip matching more than one
weather hour cannot be published, because choosing between them would be
arbitrary.

### How the joins are constrained

| Requirement | How it holds |
|---|---|
| Pickup and drop-off roles stay separate | Two independent status columns; the two roles are never summed into one figure |
| Weather uses the pickup hour, DST-aware | `convert_timezone('America/New_York', 'UTC', pickup)` truncated to the hour (D09, D23) |
| `LEFT JOIN` for nullable relationships | Both zone joins and the weather join; an unresolved row survives with a status rather than disappearing |
| Unmatched counted before a join type is chosen | Recorded as `INFO` measurements in the Integration gate, not as failures |
| No unintended fan-out | Each map's row count is compared to `green_taxi_clean` and `trip_hash` uniqueness is asserted; the weather match is aggregated per trip so a multi-hour match cannot multiply rows |
| Counts reconcile | Key sets compared in both directions: every trip has a map row, and no map row lacks a trip |
| Unknown members handled per the star schema | 264 and 265 resolve to `matched_special`; a null weather key is left null rather than pointing at an invented member |
| Facts resolve keys only against built dimensions | Gold reads Silver `green_taxi_clean` for trip **measures** and resolves `zone_key` against `dim_taxi_zone`; no dimension is joined from Silver once the Gold dimension exists |
| Deterministic and rerunnable | `INSERT OVERWRITE` with no generated identifiers in either map; the same input produces the same output |

## Required evidence by layer

| Layer | Required evidence |
|---|---|
| Source/Bronze | Availability; source schema; file/response validity; raw counts vs landed counts; source version and provenance; dates and batch coverage |
| Silver | Typed-field validity; required nulls; duplicate disposition; accepted values; date/range anomalies; row and measure deltas |
| Gold/integration | Unique non-null PKs; nullable/non-null FK policy; unmatched counts; no unintended fan-out; grain and measure reconciliation |
| Analytics | Hand-calculated selected zone/date/hour spot checks; denominators and zero/missing coverage handling |
| Dashboard | Numbers match Analytics/Gold; last checked and data coverage are visible |

Reconcile raw rows = accepted rows + quarantined rows + removed duplicate occurrences with mutually exclusive accounting. Reconcile an important source measure across the same dispositions before comparing Silver and Gold. Define monetary precision/tolerance explicitly. A retained row can have an ineligible measure; document each metric's denominator.

Persist DQ results including run_id, batch_id/source_version_id, code_revision, dataset/layer, check_name/type, executed_at, status, fail_count, total_count, fail_pct, threshold, severity, owner and evidence location. Critical failures block publication; warnings require explanation. Thresholds are relative or schema/business invariants, not fixed current row totals. All checks need explicit empty-dataset behavior.

## Proof sequence

1. Load March; record source versions, target content, counts and measures.
2. Add April; confirm unaffected March content is unchanged.
3. Add May; confirm unaffected earlier content is unchanged.
4. Repeat May; compare business content in both directions, row multiplicities, key sets and reconciled measures. Counts alone are insufficient. Existing input metadata must not be reset on a retry; run/DQ logs may gain entries.
5. Force a failure before publication and after a data commit/before checkpoint update; retry without duplicates or manual deletion.
6. In an isolated test target, process a revised snapshot and late-arrival fixture; confirm affected data updates, unchanged data remains intact, and earlier event dates are not skipped.
7. Introduce a schema-breaking fixture and verify no apparently successful empty output.
8. Replay pinned raw inputs, code, configuration and dependencies in a fresh target; compare business output excluding genuinely run-specific audit records.

Capture immutable evidence under a run-specific directory with the exact source manifest, code revision, config version and runtime. Store large comparison results in R2; commit concise reviewed summaries under `evidence/`.

| Scenario | Run IDs | Source versions | Content comparison | Counts/measures | Result |
|---|---|---|---|---|---|
| March | Logged in `ingestion_batches` | `green_taxi_2026-03_v1` | Schema drift check: clean | 44,208 rows, matches source count | Pass |
| + April | Logged in `ingestion_batches` | `green_taxi_2026-04_v1` | Schema drift check across March+April: clean | 44,238 rows, matches source count | Pass |
| + May | Logged in `ingestion_batches` | `green_taxi_2026-05_v1` | Schema drift check across all 3 months: clean | 44,921 rows, matches source count | Pass |
| Repeat May | New run against same file, same batch skipped | Same content_sha256 as original May batch | Skipped — content hash matched an existing SUCCESS batch | 133,367 total rows unchanged, no duplicates (verified via `etl/02_bronze/90_validate_green_taxi.sql`, then named `green_taxi_trip_validate_ingestion.sql`) | Pass |
| Silver (Green Taxi) | Ran `etl/03_silver/10_clean_green_taxi.sql` (then `green_taxi_trip_create_table_silver.sql`) | `green_taxi_2026-03_v1` / `-04_v1` / `-05_v1` | Row-count reconciliation via `etl/03_silver/90_validate_green_taxi.sql`: 133,367 Bronze = 133,353 clean + 14 quarantined | Quarantine: 14 rows, all `duplicate_hash_collision` (matches Issue #14). Clean-table flags: 384 negative fare, 0 negative distance, 1 dropoff-before-pickup, 101 implausible duration, 13 implausible passenger count | Pass |
| Failure/revision/late/schema | Simulated failure batch marked FAILED; retry succeeded with new batch_id | N/A for failure test | N/A | Failed batch left no partial rows; retry produced correct row count | Partial — failure/retry tested; schema-breaking fixture not yet run |
| Fresh replay | Not run | — | — | — | Not run |
