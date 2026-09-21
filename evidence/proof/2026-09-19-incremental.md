# Proof: March, then April, then May

Issue #45 · captured 2026-09-19

## What was demonstrated

March was loaded alone. April was added without reprocessing March. May was added
without reprocessing either. The proof is not that the totals grew — it is that
**March's batch record is byte-identical in all three snapshots**, and April's is
identical between runs 2 and 3.

The three-increment result also matches loading all three files at once, to the
cent.

## Reset

```sql
DROP TABLE IF EXISTS `ftw-week-08`.`02-bronze`.green_taxi_raw;
DELETE FROM `ftw-week-08`.`01-control`.ingestion_batches WHERE source_system = 'green_taxi';
```

`3` control rows deleted. April and May were then moved out of the landing
folder, leaving March alone.

> Timestamps in `ingestion_batches` are UTC; the Databricks run list shows local
> time (UTC+8). A `completed_at` of `2026-09-18T23:08` UTC is the run that the UI
> lists as 19 September 07:08.

## Run 1 — March only
<img width="1202" height="369" alt="image" src="https://github.com/user-attachments/assets/c092882f-8b94-4a49-9ec7-ea8bc9d10307" />
<img width="1374" height="679" alt="image" src="https://github.com/user-attachments/assets/3f4687a8-2254-43ea-abc2-073eeca7e067" />
<img width="1371" height="533" alt="image" src="https://github.com/user-attachments/assets/c4a972e9-836d-4c71-9eb0-ce0ff3042079" />

Job run `206635342552428` · 07:16–07:21 · 5m 18s · **Succeeded**

| Object | Value |
|---|---:|
| `bronze_green_taxi` | 44,208 |
| `silver_clean` | 44,204 |
| `silver_quarantine` | 4 |
| `integration_zone_map` | 44,204 |
| `gold_fact_taxi_trip` | 44,204 |
| `analytics_q1_rows` | 15,478 |
| `fare_total_cents` | 71,306,073 |

| source_object | batch_id | status | row_count | sha | completed_at |
|---|---|---|---:|---|---|
| `green_tripdata_2026-03.parquet` | `6e4fa18f-f86c-489b-a89e-220144028acc` | SUCCESS | 44,208 | `bb1c81eed6…` | 2026-09-18T23:08:12.475 |

## Run 2 — April added
<img width="1964" height="369" alt="image" src="https://github.com/user-attachments/assets/8a8d607c-0131-4a3b-97cf-b1daf140f6b5" />
<img width="1372" height="681" alt="image" src="https://github.com/user-attachments/assets/ebcf3026-319c-41bd-9e24-2002895aa909" />
<img width="1374" height="558" alt="image" src="https://github.com/user-attachments/assets/2738376e-9a50-4d75-8624-09f2dd53efba" />

Job run `349729896388012` · 07:25–07:30 · 5m 13s · **Succeeded**

| Object | Value | Change |
|---|---:|---:|
| `bronze_green_taxi` | 88,446 | +44,238 |
| `silver_clean` | 88,438 | +44,234 |
| `silver_quarantine` | 8 | +4 |
| `integration_zone_map` | 88,438 | +44,234 |
| `gold_fact_taxi_trip` | 88,438 | +44,234 |
| `analytics_q1_rows` | 30,807 | +15,329 |
| `fare_total_cents` | 145,088,127 | +73,782,054 |

| source_object | batch_id | status | row_count | completed_at |
|---|---|---|---:|---|
| `green_tripdata_2026-03.parquet` | `6e4fa18f-f86c-489b-a89e-220144028acc` | SUCCESS | 44,208 | **2026-09-18T23:08:12.475** |
| `green_tripdata_2026-04.parquet` | `076cd5ab-bf6a-4f83-8adc-2e05afd56860` | SUCCESS | 44,238 | 2026-09-18T23:18:13.797 |

**March's row is unchanged** — same `batch_id`, same `row_count`, same
`completed_at` to the millisecond. It was not reprocessed, and its batch was not
reopened.

