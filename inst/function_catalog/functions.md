# Rducks Function Catalog

## `rducks_enable`

- Kind: `r-wrapper/native-extension`
- Category: `connection`
- Signature: `rducks_enable(con, extension_path, threads)`
- Returns: `duckdb_connection invisibly`

Load the Rducks DuckDB extension into a connection. R-backed DuckDB scalar UDF, aggregate, and table registration require explicit single-thread setup via threads = 'single'.

## `rducks_register_scalar_udf`

- Kind: `r-wrapper/native-extension`
- Category: `registration`
- Signature: `rducks_register_scalar_udf(con, name, fun, args, returns, mode, null_handling, exception_handling, side_effects)`
- Returns: `rducks_scalar_udf_registration`

Register an R function as a DuckDB scalar UDF. In DuckDB terms the function returns one SQL value per logical input row; the Rducks mode controls whether R is called once per row or once per DuckDB chunk. Execution plans choose marshalling and concurrency without redefining SQL type, NULL, or result semantics.

## `rducks_is_type`

- Kind: `r-wrapper/S7`
- Category: `types`
- Signature: `rducks_is_type(x)`
- Returns: `logical scalar`

Check whether an object is a structurally valid Rducks DuckDB type descriptor.

