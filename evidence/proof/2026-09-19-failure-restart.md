# Proof: safe restart after a controlled failure

Issue #47 · captured 2026-09-19
<img width="1198" height="875" alt="image" src="https://github.com/user-attachments/assets/c28e4bab-b3bb-4412-9522-77f01682f518" />


## What was demonstrated

A blocking validation gate stopped the run before a trusted layer published. The
same run was then repaired, the failed task and its dependants re-ran, and the
job reached a normal successful state with no duplicate data and no manual
deletion.

## Run identity

| | |
|---|---|
| Job ID | `247151548292923` |
| Job run ID | `671686268016225` |
| Git branch | `main` |
| Commit | `9b38b72d` |
| Started | 2026-09-19 05:55 |
| Ended (after repair) | 2026-09-19 06:23 |
| Launched | Manually |

## The failure

Task `90_validate_taxi_zones` failed after 25s:

```
[USER_RAISED_EXCEPTION] Bronze taxi_zones gate BLOCKED: 1 failed checks
SQLSTATE: P0001
```
<img width="1191" height="379" alt="image" src="https://github.com/user-attachments/assets/104b5408-4b68-4cb6-bd07-2390cd4b1090" />

**This was a gate refusing to publish, not a crash.** `raise_error` is how a
validation file fails its task, so the failure is the pipeline working as
designed rather than breaking. Worth stating plainly: the proof here is that a
deliberate stop is recoverable, which is the same property a crash would need,
demonstrated through the mechanism the pipeline actually uses.

Downstream tasks were skipped rather than run on unvalidated data:

| Task | State |
|---|---|
| `90_validate_taxi_zones` | Failed |
| `30_clean_taxi_zones` | Upstream failed · 0s |
| `90_validate_clean_taxi_zones` | Upstream failed · 0s |

Tasks on the other two sources — `90_validate_control`, `90_validate_open_meteo`,
`20_clean_weather_hourly`, `90_validate_clean_weather_hourly` — had already
succeeded and were unaffected. Sources advance independently until Integration
(D17), and this run shows that holding under failure.

## The restart

Repair run on the same job run ID. No tables were dropped and no rows were
deleted by hand.

| Task | Result after repair |
|---|---|
| `90_validate_taxi_zones` | Succeeded · 25s · **2 attempts** |
| `30_clean_taxi_zones` | Succeeded · 5s · **2 attempts** |
| `90_validate_clean_taxi_zones` | Succeeded |
| Job run | **Succeeded** · 6m 4s total |

The `2 attempts` marker is the evidence that the same task re-ran inside the same
run, rather than a fresh run being started alongside it.

## Final state

| | |
|---|---|
| Rows read | 10,913,394 |
| Rows written | 405,111 |
| Queries | 158 |

Every gate passed on completion. No duplicate records were created at any
declared grain: the gates that would have caught one — `location_id_unique`,
`trip_hash_unique`, `no_duplicate_successful_batches`,
`bronze_to_silver_row_reconciliation` — all passed in the repaired run.

## Acceptance evidence, against issue #47

| Required | Met |
|---|---|
| A controlled failure before batch completion | Yes — gate blocked before Silver published |
| The failed run is recorded with a failed status | Yes — task Failed, run Failed |
| Watermark / processed-file state does not advance | Yes — no batch reached `SUCCESS` for the blocked content |
| Already committed data remains internally consistent | Yes — the other two sources were untouched and their gates had passed |
| Restarting the same batch completes safely | Yes — Repair run, 2 attempts |
| Final state matches a normal successful execution | Yes — all gates pass |
| No duplicate records | Yes — uniqueness and reconciliation checks pass |
| Restart instructions documented | Below |

## Restart instructions

1. Open the failed run from **Jobs & Pipelines → NYC Mobility Pipeline → Runs**.
2. Read the failing task's error. A `USER_RAISED_EXCEPTION` names the gate and
   the number of failed checks; the checks themselves are rows in
   `01-control`.`data_quality_results` for that run.
3. Fix the cause. Do **not** drop tables or delete rows to make a gate pass.
4. Click **Repair run** and select the failed task. Its dependants are selected
   automatically.
5. Confirm the task shows more than one attempt and the run reaches Succeeded.

A repair is safe because every load is idempotent: the Bronze loaders skip
content whose hash already has a `SUCCESS` batch, and every layer above Bronze is
a full deterministic rebuild (D22).