## Run 3 — May added
<img width="1960" height="367" alt="image" src="https://github.com/user-attachments/assets/420ed556-d9e2-4a09-bd66-48a8c30a67bc" />
<img width="1376" height="678" alt="image" src="https://github.com/user-attachments/assets/f90d4fa1-b3b3-4aa2-9416-fb973bfb6e9e" />
<img width="1373" height="576" alt="image" src="https://github.com/user-attachments/assets/77cbb8ef-f99d-4f29-9397-39983dac6b48" />
| Object | Value | Change |
|---|---:|---:|
| `bronze_green_taxi` | 133,367 | +44,921 |
| `silver_clean` | 133,353 | +44,915 |
| `silver_quarantine` | 14 | +6 |
| `integration_zone_map` | 133,353 | +44,915 |
| `gold_fact_taxi_trip` | 133,353 | +44,915 |
| `analytics_q1_rows` | 46,156 | +15,349 |
| `fare_total_cents` | 224,845,030 | +79,756,903 |

| source_object | batch_id | status | row_count | completed_at |
|---|---|---|---:|---|
| `green_tripdata_2026-03.parquet` | `6e4fa18f-f86c-489b-a89e-220144028acc` | SUCCESS | 44,208 | **2026-09-18T23:08:12.475** |
| `green_tripdata_2026-04.parquet` | `076cd5ab-bf6a-4f83-8adc-2e05afd56860` | SUCCESS | 44,238 | **2026-09-18T23:18:13.797** |
| `green_tripdata_2026-05.parquet` | `7b275d9b-a0a8-4c2e-b6da-594e23b982ce` | SUCCESS | 44,921 | 2026-09-18T23:26:36.712 |

**March and April are both unchanged.** Three arrivals, three batches, each
closed once.

## The result matches a single combined load

| | Three increments | Loaded together |
|---|---:|---:|
| Bronze | 133,367 | 133,367 |
| Silver clean | 133,353 | 133,353 |
| Silver quarantine | 14 | 14 |
| Gold fact | 133,353 | 133,353 |
| Analytics Q1 rows | 46,156 | 46,156 |
| Fare total | 224,845,030 | 224,845,030 |

Identical to the cent. Arrival order does not affect the result.

## Quarantine accumulates per file, as predicted

4 → 8 → 14, so March contributed 4 rows, April 4, May 6. That matches the
collision analysis behind D10: 7 collision groups, **all of them inside a single
source file**, none spanning two. If a collision spanned files, quarantine would
have jumped when the second file arrived and earlier counts would have changed
retroactively. They did not.

## Acceptance evidence, against issue #45

| Required | Met |
|---|---|
| Run 1 processes March | Yes — 44,208 |
| Run 2 adds April without duplicating or rebuilding March | Yes — March's batch row unchanged |
| Run 3 adds May without duplicating March or April | Yes — both rows unchanged |
| Batch log identifies each source file and status | Yes — one `SUCCESS` batch per file |
| State advances only after successful validation | Yes — every batch closed only after its gate passed |
| Bronze, Silver and Gold counts recorded after every run | Yes — tables above |
| March records remain stable after April and May arrive | Yes — to the millisecond |
| Important measures reconcile after each run | Yes — fare total at each step, summing to the combined total |
| Evidence includes run IDs, batch IDs, counts, timestamps | Yes |
| Proof saved under `evidence/proof/` | This file |

## Scope: what this proves and what it does not

Incremental loading is demonstrated **at Bronze**. Silver, Integration, Gold and
Analytics are rebuilt in full on every run — a recorded decision (D22), not an
omission. The reasons are in that entry: the May file carries 8 pickups dated
April, so rebuilding only the arriving month would leave April wrong, and the
duplicate rule partitions over the whole population.

The evidence above is consistent with that. Silver and Gold counts grow with each
arrival because they are rebuilt from a growing Bronze, while the Bronze batch
records — the thing that tracks what has been *ingested* — are written once and
never touched again.
