# Decision log

This document is the canonical record of important product, data, and engineering decisions for the NYC Mobility Pipeline. It records what was decided, why it was chosen, which alternatives were rejected, what assumptions remain, and what consequences follow.

**Last updated:** 2026-09-19
**Decision priority:** correctness > reliability > maintainability > scalability > observability > efficiency

## Maintenance rule

When a decision changes, update this file and every affected canonical document in the same pull request. Explicitly identify any document that remains stale.

This log explains why choices were made. Detailed implementation contracts live in:

- `docs/architecture.md`
- `docs/ingestion.md`
- `docs/data_model.md`
- `docs/data_dictionary.md`
- `docs/source_to_target_mapping.md`
- `docs/naming_conventions.md`
- `docs/model/nyc_mobility_star_schema.png`

## Decision register

| ID | Decision | Status | Primary consequence |
|---|---|---|---|
| D01 | Use Databricks and the class R2 storage environment; use GitHub for code and documentation | Platform confirmed; setup tracked separately | Do not introduce another processing or storage platform without a new decision |
| D02 | Prioritize Taxi, Weather, and Taxi Zones; defer traffic advisories | Active | Optional traffic analysis creates no model dependency until historical and spatial coverage is validated |
| D03 | Use a source-version manifest with per-layer checkpoints | Proposed | File discovery alone is not sufficient proof that a source version completed every layer |
| D04 | Replace a complete revised source-batch contribution | Proposed | Do not append a revised contribution beside stale rows from the same logical source version |
| D05 | Profile before finalizing taxi duplicate handling | Resolved by D10 and Issue #14 | Do not use `DISTINCT` or an invented trip identifier without collision evidence |
| D06 | Use one representative NYC weather coordinate initially | Active | Weather results are citywide associations and not zone-specific observations |
| D07 | Do not use SCD Type 2 for Taxi Zones initially | Final candidate under Issue #17 | Pin the selected reference snapshot; add historical versions only for a future approved requirement |
| D08 | Use one branch per work item and assign a reviewer | Proposed team workflow | Keep individual work isolated from shared integration targets |
| D09 | Store weather in UTC in Bronze and convert to `America/New_York` in Silver | Approved through Issue #16 | All conversions must be DST-aware; never use a fixed UTC offset |
| D10 | Identify taxi duplicate collisions with the approved composite hash and quarantine every colliding row | Approved through Issue #14 | Collision groups do not enter the clean Silver or Gold trip tables |
| D11 | Full-refresh the selected Taxi Zone reference snapshot | Approved through Issue #22 | Identical input produces identical business content without incremental row-level complexity |
| D12 | Approve three core business questions, defer optional traffic analysis, and use the two-fact Gold model | Final candidate for Issue #17 | Pickup and drop-off roles remain separate; trip and hourly-weather measurements remain at their natural grains |
| D13 | Use numbered Databricks schemas aligned with pipeline stages | Approved through Issue #3 | Persisted objects use `01-control`, `02-bronze`, `03-silver`, `05-gold`, and `06-analytics` |
| D14 | Build `ingestion_batches` as a standalone control table, scoped before Bronze ingestion; `pipeline_runs` deferred | Approved | The pipeline can answer "have we already processed this?" from a persisted table without requiring per-layer run tracking yet |
| D15 | Retain quality-flagged Green Taxi rows in the clean Silver table instead of quarantining them; quarantine only duplicate collisions | Active | `green_taxi_clean` requires explicit flag filtering per measure; only D10 duplicates are excluded from it |
| D16 | Standardize Taxi Zones in Silver and preserve sentinel records | Approved through Issue #29 | Taxi Zone IDs 264 and 265 remain explicit Silver members and location_id uniqueness is validated on every load |
| D17 | Validate Bronze and Silver per source with a shared result contract; remove `etl/00_source_profile/` | Proposed | Each source has its own gate and may advance independently; Integration requires every source's Silver gate |
| D18 | Build both Gold facts from validated upstream results with deterministic keys and convergent MERGE publication | Proposed through Issue #38 | Facts preserve their declared grains; Gold validation blocks publication on grain, FK, lineage, quarantine, or reconciliation failures |
| D19 | Publish Silver's `trip_hash` as the trip identity and carry it into Gold as `trip_key` | Approved | One definition of trip identity; Integration keys its maps on it and Gold stops recomputing a second hash |
| D20 | Accept the weather coverage gap and report weather measures against their own denominator | Approved | Q2 and Q3 describe 133,173 of 133,353 trips; the shortfall is concentrated on the evening of 2026-05-31 |
| D21 | Treat `passenger_count = 0` as not recorded rather than implausible | Approved | Passenger measures must exclude `passenger_count_missing_flag` rows and state their denominator |
| D22 | Rebuild every layer above Bronze in full; keep incremental processing at Bronze | Approved | Late-arriving rows and global duplicate detection stay correct without watermark state below Bronze |
| D23 | Store wall-clock business timestamps as `TIMESTAMP_NTZ` and convert with `convert_timezone` | Approved | No stored timestamp depends on the cluster's session timezone |
| D24 | Add a `SUPERSEDED` batch status for content that was later reloaded | Approved | A reload no longer reads as double processing, and the earlier attempt stays auditable |


