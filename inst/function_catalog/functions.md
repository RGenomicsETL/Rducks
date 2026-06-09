# Rducks Function Catalog

Generated from `inst/function_catalog/functions.json` by
`tools/generate_function_catalog.R`.

## `rducks_enable`

- Kind: `R function`
- Category: `connection`
- Signature: `rducks_enable(con, extension_path = rducks_extension_path(), threads = c('unchanged', 'single'))`
- Returns: `duckdb_connection (invisibly)`

Load the bundled Rducks DuckDB extension and record the calling R thread for direct native UDF evaluation.

Notes:

- The no-Arrow build does not require nanoarrow or vendored flatcc sources.

## `rducks_execution_plan`

- Kind: `R function`
- Category: `execution`
- Signature: `rducks_execution_plan(transport = 'inproc', ...)`
- Returns: `rducks_execution_plan`

Create the direct in-process execution plan. IPC wire execution is not advertised until the native Quack adapter is implemented.

Notes:

- The public plan surface intentionally has no Arrow marshalling axis.

## `rducks_register_scalar_udf`

- Kind: `R function`
- Category: `registration`
- Signature: `rducks_register_scalar_udf(con, name, fun, args, returns, mode = c('scalar', 'vectorized'), ...)`
- Returns: `rducks_scalar_udf_registration`

Register an R function as a DuckDB scalar UDF using direct native DuckDB-vector marshalling.

Notes:

- Unsupported type/mode combinations fail explicitly instead of falling back to a removed bridge.

## `rducks_quack_codec`

- Kind: `internal C/R helpers`
- Category: `wire format`
- Signature: `RDUCKS_quack_encode_chunk(rows, types, columns); RDUCKS_quack_decode_chunk(payload)`
- Returns: `raw payload or decoded chunk`

Thread-safe Quack/BinarySerializer DataChunk subset used as the future no-Arrow IPC wire-format foundation.

Notes:

- The current branch tests codec round-trips but does not advertise worker execution over it yet.

