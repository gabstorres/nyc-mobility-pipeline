# Databricks job setup

How to wire the pipeline as one multi-task Databricks **Job**. A job is used rather than a declarative ETL pipeline because the loads use `COPY INTO` and `MERGE` into our own tables, the control tables are ours (`ingestion_batches`, DQ results), and each gate must fail its task so later stages are skipped.

## Job settings

| Setting | Value |
|---|---|
| Name | `nyc-mobility-pipeline` |
| Source | Git provider, this repository, branch `main` |
| Compute | One shared job cluster for the run, or serverless. SQL file tasks also need a SQL warehouse. |
| Parameters | `landing_path` (defaults to the Volume path), `reprocess` (`false`) |
| Notifications | Email on failure |

Using the Git provider rather than a personal Git folder means every run uses reviewed code and records the commit it ran.

## Tasks

Dependencies are what enforce the gates: if a validation task fails, everything after it is skipped. Tasks with no dependency between them run in parallel, so the three sources move independently until Integration.

| Task key | Type | File | Depends on |
|---|---|---|---|
| `control_setup` | SQL file | `etl/01_control/00_create_control_tables.sql` | — |
| `gate_control` | SQL file | `etl/01_control/90_validate_control.sql` | the three load tasks |
| `load_green_taxi` | SQL file | `etl/02_bronze/10_load_green_taxi.sql` | `control_setup` |
| `load_open_meteo` | SQL file | `etl/02_bronze/20_load_open_meteo.sql` | `control_setup` |
| `load_taxi_zones` | SQL file | `etl/02_bronze/30_load_taxi_zones.sql` | `control_setup` |
| `gate_bronze_green_taxi` | SQL file | `etl/02_bronze/90_validate_green_taxi.sql` | `load_green_taxi` |
| `gate_bronze_open_meteo` | SQL file | `etl/02_bronze/90_validate_open_meteo_weather.sql` | `load_open_meteo` |
| `gate_bronze_taxi_zones` | SQL file | `etl/02_bronze/90_validate_taxi_zones.sql` | `load_taxi_zones` |
| `clean_green_taxi` | SQL file | `etl/03_silver/10_clean_green_taxi.sql` | `gate_bronze_green_taxi` |
| `clean_weather_hourly` | SQL file | `etl/03_silver/20_clean_weather_hourly.sql` | `gate_bronze_open_meteo` |
| `clean_taxi_zones` | SQL file | `etl/03_silver/30_clean_taxi_zones.sql` | `gate_bronze_taxi_zones` |
| `gate_silver_green_taxi` | SQL file | `etl/03_silver/90_validate_green_taxi.sql` | `clean_green_taxi` |
| `gate_silver_weather_hourly` | SQL file | `etl/03_silver/90_validate_weather_hourly.sql` | `clean_weather_hourly` |
| `gate_silver_taxi_zones` | SQL file | `etl/03_silver/90_validate_taxi_zones.sql` | `clean_taxi_zones` |
| `resolve_trip_zones` | SQL file | `etl/04_integration/10_resolve_trip_zones.sql` | all three `gate_silver_*` |
| `resolve_trip_weather` | SQL file | `etl/04_integration/20_resolve_trip_weather.sql` | `resolve_trip_zones` |
| `gate_integration` | SQL file | `etl/04_integration/90_validate_integration.sql` | `resolve_trip_weather` |
| `dim_date` | SQL file | `etl/05_gold/10_dim_date.sql` | `gate_integration` |
| `dim_hour` | SQL file | `etl/05_gold/11_dim_hour.sql` | `gate_integration` |
| `dim_taxi_zone` | SQL file | `etl/05_gold/12_dim_taxi_zone.sql` | `gate_integration` |
| `dim_weather_classification` | SQL file | `etl/05_gold/13_dim_weather_classification.sql` | `gate_integration` |
| `fact_weather_hourly` | SQL file | `etl/05_gold/20_fact_weather_hourly.sql` | the four dimension tasks |
| `fact_taxi_trip` | SQL file | `etl/05_gold/30_fact_taxi_trip.sql` | `fact_weather_hourly` |
| `gate_gold` | SQL file | `etl/05_gold/90_validate_gold.sql` | both fact tasks |
| `analytics_activity` | SQL file | `etl/06_analytics/10_activity_by_time_and_zone.sql` | `gate_gold` |
| `analytics_weather` | SQL file | `etl/06_analytics/20_trip_behavior_by_weather.sql` | `gate_gold` |
| `analytics_zones` | SQL file | `etl/06_analytics/30_mobility_patterns_by_zone.sql` | `gate_gold` |
| `gate_analytics` | SQL file | `etl/06_analytics/90_validate_analytics.sql` | the three analytics tasks |

Dashboards read validated Analytics results and are not job tasks.

## What makes a gate real

A validation query that prints `BLOCKED` does not fail a task. Every `90_validate_*` file must end with something that errors:

```sql
SELECT CASE
         WHEN COUNT_IF(status = 'FAIL') > 0
         THEN raise_error(concat('Bronze green_taxi gate BLOCKED: ',
                                 CAST(COUNT_IF(status = 'FAIL') AS STRING), ' failed checks'))
       END
FROM `ftw-week-08`.`01-control`.green_taxi_data_quality_results
WHERE run_id = dq_run_id;
```

Placeholder files already end with a `raise_error`, so an unimplemented stage fails instead of looking successful. Remove that block when the query is written.

## Proof runs

| Proof | How to run it | Evidence |
|---|---|---|
| Incremental (#45) | March in the Volume, run the job; add April, run; add May, run | Three run histories, row counts per file |
| Idempotency (#46) | Run again with May already loaded | Same row counts and content; the skip appears in `ingestion_batches` |
| Failure recovery (#47) | Cancel a task mid-run, then use **Repair run** | Only the failed task and its dependents re-run; no duplicates |

Commit short summaries under `evidence/proof/`, not full exports.

## Later

The task graph now lives in `databricks.yml`, which is the definition the job actually runs from. This document explains the shape and the reasoning; `databricks.yml` is the source of truth for the tasks themselves.