## Foundational decisions

### D01: Platform and repository

Use Databricks with the class R2 storage environment for processing and storage. Use GitHub for version-controlled code and documentation.

**Reason:** These are the selected course and team platforms. Introducing another platform would increase setup, access, and support risk without serving an approved requirement.

**Consequence:** Actual access, catalog paths, Volume paths, and permissions must be verified in the workspace rather than assumed from documentation.

### D02: Source scope and deferred traffic analysis

Implement the pipeline first with:

- NYC TLC Green Taxi trip records
- Open-Meteo archive weather
- NYC Taxi Zones

NYC DOT traffic advisories remain optional and deferred.

**Reason:** The currently available advisory evidence does not establish reliable historical and spatial coverage for March–May 2026. Correctness takes priority over bonus scope.

**Consequence:** Q4 does not justify a traffic fact, disruption dimension, bridge table, or trip-to-advisory relationship. Traffic modeling requires a later source-validation result and a separate approved design decision.

### D03: Source-version manifest and checkpoints

Track immutable source versions and their progress through each pipeline layer in a control manifest.

**Reason:** A filename-only skip list cannot safely distinguish discovery, partial processing, failed writes, completed commits, or an explicit replay.

**Consequence:** The design must support safe reconciliation between checkpoints and committed tables. A source version is considered complete only when its required layer checkpoint is successful.

### D04: Revised source-batch replacement

When a complete source contribution is revised, replace the prior contribution for that logical source batch rather than appending the revision beside stale rows.

**Reason:** Appending revisions can retain obsolete records. Inventing row-level merge keys where real-world identity is not provable can also preserve the wrong row.

**Consequence:** Replacement must be scoped through the source-version manifest, reconciled by row counts and content checks, and committed atomically where practical.

### D05: Profile before duplicate handling

Taxi duplicate handling must be based on observed collision evidence rather than convenience operations such as blanket `DISTINCT`.

**Status:** Resolved by D10 and Issue #14.

### D06: Representative citywide weather coordinate

Use one documented representative NYC coordinate for the initial Open-Meteo series.

**Reason:** This supports the approved weather-association questions without claiming a spatial resolution the source request does not provide.

**Consequence:** Weather results must be described as citywide associations. A Taxi Zone comparison does not mean weather was separately measured in every zone.

### D07: No initial SCD Type 2 for Taxi Zones

Use the selected validated Taxi Zone snapshot as a current reference dimension. Do not implement SCD Type 2 history initially.

**Reason:** None of the approved questions requires historical zone descriptions.

**Rejected alternative:** Adding effective dates and multiple historical versions without a business requirement.

**Consequence:** Pin the source snapshot and retain its checksum and retrieval metadata for reproducibility. Reconsider historical dimension versions only if a future approved question requires them.

### D08: Branch and review workflow

Use one branch per work item and identify a reviewer for shared changes.

**Reason:** Isolated branches make ownership, review, rollback, and integration clearer for a multi-person project.

**Consequence:** Developers should not use a shared integration branch as their personal working branch.

## Data and ingestion decisions

### D09: Weather and taxi timezone standard

**Status:** Approved through Issue #16  
**Decision date:** 2026-09-15

Request and store Open-Meteo weather in UTC in Bronze. Convert weather timestamps to `America/New_York` explicitly in Silver using a DST-aware IANA timezone conversion. Join weather to taxi trips using the trip pickup hour after both timestamps have been reconciled correctly.

The profiled weather response supports the UTC interpretation:

- `utc_offset_seconds = 0`
- `timezone = GMT`
- `timezone_abbreviation = GMT`

**Rejected alternative:** Requesting Open-Meteo data pre-localized with the API `timezone` parameter. Although the parameter is accepted, its per-hour DST behavior across the complete multi-month window was not validated before this decision. Pre-localizing the acquisition request would also move a Silver standardization concern into source-preserving Bronze.

**Assumption requiring validation:** Source taxi timestamps in `lpep_pickup_datetime` and `lpep_dropoff_datetime` represent `America/New_York` local time. If profiling proves that they are UTC instead, both taxi and weather must receive the appropriate explicit Silver conversion.

**Consequence:** Never convert with a fixed `-4` or `-5` hour offset. The March 8, 2026 spring-forward transition falls inside the reporting window. The implementation must include the worked DST-boundary example required by Issue #16.

### D10: Green Taxi duplicate-identification and quarantine policy

**Status:** Approved through Issue #14  
**Decision date:** 2026-09-15

Green Taxi has no verified natural trip ID. Construct a deterministic SHA-256 fingerprint from:

- `VendorID`
- `lpep_pickup_datetime`
- `lpep_dropoff_datetime`
- `PULocationID`
- `DOLocationID`
- `trip_distance`
- `fare_amount`

Exclude highly nullable fields such as `passenger_count`, `payment_type`, `RatecodeID`, `trip_type`, and `congestion_surcharge` from the fingerprint because they would make matching unstable.

