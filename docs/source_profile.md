# Source Profile

This document records each source's schema, volume, date coverage, nulls, duplicate candidates, keys, partitions, and anomalies.

## Status

Source profiling is currently in progress. Listed source URLs are not proof of successful downloads or valid data. Each source must be profiled and supported by recorded evidence before downstream transformations begin.

## File Inventory

For each taxi month and reference snapshot, record the source URL, filename, retrieval time, file size, SHA-256 checksum, file readability, row count, schema, and observed event range.

Compare the March, April, and May schemas before accepting a source contract. Do not assume that filenames guarantee event-date coverage.

| Source | Rows | Schema | Observed Dates | Key Nulls | Duplicate Candidates | Other Anomalies | Evidence |
|---|---:|---|---|---|---|---|---|
| Taxi March 2026 | 44,208 | 21 cols, identical across files | 2026-03 dominant; 9 stray rows (1× 2009-01, 8× 2026-02) | `ehail_fee` 100%; 6 other cols ~15% (same rows) | 0 exact duplicates | 111 negative fares, 368 zero-distance/high-fare, 1 dropoff-before-pickup | `notebooks/profile_green_taxi.ipynb` |
| Taxi April 2026 | 44,238 | 21 cols, identical across files | 2026-04 dominant; 3 stray rows (1× 2026-03, 2× 2026-05) | `ehail_fee` 100%; 6 other cols ~14% (same rows) | 0 exact duplicates | 153 negative fares, 439 zero-distance/high-fare | `notebooks/profile_green_taxi.ipynb` |
| Taxi May 2026 | 44,921 | 21 cols, identical across files | 2026-05 dominant; 10 stray rows (2× 2008-12, 8× 2026-04) | `ehail_fee` 100%; 6 other cols ~13% (same rows) | 0 exact duplicates | 120 negative fares, 548 zero-distance/high-fare | `notebooks/profile_green_taxi.ipynb` |
| Taxi zones | 265 | `LocationID`, `Borough`, `Zone`, `service_zone` | Snapshot | 0 nulls across all columns | No duplicate `LocationID` values found | Sentinel records found at `LocationID` 264 and 265; special Borough values include `EWR`, `N/A`, and `Unknown` | `notebooks/profile_taxi_zones` |
| Weather (Open-Meteo) | 2,208 | `time`, `temperature_2m`, `precipitation`, `weather_code` | 2026-03-01T00:00 to 2026-05-31T23:00 (UTC), no gaps | 0 nulls across all columns | No duplicate `time` values found | 12 distinct `weather_code` values; 0 rows with negative precipitation or out-of-range temperature; requested coordinates snapped to a grid point ~3-4 km away (40.738136, -74.04254, elevation 32.0m) | `notebooks/profile_weather.ipynb` |

Profile null rates for every column, full-row equality, candidate-key collisions, within-file and across-file duplicate candidates, unexpected codes, negative or zero measures, missing timestamps, durations, out-of-month events, and pickup and drop-off reference coverage.

The public taxi schema does not establish a unique trip ID. Do not treat `VendorID` as a vehicle or trip key.

## Green Taxi Trip Data Source Profile

### Source Details

- **Source files:** `green_tripdata_2026-03.parquet`, `-04.parquet`, `-05.parquet`
- **Source path:** `/Volumes/ftw-week-08/00-source/group_a_source/green_taxi/`
- **File format:** Parquet
- **Dataset type:** Monthly trip-level extract, ingested incrementally (`COPY INTO`)
- **Profiling notebook:** `notebooks/profile_green_taxi.ipynb`

### Dataset Schema

21 columns, identical set and types across all 3 files (no schema drift). Includes `VendorID`, `lpep_pickup_datetime`/`lpep_dropoff_datetime` (`timestamp_ntz`), `RatecodeID`, `PULocationID`/`DOLocationID`, `passenger_count`, `trip_distance`, `fare_amount`, `total_amount`, `payment_type`, `trip_type`, and surcharge/fee fields.

### Row Count

44,208 / 44,238 / 44,921 rows (March/April/May), 133,367 total. Matches the row count landed in `dev_crystal.green_taxi_tripdata` exactly — no rows lost during `COPY INTO`.

