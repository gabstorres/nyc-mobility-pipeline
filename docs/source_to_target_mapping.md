# Source-to-target mapping

This document tracks every source, configuration, metadata, and derived field from acquisition through Bronze, Silver, and Gold. A field must not be silently renamed, cast, dropped, or given a new meaning.

## Layer targets

| Layer | Tables |
|---|---|
| Bronze | `ftw-week-08`.`02-bronze`.`green_taxi_raw`, `taxi_zones_raw`, `open_meteo_weather_raw` |
| Silver | `ftw-week-08`.`03-silver`.`green_taxi_trips`, `taxi_zones`, `weather_hourly` |
| Gold | `ftw-week-08`.`05-gold`.`fact_taxi_trip`, `fact_weather_hourly`, `dim_date`, `dim_hour`, `dim_taxi_zone`, `dim_weather_classification` |

Bronze preserves source names and values where practical. Silver owns standardized names, types, timezone conversion, and objective quality flags. Gold owns dimensional keys, validated relationships, and approved analytical measures.

## Column mapping register

| Source | Source field or input | Bronze field | Silver field | Gold destination | Change, meaning, and validation |
|---|---|---|---|---|---|
| Green Taxi | `VendorID`: integer, non-null in profile | `VendorID` | `vendor_id INT` | `fact_taxi_trip.vendor_id` | Renamed and narrowed only after range validation. Valid profiled codes: `1`, `2`, `6`. |
| Green Taxi | `lpep_pickup_datetime`: `TIMESTAMP_NTZ`, non-null | `lpep_pickup_datetime` | `pickup_datetime_local TIMESTAMP` | `fact_taxi_trip.pickup_datetime_local` | Renamed. Interpreted as `America/New_York` only after timezone validation. Original value remains in Bronze. |
| Green Taxi | `lpep_dropoff_datetime`: `TIMESTAMP_NTZ`, non-null | `lpep_dropoff_datetime` | `dropoff_datetime_local TIMESTAMP` | `fact_taxi_trip.dropoff_datetime_local` | Renamed. Used with pickup time to derive trip duration. |
| Green Taxi | `store_and_fwd_flag`: string, nullable about 13–15% | `store_and_fwd_flag` | `store_and_fwd_flag STRING` | `fact_taxi_trip.store_and_fwd_flag` | Retained nullable. Null is not converted to a category without an approved rule. |
| Green Taxi | `RatecodeID`: integer, nullable about 13–15% | `RatecodeID` | `rate_code_id INT` | `fact_taxi_trip.rate_code_id` | Renamed. Valid profiled codes include `1–6` and `99`; null remains null. |
| Green Taxi | `PULocationID`: integer, non-null | `PULocationID` | `pickup_location_id INT` | `fact_taxi_trip.pickup_location_id` | Renamed and retained even when the Gold zone FK is null. |
| Green Taxi | `DOLocationID`: integer, non-null | `DOLocationID` | `dropoff_location_id INT` | `fact_taxi_trip.dropoff_location_id` | Renamed and retained even when the Gold zone FK is null. |
| Green Taxi | `passenger_count`: integer-like, nullable about 13–15% | `passenger_count` | `passenger_count DECIMAL(10,2)` | `fact_taxi_trip.passenger_count` | Type standardized without imputing nulls. Zero and greater-than-eight values receive separate flags. |
| Green Taxi | `trip_distance`: numeric, non-null | `trip_distance` | `trip_distance_miles DECIMAL(18,3)` | `fact_taxi_trip.trip_distance_miles` | Renamed with explicit miles unit. Negative and zero-distance/high-fare conditions are flagged. |
| Green Taxi | `fare_amount`: numeric, non-null | `fare_amount` | `fare_amount_usd DECIMAL(18,2)` | `fact_taxi_trip.fare_amount_usd` | Renamed with USD unit. Represents metered fare, not total charge. Negative values are retained and flagged. |
| Green Taxi | `extra`: numeric, non-null | `extra` | `extra_amount_usd DECIMAL(18,2)` | `fact_taxi_trip.extra_amount_usd` | Renamed with explicit meaning and currency unit. |
| Green Taxi | `mta_tax`: numeric, non-null | `mta_tax` | `mta_tax_amount_usd DECIMAL(18,2)` | `fact_taxi_trip.mta_tax_amount_usd` | Renamed with explicit currency unit. |
| Green Taxi | `tip_amount`: numeric, non-null | `tip_amount` | `tip_amount_usd DECIMAL(18,2)` | `fact_taxi_trip.tip_amount_usd` | Renamed and retained. Not assumed to represent cash tips. |
| Green Taxi | `tolls_amount`: numeric, non-null | `tolls_amount` | `tolls_amount_usd DECIMAL(18,2)` | `fact_taxi_trip.tolls_amount_usd` | Renamed with explicit currency unit. |
| Green Taxi | `ehail_fee`: numeric, 100% null in profile | `ehail_fee` | `ehail_fee_amount_usd DECIMAL(18,2)` | `fact_taxi_trip.ehail_fee_amount_usd` | Retained nullable under the accepted model. Removal requires a documented decision; no imputation. |
| Green Taxi | `improvement_surcharge`: numeric, non-null | `improvement_surcharge` | `improvement_surcharge_amount_usd DECIMAL(18,2)` | `fact_taxi_trip.improvement_surcharge_amount_usd` | Renamed with explicit currency unit. |
| Green Taxi | `total_amount`: numeric, non-null | `total_amount` | `total_amount_usd DECIMAL(18,2)` | `fact_taxi_trip.total_amount_usd` | Renamed and retained. Kept distinct from `fare_amount_usd`; negative values are flagged. |
| Green Taxi | `payment_type`: integer, nullable about 13–15% | `payment_type` | `payment_type_id INT` | `fact_taxi_trip.payment_type_id` | Renamed. Valid profiled codes include `0–6`; null remains null. |
| Green Taxi | `trip_type`: integer, nullable about 13–15% | `trip_type` | `trip_type_id INT` | `fact_taxi_trip.trip_type_id` | Renamed and retained nullable. |
| Green Taxi | `congestion_surcharge`: numeric, nullable about 13–15% | `congestion_surcharge` | `congestion_surcharge_amount_usd DECIMAL(18,2)` | `fact_taxi_trip.congestion_surcharge_amount_usd` | Renamed with explicit currency unit; null remains null. |
| Green Taxi | `cbd_congestion_fee`: numeric, non-null in profile | `cbd_congestion_fee` | `cbd_congestion_fee_amount_usd DECIMAL(18,2)` | `fact_taxi_trip.cbd_congestion_fee_amount_usd` | Renamed with explicit currency unit. |
| Taxi Zones | `LocationID`: integer, 265 unique non-null values | `LocationID` | `location_id INT` | `dim_taxi_zone.location_id` | Renamed. Business key for the selected snapshot; uniqueness and non-null are blocking tests. |
| Taxi Zones | `Borough`: string, non-null | `Borough` | `borough STRING` | `dim_taxi_zone.borough` | Renamed. `EWR`, `N/A`, and `Unknown` remain explicit source values. |
| Taxi Zones | `Zone`: string, non-null | `Zone` | `zone_name STRING` | `dim_taxi_zone.zone_name` | Renamed for clarity. |
| Taxi Zones | `service_zone`: string, non-null | `service_zone` | `service_zone STRING` | `dim_taxi_zone.service_zone` | Retained. Source `N/A` is not converted to SQL null. |
| Open-Meteo | `hourly.time[]`: ISO-8601 hourly values, no nulls or duplicates | `hourly.time` in raw response | `observation_timestamp_utc TIMESTAMP` | `fact_weather_hourly.observation_timestamp_utc` | Exploded to one Silver row per hour. Parsed as UTC because the request timezone is UTC. Part of the weather business key. |
| Open-Meteo | `hourly.temperature_2m[]`: numeric, no nulls | `hourly.temperature_2m` | `temperature_2m_c DECIMAL(8,3)` | `fact_weather_hourly.temperature_2m_c` | Exploded by array position with `hourly.time`; renamed with Celsius unit. |
| Open-Meteo | `hourly.precipitation[]`: numeric, no nulls | `hourly.precipitation` | `precipitation_mm DECIMAL(10,3)` | `fact_weather_hourly.precipitation_mm` | Exploded by array position; renamed with millimetre unit. Negative values fail DQ. Used to derive precipitation band. |
| Open-Meteo | `hourly.weather_code[]`: integer, no nulls | `hourly.weather_code` | `weather_code INT` | `fact_weather_hourly.weather_code` | Exploded by array position. Retained for audit and mapped through the complete WMO classification rule. |
| Open-Meteo | `latitude`: numeric response metadata | `latitude` | `returned_latitude DECIMAL(9,6)` | `fact_weather_hourly.returned_latitude` | Renamed to distinguish the grid-snapped response coordinate from the requested coordinate. |
| Open-Meteo | `longitude`: numeric response metadata | `longitude` | `returned_longitude DECIMAL(9,6)` | `fact_weather_hourly.returned_longitude` | Renamed to distinguish the grid-snapped response coordinate from the requested coordinate. |
| Open-Meteo | `elevation`: numeric response metadata | `elevation` | `elevation_m DECIMAL(10,3)` | `fact_weather_hourly.elevation_m` | Renamed with metres unit. Repeated on hourly Gold rows for reproducibility of the selected series. |
| Open-Meteo | `generationtime_ms`: volatile response metadata | `generationtime_ms` | Not promoted to hourly Silver rows | No Gold column | Preserved in raw Bronze and request/batch evidence. Excluded from normalized weather-content comparison because it varies across identical requests. |
| Open-Meteo | `utc_offset_seconds`: expected `0` for UTC request | `utc_offset_seconds` | Request validation metadata | No Gold column | Validate equals `0`; retain in Bronze/control evidence rather than repeating per hour. |
| Open-Meteo | `timezone`: expected `GMT` for profiled UTC request | `timezone` | Request validation metadata | No Gold column | Validate against requested UTC behavior; retained in Bronze/control. |
| Open-Meteo | `timezone_abbreviation`: expected `GMT` | `timezone_abbreviation` | Request validation metadata | No Gold column | Retained in Bronze/control; not an analytical field. |
| Open-Meteo | `hourly_units.time`: `iso8601` | `hourly_units.time` | Unit validation metadata | No Gold column | Validate expected representation and document it; no per-hour repetition. |
| Open-Meteo | `hourly_units.temperature_2m`: `°C` | `hourly_units.temperature_2m` | Unit validation metadata | No Gold column | Must equal the unit documented for `temperature_2m_c`. |
| Open-Meteo | `hourly_units.precipitation`: `mm` | `hourly_units.precipitation` | Unit validation metadata | No Gold column | Must equal the unit documented for `precipitation_mm`. |
| Open-Meteo | `hourly_units.weather_code`: WMO code | `hourly_units.weather_code` | Unit validation metadata | No Gold column | Validate and retain in Bronze/control. |
| Weather config | `coordinate_id`: injected configuration | `coordinate_id` ingestion metadata | `coordinate_id STRING` | `fact_weather_hourly.coordinate_id` | Required business-key component. Example value should identify the approved representative NYC request point. Not parsed from API response. |
| Weather config | `requested_latitude`: `40.7128` for profiled request | `requested_latitude` ingestion metadata | `requested_latitude DECIMAL(9,6)` | `fact_weather_hourly.requested_latitude` | Injected configuration; kept distinct from returned grid latitude. |
| Weather config | `requested_longitude`: `-74.0060` for profiled request | `requested_longitude` ingestion metadata | `requested_longitude DECIMAL(9,6)` | `fact_weather_hourly.requested_longitude` | Injected configuration; kept distinct from returned grid longitude. |
| Weather config | `requested_timezone`: `UTC` | `requested_timezone` ingestion metadata | `requested_timezone STRING` | `fact_weather_hourly.requested_timezone` | Injected request setting. Bronze acquisition remains UTC. |
| Weather config | `weather_model`: explicit model parameter | `weather_model` ingestion metadata | `weather_model STRING` | `fact_weather_hourly.weather_model` | Required business-key component. Must be pinned before implementation. Existing unpinned response is recorded as `api_default_unpinned`, not assigned an invented model. |
| Weather config | `request_start_date` | Request metadata | Request-window metadata | No Gold column | Stored in control/manifest. Used to validate expected coverage, not as observation time. |
| Weather config | `request_end_date` | Request metadata | Request-window metadata | No Gold column | Stored in control/manifest. The intended NYC-local interval is filtered explicitly downstream. |
| Derived trip | Approved trip identity inputs | None | `trip_key STRING` | `fact_taxi_trip.trip_key` | Deterministic technical PK. Exact serialization and duplicate policy are finalized in Issue #14; must not use `batch_id` or ingest time to invent uniqueness. |
| Derived trip | `pickup_datetime_local` | None | `pickup_timestamp_utc TIMESTAMP` | `fact_taxi_trip.pickup_timestamp_utc` | DST-aware conversion using `America/New_York`. Used only after timezone semantics pass validation. |
| Derived trip | `dropoff_datetime_local` | None | `dropoff_timestamp_utc TIMESTAMP` | `fact_taxi_trip.dropoff_timestamp_utc` | DST-aware conversion using `America/New_York`. |
| Derived trip | Pickup local date | None | `pickup_date_key INT` | `fact_taxi_trip.pickup_date_key` | `YYYYMMDD` lookup to built `dim_date`; non-null for retained valid timestamp. |
| Derived trip | Drop-off local date | None | `dropoff_date_key INT` | `fact_taxi_trip.dropoff_date_key` | `YYYYMMDD` lookup to built `dim_date`; non-null for retained valid timestamp. |
| Derived trip | Pickup local hour | None | `pickup_hour_key INT` | `fact_taxi_trip.pickup_hour_key` | Hour `0–23` lookup to built `dim_hour`. |
| Derived trip | Drop-off local hour | None | `dropoff_hour_key INT` | `fact_taxi_trip.dropoff_hour_key` | Hour `0–23` lookup to built `dim_hour`. |
| Derived trip | `pickup_location_id` lookup | None | `pickup_zone_key BIGINT` | `fact_taxi_trip.pickup_zone_key` | Nullable FK to built `dim_taxi_zone`; never look up directly from Silver during fact consumption. |
| Derived trip | `dropoff_location_id` lookup | None | `dropoff_zone_key BIGINT` | `fact_taxi_trip.dropoff_zone_key` | Nullable FK to built `dim_taxi_zone`. |
| Derived trip | Unique pickup-hour weather match | None | `pickup_weather_classification_key STRING` | `fact_taxi_trip.pickup_weather_classification_key` | Nullable FK copied from the matched hourly weather row. No direct fact-to-fact FK and no weather measures copied to trips. |
| Derived trip | Pickup and drop-off timestamps | None | `trip_duration_seconds BIGINT` | `fact_taxi_trip.trip_duration_seconds` | Difference in seconds. Retain negative result for traceability and flag it; eligible duration requires `dropoff > pickup`. |
| Derived trip | Constant | None | `trip_count INT` | `fact_taxi_trip.trip_count` | Always `1` for each accepted trip fact row. |
| Derived trip | Pickup timestamp and reporting interval | None | `pickup_in_reporting_window_flag BOOLEAN` | `fact_taxi_trip.pickup_in_reporting_window_flag` | True for local pickup at or after `2026-03-01 00:00` and before `2026-06-01 00:00`. |
| Derived trip | Pickup timestamp and source month | None | `out_of_source_file_month_flag BOOLEAN` | `fact_taxi_trip.out_of_source_file_month_flag` | True when pickup year-month differs from the source file logical month. Retain and quantify. |
| Derived trip | Pickup and drop-off timestamps | None | `dropoff_before_pickup_flag BOOLEAN` | `fact_taxi_trip.dropoff_before_pickup_flag` | True when drop-off is earlier than pickup. |
| Derived trip | `trip_distance_miles` | None | `negative_trip_distance_flag BOOLEAN` | `fact_taxi_trip.negative_trip_distance_flag` | True when distance is below zero; null-safe Boolean. |
| Derived trip | `fare_amount_usd` | None | `negative_fare_amount_flag BOOLEAN` | `fact_taxi_trip.negative_fare_amount_flag` | True when metered fare is below zero; retained as potential adjustment/refund pending domain interpretation. |
| Derived trip | `total_amount_usd` | None | `negative_total_amount_flag BOOLEAN` | `fact_taxi_trip.negative_total_amount_flag` | True when total amount is below zero. |
| Derived trip | Distance and metered fare | None | `zero_distance_high_fare_flag BOOLEAN` | `fact_taxi_trip.zero_distance_high_fare_flag` | True when distance equals `0` and fare is greater than `20 USD`, matching profiling evidence. |
| Derived trip | `passenger_count` | None | `passenger_count_zero_flag BOOLEAN` | `fact_taxi_trip.passenger_count_zero_flag` | True only when passenger count equals zero; null produces false and remains independently visible. |
| Derived trip | `passenger_count` | None | `passenger_count_over_8_flag BOOLEAN` | `fact_taxi_trip.passenger_count_over_8_flag` | True only when passenger count is greater than eight; null produces false. |
| Derived trip | Pickup location lookup result | None | `pickup_zone_match_status STRING` | `fact_taxi_trip.pickup_zone_match_status` | One of `matched_regular`, `matched_special`, `missing_source_id`, `unmatched_location_id`. Explains nullable FK. |
| Derived trip | Drop-off location lookup result | None | `dropoff_zone_match_status STRING` | `fact_taxi_trip.dropoff_zone_match_status` | Same accepted values as pickup status. |
| Derived trip | Pickup-hour weather join cardinality | None | `weather_match_status STRING` | `fact_taxi_trip.weather_match_status` | One of `matched_unique`, `no_match`, `invalid_pickup_timestamp`, `ambiguous_match`; ambiguous match blocks publication. |
| Derived weather | Coordinate, UTC hour, and model | None | `weather_observation_key STRING` | `fact_weather_hourly.weather_observation_key` | Deterministic hash PK of `coordinate_id`, `observation_timestamp_utc`, and `weather_model`. |
| Derived weather | `observation_timestamp_utc` | None | `observation_timestamp_local TIMESTAMP` | `fact_weather_hourly.observation_timestamp_local` | DST-aware conversion to `America/New_York`. UTC timestamp remains authoritative for uniqueness. |
| Derived weather | Local observation date | None | `observation_date_key INT` | `fact_weather_hourly.observation_date_key` | `YYYYMMDD` FK to built `dim_date`. |
| Derived weather | Local observation hour | None | `observation_hour_key INT` | `fact_weather_hourly.observation_hour_key` | Hour `0–23` FK to built `dim_hour`. |
| Derived weather | Weather code and precipitation band | None | `weather_classification_key STRING` | `fact_weather_hourly.weather_classification_key` | Deterministic FK to built `dim_weather_classification`; non-null because complete mapping includes `unknown_code`. |
| Derived zone | `location_id` | None | `zone_key BIGINT` | `dim_taxi_zone.zone_key` | Surrogate PK assigned in the built dimension; fact FKs resolve only against this dimension. |
| Derived zone | Location ID and Borough | None | `zone_classification STRING` | `dim_taxi_zone.zone_classification` | Rule order: `264` unknown; `265` outside_nyc; Borough `EWR` ewr; five NYC boroughs nyc_borough; otherwise other_special. |
| Derived classification | Weather code and precipitation band | None | `weather_classification_key STRING` | `dim_weather_classification.weather_classification_key` | Deterministic PK from the two-column business key. |
| Derived classification | `weather_code` | None | `weather_condition STRING` | `dim_weather_classification.weather_condition` | Complete WMO mapping: clear, cloudy, fog, drizzle, rain, freezing precipitation, snow, showers, thunderstorm, or `unknown_code`. |
| Derived classification | `precipitation_mm` | None | `precipitation_band STRING` | `dim_weather_classification.precipitation_band` | `dry = 0`; `light > 0 and <= 2.5`; `moderate > 2.5 and <= 7.5`; `heavy > 7.5`. |
| Derived classification | Source `weather_code` | None | `weather_code INT` | `dim_weather_classification.weather_code` | Retained WMO code; composite UK part with precipitation band. |
| Calendar seed | Local calendar date | None | `full_date DATE` | `dim_date.full_date` | One unique row per local date covering the reporting interval and every retained observed taxi date. |
| Calendar seed | `full_date` | None | `date_key INT` | `dim_date.date_key` | Deterministic `YYYYMMDD` PK. |
| Calendar seed | `full_date` | None | `calendar_year INT` | `dim_date.calendar_year` | Calendar year. |
| Calendar seed | `full_date` | None | `calendar_quarter INT` | `dim_date.calendar_quarter` | Quarter `1–4`. |
| Calendar seed | `full_date` | None | `month_number INT` | `dim_date.month_number` | Month `1–12`. |
| Calendar seed | `full_date` | None | `month_name STRING` | `dim_date.month_name` | English full month name. |
| Calendar seed | `full_date` | None | `day_of_month INT` | `dim_date.day_of_month` | Day `1–31`. |
| Calendar seed | `full_date` | None | `day_of_week_number INT` | `dim_date.day_of_week_number` | ISO numbering: Monday `1` through Sunday `7`. |
| Calendar seed | `full_date` | None | `day_of_week_name STRING` | `dim_date.day_of_week_name` | English full weekday name. |
| Calendar seed | `day_of_week_number` | None | `weekend_flag BOOLEAN` | `dim_date.weekend_flag` | True for ISO day `6` or `7`. |
| Hour seed | Constant values `0–23` | None | `hour_key INT` | `dim_hour.hour_key` | Deterministic PK equal to hour of day. |
| Hour seed | Constant values `0–23` | None | `hour_of_day INT` | `dim_hour.hour_of_day` | Unique business value. |
| Hour seed | `hour_of_day` | None | `hour_label STRING` | `dim_hour.hour_label` | Zero-padded label such as `00:00`, `13:00`. |
| Hour seed | `hour_of_day` | None | `time_of_day_band STRING` | `dim_hour.time_of_day_band` | Proposed rule: overnight `00–05`, morning `06–11`, afternoon `12–17`, evening `18–23`. |
| Ingestion metadata | `source_system` | `source_system` | `source_system` | Trip fact, weather fact, and Taxi Zone dimension `source_system` | Values are `green_taxi`, `taxi_zones`, and `open_meteo`, identical to `ingestion_batches.source_system` so a row can be joined back to its own batch. Not taken from business payload. |
| Ingestion metadata | Source filename | `source_file` | `source_file` | Trip fact and Taxi Zone dimension `source_file` | Original filename retained. Not part of analytical grain. |
| Ingestion metadata | Weather endpoint URL | `source_url` | `source_url` | `fact_weather_hourly.source_url` | Request endpoint retained separately from canonical request parameters. |
| Ingestion metadata | File content checksum | `content_sha256` and `source_file_version` | `source_file_version` | Trip fact and Taxi Zone dimension `source_file_version` | Immutable file identity. Same checksum and successful layer/version is a no-op unless replay is explicitly requested. |
| Ingestion metadata | Normalized weather response hash | `source_response_version` | `source_response_version` | `fact_weather_hourly.source_response_version` | Hash normalized content excluding volatile `generationtime_ms`; raw response checksum remains in control metadata. |
| Ingestion metadata | Logical source period or request window | `source_period` or request bounds | Preserved lineage metadata | No Gold column | Used for reconciliation and out-of-file-month flag; never assumed to equal observed event coverage. |
| Ingestion metadata | `batch_id` | `batch_id` | `batch_id` | Trip fact, weather fact, and Taxi Zone dimension `batch_id` | Identifies an external source batch/version. Not part of business grain. |
| Pipeline metadata | `run_id` | `run_id` | `run_id` | Trip fact and weather fact `run_id` | Identifies execution attempt; kept separate from `batch_id`. |
| Ingestion metadata | `ingested_at` in UTC | `ingested_at` | `ingested_at` | Trip fact, weather fact, and Taxi Zone dimension `ingested_at` | Operational timestamp, never used as a source update timestamp or identity component. |
| Ingestion metadata | Source row locator | `source_row_locator` | `source_row_locator` | `fact_taxi_trip.source_row_locator` | Stable audit locator where practical. Not proof of real-world trip identity. |
| Ingestion metadata | Raw storage URI | `raw_uri` | Preserved in manifest/control | No Gold column | Points to immutable source artifact in R2; not an analytical attribute. |
| Ingestion metadata | Canonical weather request parameters | `request_parameters` | Preserved in manifest/control | No single Gold column | Includes requested variables, coordinates, dates, timezone, and model. Analytical components are mapped separately above. |

