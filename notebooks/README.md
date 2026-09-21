# Databricks entry points

Add thin, ordered entry points after source contracts and platform setup are validated. Keep reusable ingestion code in `src/ingestion/` and SQL logic in `etl/`. Record required runtime, dependencies, parameters and execution order in the project README. Avoid hidden session state and clear data-bearing cell outputs before committing.
