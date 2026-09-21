import hashlib
from datetime import datetime, timezone

DEFAULT_TABLE = "`ftw-week-08`.`01-control`.ingestion_batches"


def clean_path(path):
    """Normalize a dbutils.fs path (dbfs:/Volumes/...) to a plain openable
    path (/Volumes/...). Unity Catalog Volumes don't use the legacy /dbfs
    mount convention."""
    return path.replace("dbfs:", "")


def hash_file(path):
    """Hash a file's raw bytes in chunks, to avoid loading the whole file into memory."""
    sha256 = hashlib.sha256()
    with open(clean_path(path), "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            sha256.update(chunk)
    return sha256.hexdigest()


def get_schema_fingerprint(spark, file_path):
    """Hash the column name+type signature of a Parquet file, to detect schema drift."""
    df = spark.read.parquet(clean_path(file_path))
    schema_str = "|".join(
        f"{field.name}:{field.dataType.simpleString()}" for field in df.schema.fields
    )
    return hashlib.sha256(schema_str.encode("utf-8")).hexdigest()


def register_batch_discovered(
    spark, dbutils, file_path, source_system, source_period, table=DEFAULT_TABLE
):
    """Register a new batch as DISCOVERED. Returns the generated batch_id."""
    import uuid
    from pyspark.sql import Row
    from pyspark.sql.types import (
        StructType, StructField, StringType, TimestampType, LongType,
    )

    normalized_path = clean_path(file_path)
    file_info = dbutils.fs.ls(file_path)[0]

    batch_id = str(uuid.uuid4())
    content_hash = hash_file(file_path)
    schema_fingerprint = get_schema_fingerprint(spark, file_path)
    source_version_id = f"{source_system}_{source_period}_v1"

    schema = StructType([
        StructField("batch_id", StringType(), True),
        StructField("source_system", StringType(), True),
        StructField("source_object", StringType(), True),
        StructField("source_period", StringType(), True),
        StructField("request_parameters", StringType(), True),
        StructField("content_sha256", StringType(), True),
        StructField("source_version_id", StringType(), True),
        StructField("schema_fingerprint", StringType(), True),
        StructField("raw_uri", StringType(), True),
        StructField("status", StringType(), True),
        StructField("discovered_at", TimestampType(), True),
        StructField("started_at", TimestampType(), True),
        StructField("completed_at", TimestampType(), True),
        StructField("row_count", LongType(), True),
        StructField("file_size", LongType(), True),
        StructField("file_modified_time", TimestampType(), True),
    ])

    row = spark.createDataFrame([Row(
        batch_id=batch_id,
        source_system=source_system,
        source_object=normalized_path.split("/")[-1],
        source_period=source_period,
        request_parameters=None,
        content_sha256=content_hash,
        source_version_id=source_version_id,
        schema_fingerprint=schema_fingerprint,
        raw_uri=normalized_path,
        status="DISCOVERED",
        discovered_at=datetime.now(timezone.utc),
        started_at=None,
        completed_at=None,
        row_count=None,
        file_size=file_info.size,
        file_modified_time=datetime.fromtimestamp(
            file_info.modificationTime / 1000, tz=timezone.utc
        ),
    )], schema=schema)

    row.write.mode("append").saveAsTable(table)
    return batch_id


def mark_batch_started(spark, batch_id, table=DEFAULT_TABLE):
    """Mark a batch STARTED, immediately before the actual load begins."""
    started_at = datetime.now(timezone.utc)
    spark.sql(f"""
        UPDATE {table}
        SET status = 'STARTED',
            started_at = '{started_at.isoformat()}'
        WHERE batch_id = '{batch_id}'
    """)


def mark_batch_success(spark, batch_id, row_count, table=DEFAULT_TABLE):
    """Mark a batch SUCCESS. Call only after the load has been validated."""
    completed_at = datetime.now(timezone.utc)
    spark.sql(f"""
        UPDATE {table}
        SET status = 'SUCCESS',
            row_count = {row_count},
            completed_at = '{completed_at.isoformat()}'
        WHERE batch_id = '{batch_id}'
    """)


def mark_batch_failed(spark, batch_id, table=DEFAULT_TABLE):
    """Mark a batch FAILED. The batch stays re-processable — a retry uses a new batch_id."""
    completed_at = datetime.now(timezone.utc)
    spark.sql(f"""
        UPDATE {table}
        SET status = 'FAILED',
            completed_at = '{completed_at.isoformat()}'
        WHERE batch_id = '{batch_id}'
    """)
