# NYC Mobility Pipeline data model

This document is the plain-language implementation contract for the Gold dimensional model.

**Reporting timezone:** `America/New_York`  
**Weather storage and matching timezone:** UTC  
**Source scope:** NYC TLC Green Taxi, Open-Meteo archive weather, and NYC Taxi Zones

## Business Questions

| ID | Business question | Measures | Dimensions |
|---|---|---|---|
| Q1 | When and where is recorded Green Taxi activity highest? | Trip count | Pickup date, day of week, hour, and Taxi Zone; pickup and drop-off zone roles are analyzed separately |
| Q2 | How is weather associated with taxi activity and trip behavior? | Trip count, average trip duration, average trip distance, average fare amount | Weather condition and precipitation band |
| Q3 | Which areas show the strongest mobility patterns? | Pickup count, drop-off count, average trip duration, average trip distance, average fare amount | Taxi Zone, time, and weather condition; pickup and drop-off roles remain separate |
| Q4 | (Optional) Do traffic disruptions affect taxi activity? | Deferred | No implementation unless reliable historical and spatial coverage is validated from the NYC DOT advisory source |

Recorded trip count is a proxy for demand. Weather comparisons describe association, not causation. The weather series represents one documented citywide NYC coordinate and not separate observations for every Taxi Zone.

Q4 is not a Gold implementation requirement while it remains deferred. This model contains no traffic fact, disruption dimension, bridge, or trip-to-advisory relationship.

## Assumptions requiring validation

- Reporting timezone is `America/New_York`.
- Weather is attributed using the trip pickup hour.
- Weather measures are reported against the trips that have a weather match:
  133,173 of 133,353 accepted trips (99.87%). The weather series was requested
  in UTC while trips are local, so 2026-05-31 after 20:00 has no weather and is
  understated in any by-date weather view (D20).
- Open-Meteo represents one documented citywide NYC coordinate.
- Q2 and Q3 describe association, not causation.
- Trip count measures recorded taxi activity and is only a proxy for demand.
- Fare analysis uses `fare_amount`, excluding tolls, surcharges, and tips.
- Weather-code and precipitation-band mappings are documented before transformation.
- Fare, duration, and distance validity rules are based on profiling.
- Invalid values remain traceable through quality flags or quarantine records.
- March–May 2026 files must contain the expected fields and usable date coverage.
- Source fields and coverage remain unverified until profiling is complete.

## Model overview
The Gold model uses two fact tables because taxi trips and hourly weather observations have different grains.

![NYC Mobility Star Schema](model/nyc_mobility_star_schema.png)

| Gold table | Type | Grain | Primary or unique key |
|---|---|---|---|
| `fact_taxi_trip` | Fact | One row per accepted Green Taxi trip after the approved duplicate policy | `trip_key` |
| `fact_weather_hourly` | Fact | One row per configured coordinate, UTC observation hour, and selected weather model | `weather_observation_key`; unique (`coordinate_id`, `observation_timestamp_utc`, `weather_model`) |
| `dim_date` | Dimension | One row per NYC-local calendar date | `date_key` |
| `dim_hour` | Dimension | One row per hour of day | `hour_key` |
| `dim_taxi_zone` | Dimension | One row per source `LocationID` in the selected validated Taxi Zone snapshot | `zone_key`; unique `location_id` |
| `dim_weather_classification` | Dimension | One row per weather-code and precipitation-band combination | `weather_classification_key`; unique (`weather_code`, `precipitation_band`) |

Weather measurements are not copied onto trip rows. A trip stores only the weather-classification key from its unique pickup-hour match. This prevents precipitation and temperature from being multiplied by the number of trips in the same hour.

## Fact tables

### `fact_taxi_trip`

**Grain:** One row per accepted Green Taxi trip record after all rows in an approved duplicate collision group have been routed to quarantine.

**Primary key:** `trip_key`, a deterministic hash of the approved identity inputs:

- `vendor_id`
- `pickup_datetime_local`
- `dropoff_datetime_local`
- `pickup_location_id`
- `dropoff_location_id`
- `trip_distance_miles`
- `fare_amount_usd`

The key must not include `batch_id`, `run_id`, ingestion time, or another operational value merely to manufacture uniqueness.

**Role-playing foreign keys:**

