# 03 — Silver

Contains deterministic cleaning, standardization, quality flags, duplicate handling, and Silver validation for each source.

Silver logic must follow the approved grain, source profiles, and source-to-target mapping.

| File | Source | Purpose |
|---|---|---|
| `10_clean_green_taxi.sql` | Green Taxi | Builds `green_taxi_clean` and `green_taxi_quarantine` |
| `20_clean_weather_hourly.sql` | Open-Meteo | Builds the hourly weather table |
| `90_validate_green_taxi.sql` | Green Taxi | Silver gate: row reconciliation, quarantine reasons, quality flags |
| `90_validate_weather_hourly.sql` | Open-Meteo | Silver gate: continuity, DST hours, ranges, classification coverage (placeholder) |

A source's Silver step runs only after that source's Bronze gate passes.
