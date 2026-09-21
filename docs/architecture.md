This document explains how data moves from external sources through Ingestion, Bronze, Silver, Gold, and Analytics.

# Architecture
Status: proposed, not deployed. Platform: Databricks + class R2.

<img width="820" height="1150" alt="pipeline_flow" src="https://github.com/user-attachments/assets/62179037-d51c-4456-ab36-5f69981b4b2e" />

Ingestion manifests, per-layer checkpoints and DQ results support the whole pipeline; DQ results also feed a DQ dashboard.

## Pipeline stages
 
Each stage has a number. The number is the same in the schema name and in the
`etl/` folder, so a stage can be identified from either side. Names are fixed in
[naming_conventions.md](naming_conventions.md).
 
### 00 Source
 
The raw source files exactly as they arrived, in the R2-backed Volume:
`green_tripdata_2026-03.parquet`, `taxi_zone_lookup.csv`, and the saved
Open-Meteo responses. No project tables are created here. The pipeline only
reads from this stage; nothing writes to it. Source copies are immutable and
identified by content checksum.
 
### 01 Control
 
State about the pipeline itself rather than about mobility. `pipeline_runs`
records executions, `ingestion_batches` records which source versions have been
processed, and `data_quality_results` records validation outcomes. This stage is
what answers "have we already processed this batch?", "can May be rerun safely?"
and "did the load that advanced the watermark actually succeed?". It is kept in
its own schema because its grain and lifecycle differ from business records: it
must survive a rebuild of the business layers.
 
### 02 Bronze
 
The source landed as tables, preserving the source representation, plus
ingestion metadata: `source_system`, `source_file` or `source_url`,
`ingested_at`, and `batch_id`. Source column names and values are preserved
where practical. Nothing is cleaned, corrected, or filtered here. Bronze exists
so the team can always show what the source actually contained, independently of
any later transformation decision.
 
### 03 Silver
 
Cleaned and standardized. Types cast explicitly, column names standardized to
`snake_case`, invalid and out-of-range values quantified and given an explicit
disposition, duplicates resolved against the declared grain with a deterministic
survivorship rule. The grain does not change in this stage: cleaning makes rows
trustworthy, it does not change what a row represents. Every rename, type
change, derived field, semantic change, and dropped field is documented in
[data_dictionary.md](data_dictionary.md).
 
### 04 Integration
 
Where the sources meet: taxi trips resolved to pickup and dropoff zones and to
the corresponding weather observation. Unmatched records are counted before a
join type is chosen, and expected unmatched volumes are documented rather than
silently dropped. Integration produces no tables of its own: it adds columns to a trip without
changing its grain, so its output is written by the Gold build. That is why stage 04 has an `etl/` folder but no schema. Join-coverage counts are recorded in `01-control`.
 
### 05 Gold
 
The approved business model: fact tables at the declared grain, with dimensions
built first and facts resolving foreign keys against those built dimensions. No
Gold fact joins back to Silver for a dimension lookup. Primary key uniqueness,
foreign key integrity, grain, and measures are validated before Analytics is
built on top. Exact names remain pending Issue #17.
 
### 06 Analytics
 
One dataset per approved business question, shaped so the dashboard reads it
directly, named `<measure>_by_<dimensions>`. Each result is spot-checked against
a hand calculation before it is published. The business dashboard consumes only
validated Analytics and Gold output; the DQ dashboard consumes stage 01.
 
## Storage boundaries
 
Suggested group prefix from the lecture: `groups/week09/<group-name>/` inside the class `ftw-b12-r2` storage. Confirm the actual bucket/prefix and Databricks Volume mapping with the class setup; this is not a verified mounted filesystem path.
 
Within the approved prefix, propose `landing/green_taxi/`, `landing/weather/`, `landing/taxi_zones/`, and `evidence/`. Store source versions immutably using a content checksum. Keep requested windows/source months separate from observed event dates.
 
Bronze preserves source representation and ingestion metadata. Silver owns explicit standardization and quality disposition. Gold owns the approved business model. Analytics queries Gold. The dashboard consumes validated Analytics/Gold.
 
Dimensions are built before fact FK resolution. No Gold fact may bypass built dimensions by joining directly back to Silver for dimension lookup.
 
Use Python for external interactions and orchestration, SQL for relational profiling, transformations, modeling and DQ. Keep notebooks thin. Pin code/configuration/source versions for replay; record runtime and dependencies after the platform is inspected.
 
Shared integration tables have one coordinated writer. Each developer uses isolated approved development targets. Physical table format, job orchestration, transaction boundaries and checkpoint implementation remain pending platform validation.
 
