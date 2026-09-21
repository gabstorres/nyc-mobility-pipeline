# Databricks notebook source
# MAGIC %md
# MAGIC # Taxi Duplicate-Identification Policy
# MAGIC Defines a candidate hash key for taxi trips (no natural trip ID exists in source),
# MAGIC tests it against the full cumulative Bronze table (March–May), inspects
# MAGIC collisions, and defines how duplicate records are treated (quarantine policy).

# COMMAND ----------

files = dbutils.fs.ls("/Volumes/ftw-week-08/00-source/group_a_source/green_taxi/")
file_paths = [f.path for f in files if f.name.endswith(".parquet")]
dfs = {f: spark.read.parquet(f) for f in file_paths}

from pyspark.sql import functions as F
from pyspark.sql.window import Window

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 1 — Candidate business key
# MAGIC
# MAGIC No natural trip ID exists in the source (confirmed against the TLC LPEP data
# MAGIC dictionary). Composite business key: VendorID, lpep_pickup_datetime,
# MAGIC lpep_dropoff_datetime, PULocationID, DOLocationID, trip_distance, fare_amount.
# MAGIC
# MAGIC Excluded: passenger_count, payment_type, RatecodeID, trip_type,
# MAGIC congestion_surcharge — null on ~13-15% of rows (source_profile.md, A4); nulls
# MAGIC in a hash key produce unstable matching.
# MAGIC
# MAGIC `trip_hash` is a SHA-256 digest of the composite key — a fingerprint used to
# MAGIC detect collisions, not a key in itself.

# COMMAND ----------

BUSINESS_KEY = [
    "VendorID",
    "lpep_pickup_datetime",
    "lpep_dropoff_datetime",
    "PULocationID",
    "DOLocationID",
    "trip_distance",
    "fare_amount",
]

# NOTE: reads the full cumulative Bronze table, not a single month —
# required to catch cross-month duplicates and for idempotency on rerun.
bronze_trips = spark.table("`ftw-week-08`.`dev_crystal`.`green_taxi_tripdata`")

hashed = bronze_trips.withColumn(
    "trip_hash",
    F.sha2(F.concat_ws("||", *[F.col(c).cast("string") for c in BUSINESS_KEY]), 256)
)