Profiling across March–May 2026 found:

- 133,367 total rows
- 7 collision groups
- 14 colliding rows
- approximately 0.010% of rows affected

Manual inspection showed reversal or correction-like pairs with identical identity inputs and sign-flipped charge fields.

**Rejected alternative:** Automatically choosing a survivor such as the row where `total_amount > 0`. The observed examples do not prove that the rule would remain correct for future collision types.

**Policy:**

- Route every row in a collision group to the Silver quarantine table.
- Do not place a selected survivor from that group into the clean Silver table or Gold trip fact.
- Tag quarantined records for investigation and preserve their complete lineage.
- Halt publication of the clean Silver contribution if the quarantine rate exceeds 1%, while still writing the quarantine output for investigation.
- Use deterministic full Bronze rereads and overwrite/replacement behavior so identical input produces identical clean and quarantine business content.

**Consequence:** The Gold `trip_key` can use the approved fingerprint inputs after collision groups have been removed. It must not include `batch_id`, `run_id`, or ingestion time merely to manufacture uniqueness.

### D11: Taxi Zones full-refresh ingestion

**Status:** Approved through Issue #22  
**Decision date:** 2026-09-16

Taxi Zones is a small complete reference snapshot containing 265 profiled rows. Preserve each received source artifact with checksum and retrieval metadata, then rebuild the selected reference table from the complete validated snapshot.

The Bronze target is:

```text
`ftw-week-08`.`02-bronze`.taxi_zones_raw
```

The selected normalized reference is rebuilt deterministically for downstream use.

**Reason:**

- The complete dataset arrives as one lookup snapshot.
- The dataset is small and inexpensive to reload.
- Full refresh naturally captures inserts, updates, and removals within the selected snapshot.
- Replacement is easier to validate than unnecessary row-level change tracking.

**Rejected alternatives:**

- `INSERT INTO` or row-level `MERGE`, which would require extra insert/update/delete detection and snapshot-version logic.
- `COPY INTO` as the sole incremental mechanism, which is better suited to independently arriving files such as monthly Taxi extracts and does not solve selected-snapshot replacement.

**Rerun behavior:** Identical input produces the same row count and business content with no duplicate business records. Operational metadata such as `ingested_at` may reflect the latest execution.

**Consequence:** If Taxi Zones later becomes a versioned incremental source, revisit this decision before changing the load strategy.

## Business and model decision

### D12: Final business questions and Gold model

**Status:** Approved through Issue #17  
**Decision date:** 2026-09-17  

#### Final business questions

##### Q1. When and where is recorded Green Taxi activity highest?

**Measure:** Trip count  
**By:** Pickup date, day of week, hour, and Taxi Zone

Pickup and drop-off zones are analyzed separately.

##### Q2. How is weather associated with taxi activity and trip behavior?

**Measures:**

- Trip count
- Average trip duration
- Average trip distance
- Average fare amount

**By:** Weather condition and precipitation band

##### Q3. Which areas show the strongest mobility patterns?

**Measures:**

- Pickup count
- Drop-off count
- Average trip duration
- Average trip distance
- Average fare amount

**By:** Taxi Zone, time, and weather condition

Pickup and drop-off roles remain separate.

##### Q4. Optional: Do traffic disruptions affect taxi activity?

This question remains deferred unless reliable historical and spatial coverage can be validated from the NYC DOT advisory source.

#### Qualifications

- Recorded trip count is a proxy for demand.
- Weather comparisons show association, not causation.
- Source fields and coverage remain unverified until profiling is complete.

#### Assumptions requiring validation

- Reporting timezone is `America/New_York`.
- Weather is attributed using the trip pickup hour.
- Open-Meteo represents one documented citywide NYC coordinate.
- Q2 and Q3 describe association, not causation.
- Trip count measures recorded taxi activity and is only a proxy for demand.
- Fare analysis uses `fare_amount`, excluding tolls, surcharges, and tips.
- Weather-code and precipitation-band mappings will be documented.
- Fare, duration, and distance validity rules will be based on profiling.
- Invalid values will remain traceable through quality flags or quarantine records.
- March–May 2026 files contain the expected fields and usable date coverage.

#### Model choice

Use a two-fact Gold design:

- `fact_taxi_trip`: one row per accepted Green Taxi trip after the approved duplicate policy.
- `fact_weather_hourly`: one row per configured coordinate, UTC observation hour, and selected weather model.
- `dim_date`: one row per NYC-local calendar date.
- `dim_hour`: one row per hour of day from 0 through 23.
- `dim_taxi_zone`: one row per Taxi Zone `LocationID` in the selected validated snapshot.
- `dim_weather_classification`: one row per weather-code and precipitation-band combination.

Trip and weather measurements remain at their natural grains. Many trips can occur during one weather hour. Copying precipitation or temperature to every trip would create a double-counting risk. The separate weather fact also preserves the complete hourly series, including hours with no recorded trips.

A trip receives only the weather-classification key from its unique pickup-hour match. Temperature and precipitation remain exclusively in `fact_weather_hourly`. The facts are not joined through a fact-to-fact foreign key.

