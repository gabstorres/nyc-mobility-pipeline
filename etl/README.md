# SQL implementation

SQL is organized in pipeline order:

1. `01_control/`
2. `02_bronze/`
3. `03_silver/`
4. `04_integration/`
5. `05_gold/`
6. `06_analytics/`

There is no `00_source_profile/` folder. Source profiling lives in `notebooks/` and creates no tables (D17).

The folder number describes the planned engineering sequence. It does not mean that each folder has a corresponding Databricks schema. `04_integration` creates no tables of its own: it resolves trips to zones and to the weather hour without changing the grain of a trip, so its output is written by the Gold build into `05-gold`. `01_control` owns persisted operational metadata in the `01-control` schema.

Approved schema names are fixed in [docs/naming_conventions.md](../docs/naming_conventions.md).

Validation belongs beside the layer it validates. Each source has its own exit gate in that layer, because each source defines good data differently (D17). Within a layer, use ordered filenames: `00_` setup, `10_`/`20_`/`30_` tasks, and one `90_validate_<source>` file per source (for example `90_validate_green_taxi.sql`). Integration and later stages combine sources and use one `90_validate_<stage>` file.

The numeric prefixes make navigation and review order clear. They do not replace explicit Databricks job dependencies. Resolve actual names from approved configuration and use fully qualified `catalog.schema.table` references.

Stages 04 to 06 are placeholder files: each one carries its purpose, upstream
dependency, target table, grain and the checks to implement, and ends with a
`raise_error` so an unfinished stage fails its job task instead of looking
successful. Delete that block when the query is written.