| Field | References | Nullability and rule |
|---|---|---|
| `pickup_date_key` | `dim_date.date_key` | Non-null for a published trip |
| `dropoff_date_key` | `dim_date.date_key` | Non-null for a published trip |
| `pickup_hour_key` | `dim_hour.hour_key` | Non-null for a published trip |
| `dropoff_hour_key` | `dim_hour.hour_key` | Non-null for a published trip |
| `pickup_zone_key` | `dim_taxi_zone.zone_key` | Nullable for a missing or unmatched source ID |
| `dropoff_zone_key` | `dim_taxi_zone.zone_key` | Nullable for a missing or unmatched source ID |
| `pickup_weather_classification_key` | `dim_weather_classification.weather_classification_key` | Nullable for no weather match or invalid pickup time; ambiguous matches block publication |

The original pickup and drop-off location IDs stay on the fact even when their zone foreign key is null. Match-status fields explain every nullable zone or weather relationship.

**Measures:**

- `trip_count`, always 1
- `trip_distance_miles`
- `trip_duration_seconds`
- `fare_amount_usd`
- retained source amounts and surcharges for traceability

**Required audit and quality fields:**

- local and UTC pickup/drop-off timestamps
- reporting-window and source-month flags
- negative distance, fare, and total flags
- invalid duration and passenger-count flags
- pickup-zone, drop-off-zone, and weather match statuses
- source version, batch, run, ingestion timestamp, and source-row locator

### `fact_weather_hourly`

**Grain:** One row per configured weather coordinate, UTC observation hour, and selected weather model.

**Primary key:** `weather_observation_key`, deterministically generated from:

- `coordinate_id`
- `observation_timestamp_utc`
- `weather_model`

**Foreign keys:**

| Field | References | Rule |
|---|---|---|
| `observation_date_key` | `dim_date.date_key` | Derived from the DST-aware NYC-local timestamp |
| `observation_hour_key` | `dim_hour.hour_key` | Derived from the DST-aware NYC-local timestamp |
| `weather_classification_key` | `dim_weather_classification.weather_classification_key` | Non-null after the complete WMO and precipitation-band mapping |

**Measures:**

- `temperature_2m_c`
- `precipitation_mm`

The fact also retains the WMO code, requested and returned coordinates, elevation, selected model, request timezone, response version, and operational lineage.

## Dimensions

### `dim_date`

**Grain:** One row per NYC-local calendar date covering the reporting interval and every retained observed trip date.

`date_key` uses `YYYYMMDD`. The dimension supplies calendar year, quarter, month, day, ISO day-of-week number, weekday name, and weekend flag.

### `dim_hour`

**Grain:** One row per hour value from 0 through 23.

`hour_key` equals `hour_of_day`. The dimension supplies a zero-padded hour label and the approved time-of-day band.

### `dim_taxi_zone`

**Grain:** One row per source Taxi Zone `LocationID` in the selected validated snapshot.

`zone_key` is the surrogate primary key and `location_id` is the unique business key. The dimension retains Borough, Zone, service zone, classification, and snapshot lineage.

Classification rules are evaluated in this order:

1. `location_id = 264` → `unknown`
2. `location_id = 265` → `outside_nyc`
3. `borough = 'EWR'` → `ewr`
4. Bronx, Brooklyn, Manhattan, Queens, or Staten Island → `nyc_borough`
5. Anything else → `other_special` and a data-quality review item

IDs 264 and 265 are valid source members. An unrelated missing or unmatched location ID must not be silently assigned to either row.

### `dim_weather_classification`

**Grain:** One row per WMO weather code and precipitation-band combination.

The dimension contains the original code, its approved condition label, and the precipitation band. Any unrecognized non-null code maps to `unknown_code` and creates a data-quality review item.

Precipitation bands are:

- `dry`: 0 mm
- `light`: greater than 0 mm and at most 2.5 mm
- `moderate`: greater than 2.5 mm and at most 7.5 mm
- `heavy`: greater than 7.5 mm

## Weather-to-trip integration

1. Interpret the source taxi pickup timestamp as `America/New_York` only after the approved source-timezone validation.
2. Convert the pickup timestamp to UTC using a DST-aware IANA timezone conversion.
3. Truncate the UTC timestamp to the observation hour.
4. Match it to hourly weather using UTC hour, `coordinate_id`, and the pinned `weather_model`.
5. Require zero or one matching weather row. More than one match is an error and blocks publication.
6. Copy only `weather_classification_key` to the trip fact.
7. Keep temperature and precipitation in `fact_weather_hourly`.

Facts are aggregated independently before their outputs are combined. No query should sum weather measurements through trip rows.

## Business-question field mapping

