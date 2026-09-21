# Data Dictionary

This document defines every retained Gold field in the approved NYC Mobility Pipeline dimensional model.

## Conventions

- All timestamps with `_utc` are UTC.
- All timestamps with `_local` use the DST-aware `America/New_York` timezone.
- Currency fields ending in `_usd` are US dollars.
- Distance fields ending in `_miles` are miles.
- Precipitation fields ending in `_mm` are millimetres.
- Temperature fields ending in `_c` are degrees Celsius.
- Operational identifiers such as `batch_id` and `run_id` are never part of a business grain unless explicitly stated.
- `No` in the Nullable column means the field is required for a published Gold row.

## `fact_taxi_trip`

**Grain:** One row per accepted Green Taxi trip after the approved duplicate policy.

| Field | Type | Nullable | Key | Definition and rule |
|---|---|---:|---|---|
| `trip_key` | STRING | No | PK | Deterministic hash of the approved trip-identity inputs. Must not use batch, run, or ingestion time to manufacture uniqueness. |
| `vendor_id` | INT | No |  | Renamed source `VendorID`; profiled values include 1, 2, and 6. |
| `pickup_datetime_local` | TIMESTAMP | No |  | Source pickup timestamp interpreted as `America/New_York` after timezone validation. |
| `dropoff_datetime_local` | TIMESTAMP | No |  | Source drop-off timestamp interpreted as `America/New_York` after timezone validation. |
| `pickup_timestamp_utc` | TIMESTAMP | No |  | DST-aware UTC conversion of `pickup_datetime_local`. |
| `dropoff_timestamp_utc` | TIMESTAMP | No |  | DST-aware UTC conversion of `dropoff_datetime_local`. |
| `store_and_fwd_flag` | STRING | Yes |  | Source store-and-forward indicator; null is preserved. |
| `rate_code_id` | INT | Yes |  | Renamed source `RatecodeID`; null is not imputed. |
| `pickup_location_id` | INT | No | BK input | Original pickup `PULocationID`; retained even when `pickup_zone_key` is null. |
| `dropoff_location_id` | INT | No | BK input | Original drop-off `DOLocationID`; retained even when `dropoff_zone_key` is null. |
| `passenger_count` | DECIMAL(10,2) | Yes |  | Source passenger count after type standardization; null is preserved. |
| `trip_distance_miles` | DECIMAL(18,3) | No | Measure | Source `trip_distance` with explicit miles unit. Negative and suspicious zero-distance values are retained and flagged. |
| `fare_amount_usd` | DECIMAL(18,2) | No | Measure | Metered fare, not total charged amount. Negative values are retained and flagged. |
| `extra_amount_usd` | DECIMAL(18,2) | No |  | Source `extra`, renamed with currency unit. |
| `mta_tax_amount_usd` | DECIMAL(18,2) | No |  | Source `mta_tax`, renamed with currency unit. |
| `tip_amount_usd` | DECIMAL(18,2) | No |  | Source `tip_amount`; must not be interpreted as representing every cash tip. |
| `tolls_amount_usd` | DECIMAL(18,2) | No |  | Source `tolls_amount`, renamed with currency unit. |
| `ehail_fee_amount_usd` | DECIMAL(18,2) | Yes |  | Source `ehail_fee`; 100% null in the profiled data and retained pending an explicit removal decision. |
| `improvement_surcharge_amount_usd` | DECIMAL(18,2) | No |  | Source `improvement_surcharge`, renamed with currency unit. |
| `total_amount_usd` | DECIMAL(18,2) | No |  | Source total charge. Kept distinct from metered fare. Negative values are retained and flagged. |
| `payment_type_id` | INT | Yes |  | Renamed source `payment_type`; null is preserved. |
| `trip_type_id` | INT | Yes |  | Renamed source `trip_type`; null is preserved. |
| `congestion_surcharge_amount_usd` | DECIMAL(18,2) | Yes |  | Source `congestion_surcharge`, renamed with currency unit. |
| `cbd_congestion_fee_amount_usd` | DECIMAL(18,2) | No |  | Source `cbd_congestion_fee`, renamed with currency unit. |
| `pickup_date_key` | INT | No | FK | References `dim_date.date_key` for the NYC-local pickup date. |
| `dropoff_date_key` | INT | No | FK | References `dim_date.date_key` for the NYC-local drop-off date. |
| `pickup_hour_key` | INT | No | FK | References `dim_hour.hour_key` for the NYC-local pickup hour. |
| `dropoff_hour_key` | INT | No | FK | References `dim_hour.hour_key` for the NYC-local drop-off hour. |
| `pickup_zone_key` | BIGINT | Yes | FK | References `dim_taxi_zone.zone_key`; null for missing or unmatched pickup IDs. |
| `dropoff_zone_key` | BIGINT | Yes | FK | References `dim_taxi_zone.zone_key`; null for missing or unmatched drop-off IDs. |
| `pickup_weather_classification_key` | STRING | Yes | FK | References `dim_weather_classification.weather_classification_key` copied from the unique pickup-hour weather match. Null for no match or invalid pickup time. |
| `trip_duration_seconds` | BIGINT | No | Measure | Drop-off minus pickup in seconds. Negative or zero values remain traceable; duration averages require drop-off strictly after pickup. |
| `trip_count` | INT | No | Measure | Constant 1 for every accepted trip row. |
| `pickup_in_reporting_window_flag` | BOOLEAN | No | DQ | True when local pickup is at or after `2026-03-01 00:00` and before `2026-06-01 00:00`. |
| `out_of_source_file_month_flag` | BOOLEAN | No | DQ | True when pickup year-month differs from the logical month of the source file. |
| `dropoff_before_pickup_flag` | BOOLEAN | No | DQ | True when drop-off precedes pickup. |
| `negative_trip_distance_flag` | BOOLEAN | No | DQ | True when `trip_distance_miles < 0`. |
| `negative_fare_amount_flag` | BOOLEAN | No | DQ | True when `fare_amount_usd < 0`. |
| `negative_total_amount_flag` | BOOLEAN | No | DQ | True when `total_amount_usd < 0`. |
| `zero_distance_high_fare_flag` | BOOLEAN | No | DQ | True when distance is 0 and metered fare exceeds 20 USD. |
| `passenger_count_zero_flag` | BOOLEAN | No | DQ | True only when passenger count equals 0; null remains separately visible. |
| `passenger_count_over_8_flag` | BOOLEAN | No | DQ | True only when passenger count exceeds 8. |
| `pickup_zone_match_status` | STRING | No | DQ | One of `matched_regular`, `matched_special`, `missing_source_id`, or `unmatched_location_id`. |
| `dropoff_zone_match_status` | STRING | No | DQ | Uses the same accepted values as pickup zone status. |
| `weather_match_status` | STRING | No | DQ | One of `matched_unique`, `no_match`, `invalid_pickup_timestamp`, or `ambiguous_match`. Ambiguous matches block publication. |
| `source_system` | STRING | No | Lineage | Constant source identifier `green_taxi`, matching `ingestion_batches.source_system`. |
| `source_file` | STRING | No | Lineage | Original source filename. |
| `source_file_version` | STRING | No | Lineage | Immutable file-content version derived from the approved checksum strategy. |
| `batch_id` | STRING | No | Lineage | External source batch/version identifier; not part of trip identity. |
| `run_id` | STRING | No | Lineage | Pipeline execution-attempt identifier; distinct from `batch_id`. |
| `ingested_at` | TIMESTAMP | No | Lineage | UTC operational ingestion timestamp. |
| `source_row_locator` | STRING | Yes | Lineage | Stable audit locator where practical; not proof of real-world trip identity. |
| `gold_processed_at` | TIMESTAMP | No | Lineage | UTC timestamp of the Gold build that last wrote the row. It may change on replay; business content does not. |

