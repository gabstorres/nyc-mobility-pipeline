def get_schema(spark, file_path):
    """Read a Parquet file's schema as {column_name: type_string}."""
    df = spark.read.parquet(file_path)
    return {field.name: field.dataType.simpleString() for field in df.schema.fields}


def check_schema_drift(spark, file_paths: dict):
    """
    Compare schemas across multiple files.

    file_paths: dict like {"March": "/path/to/march.parquet", "April": ...}

    Returns a dict of {column_name: {label: type_or_MISSING}} for every
    column that differs across the given files. Empty dict means no drift.
    Never silently passes — always prints a report, even when clean.
    """
    schemas = {label: get_schema(spark, path) for label, path in file_paths.items()}
    all_columns = sorted(set().union(*[set(s.keys()) for s in schemas.values()]))
    labels = list(schemas.keys())

    drift = {}
    for col in all_columns:
        types_seen = {label: schemas[label].get(col, "MISSING") for label in labels}
        if len(set(types_seen.values())) > 1:
            drift[col] = types_seen

    print("SCHEMA DRIFT REPORT")
    print("=" * 50)
    if drift:
        for col, types_seen in drift.items():
            print(f"DIFFERENCE — {col}: {types_seen}")
    else:
        print(f"No drift found across: {', '.join(labels)}")

    return drift


def check_drift_for_landing(spark, dbutils, landing_path="/Volumes/ftw-week-08/00-source/group_a_source/green_taxi/"):
    """
    Discover every file currently in the landing location and check for
    schema drift across all of them. No hardcoded filenames.
    """
    files = dbutils.fs.ls(landing_path)
    file_paths = [f.path for f in files if f.name.endswith(".parquet")]
    file_dict = {path.split("/")[-1]: path for path in file_paths}
    return check_schema_drift(spark, file_dict)
