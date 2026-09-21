# 04 — Integration

Where the sources meet: taxi trips resolved to pickup and drop-off zones and to the pickup weather hour. Unmatched records are counted before a join type is chosen, and expected unmatched volumes are documented rather than silently dropped.

Integration produces no tables of its own. Its output is written by the Gold build into `05-gold`, which is why stage 04 has a folder but no schema.

| File | Purpose | Status |
|---|---|---|
| `10_resolve_trip_zones.sql` | Trips to pickup and drop-off zones, with match statuses | Placeholder |
| `20_resolve_trip_weather.sql` | Trips to the pickup weather hour; copies the classification key only | Placeholder |
| `90_validate_integration.sql` | Integration gate: no fan-out, unmatched counts, one measure reconciled | Placeholder |

Runs only after the Silver gates for Green Taxi, weather **and** Taxi Zones have passed.