print(f"Total Bronze rows: {hashed.count()}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 2 — Collision Detection

# COMMAND ----------

total = hashed.count()
distinct_hashes = hashed.select("trip_hash").distinct().count()

print(f"Total rows:              {total}")
print(f"Distinct trip_hash:      {distinct_hashes}")
print(f"Collisions (extra rows): {total - distinct_hashes}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 3 — Inspect collision groups

# COMMAND ----------

collision_groups = (
    hashed.groupBy("trip_hash")
    .count()
    .filter(F.col("count") > 1)
    .orderBy(F.desc("count"))
)

n_groups = collision_groups.count()
print(f"Number of colliding hash groups: {n_groups}")

sample_hashes = [r["trip_hash"] for r in collision_groups.limit(10).collect()]

(hashed
 .filter(F.col("trip_hash").isin(sample_hashes))
 .orderBy("trip_hash", "lpep_pickup_datetime")
 .display())

# COMMAND ----------

# MAGIC %md
# MAGIC **Inspection conclusion:**
# MAGIC
# MAGIC 7 collision groups found across the full Bronze table (March–May combined) —
# MAGIC up from the 2 found when checking March alone, confirming this pattern isn't
# MAGIC March-specific. All 7 groups (100% inspected) follow the same pattern: identical
# MAGIC trip identity on the 7 key columns, but `mta_tax`, `improvement_surcharge`,
# MAGIC `total_amount` (and in one case `congestion_surcharge`/`cbd_congestion_fee`)
# MAGIC are exact sign-flipped pairs, netting to zero.
# MAGIC
# MAGIC Distribution: 2 groups in March, 2 in April, 3 in May — roughly even across
# MAGIC months, consistent with an ongoing source pattern rather than a one-off
# MAGIC March anomaly.
# MAGIC
# MAGIC Still not confirmed by anyone with TLC billing knowledge, so no automatic
# MAGIC survivorship rule is applied (see Step 4 policy). The consistency across all
# MAGIC 3 months is worth flagging to the team as evidence this may eventually
# MAGIC warrant a confirmed rule, once enough history accumulates.

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 4 — Duplicate policy: quarantine, no survivorship
# MAGIC
# MAGIC Correctness > completeness. Every row involved in a collision (all sides, not
# MAGIC just one) is excluded from the clean Silver table and routed to a separate
# MAGIC quarantine table, tagged PASS/FIX. No winner is picked — the earlier
# MAGIC `total_amount > 0` rule was dropped as an unconfirmed inference from only 2
# MAGIC pairs, too thin a sample to trust as policy.
# MAGIC
# MAGIC A separate table (not just a flag on the same table) is used so Gold never
# MAGIC has to remember to filter duplicates out — the clean table is trustworthy by
# MAGIC construction.

# COMMAND ----------

QUARANTINE_THRESHOLD_PCT = 1.0  # March baseline: 0.009%. Wide margin above
                                  # normal noise, low enough to catch a
                                  # genuinely broken ingestion.

flagged = (
    hashed
    .withColumn("_collision_count", F.count("*").over(Window.partitionBy("trip_hash")))
    .withColumn("_dq_status", F.when(F.col("_collision_count") == 1, "PASS").otherwise("FIX"))
    .withColumn("_quarantine_reason",
        F.when(F.col("_dq_status") == "FIX", F.lit("hash_collision_unresolved")))
)

silver_trips = (
    flagged.filter(F.col("_dq_status") == "PASS")
    .drop("_collision_count", "_dq_status", "_quarantine_reason")
)

silver_trips_quarantine = flagged.filter(F.col("_dq_status") == "FIX")

total_rows = flagged.count()
quarantined_rows = silver_trips_quarantine.count()
quarantine_pct = (quarantined_rows / total_rows * 100) if total_rows > 0 else 0

print(f"Total rows:       {total_rows}")
print(f"Clean rows:       {silver_trips.count()}")
print(f"Quarantined rows: {quarantined_rows}")
print(f"Quarantine rate:  {quarantine_pct:.3f}%")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 5 — Threshold gate + Dry Run
# MAGIC
# MAGIC Quarantine table always writes (needed for investigation regardless of
# MAGIC outcome). The clean Silver table only writes if the quarantine rate is within
# MAGIC threshold — otherwise the run halts before Gold could see a badly broken batch.
# MAGIC
# MAGIC This is a dry run — writes are commented out until the policy is
# MAGIC reviewed. Once confirmed, uncomment both `.write.mode("overwrite")` calls.
# MAGIC `overwrite` (not `append`) is required for idempotency, since Silver always
# MAGIC rebuilds from the full cumulative Bronze table on every run.

# COMMAND ----------

# DRY RUN — writes are commented out until the policy is confirmed.

print("=== DRY RUN: no tables written ===\n")

# silver_trip_quarantine.write.mode("overwrite").saveAsTable(

print(f"Would write quarantine table: {silver_trips_quarantine.count()} rows")

if quarantine_pct > QUARANTINE_THRESHOLD_PCT:
    print(
        f"⚠️ Threshold check WOULD HALT: quarantine rate {quarantine_pct:.3f}% "
        f"exceeds {QUARANTINE_THRESHOLD_PCT}% — clean Silver table would NOT load."
    )
else:
    print(f"✅ Threshold check PASSES: quarantine rate {quarantine_pct:.3f}% is within {QUARANTINE_THRESHOLD_PCT}%")
    # silver_trips.write.mode("overwrite").saveAsTable(

    print(f"Would write clean table: {silver_trips.count()} rows")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Summary — for docs/decisions.md
# MAGIC
# MAGIC - Composite business key: VendorID, lpep_pickup_datetime, lpep_dropoff_datetime,
# MAGIC   PULocationID, DOLocationID, trip_distance, fare_amount
# MAGIC - trip_hash: SHA-256 digest of the composite key, used to detect collisions
# MAGIC - Scope: full cumulative Bronze table (March–May 2026), 133,367 total rows
# MAGIC - Collisions: 7 rows (133,367 → 133,360 distinct hashes)
# MAGIC - Collision groups: 7 (100% manually inspected — 2 in March, 2 in April,
# MAGIC   3 in May)
# MAGIC - Inspection conclusion: all 7 groups are reversal/correction pairs — same
# MAGIC   trip identity, sign-flipped charge fields netting to zero. Consistent
# MAGIC   pattern across all 3 months, but not confirmed as an official rule.
# MAGIC - Duplicate policy: quarantine all rows in a collision, no survivor picked
# MAGIC - Quarantine table: green_taxi_trip_quarantine_silver — 14 rows, always written
# MAGIC - Clean table: green_taxi_tripdata_silver — 133,353 rows
# MAGIC - Quarantine rate: 0.010% — within the 1% threshold, load proceeds
# MAGIC - Threshold: 1% quarantine rate halts the clean Silver table load
# MAGIC   (observed baseline: 0.010% across March–May)
# MAGIC - Idempotent: full Bronze re-read + overwrite mode on every run — same
# MAGIC   input always produces the same clean and quarantine table contents
# MAGIC - Rejected alternative: automatic survivorship (total_amount > 0) — dropped;
# MAGIC   even with the pattern now confirmed across 3 months, still not something
# MAGIC   anyone with TLC billing knowledge has validated as correct handling