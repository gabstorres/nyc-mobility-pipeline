"""
DuckDB-based validation for etl/06_analytics/40_fare_efficiency_by_borough.sql

Unlike test_fare_per_mile.py (which reimplements the query's LOGIC in pandas),
this runs the ACTUAL SQL text from the .sql file -- adapted only where DuckDB's
dialect diverges from Databricks SQL -- against a local, in-process DuckDB
database. This is the "different location" DuckDB question from the Part 2
exercise: instead of needing a live Databricks SQL warehouse to test Gold/
Analytics logic, this runs (nearly) the real query on a laptop in milliseconds.

Known dialect differences from the production Databricks SQL, documented here
rather than silently patched over:
  1. Databricks addresses tables as `catalog`.`schema`.`table` with backticks;
     DuckDB doesn't support catalog-qualified backtick identifiers the same
     way, so this test uses plain table names in DuckDB's default in-memory
     catalog instead.
  2. `CREATE SCHEMA IF NOT EXISTS` is dropped -- not meaningful for an
     in-memory DuckDB database with no schema separation here.
  3. Everything else -- the CTE, CASE WHEN, SUM, NULLIF, COUNT_IF,
     DENSE_RANK() OVER (...) -- is UNMODIFIED: DuckDB supports all of it
     natively. That's itself a useful research finding for the writeup.
     (By contrast, dim_date.sql's `EXPLODE(SEQUENCE(...))` calendar build
     would NOT run as-is on DuckDB -- that's the evaluation evidence that
     DuckDB isn't a 100%-compatible drop-in, only a compatible-enough one
     for scripts like this.)

Run: python test_fare_per_mile_duckdb.py
"""

import duckdb

FACT_TAXI_TRIP_FIXTURE = """
CREATE TABLE fact_taxi_trip (
    pickup_zone_key VARCHAR,
    trip_count INTEGER,
    trip_distance_miles DOUBLE,
    fare_amount_usd DOUBLE,
    negative_trip_distance_flag BOOLEAN,
    negative_fare_amount_flag BOOLEAN
);

INSERT INTO fact_taxi_trip VALUES
    ('Z_MANHATTAN_1', 1, 5.0, 25.0, false, false),
    ('Z_MANHATTAN_1', 1, 2.0, 40.0, false, false),
    ('Z_BROOKLYN_1',  1, 10.0, 20.0, false, false),
    ('Z_BROOKLYN_1',  1, 3.0, -5.0, false, true),
    ('Z_QUEENS_1',    1, 8.0, 30.0, false, false),
    ('Z_QUEENS_1',    1, -1.0, 15.0, true, false),
    ('Z_QUEENS_1',    1, 0.0, 12.0, false, false),
    ('Z_UNKNOWN_99',  1, 4.0, 20.0, false, false);
"""

DIM_TAXI_ZONE_FIXTURE = """
CREATE TABLE dim_taxi_zone (
    zone_key VARCHAR,
    borough VARCHAR
);

INSERT INTO dim_taxi_zone VALUES
    ('Z_MANHATTAN_1', 'Manhattan'),
    ('Z_BROOKLYN_1', 'Brooklyn'),
    ('Z_QUEENS_1', 'Queens');
"""

# The real query from etl/06_analytics/40_fare_efficiency_by_borough.sql,
# with ONLY the two dialect changes noted in the module docstring applied.
FARE_EFFICIENCY_QUERY = """
CREATE OR REPLACE TABLE fare_efficiency_by_borough AS

WITH trips AS (
    SELECT
        f.pickup_zone_key,
        f.trip_count,
        f.trip_distance_miles,
        f.fare_amount_usd,
        (NOT f.negative_trip_distance_flag AND f.trip_distance_miles > 0)
            AS distance_eligible,
        NOT f.negative_fare_amount_flag AS fare_eligible
    FROM fact_taxi_trip AS f
)

SELECT
    z.borough AS pickup_borough,

    SUM(t.trip_count) AS trip_count,

    SUM(CASE WHEN t.fare_eligible THEN t.fare_amount_usd END)
        AS total_fare_amount_usd,
    SUM(CASE WHEN t.distance_eligible THEN t.trip_distance_miles END)
        AS total_trip_distance_miles,

    ROUND(
        SUM(CASE WHEN t.fare_eligible THEN t.fare_amount_usd END)
        / NULLIF(SUM(CASE WHEN t.distance_eligible THEN t.trip_distance_miles END), 0)
    , 2) AS fare_per_mile_usd,

    ROUND(SUM(CASE WHEN t.fare_eligible THEN t.fare_amount_usd END)
          / NULLIF(COUNT_IF(t.fare_eligible), 0), 2) AS avg_fare_amount_usd,

    ROUND(SUM(CASE WHEN t.distance_eligible THEN t.trip_distance_miles END)
          / NULLIF(COUNT_IF(t.distance_eligible), 0), 3) AS avg_trip_distance_miles,

    DENSE_RANK() OVER (
        ORDER BY
            SUM(CASE WHEN t.fare_eligible THEN t.fare_amount_usd END)
            / NULLIF(SUM(CASE WHEN t.distance_eligible THEN t.trip_distance_miles END), 0)
            DESC
    ) AS fare_per_mile_rank

FROM trips AS t
LEFT JOIN dim_taxi_zone AS z
    ON t.pickup_zone_key = z.zone_key

GROUP BY z.borough;
"""

DQ_GATE_QUERY = """
SELECT
    (SELECT SUM(trip_count) FROM fare_efficiency_by_borough) AS analytics_trip_count,
    (SELECT SUM(trip_count) FROM fact_taxi_trip) AS gold_trip_count,
    (SELECT COUNT(*) FROM fare_efficiency_by_borough) AS result_rows,
    (SELECT COUNT_IF(pickup_borough IS NULL) FROM fare_efficiency_by_borough)
        AS rows_with_unresolved_borough;
"""


def main() -> None:
    con = duckdb.connect(database=":memory:")

    con.execute(FACT_TAXI_TRIP_FIXTURE)
    con.execute(DIM_TAXI_ZONE_FIXTURE)
    con.execute(FARE_EFFICIENCY_QUERY)

    print("--- Query result (real SQL, run on DuckDB) ---")
    result = con.execute(
        "SELECT * FROM fare_efficiency_by_borough ORDER BY fare_per_mile_rank"
    ).fetchdf()
    print(result.to_string(index=False))

    dq = con.execute(DQ_GATE_QUERY).fetchdf().iloc[0]
    print("\n--- DQ gate ---")
    print(dq.to_string())

    assert dq["analytics_trip_count"] == dq["gold_trip_count"], (
        "BUG: trip_count didn't reconcile against the fixture."
    )
    assert dq["rows_with_unresolved_borough"] == 1, (
        f"Expected exactly 1 unresolved-borough row, got {dq['rows_with_unresolved_borough']}"
    )

    top_row = result[result["fare_per_mile_rank"] == 1].iloc[0]
    assert top_row["pickup_borough"] == "Manhattan", (
        "BUG: rank 1 should be the highest fare_per_mile_usd (Manhattan in this fixture)."
    )

    print(
        "\nAll checks passed against the ACTUAL SQL (not a reimplementation), "
        "running on DuckDB."
    )


if __name__ == "__main__":
    main()