### Key Validation

No natural trip ID exists in this schema. `VendorID` is not a valid key (highly repeated). Duplicate check used full-row equality instead: **0 exact duplicate rows** in any file.

### Date Coverage

Each file is dominated by its expected month, but all 3 contain a small number of stray out-of-month timestamps (9–10 rows per file, <0.03%), including a few implausible years (2008–2009). This is a known TLC meter-clock quirk, not an ingestion error — needs a documented filter/flag rule before Silver.

### Null Analysis

`ehail_fee` is **100% null** in all 3 files — appears to be a dead/legacy column. `store_and_fwd_flag`, `RatecodeID`, `passenger_count`, `payment_type`, `trip_type`, `congestion_surcharge` are null together on the same ~13–15% of rows per file (consistent pattern, likely one shared source condition — not yet root-caused).

### Validity / Range Findings

- Negative `fare_amount`/`total_amount`: 111–155 rows per file
- Zero-distance trips with `fare_amount > $20`: 368–548 rows per file (largest-volume anomaly found)
- `passenger_count` out of range (0 or >8): 2–7 rows per file
- Dropoff before pickup: 1 row total (March only)

### Categorical Code Validity

Validated against the official TLC LPEP data dictionary. All three codes are
fully valid: `VendorID` includes `6` (Myle Technologies Inc.), `payment_type`
includes `0` (Flex Fare), and `RatecodeID` includes `99` (Null/unknown) —
none of these were in the team's initial assumed valid sets, which caused a
false "unmapped" flag (`VendorID = 6`, ~9-12% of rows) in the first profiling
pass. 0 invalid rows found across all three codes in all 3 files after
correcting the valid sets.

### Profiling Findings

- Schema is stable across all 3 months, no drift.
- Ingestion is complete and lossless (row-count reconciliation matches exactly).
- No exact duplicates.
- Known, low-volume out-of-month timestamp noise (TLC-wide known issue).
- `ehail_fee` is a dead column.
- Negative fares/totals and zero-distance/high-fare trips are the most material data quality issues, both low-single-digit % of rows but non-trivial in count.
- All categorical codes (`payment_type`, `RatecodeID`, `VendorID`) are fully valid against the official TLC data dictionary; 0 invalid rows.

### Profiling Conclusion

Green taxi data is structurally sound (stable schema, zero data loss, no duplicates) and suitable as a source. Remaining caveats that do not block this profiling task but should be resolved before Silver: the negative fare/total rows, zero-distance/high-fare trips, and stray out-of-month rows should be filtered or flagged, not silently dropped.

### Recommended Downstream Rules

1. Define handling for out-of-month timestamp rows (filter vs. flag) before Silver.
2. Confirm `ehail_fee` is safe to drop or exclude downstream.
3. Define a rule for negative fare/total rows (e.g. refunds/adjustments vs. bad data — needs domain confirmation, not an assumption).
4. Investigate zero-distance/high-fare trips before deciding filter vs. flag.
5. Root-cause the ~13–15% co-occurring nulls across `RatecodeID`/`payment_type`/`trip_type`/etc.

## Taxi Zones Source Profile

### Source Details

- **Source file:** `taxi_zone_lookup.csv`
- **Source path:** `/Volumes/ftw-week-08/00-source/group_a_source/taxi_zones/taxi_zone_lookup.csv`
- **File format:** CSV
- **Dataset type:** Reference snapshot
- **Profiling notebook:** `notebooks/profile_taxi_zones`

### Dataset Schema

| Column | Description |
|---|---|
| `LocationID` | Identifier assigned to a taxi zone |
| `Borough` | Borough or special geographic classification |
| `Zone` | Taxi zone name |
| `service_zone` | Taxi service-zone classification |

### Row Count

The Taxi Zones CSV contains **265 rows**.

### Key Validation

`LocationID` was evaluated as the candidate key for the Taxi Zones reference dataset.

The uniqueness query returned no rows, which means:

- No duplicate `LocationID` values were detected.
- All 265 records have distinct `LocationID` values.
- `LocationID` is suitable as the candidate business key for downstream reference joins, subject to the documented sentinel-value policy.

### Null Analysis

