# 01 — Control

Contains SQL for ingestion batches, pipeline runs, processing checkpoints, schema observations, and data-quality results.

Persisted operational tables created here use the approved control schema.

Processing state must advance only after the corresponding load and required validation succeed.

| File | Purpose |
|---|---|
| `00_create_control_tables.sql` | Creates `01-control` tables (currently `ingestion_batches`) |
| `90_validate_control.sql` | Checks the control tables: stuck batches and retry history |