## `fact_weather_hourly`

**Grain:** One row per configured coordinate, UTC observation hour, and selected weather model.

| Field | Type | Nullable | Key | Definition and rule |
|---|---|---:|---|---|
| `weather_observation_key` | STRING | No | PK | Deterministic hash of `coordinate_id`, `observation_timestamp_utc`, and `weather_model`. |
| `coordinate_id` | STRING | No | UK part | Stable configured identifier for the approved representative NYC request coordinate. |
| `observation_timestamp_utc` | TIMESTAMP | No | UK part | Authoritative hourly observation timestamp parsed from `hourly.time[]` as UTC. |
| `weather_model` | STRING | No | UK part | Explicit pinned Open-Meteo model. Existing unpinned evidence is labelled `api_default_unpinned`, not assigned an invented model name. |
| `observation_timestamp_local` | TIMESTAMP | No |  | DST-aware conversion of the UTC observation timestamp to `America/New_York`. |
| `observation_date_key` | INT | No | FK | References `dim_date.date_key` for the local observation date. |
| `observation_hour_key` | INT | No | FK | References `dim_hour.hour_key` for the local observation hour. |
| `weather_classification_key` | STRING | No | FK | References `dim_weather_classification.weather_classification_key`. |
| `weather_code` | INT | No |  | Original WMO weather code retained for audit. |
| `temperature_2m_c` | DECIMAL(8,3) | No | Measure | Two-metre air temperature in degrees Celsius. |
| `precipitation_mm` | DECIMAL(10,3) | No | Measure | Hourly precipitation in millimetres. Negative values fail data quality. |
| `requested_latitude` | DECIMAL(9,6) | No | Config | Latitude sent in the request, injected from configuration. |
| `requested_longitude` | DECIMAL(9,6) | No | Config | Longitude sent in the request, injected from configuration. |
| `requested_timezone` | STRING | No | Config | Request timezone; `UTC` for Bronze acquisition. |
| `returned_latitude` | DECIMAL(9,6) | No |  | Grid-snapped latitude returned by Open-Meteo. |
| `returned_longitude` | DECIMAL(9,6) | No |  | Grid-snapped longitude returned by Open-Meteo. |
| `elevation_m` | DECIMAL(10,3) | No |  | Returned elevation in metres, repeated per hourly row for reproducibility. |
| `source_system` | STRING | No | Lineage | Constant source identifier `open_meteo`, matching `ingestion_batches.source_system`. |
| `source_url` | STRING | No | Lineage | Request endpoint URL; canonical parameters are retained separately in control metadata. |
| `source_response_version` | STRING | No | Lineage | Hash of normalized response content excluding volatile `generationtime_ms`. |
| `batch_id` | STRING | No | Lineage | External request or response batch identifier. |
| `run_id` | STRING | No | Lineage | Pipeline execution-attempt identifier. |
| `ingested_at` | TIMESTAMP | No | Lineage | UTC operational ingestion timestamp. |
| `gold_processed_at` | TIMESTAMP | No | Lineage | UTC timestamp of the Gold build that last wrote the row. It may change on replay; business content does not. |