| Column | Null Count |
|---|---:|
| `LocationID` | 0 |
| `Borough` | 0 |
| `Zone` | 0 |
| `service_zone` | 0 |

No SQL `NULL` values were found in the four source columns.

Values such as `N/A` and `Unknown` are not SQL nulls. They are explicit source values and must be handled separately during Silver-layer standardization.

### Distinct Borough Values

The following eight distinct `Borough` values were identified:

- `Bronx`
- `Brooklyn`
- `EWR`
- `Manhattan`
- `N/A`
- `Queens`
- `Staten Island`
- `Unknown`

The values `EWR`, `N/A`, and `Unknown` require explicit handling because they are not standard New York City borough names.

These values should not be silently removed or automatically converted to SQL `NULL` until the team agrees on the zone-standardization policy.

### Sentinel Records

Two sentinel or special reference records were identified:

| LocationID | Borough | Zone | service_zone |
|---:|---|---|---|
| 264 | `Unknown` | `N/A` | `N/A` |
| 265 | `N/A` | `Outside of NYC` | `N/A` |

These records represent special conditions rather than ordinary NYC taxi zones:

- `LocationID` 264 represents an unknown or unavailable zone.
- `LocationID` 265 represents a location outside New York City.

The sentinel records must remain identifiable during downstream transformations so unmatched, unknown, and outside-NYC trips are not silently dropped.

### Profiling Findings

- The source file is readable as CSV.
- The file contains 265 rows.
- `LocationID` contains no null values.
- No duplicate `LocationID` values were detected.
- No SQL null values were detected in `LocationID`, `Borough`, `Zone`, or `service_zone`.
- Eight distinct Borough values were identified.
- `EWR`, `N/A`, and `Unknown` are special Borough values requiring a documented standardization rule.
- `LocationID` 264 and 265 are sentinel records.
- Sentinel records must be preserved or intentionally mapped based on the team's approved Silver-layer policy.
- Downstream joins should measure how many taxi records match regular zones, sentinel zones, and no zone record.

### Profiling Conclusion

The Taxi Zones CSV is suitable for use as a reference source for downstream processing.

`LocationID` is unique and has complete coverage within the reference file. However, the dataset contains special values that require documented treatment during Silver-layer cleaning and standardization.

The profiling task does not clean, replace, or remove these values. It records the source behavior so the team can define the transformation policy before building downstream tables.

### Recommended Downstream Rules

The following items require team agreement before Silver processing:

1. Define whether `EWR` will remain a separate geographic classification.
2. Define how `Borough = 'Unknown'` will be standardized.
3. Define how `Borough = 'N/A'` will be represented.
4. Preserve the distinction between `LocationID` 264 and 265.
5. Measure pickup and drop-off join coverage against the Taxi Zones reference.
6. Do not use an inner join if doing so silently removes unknown or unmatched trip locations.
7. Record row counts for matched zones, sentinel zones, and unmatched zone IDs.

## Open-Meteo Weather Source Profile

### Source Details

- **Endpoint:** `https://archive-api.open-meteo.com/v1/archive`
- **Requested coordinates:** 40.7128, -74.0060 — proposed city-level representative point, not zone-specific
- **Returned (grid-snapped) coordinates:** 40.738136, -74.04254, elevation 32.0m — Open-Meteo snaps the request to its nearest grid cell rather than the exact point requested, roughly 3-4 km from the requested coordinate; this reinforces decision D06's caveat that this is a city-level approximation, not zone-level weather
- **Requested variables:** `temperature_2m`, `precipitation`, `weather_code`
- **Requested timezone:** `UTC` (explicit); response confirms `utc_offset_seconds: 0`, `timezone`/`timezone_abbreviation`: `GMT`/`GMT`
- **Request window profiled:** 2026-03-01 through 2026-05-31 (the full three-month window, not just a sample)
- **Dataset type:** External REST API, hourly time series (not a static file)
- **Model:** not specified in the request; the default model was used and is not yet pinned (see Recommended Downstream Rules)
- **Profiling notebook:** `notebooks/profile_weather.ipynb`
- **Sample response evidence:** saved to `/Volumes/ftw-week-08/00-source/group_a_source/weather/open_meteo_mar_may_2026_sample.json`, SHA-256 `4e6c8d0b238f1329245af1e06081cc0d43c0f46501a38d846605065fb4e87e96`

