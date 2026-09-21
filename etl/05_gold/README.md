# 05 — Gold

Approved facts and dimensions, per `docs/data_model.md`. Dimensions are built before facts, and a fact resolves its foreign keys only against built dimensions, never against Silver.

| File | Target table | Status |
|---|---|---|
| `10_dim_date.sql` | `dim_date` | Implemented, pending proof run |
| `11_dim_hour.sql` | `dim_hour` | Implemented, pending proof run |
| `12_dim_taxi_zone.sql` | `dim_taxi_zone` | Implemented, pending proof run |
| `13_dim_weather_classification.sql` | `dim_weather_classification` | Implemented, pending proof run |
| `20_fact_weather_hourly.sql` | `fact_weather_hourly` | Implemented, pending proof run |
| `30_fact_taxi_trip.sql` | `fact_taxi_trip` | Implemented, pending proof run |
| `90_validate_gold.sql` | Gold gate: PKs, FKs, grain, measures | Implemented, pending proof run |

Trip and weather measurements stay at their own grain. A trip carries only the weather classification key; temperature and precipitation stay in `fact_weather_hourly` (D12).

Run `20_fact_weather_hourly.sql` before `30_fact_taxi_trip.sql`. The trip build
reads Silver `green_taxi_clean` joined to the validated `04-integration` key
maps on `trip_hash`, then uses the weather fact as a build-time lookup for the
pickup-hour classification key; it does not store a fact-to-fact foreign key.

`90_validate_gold.sql` persists one result row per check to
`01-control`.data_quality_results and raises an error when any blocking check
fails. The Gold files are not marked validated until the Databricks proof run is
captured.