**Rejected alternative:** One trip fact with measured hourly weather stored as a dimension attached to trips. Although queryable with care, that structure blurs the weather grain and makes repeated-measure aggregation errors easier.

#### Keys and relationships

- `fact_taxi_trip.trip_key` is the deterministic non-null primary key created from the D10 identity inputs after collision groups are quarantined.
- `fact_weather_hourly.weather_observation_key` is deterministic from `coordinate_id`, `observation_timestamp_utc`, and `weather_model`.
- `dim_taxi_zone.zone_key` is the surrogate primary key; `location_id` is the unique source business key.
- `dim_weather_classification.weather_classification_key` is deterministic from `weather_code` and `precipitation_band`.
- `dim_date.date_key` uses `YYYYMMDD`.
- `dim_hour.hour_key` equals the hour value from 0 through 23.
- Pickup and drop-off use separate role-playing Date, Hour, and Taxi Zone foreign keys.
- `fact_taxi_trip.pickup_weather_classification_key` references the classification dimension and is not a foreign key to the weather fact.
- No Gold fact resolves a relationship directly against a Silver lookup table.

#### Nullable relationships and unknown handling

- `pickup_zone_key` and `dropoff_zone_key` are nullable for missing or unmatched source IDs. Preserve the original location ID and a match-status field.
- Taxi Zone IDs 264 and 265 remain valid members representing `unknown` and `outside_nyc`. Do not convert an unrelated unmatched ID to either member.
- `pickup_weather_classification_key` is nullable for `no_match` or `invalid_pickup_timestamp`.
- An ambiguous weather match blocks Gold publication.
- An unrecognized non-null WMO code maps to an explicit `unknown_code` classification and creates a data-quality review item.
- Do not create generic unknown Date or Hour members.

#### Measure rules

- **Trip count:** `SUM(trip_count)`, where `trip_count = 1` for every accepted trip inside the reporting window.
- **Pickup count:** trip count grouped through the pickup Taxi Zone role.
- **Drop-off count:** trip count grouped through the drop-off Taxi Zone role.
- **Average trip duration:** average `trip_duration_seconds / 60.0` only when drop-off is strictly later than pickup.
- **Average trip distance:** average non-null distance greater than or equal to zero.
- **Average fare amount:** average non-null, non-negative `fare_amount_usd`. This represents `fare_amount` and excludes tolls, surcharges, and tips.

Q1 uses pickup date, day of week, and hour as its time context while presenting pickup-zone and drop-off-zone results separately. Q2 groups measures by the weather classification matched at pickup hour. Q3 produces separate pickup-role and drop-off-role results; weather in both remains the pickup-hour classification.

An invalid value for one measure does not automatically remove the row from unrelated measures. Preserve the row through quality flags or quarantine according to the applicable policy.

#### Incremental and rerun behavior

- Trip and weather fact keys are deterministic; rerunning identical approved input must not create extra fact rows.
- A complete revised source contribution replaces the prior contribution rather than being appended beside stale rows.
- `dim_taxi_zone` uses a deterministic full refresh from the selected complete snapshot.
- `dim_date`, `dim_hour`, and `dim_weather_classification` are reproducible from deterministic seeds and rules.
- Operational fields such as `run_id` and `ingested_at` may change on replay; business content and row counts remain stable for identical input.

#### Consequences

- Q4 creates no traffic-model dependency while deferred.
- Pickup and drop-off roles must not be collapsed into one ambiguous zone or time field.
- Analytics must not sum hourly weather measurements through trip rows.
- The six Gold tables form the implementation contract after Issue #17 approval.
- A change to a table, grain, key, relationship, classification, or analytical measure must update the data model, dictionary, source-to-target mapping, this log, DBML source, and exported diagram together.

## Namespace and workflow decision

### D13: Databricks namespace and naming

**Status:** Approved through Issue #3  
**Decision date:** 2026-09-14  
**Revised:** 2026-09-15 after review

Use the `ftw-week-08` catalog and the existing R2-backed Volume:

```text
`ftw-week-08`.`00-source`.group_a_source
```

Persisted processing objects use these schemas:

| Pipeline responsibility | Schema |
|---|---|
| Control state | `01-control` |
| Bronze | `02-bronze` |
| Silver | `03-silver` |
| Integration step | No dedicated schema initially; writes approved integrated outputs to Gold |
| Gold | `05-gold` |
| Analytics | `06-analytics` |

Schema numbers align with the numbered `etl/` folders and sort the catalog in pipeline order. Table names do not repeat the group name because the approved processing schemas are dedicated to Group A.

Stage 00 is the source Volume; profiling happens in `notebooks/` and creates no processing schema. Stage 04 integration resolves trip relationships without changing the trip grain, so it writes to Gold initially. The `04-` slot remains available rather than forcing later renames.

A dedicated `04-integration` schema requires a new decision if integration begins producing a different grain, several Gold facts reuse an expensive persisted join, or the output requires separate write ownership.

**Rejected alternatives:**

