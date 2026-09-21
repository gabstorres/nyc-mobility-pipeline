# 02 — Bronze

Contains Bronze table definitions, source-preserving landing code, and Bronze validation for each source.

Bronze must preserve received records and provenance without silently cleaning, deduplicating, or dropping them.

| File | Source | Purpose |
|---|---|---|
| `10_load_green_taxi.sql` | Green Taxi | Creates `green_taxi_raw` if missing, then loads every unprocessed Parquet file in the landing folder |
| `20_load_open_meteo.sql` | Open-Meteo | Creates `open_meteo_weather_raw` if missing, then merges the landed weather response |
| `30_load_taxi_zones.sql` | Taxi Zones | Creates `taxi_zones_raw` if missing, then full-refreshes from the zone lookup CSV |
| `90_validate_green_taxi.sql` | Green Taxi | Bronze gate: schema, reconciliation against the source files, provenance, known source traits |
| `90_validate_open_meteo_weather.sql` | Open-Meteo | Bronze gate: response structure, hourly array alignment, observation-level checks |
| `90_validate_taxi_zones.sql` | Taxi Zones | Bronze gate: key uniqueness, sentinel members, reconciliation against the CSV |

Each load file creates its own table if it is missing, so it can run on its own. Run a source's load, then that source's `90_validate_<source>`. Each source has its own gate (see `docs/validation.md`).