## Accepted code and classification rules

### Zone classification

Rules are evaluated in order:

1. `location_id = 264` → `unknown`
2. `location_id = 265` → `outside_nyc`
3. `borough = 'EWR'` → `ewr`
4. Borough is Bronx, Brooklyn, Manhattan, Queens, or Staten Island → `nyc_borough`
5. Anything else → `other_special` and a DQ review item

Sentinel locations 264 and 265 remain separate valid dimension rows.

### WMO weather condition

| Codes | Condition |
|---|---|
| `0` | `clear_sky` |
| `1` | `mainly_clear` |
| `2` | `partly_cloudy` |
| `3` | `overcast` |
| `45, 48` | `fog` |
| `51, 53, 55` | `drizzle` |
| `56, 57` | `freezing_drizzle` |
| `61, 63, 65` | `rain` |
| `66, 67` | `freezing_rain` |
| `71, 73, 75` | `snow` |
| `77` | `snow_grains` |
| `80, 81, 82` | `rain_showers` |
| `85, 86` | `snow_showers` |
| `95` | `thunderstorm` |
| `96, 99` | `thunderstorm_with_hail` |
| Any other non-null code | `unknown_code` and a DQ review item |

### Measure-specific eligibility

| Metric | Eligibility rule |
|---|---|
| Trip count | Every accepted, deduplicated trip in the reporting window; measure anomalies do not automatically remove the trip |
| Average duration | Both timestamps present and drop-off strictly later than pickup |
| Average distance | Distance is non-null and at least zero; zero-distance/high-fare rows remain flagged for sensitivity review |
| Average fare | Metered fare is non-null and at least zero; negative adjustments remain retained and flagged |
| Fare per mile, if used | Fare is at least zero and distance is greater than zero |