### Response Schema

Top-level response keys: `latitude`, `longitude`, `generationtime_ms`, `utc_offset_seconds`, `timezone`, `timezone_abbreviation`, `elevation`, `hourly_units`, `hourly`.

| Field | Description | Unit (`hourly_units`) |
|---|---|---|
| `hourly.time` | Hour timestamp | `iso8601` |
| `hourly.temperature_2m` | Air temperature at 2m | `°C` |
| `hourly.precipitation` | Hourly precipitation | `mm` |
| `hourly.weather_code` | WMO weather interpretation code | `wmo code` |

`generationtime_ms` for the full March–May request was ~1.2ms — response generation is fast and not a practical ingestion bottleneck.

### Row Count / Coverage

Expected hourly rows for 2026-03-01 through 2026-05-31: **2,208** (92 days × 24 hours).

Actual hourly rows returned: **2,208**. Gap: **0**. Full hourly coverage confirmed for the entire March–May 2026 window with no missing hours.

### Key Validation

`time` was evaluated as the candidate key for the hourly weather series.

The duplicate-timestamp query (`GROUP BY time HAVING COUNT(*) > 1`) returned **0 rows**:

- No duplicate `time` values were detected across the 2,208-row window.
- `time` is suitable as the key for the `fact_weather_hourly` grain (per `docs/data_model.md`).

### Null Analysis

| Column | Null Count |
|---|---:|
| `time` | 0 |
| `temperature_2m` | 0 |
| `precipitation` | 0 |
| `weather_code` | 0 |

No nulls were found in any of the four fields across the full profiled window.

### Distinct Weather Code Values

**12 distinct `weather_code` values** were returned: `0`, `1`, `2`, `3`, `51`, `53`, `55`, `61`, `63`, `71`, `73`, `75`.

Mapped against Open-Meteo's published WMO code table, these correspond to: 0 = clear sky, 1 = mainly clear, 2 = partly cloudy, 3 = overcast, 51/53/55 = light/moderate/dense drizzle, 61/63 = slight/moderate rain, 71/73/75 = slight/moderate/heavy snowfall.

No fog (45/48), freezing-rain (56/57/66/67), shower (80-86), or thunderstorm (95/96/99) codes appeared in this March-May 2026 window. This is an observation about this specific window, not a guarantee those codes can't appear in other periods — the weather-code mapping table (see Recommended Downstream Rules) should still cover the full WMO code set, not just the 12 observed here.

### Anomalies

The anomaly query (`precipitation < 0 OR temperature_2m < -50 OR temperature_2m > 60`) returned **0 rows**. No negative precipitation values or out-of-range temperatures were found in the profiled window.

### HTTP Status and Empty-Response Behavior

- Successful request status code: **200**
- Out-of-range request (2099-01-01 to 2099-01-02) status code: **400**, with JSON error body `{"error":true,"reason":"Bad Request"}`

The API returns an explicit 4xx error with a JSON error body for an invalid/out-of-range date window — it does not return a 200 with empty `hourly` arrays. Ingestion code must treat a non-200 status as a hard failure, not interpret it as "no data for this period."

### Repeated-Request Determinism

Two identical requests for the same window were compared with `generationtime_ms` excluded (since that field is expected to vary per call): **content was identical** (`same content on repeat: True`, both returned status 200). The API is deterministic for a fixed historical window, aside from that one volatile metadata field.

### Rate-Limit Behavior

No per-request rate-limit headers were present in the response (observed headers: `Date`, `Content-Type`, `Transfer-Encoding`, `Connection`, `Content-Encoding` — no `X-RateLimit-*` or similar). No API key is required for non-commercial use.

Open-Meteo's published free-tier fair-usage limits (from their pricing page, not the archive-API docs page, which doesn't state numeric quotas itself): **600 calls/minute, 5,000/hour, 10,000/day, 300,000/month**, rate-limited on a fair-usage basis with no uptime guarantee for the free tier. The bounded retry (429/5xx + backoff) implemented in the notebook is the intended safeguard for real ingestion runs; this profiling exercise made only a handful of calls and did not test the throttling threshold itself, per the "do not deliberately stress the service" guidance.