| Question | Fact fields | Dimension fields | Calculation contract |
|---|---|---|---|
| Q1 | `fact_taxi_trip.trip_count`, `pickup_zone_key`, `dropoff_zone_key`, `pickup_date_key`, `pickup_hour_key` | `dim_taxi_zone.zone_name`, `dim_date.full_date`, `dim_date.day_of_week_name`, `dim_hour.hour_of_day` | Create separate pickup-zone and drop-off-zone results. Both use pickup date, pickup day of week, and pickup hour as the stated time context. Sum `trip_count` for accepted trips inside the reporting window. |
| Q2 | `fact_taxi_trip.trip_count`, `trip_duration_seconds`, `trip_distance_miles`, `fare_amount_usd`, `pickup_weather_classification_key` | `dim_weather_classification.weather_condition`, `precipitation_band` | Group trips by the classification matched at pickup hour. Apply each measure's own eligibility rule; do not copy or sum hourly weather measurements through trip rows. |
| Q3 pickup role | `trip_count`, `trip_duration_seconds`, `trip_distance_miles`, `fare_amount_usd`, `pickup_zone_key`, `pickup_date_key`, `pickup_hour_key`, `pickup_weather_classification_key` | Taxi Zone, Date, Hour, and Weather Classification dimensions | Group by pickup zone, pickup time, and pickup-hour weather condition. Pickup count is `SUM(trip_count)`. |
| Q3 drop-off role | `trip_count`, `trip_duration_seconds`, `trip_distance_miles`, `fare_amount_usd`, `dropoff_zone_key`, `dropoff_date_key`, `dropoff_hour_key`, `pickup_weather_classification_key` | Taxi Zone, Date, Hour, and Weather Classification dimensions | Group by drop-off zone and drop-off time while retaining the explicitly approved pickup-hour weather attribution. Drop-off count is `SUM(trip_count)`. Do not combine pickup and drop-off roles in one zone column. |
| Q4 | None | None | Deferred. No traffic table or relationship is part of this implementation contract unless NYC DOT historical and spatial coverage is validated and a follow-up decision is approved. |

## Measure eligibility

| Measure | Eligibility rule |
|---|---|
| Trip count | Every accepted, deduplicated trip with pickup inside the reporting window |
| Pickup count | Trip count grouped through `pickup_zone_key` |
| Drop-off count | Trip count grouped through `dropoff_zone_key` |
| Average duration | Pickup and drop-off timestamps are present and drop-off is strictly later than pickup |
| Average distance | Distance is non-null and greater than or equal to zero |
| Average fare amount | `fare_amount_usd` is non-null and greater than or equal to zero; tolls, surcharges, and tips are excluded |

An ineligible value for one measure does not automatically exclude the record from unrelated measures. Quality flags remain queryable.

## Unknown-member and null policy

- Preserve original location IDs even when zone lookups fail.
- Use null zone foreign keys plus explicit match statuses for missing or unmatched IDs.
- Keep valid source members 264 and 265 distinct from failed lookups.
- Use an explicit `unknown_code` weather classification for an unrecognized non-null WMO code.
- Use a null trip weather-classification key for `no_match` or `invalid_pickup_timestamp`.
- Do not invent an unknown Date or Hour row.
- Do not impute nullable source values unless a separate approved decision authorizes the rule.

## Slowly changing dimensions

No approved question requires SCD Type 2. The Taxi Zone dimension is built from a pinned complete snapshot. A historical dimension-version design will be introduced only if a future approved question requires historical descriptions.

## Incremental and rerun contract

| Table | Load and rerun behavior |
|---|---|
| `fact_taxi_trip` | Use deterministic `trip_key` values. The same approved input cannot create extra rows. A complete revised source-file contribution replaces its earlier contribution. Duplicate collision groups remain in quarantine rather than Gold. |
| `fact_weather_hourly` | Upsert or replace by the deterministic coordinate/hour/model key. A repeated normalized response is a no-op for business content. A revised response replaces measures for the same natural key with updated lineage. |
| `dim_taxi_zone` | Full refresh from the pinned complete snapshot. Identical input produces identical business rows and keys. |
| `dim_date` | Deterministic rebuild or merge by `date_key`. |
| `dim_hour` | Deterministic 24-row seed. |
| `dim_weather_classification` | Deterministic rebuild or merge from the approved WMO and precipitation-band rules. |

Operational values such as `run_id` and `ingested_at` may change during a replay. Business content and row counts must remain stable for identical input.