Q1 presents pickup-zone and drop-off-zone results separately using pickup date, day of week, and hour as the stated time context. Q2 groups all four measures by the weather classification matched at pickup hour. Q3 produces separate pickup- role and drop-off-role views; weather in both views remains the pickup-hour classification. Q4 remains deferred and creates no Gold-model dependency.

## Weather-to-trip integration contract

1. Convert `pickup_datetime_local` to UTC using the DST-aware `America/New_York` timezone.
2. Truncate the UTC pickup timestamp to the hour.
3. Match to Silver hourly weather on UTC hour, configured `coordinate_id`, and pinned `weather_model`.
4. Require at most one matching hourly row.
5. Copy only `weather_classification_key` to the trip fact.
6. Keep temperature and precipitation exclusively in `fact_weather_hourly`.
7. Aggregate each fact before combining weather exposure and taxi activity.

## Maintenance rule

The owner of any layer-changing PR must update this mapping in the same PR when a field is added, renamed, cast, derived, dropped, reinterpreted, or routed to a different target. Schema drift must create a visible review item; unknown fields must not disappear silently.

## Resolved design gates

- Issue #14 approved the deterministic trip-identity inputs and the rule that every row in a duplicate collision group is routed to quarantine rather than Gold.
- Issue #16 approved UTC weather acquisition, DST-aware conversion to `America/New_York` in Silver, and pickup-hour weather matching in UTC.
- Issue #17 approved the two-fact Gold model, all fact and dimension names, their grains, keys, nullable relationships, and unknown-member handling.

## Remaining implementation validations

- Pin an explicit Open-Meteo model before new production ingestion. Existing unpinned evidence remains labelled `api_default_unpinned`.
- Validate every proposed numeric cast against the persisted Parquet and JSON schemas before creating Silver and Gold tables.
- Implement and test every WMO, precipitation-band, Taxi Zone, measure-eligibility, and match-status rule exactly as documented.
- Reconcile row counts, unmatched keys, join cardinality, and same-input rerun behavior before publishing each Gold table.
- If a classification band or implementation field changes, update this file, `docs/data_model.md`, `docs/data_dictionary.md`, `docs/decisions.md`, the DBML source, and the exported diagram together.
```