### Profiling Findings

- The endpoint is reachable and returns valid JSON with status 200 for a well-formed request.
- The full March–May 2026 window returns exactly the expected 2,208 hourly rows with zero gaps.
- No duplicate `time` values and no nulls were found in any of the four fields.
- 12 distinct `weather_code` values were observed; none indicate malformed data.
- No negative precipitation or implausible temperature values were found.
- Requested coordinates are silently snapped to the nearest model grid cell (~3-4 km away here) rather than matched exactly — record the returned coordinates and elevation as part of any reproducible run, not just the requested ones.
- Invalid/out-of-range windows return HTTP 400 with a JSON error body, not an empty 200.
- Repeated identical requests return identical content (aside from `generationtime_ms`).
- No rate-limit headers are returned per-request; documented limits are published separately as fair-usage quotas.

### Profiling Conclusion

The Open-Meteo historical archive API is confirmed suitable as the weather source for the documented March–May 2026 coverage: it returns complete, duplicate-free, null-free hourly data for the full window, behaves deterministically on repeat calls, and fails loudly (HTTP 400) rather than silently on bad requests.

Remaining caveats that do not block this profiling task but should be resolved before Silver: the single representative coordinate is a city-level approximation (confirmed here to be ~3-4 km from the exact requested point), the model parameter is not yet pinned, and the weather-code-to-condition / precipitation-band mappings referenced in the business questions are not yet defined.

### Recommended Downstream Rules

The following items require team agreement before Silver processing:

1. Pin the `model` parameter explicitly once variable support across candidate models is confirmed, rather than relying on the API default used here.
2. Define and document the weather-code-to-condition and precipitation-band mappings referenced in the business questions, covering the full WMO code table rather than only the 12 codes observed in this window.
3. Confirm whether Open-Meteo revises historical hourly values after initial publication, and if so, define a re-fetch/reconciliation policy.
4. Confirm the single representative NYC coordinate (decision D06) is acceptable for all three business questions before finalizing the weather fact grain, given the confirmed ~3-4 km grid-snap offset from the requested point.
5. Confirm weather is attributed to trips using the pickup hour, per the documented assumption, and that this is implemented correctly at Silver.
6. Record the actual free-tier quota (600/min, 5,000/hour, 10,000/day, 300,000/month) in ingestion runbooks so batch/backfill jobs stay within fair-usage limits.

## Exit Gate

The source-profile exit gate passes only when the owner and reviewer agree on:

- Source schemas
- Date coverage
- Source volume
- Candidate keys and identity limitations
- Null and duplicate findings
- Special and sentinel values
- Documented anomalies
- Response contracts
- Evidence locations

Any unresolved issue affecting correctness blocks dependent transformations.

## NYC DOT Traffic Advisory Feasibility Check

The NYC DOT Traffic Advisory was evaluated as a potential bonus source for traffic closure and event information. This source has not yet been added to the finalized source inventory because the team has not made a final decision on bonus-source inclusion.

### Source Inventory

| Source | URL | Format | Coverage | Structure | Status | Evidence |
|---|---|---|---|---|---|---|
| Weekly Traffic Advisory | https://www.nyc.gov/html/dot/html/motorist/weektraf.shtml | HTML | Saturday–Friday | Semi-structured HTML | Profiled | 2026-09-14 HTML snapshot |
| Weekend Traffic Advisory | https://www.nyc.gov/html/dot/html/motorist/wkndtraf.shtml | HTML | Friday–Sunday | Semi-structured HTML | Profiled | 2026-09-14 HTML snapshot |

### API / Download Alternative Check

NYC DOT provides transportation data through its data feeds and NYC Open Data.

Historical NYC Open Data entries were identified for:

- Weekend Traffic Updates
- Special Traffic Updates

These entries were last updated in October 2024 and point to NYC DOT traffic advisory pages rather than providing a current machine-readable equivalent of the live 2026 advisory.

No suitable current machine-readable API or downloadable structured equivalent was identified during the feasibility check.

