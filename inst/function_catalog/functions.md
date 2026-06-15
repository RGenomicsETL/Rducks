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

- The bundled extension links no Arrow or columnar interchange library.

## `rducks_execution_plan`

- Kind: `R function`
- Category: `execution`
- Signature: `rducks_execution_plan(transport = c('inproc', 'ipc'), ...)`
- Returns: `rducks_execution_plan`

Create an execution plan: the direct in-process plan ('inproc') or the worker-process Quack wire plan ('ipc').

Notes:

- The 'ipc' plan covers fixed-width scalars, VARCHAR/BLOB, DECIMAL, INTERVAL, ENUM, BIT, GEOMETRY, MAP, UNION, and LIST/ARRAY/STRUCT of supported types; VARIANT is rejected at registration.

## `rducks_register_scalar_udf`

- Kind: `R function`
- Category: `registration`
- Signature: `rducks_register_scalar_udf(con, name, fun, args, returns, mode = c('scalar', 'vectorized'), ...)`
- Returns: `rducks_scalar_udf_registration`

Register an R function as a DuckDB scalar UDF using direct native DuckDB-vector marshalling.

Notes:

- Unsupported type/mode/plan combinations fail explicitly instead of falling back to another engine.

## `rducks_quack_codec`

- Kind: `internal C/R helpers`
- Category: `wire format`
- Signature: `RDUCKS_quack_encode_chunk(rows, types, columns); RDUCKS_quack_decode_chunk(payload, expected)`
- Returns: `raw payload or decoded chunk`

Thread-safe Quack/BinarySerializer DataChunk subset used as the worker-process IPC wire format.

Notes:

- Backs the 'ipc' transport; the standalone codec round-trips are exercised in the test suite.