- Unnumbered schemas such as `bronze`, `silver`, and `gold`, because they sort alphabetically rather than in pipeline order and would leave `00-source` as the only numbered stage.
- Numbering table names as well, because the schema already identifies the layer and identifiers beginning with digits would require additional quoting.
- Storing control state in Bronze, because pipeline runs, source batches, checkpoints, and data-quality results have different grains and lifecycles from source-preserving business data.

**Consequences:**

- Catalog and schema identifiers containing hyphens or beginning with digits require backticks in SQL.
- Table and column names must not begin with digits.
- The processing schemas are assumed to be dedicated to Group A. Revisit the namespace before implementation if another group must share them.
- Gold table names are governed by D12 and the approved model documents.


### D14: Ingestion batch tracking

**Status:** Active
**Decision date:** 2026-09-17

Implement Issue #19 as the `ingestion_batches` control table only, per the
approved name in `naming_conventions.md`. `pipeline_runs` (per-layer
execution tracking) is deferred to a separate future issue.

**Reason:** The issue's stated outcome — "the pipeline can answer 'have we
already processed this?' from a persisted table" — is fully answerable by
batch-level tracking alone. Per-layer run tracking (`pipeline_runs`) answers
a narrower, separate question and is not required to satisfy this outcome.

This work is scoped to sit before official Bronze ingestion (Issue #20). Data
previously loaded into personal dev/sandbox schemas during earlier profiling
and deduplication work (Issue #14) was exploratory and is not treated as
official Bronze ingestion.

**Table grain:** One row per external source batch or source version, per
`naming_conventions.md`'s Control-table grains section.

**Lifecycle:** `DISCOVERED` → `STARTED` → `SUCCESS` / `FAILED`. Status
advances to `SUCCESS` only after the load lands and passes validation (for
example, row-count reconciliation), not merely after the write technically
succeeds. A failed batch does not block retry: a retry registers a new
`batch_id` against the same file, preserving the failed attempt's history
rather than overwriting it.

**Two distinct hashing fields:**

- `content_sha256`: hashes the batch's actual content, to detect whether it
  changed independent of filename. For Green Taxi and Taxi Zones, this is a
  whole-file hash.
- `schema_fingerprint`: a separate hash of the column name-and-type
  signature, to detect structural drift independently of content changes.
  Not to be confused with `trip_hash` (D10, Issue #14), which is unrelated
  row-level deduplication logic at the Silver layer.

**`source_version_id`:** a human-readable label
(`<source_system>_<source_period>_v1`), distinct from `content_sha256`. Only
incremented by a person who has confirmed a genuine content change for an
already-processed period, not auto-incremented.


**Files:**

- `etl/01_control/00_create_control_tables.sql`: table DDL
- `src/ingestion/batch_tracking.py`: reusable register and mark-status
  functions
- `etl/01_control/90_validate_control.sql`: reusable validation queries (stuck
  batches, retry-history integrity)

**Consequence:** Any ingestion code for Green Taxi, weather, or Taxi Zones
must call `register_batch_discovered`, `mark_batch_started`, and either
`mark_batch_success` or `mark_batch_failed` from `src/ingestion/batch_tracking.py` rather
than writing ad hoc status tracking per source.

### D15: Silver quality-flag policy for Green Taxi trips

**Status:** Active
**Decision date:** 2026-09-17

Only duplicate hash collisions (per D10) are quarantined out of
`green_taxi_clean`. Negative fares, negative distances,
dropoff-before-pickup, and implausible passenger counts remain on
`green_taxi_clean`, tagged with boolean flag columns
(`negative_fare_flag`, `negative_distance_flag`,
`dropoff_before_pickup_flag`, `implausible_passenger_count_flag`)
rather than being excluded.

**Reason:** D12's measure eligibility rule states an invalid value for
one measure does not automatically remove the row from unrelated
measures. A trip with a negative fare still has a valid pickup,
dropoff, and location for trip-count purposes (Q1); fully quarantining
it would discard legitimate data that unrelated measures still need.
D10 is the only decision requiring full quarantine, and it covers
duplicate collisions only.

**Rejected alternative:** Quarantining every flagged row, as
Issue #27's initial acceptance-evidence wording suggested
("quantified, not silently dropped" was read as requiring quarantine
for negative fares, bad durations, and implausible passenger counts).
Rejected because no decision requires exclusion for these specific
conditions, and doing so would conflict with D12's measure-eligibility
rule.

**Also computed:** `trip_hash` (D10's composite fingerprint) is
computed in the same step as typing, from raw Bronze values before any
casting — so rounding introduced by casting `trip_distance`/`fare_amount`
to `DECIMAL` cannot change the hash or diverge from the fingerprint
tested in Issue #14.

**Consequence:** Any query using `fare_amount_usd`, `trip_distance_miles`,
or duration-derived measures must filter on the relevant flag
explicitly (e.g. `WHERE NOT negative_fare_flag`) rather than assuming
`green_taxi_clean` contains only valid values for every measure.

**Files:**

- `etl/03_silver/10_clean_green_taxi.sql`
- `etl/03_silver/90_validate_green_taxi.sql`

### D16: Taxi Zones Silver standardization and key-validation policy

**Status:** Approved through Issue #29  
**Decision date:** 2026-09-17

Standardize Taxi Zones in the Silver layer while preserving every valid source record from the selected reference snapshot.

Silver processing applies to:

- Zone-name cleanup
- Service-zone standardization
- Zone classification derivation
- Sentinel-record handling
- LocationID validation

Borough values remain explicit source values and are not converted to lowercase or rewritten.

Examples:

- Bronx → Bronx
- Brooklyn → Brooklyn
- Manhattan → Manhattan
- Queens → Queens
- Staten Island → Staten Island
- EWR → EWR
- N/A → N/A
- Unknown → Unknown

Classification logic is handled separately through zone_classification.


## Validation structure decision

### D17: Validation gates per source, and no source-profile folder

**Status:** Proposed
**Decision date:** 2026-09-17

**Decision:**

1. Bronze and Silver are validated per source. Each layer folder holds one
   `90_validate_<source>` file per source instead of a single
   `90_validate_<layer>` file. Integration, Gold and Analytics keep one
   validation file each, because they combine sources.
2. A source may advance from Bronze to Silver when its own gate passes.
   Integration requires the Silver gates of Green Taxi, weather and Taxi Zones.
3. All gates share one result contract, defined in `docs/validation.md`: one
   `01-control`.`data_quality_results` table, percentage units, one status rule,
   and lineage fields.
4. `etl/00_source_profile/` is removed. Source profiling lives in `notebooks/`
   and is recorded in `docs/source_profile.md`. The README repository structure
   is the reference layout.

**Reason:**

- The sources define good data differently: Green Taxi needs duplicate and
  duration rules, weather needs complete hourly coverage, and Taxi Zones needs
  key uniqueness and special-member rules. One combined file mixes unrelated
  rules and ownership.
- Sources are ingested on different schedules. Green Taxi Bronze is loaded while
  weather and Taxi Zones ingestion are still in progress; one layer gate would
  block Green Taxi on unrelated work.
- The profiling folder duplicated the profiling notebooks and
  `docs/source_profile.md`.
- Without a shared result contract, per-source notebooks had already diverged:
  different status rules, fractional thresholds compared with percentage
  failure rates, and separate results tables in Bronze with names starting with
  a digit.

**Rejected alternatives:**

- One `90_validate_<layer>` file per layer: couples unrelated sources and blocks
  finished sources.
- Per-source results tables (for example `02-bronze`.`90_validate_green_taxi`):
  cannot be combined into one gate or DQ dashboard, place control data in a
  business schema, and break D13's rule that table names must not begin with a
  digit.
- Allowing Integration to start when only some sources pass: trips would be
  resolved against unvalidated zones or weather.

**Assumptions:**

- Every source's checks can be expressed in the shared result format.
- `data_quality_results` is created in `01-control` before the per-source
  notebooks are migrated to it.

**Consequences:**

- Existing files were moved to the README layout in the same pull request as
  this decision (for example, `etl/01_control/validate_taxi_zones.ipynb`
  became `etl/02_bronze/90_validate_taxi_zones.sql`). Notebooks are committed
  in Databricks source format, and `.py` is used only where a step needs Python.
- Each Bronze load file creates its own table with `CREATE TABLE IF NOT EXISTS`, so
  it runs on its own; only shared control tables have a separate `00` setup file.
- `src/ingestion/batch_tracking.py` and `src/ingestion/schema_drift_check.py`
  keep their descriptive names; the README tree lists them instead of a single
  `common.py`, because the file name should say what the module does.
- The results tables `02-bronze`.`90_validate_taxi_zones` and
  `02-bronze`.`90_validate_green_taxi` (PR #82) should write to
  `01-control`.`data_quality_results` instead.
- The Silver weather table was built before a Bronze weather gate existed; it
  must be revalidated once that gate passes.
- `docs/naming_conventions.md` and `etl/README.md` now point to `etl/`, not
  `sql/`, and no longer list `00_source_profile/`.


## Gold fact build decision

### D18: Deterministic facts and a blocking Gold gate

**Status:** Proposed through Issue #38
**Decision date:** 2026-09-18

**Decision:**

1. `fact_weather_hourly` reuses Silver's deterministic observation key and
   resolves Date, Hour, and Weather Classification keys only from built Gold
   dimensions.
2. `fact_taxi_trip` reads Silver `green_taxi_clean` joined to the validated
   `04-integration`.`trip_zone_map` and `trip_weather_map` on `trip_hash`.
   It resolves role-playing dimension keys in Gold and copies only the matched
   weather classification key; hourly temperature and precipitation remain on
   the weather fact.
3. `trip_key` is Silver's published `trip_hash` (D19), which is the deterministic
   hash of the approved D10 identity inputs and excludes batch, run, and
   ingestion metadata. Gold carries it rather than recomputing its own.
4. Both facts use `MERGE` on their deterministic keys. Because the current
   Silver and Integration inputs are complete accepted snapshots, the delete
   arm makes a revised contribution converge without leaving stale rows.
5. Pre-write guards block join fan-out, duplicate trip keys, unresolved required
   FKs, ambiguous weather matches, and non-unique source-version lineage.
6. `90_validate_gold.sql` writes one row per check to the shared control table
   and raises an error if any blocking check fails.

**Known contract gap:** `requested_timezone` is specified in the data
dictionary, but the request parameter is not persisted in Bronze or Silver.
Gold does not fabricate it. It must be captured upstream before the column can
be published and validated.

**Consequence:** The files are implementation-ready but are not proof of a
passing Gold layer until the Integration branch is merged and the Databricks
proof run records counts, reconciled measures, and an identical-input rerun.

### D20: Accept the weather coverage gap rather than re-requesting the series

**Status:** Approved
**Decision date:** 2026-09-18

**Decision:**

Weather-based measures (Q2, Q3) are reported against the trips that have a
weather match, not against all accepted trips. The denominator is stated
wherever such a measure appears: **133,173 of 133,353 accepted trips, 99.87%**.

**Reason:**

The Open-Meteo series was requested for 2026-03-01 to 2026-05-31 in **UTC**,
while trips are recorded in `America/New_York`. The two windows do not align at
either end, so 180 trips have no weather hour to match:

| | trips |
|---|---:|
| Inside the reporting window but past the weather window | 175 |
| Outside the reporting window entirely (2008-12, 2009-01, 2026-02) | 11 |

The 175 are all late on **2026-05-31**: the last weather hour is 23:00 UTC,
which is 19:00 local, so pickups after 20:00 that evening have no match.

**Rejected alternative:** re-requesting the series for 2026-02-28 to 2026-06-01
and reloading. This is the better fix and remains the recommendation for any
future run — the source window was specified wrongly, not the pipeline. It was
rejected for this iteration on time, not on merit: it needs the superseded
Bronze response deleted first (a wider request is a different business key, so
it inserts beside the old one rather than replacing it, and two responses
covering the same hour break Silver's MERGE), then a full reload through
Integration and Gold.

**Consequence:**

- Any by-date weather view understates **2026-05-31**. The shortfall is
  systematic, not random, and must not be read as a finding about that day.
- `weather_match_status` on `fact_taxi_trip` carries the reason per row, so the
  excluded trips stay identifiable rather than silently absent.
- 11 of the 180 can never be covered by any request for this period; they are
  permanently out of scope for Q2 and Q3.

### D19: Publish Silver's `trip_hash` as the trip identity

**Status:** Approved
**Decision date:** 2026-09-18

**Decision:**

`green_taxi_clean` publishes `trip_hash` instead of dropping it. Integration keys
its maps on it, and Gold carries it as `fact_taxi_trip.trip_key` rather than
computing a hash of its own.

**Reason:**

The hash is unique within the clean set by construction: that is exactly what
`collision_count = 1` means under D10. Dropping it left Silver with no key, so
Gold recomputed one over the **typed** Silver columns while Silver had hashed the
**raw** Bronze values. Two serializations of one identity existed, over values of
different precision, with nothing keeping them in step. Integration also had
nothing to hang a key map on, which is why stage 04 had no workable shape.

**Rejected alternatives:**

- Keep recomputing in Gold: two definitions that agree today only because the
  source carries at most two decimal places. A future month with three would let
  two rows distinct in Silver round into one `trip_key`, breaking the fact's
  primary key in a way the Silver gate structurally cannot see.
- Join Integration maps on the seven identity columns instead of a key: works,
  but puts a seven-column join in every downstream query.

**Assumptions:**

- The D10 collision policy continues to quarantine whole groups, which is what
  makes the hash unique in the clean set.

**Consequences:**

- Every `trip_key` value changed; `fact_taxi_trip` had to be rebuilt.
- The Silver gate proves the key is usable: non-null, unique, 64 characters, and
  disjoint from the quarantine table.

### D21: `passenger_count = 0` means not recorded, not implausible

**Status:** Approved
**Decision date:** 2026-09-18

**Decision:**

`passenger_count = 0` sets `passenger_count_missing_flag`, alongside null. It does
not set `implausible_passenger_count_flag`, which stays for counts below zero or
above eight.

**Reason:**

Profiling the three source files shows it is a vendor reporting convention rather
than a data error:

| VendorID | Trips | `= 0` | NULL | % zero |
|---:|---:|---:|---:|---:|
| 2 | 108,531 | 205 | 4,396 | 0.19% |
| 6 | 14,181 | 0 | 14,181 | 0% |
| 1 | 10,655 | 1,522 | 177 | 14.28% |

Vendor 6 reports null for every one of its trips; vendor 1 writes `0` on 14.28% of
its. The trips themselves are ordinary: median fare $14.90 against $14.20 for
trips with a recorded count, median distance 1.7 miles against 1.9.

**Rejected alternative:**

Flagging zero as implausible. The trip is not implausible; only the passenger
count is unknown, and the two statements belong in different columns.

**Consequences:**

- 20,481 rows carry `passenger_count_missing_flag`, 15.35% of the clean table.
- **Any passenger measure in Gold or Analytics must exclude those rows and state
  its denominator.** Leaving zero unflagged would average the zeros in while
  dropping the nulls, biasing every passenger average low.
- None of the three approved business questions currently uses passenger count,
  so nothing downstream depends on this yet.

### D22: Full deterministic rebuild above Bronze

**Status:** Approved
**Decision date:** 2026-09-19

**Decision:**

Bronze is the only incremental layer. Silver, Integration, Gold and Analytics are
rebuilt in full from the layer below on every run. No watermark, processed-batch
marker or row-level merge state exists below Bronze.

**Reason:**

1. **Late-arriving rows are real and cross-month.** Counted on the three source
   files: the May file carries 8 pickups dated April 2026 and 2 dated December
   2008; the April file carries 1 dated March and 2 dated May. Rebuilding only the
   arriving month, or advancing a watermark on pickup date, leaves April wrong by
   eight trips and reports success.
2. **The duplicate rule is global by construction.** `collision_count` partitions
   over the whole trip population. An incremental Silver would have to detect
   collisions between an arriving batch and already-published rows, then
   retroactively move a clean row into quarantine. Verified: all 7 collision
   groups fall inside a single source file, so that machinery would cover a case
   that does not occur.
3. **Volume does not justify it.** 133,367 rows over three months.
4. **It makes the idempotency proof simpler**: rerunning reduces to Bronze
   skipping on content hash plus every layer above being a function of Bronze.

**Rejected alternatives:**

- Batch-scoped append into Silver: breaks D10, since duplicate detection would see
  one batch at a time.
- Partition-scoped rebuild of Gold by pickup month: correct only if the affected
  partitions come from the arriving batch's actual pickup dates rather than the
  file's month, which the table above shows differ. Recorded as the upgrade path.

**Assumptions:**

- Monthly volume stays near 50,000 rows. Revisit past roughly 2 million rows in
  Silver, or a rebuild over ten minutes.
- Cross-batch hash collisions remain absent. This is a property of the data, not a
  guarantee, so the Silver gate counts collision groups every run rather than
  assuming zero.

### D23: Wall-clock business timestamps are `TIMESTAMP_NTZ`

**Status:** Approved
**Decision date:** 2026-09-19

**Decision:**

Business timestamps that represent a wall-clock reading are stored as
`TIMESTAMP_NTZ` in Silver, Integration and Gold. Timezone conversion uses
`convert_timezone(from, to, ts)` with both ends named. `to_timestamp`,
`from_utc_timestamp`, `to_utc_timestamp` and `unix_timestamp` are not used on
these columns. Operational timestamps (`ingested_at`, `silver_processed_at`,
`executed_at`) remain `TIMESTAMP`, since they record an instant.

**Reason:**

Those functions resolve a zoneless value through the **session** timezone, so the
same input produced different stored data depending on a cluster setting nobody
had written down. Three cases were found:

- Open-Meteo sends a zoneless ISO8601 string. `to_timestamp` then
  `from_utc_timestamp` was correct on a UTC cluster and silently cancelled itself
  out on an `America/New_York` one: `2026-03-01T00:00Z` became midnight on 1 March
  instead of 19:00 on 28 February.
- `unix_timestamp` differences for trip duration were wrong across the 8 March DST
  transition on a New York cluster.
- A plain `TIMESTAMP` column in Gold would have converted Silver's values on
  insert, undoing the fix one layer down.

**Rejected alternative:**

Pinning the cluster's session timezone. That makes correctness depend on
configuration outside the repository, which no gate can check.

**Consequences:**

- The Silver weather gate asserts every interior local day holds 23 to 25 distinct
  hours, which detects a conversion that is not shifting at all.
- Boundary days are excluded from that check: a UTC request window cuts the first
  and last local days short by construction.

### D24: `SUPERSEDED` batch status

**Status:** Approved
**Decision date:** 2026-09-19

**Decision:**

`ingestion_batches.status` gains `SUPERSEDED`. A loader demotes a prior `SUCCESS`
batch to it before registering a replacement for the same content.

**Reason:**

Reloading content that already succeeded, usually because its Bronze table was
dropped, left two `SUCCESS` rows for one content hash. The control gate reads that
as the same bytes processed twice, which is exactly what it should flag. Deleting
the earlier row would hide a real attempt, so it is demoted instead and keeps its
own `batch_id`, `row_count` and timestamps.

**Rejected alternatives:**

- Deleting the earlier batch: destroys the audit trail the control table exists for.
- Exempting reloads from the duplicate check: removes the only check that answers
  "what prevents this batch being processed twice?".

**Consequences:**

- The demotion is guarded by the same condition that decides whether a replacement
  is registered, so the two cannot disagree.
- `source_systems_registering_batches` counts only `SUCCESS`, so coverage
  reporting is unaffected.
- `supersedes_batch_id` exists on the table but is **not yet populated**; the link
  between a batch and the one it replaces is currently inferable only from
  `content_sha256` and timestamps.