**Result:** HTML scraping is considered a reasonable fallback if the source is implemented.

### HTML Structure Assessment

#### Weekly Traffic Advisory

The Weekly Traffic Advisory is organized into geographic sections such as:

- East River Bridge Crossings
- Manhattan
- Bronx
- Brooklyn
- Queens
- Cross-borough advisories

Individual advisories use more than one HTML pattern. Common patterns include:

- `<h3>Location</h3>` followed by `<p>` description
- `<strong>Location</strong>` followed by `<p>` description

Events use additional fields such as:

- Event name
- Location(s)
- Formation
- Route
- Dispersal

Dates and times are generally embedded in natural-language descriptions rather than consistently provided as separate fields.

#### Weekend Traffic Advisory

The Weekend Traffic Advisory is organized into sections such as:

- Bronx
- Brooklyn
- Manhattan
- Manhattan/Brooklyn
- Queens
- Queens/Brooklyn
- Staten Island
- Citywide

Ordinary closure advisories commonly use a `<strong>` location followed by a `<p>` description.

Events contain identifiable fields such as event name, location(s), formation, route, and dispersal.

### Data Identifiability

| Attribute | Identifiable? | Notes |
|---|---|---|
| Advisory period | Yes | Stated in page heading |
| Geographic area | Yes | Organized by borough/area sections |
| Location | Yes | Usually identifiable from headings or bold text |
| Closure description | Yes | Provided in paragraph text |
| Closure date/time | Yes | Usually embedded in natural-language text |
| Closure type/reason | Often | Requires text parsing |
| Event name | Yes | Identifiable for event sections |
| Event location | Yes | Identifiable |
| Formation | Yes, for applicable events | Structured label |
| Route | Yes, for applicable events | Structured label |
| Dispersal | Yes, for applicable events | Structured label |
| Source URL | Yes | Can be stored with each retrieval |
| Retrieval timestamp | Yes | Should be added during ingestion |

### Structure Finding

The DOT advisories are **semi-structured HTML** rather than a clean tabular dataset.

The main concern is that individual advisories do not follow one consistent HTML pattern. A scraper relying on a single CSS selector or tag would risk silently missing records when the page uses another structure.

Dates and times also require additional parsing because they are frequently embedded in natural-language descriptions.

### Duplicate and Overlap Considerations

The Weekly Advisory covers Saturday–Friday, while the Weekend Advisory covers Friday–Sunday. These periods overlap.

Implementing both sources could therefore result in duplicate or overlapping advisories.

If the DOT source is implemented, the **Weekend Traffic Advisory is the preferred starting point** because it has a narrower coverage period and a somewhat more manageable scope.

### Maintenance Risks

Potential scraper breakage includes:

1. HTML tags or CSS structure changing.
2. Advisory content moving to different sections.
3. New HTML patterns being introduced for individual closures.
4. Event fields changing structure.
5. Date/time wording changing.
6. New sections or geographic categories being added.

A scraper should therefore preserve the raw HTML/text and retrieval timestamp so that parsing results can be audited and reprocessed if the page structure changes.

### Feasibility Assessment

| Criterion | Finding |
|---|---|
| Official/public source | Pass |
| Current information | Pass |
| Geographic information identifiable | Pass |
| Individual advisories identifiable | Pass, with multiple patterns |
| Consistent HTML structure | Partial |
| Data richness | High |
| Parsing complexity | Medium–High |
| Maintenance risk | Medium–High |
| Current machine-readable equivalent | Not identified |
| Overall feasibility | Feasible with caveats |

### Recommendation

**BUILD — NYC DOT Weekend Traffic Advisory**, if the team proceeds with the bonus source.

The source provides useful information about temporary road closures, construction, events, and traffic disruptions that could add context to the NYC Mobility Pipeline.

However, the HTML is semi-structured and would require multiple parsing rules. The scraper should not rely on a single HTML selector, and raw source content should be preserved for auditability and future parser changes.

The Weekend Advisory is recommended over the Weekly Advisory because its Friday–Sunday scope is narrower and somewhat easier to manage. The overlap between the two advisory periods should also be considered to avoid duplicate records.

**No scraper is being built as part of this feasibility-check issue.**