The natural uniqueness constraint is (`coordinate_id`, `observation_timestamp_utc`, `weather_model`).

`requested_timezone` remains a contract gap: the approved value is UTC, but
neither Bronze nor Silver currently persists the request parameter. Gold does
not fabricate the field; capture it upstream before making it a published
column.

## `dim_taxi_zone`

**Grain:** One row per source Taxi Zone `LocationID` in the selected validated snapshot.

| Field | Type | Nullable | Key | Definition and rule |
|---|---|---:|---|---|
| `zone_key` | BIGINT | No | PK | Deterministic or reproducibly assigned surrogate key used by trip facts. |
| `location_id` | INT | No | UK | Unique source `LocationID`. IDs 264 and 265 remain valid members. |
| `borough` | STRING | No |  | Source Borough, whitespace-trimmed and otherwise left as the source renders it (`Manhattan`, not `manhattan`). Values such as `EWR`, `N/A`, and `Unknown` are not converted to SQL null. |
| `zone_name` | STRING | No |  | Source `Zone`, renamed for clarity, whitespace-trimmed and left in the source's casing. |
| `service_zone` | STRING | No |  | Source `service_zone`, lower-cased as a coded category (`boro zone`, `yellow zone`, `airports`, `ewr`); source `N/A` becomes the literal `na` and is not converted to SQL null. |
| `zone_classification` | STRING | No |  | The canonical coded form, always lower case: one of `unknown`, `outside_nyc`, `ewr`, `nyc_borough`, or `other_special`. |
| `source_system` | STRING | No | Lineage | Constant source identifier `taxi_zones`, matching `ingestion_batches.source_system`. |
| `source_file` | STRING | No | Lineage | Original Taxi Zone snapshot filename. |
| `source_file_version` | STRING | No | Lineage | Immutable snapshot-content version. |
| `batch_id` | STRING | No | Lineage | Snapshot ingestion batch identifier. |
| `ingested_at` | TIMESTAMP | No | Lineage | UTC operational ingestion timestamp. |

## `dim_weather_classification`

**Grain:** One row per WMO weather code and precipitation-band combination.

| Field | Type | Nullable | Key | Definition and rule |
|---|---|---:|---|---|
| `weather_classification_key` | STRING | No | PK | Deterministic key generated from `weather_code` and `precipitation_band`. |
| `weather_code` | INT | No | UK part | Original WMO weather code. An unrecognized non-null code remains present. |
| `weather_condition` | STRING | No |  | Approved condition label derived from the complete WMO mapping. |
| `precipitation_band` | STRING | No | UK part | One of `dry`, `light`, `moderate`, or `heavy`. |

The natural uniqueness constraint is (`weather_code`, `precipitation_band`).

### WMO condition mapping

