This document defines the approved catalog, schema, table, column, source-file, and path naming conventions.

# Naming conventions
## Catalog

The project uses:

```text
ftw-week-08
```

Because the catalog name contains hyphens, SQL references must enclose it in backticks.

## Source Volume

The R2-backed source Volume is:

```text
`ftw-week-08`.`00-source`.`group_a_source`
```

Workspace path:

```text
/Volumes/ftw-week-08/00-source/group_a_source/
```

The source Volume contains:

```text
green_taxi/
taxi_zones/
weather/
traffic_advisory/
```

Original source filenames are preserved where practical. The Volume path supplies group isolation, so source filenames do not use a `group_a_` prefix.

## Schemas

Schema names are `<stage-number>-<layer>`, extending the existing `00-source`
schema. The number is the pipeline stage and matches the `etl/` folder for that
stage, so schemas sort in pipeline order in the catalog browser and nobody has to
guess which schema a folder writes to.

| Stage | Scope | Code lives here | Tables land here |
|---|---|---|---|
| 00 | Source: raw files as received | profiling is in `notebooks/` | no tables |
| 01 | Control: runs, ingestion batches, DQ results | `etl/01_control/` | `ftw-week-08`.`01-control` |
| 02 | Bronze: source landed with provenance, unchanged | `etl/02_bronze/` | `ftw-week-08`.`02-bronze` |
| 03 | Silver: typed, standardized, deduplicated, same grain | `etl/03_silver/` | `ftw-week-08`.`03-silver` |
| 04 | Integration: trips resolved to zones and weather | `etl/04_integration/` | `ftw-week-08`.`05-gold` |
| 05 | Gold: approved facts and built dimensions | `etl/05_gold/` | `ftw-week-08`.`05-gold` |
| 06 | Analytics: one dataset per business question | `etl/06_analytics/` | `ftw-week-08`.`06-analytics` |

What each stage is responsible for is defined in
[architecture.md](architecture.md). This document only fixes the names.

A stage number identifies a step, not a schema. Stage 00 creates no tables, and
stage 04 writes into Gold: resolving a trip to its zones and weather hour adds
columns without changing the grain of a trip, so it is not a separate layer. The
`04-` slot is left empty rather than renumbering Gold and Analytics, so that an
`04-integration` schema can be added later without renaming anything.

The source Volume remains in the existing `00-source` schema. No project tables
are created in `00-source`.

Because every schema name contains a hyphen and begins with a digit, backticks
are mandatory on schema references. Table and column names must not begin with a
digit and must not contain hyphens.

## Fully qualified references

Every persisted table reference must use:

```text
catalog.schema.table
```

Example:

```sql
SELECT *
FROM `ftw-week-08`.`03-silver`.`green_taxi_trips`;
```

Do not depend on hidden `USE CATALOG` or `USE SCHEMA` state.

## Table names

### Control

| Purpose | Table |
|---|---|
| Pipeline executions | `pipeline_runs` |
| External source batches | `ingestion_batches` |
| Validation results | `data_quality_results` |

### Bronze

| Source | Table |
|---|---|
| Green Taxi | `green_taxi_raw` |
| Open-Meteo | `open_meteo_weather_raw` |
| Taxi Zones | `taxi_zones_raw` |
| DOT advisories | `dot_advisories_raw` |

The DOT advisory table is optional.

### Silver

| Entity | Table |
|---|---|
| Green Taxi trips | `green_taxi_trips` |
| Hourly weather | `weather_hourly` |
| Taxi zones | `taxi_zones` |

### Gold

Exact names require approval in Issue #17.

Patterns:

```text
fact_<business_process>
dim_<business_entity>
```

### Analytics

Exact names depend on the approved business-question outputs.

Pattern:

```text
<measure>_by_<dimensions>
```

## Control-table grains

### `pipeline_runs`

One row per pipeline execution.

### `ingestion_batches`

One row per external source batch or source version.

### `data_quality_results`

One row per validation check per run, batch, and target table.

## Column conventions

- Use lowercase `snake_case` outside source-preserving Bronze columns.
- Use `_id` for identifiers.
- Use `_at` for timestamps.
- Use `_date` for dates.
- Use `_count` for counts.
- Use `_amount` for currency.
- Use `_flag` for Boolean indicators.
- Preserve source column names in Bronze where practical.
- Document every rename, type change, derived field, semantic change, and dropped field.

## File and batch naming

Preserve official source filenames:

```text
green_tripdata_2026-03.parquet
green_tripdata_2026-04.parquet
green_tripdata_2026-05.parquet
taxi_zone_lookup.csv
```

Generated Open-Meteo artifacts must be stored under a batch-specific directory:

```text
weather/<batch_id>/response.json
weather/<batch_id>/weather_hourly.csv
```

A filename does not prove that a batch is new. The ingestion process must also register the source identifier, version, content hash, batch ID, and processing status.