| Codes | `weather_condition` |
|---|---|
| 0 | `clear_sky` |
| 1 | `mainly_clear` |
| 2 | `partly_cloudy` |
| 3 | `overcast` |
| 45, 48 | `fog` |
| 51, 53, 55 | `drizzle` |
| 56, 57 | `freezing_drizzle` |
| 61, 63, 65 | `rain` |
| 66, 67 | `freezing_rain` |
| 71, 73, 75 | `snow` |
| 77 | `snow_grains` |
| 80, 81, 82 | `rain_showers` |
| 85, 86 | `snow_showers` |
| 95 | `thunderstorm` |
| 96, 99 | `thunderstorm_with_hail` |
| Any other non-null code | `unknown_code` and a data-quality review item |

### Precipitation-band mapping

| Rule | `precipitation_band` |
|---|---|
| `precipitation_mm = 0` | `dry` |
| `0 < precipitation_mm <= 2.5` | `light` |
| `2.5 < precipitation_mm <= 7.5` | `moderate` |
| `precipitation_mm > 7.5` | `heavy` |

## `dim_date`

**Grain:** One row per NYC-local calendar date.

| Field | Type | Nullable | Key | Definition and rule |
|---|---|---:|---|---|
| `date_key` | INT | No | PK | Deterministic `YYYYMMDD` representation of `full_date`. |
| `full_date` | DATE | No | UK | NYC-local calendar date. |
| `calendar_year` | INT | No |  | Four-digit calendar year. |
| `calendar_quarter` | INT | No |  | Calendar quarter from 1 through 4. |
| `month_number` | INT | No |  | Month number from 1 through 12. |
| `month_name` | STRING | No |  | English full month name. |
| `day_of_month` | INT | No |  | Day number from 1 through 31. |
| `day_of_week_number` | INT | No |  | ISO weekday number: Monday 1 through Sunday 7. |
| `day_of_week_name` | STRING | No |  | English full weekday name. |
| `weekend_flag` | BOOLEAN | No |  | True when ISO weekday number is 6 or 7. |

## `dim_hour`

**Grain:** One row per hour of day from 0 through 23.

| Field | Type | Nullable | Key | Definition and rule |
|---|---|---:|---|---|
| `hour_key` | INT | No | PK | Deterministic key equal to `hour_of_day`. |
| `hour_of_day` | INT | No | UK | Integer hour value from 0 through 23. |
| `hour_label` | STRING | No |  | Zero-padded label such as `00:00` or `13:00`. |
| `time_of_day_band` | STRING | No |  | `overnight` for 00–05, `morning` for 06–11, `afternoon` for 12–17, and `evening` for 18–23. |

## Relationship and unknown-value policy

| Relationship or condition | Required handling |
|---|---|
| Missing or unmatched Taxi Zone source ID | Preserve the original ID, set the zone FK to null, and set the appropriate match status. |
| Source zone 264 | Join to the valid `unknown` Taxi Zone member. |
| Source zone 265 | Join to the valid `outside_nyc` Taxi Zone member. |
| Unique pickup-hour weather match | Copy only `weather_classification_key` to the trip fact. |
| No pickup-hour weather match | Leave `pickup_weather_classification_key` null and set `weather_match_status = 'no_match'`. |
| Ambiguous pickup-hour weather match | Block Gold publication; do not select an arbitrary row. |
| Unrecognized non-null WMO code | Use the explicit `unknown_code` classification and create a review item. |
| Nullable source field | Preserve null unless a separately approved rule authorizes imputation. |

## Measure definitions

| Measure | Definition |
|---|---|
| Trip count | `SUM(trip_count)` for accepted trips inside the reporting window. |
| Pickup count | `SUM(trip_count)` grouped through the pickup Taxi Zone role. |
| Drop-off count | `SUM(trip_count)` grouped through the drop-off Taxi Zone role. |
| Average trip duration | `AVG(trip_duration_seconds) / 60.0` for rows where drop-off is strictly after pickup. |
| Average trip distance | `AVG(trip_distance_miles)` for non-null values greater than or equal to zero. |
| Average fare amount | `AVG(fare_amount_usd)` for non-null values greater than or equal to zero. `fare_amount_usd` is metered fare and excludes tolls, surcharges, and tips. |

For Q2, all measures are grouped by the weather classification matched at pickup hour. For Q3, pickup and drop-off zone roles are evaluated separately. The drop-off role may use drop-off date and hour for its time grouping, but its weather classification remains the one attributed at pickup hour.

## Maintenance rule

Any pull request that adds, renames, casts, derives, drops, reinterprets, or reroutes a field must update this dictionary and `docs/source_to_target_mapping.md` in the same change. Changes to a Gold table, grain, key, or relationship must also update `docs/data_model.md`, `docs/decisions.md`, the DBML source, and the exported model diagram.
