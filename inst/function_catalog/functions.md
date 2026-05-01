# Rducks Function Catalog

## `rducks_enable`

- Kind: `r-wrapper/native-extension`
- Category: `connection`
- Signature: `rducks_enable(con, extension_path, threads)`
- Returns: `duckdb_connection invisibly`

Load the Rducks DuckDB extension into a connection. Scalar-mode R UDF registration requires explicit single-thread setup via threads = 'single'.

## `rducks_register`

- Kind: `r-wrapper/native-extension`
- Category: `registration`
- Signature: `rducks_register(con, name, fun, args, returns, mode, null_handling, exception_handling, side_effects)`
- Returns: `rducks_registration`

Register an R function as a DuckDB UDF. The implemented mode = 'scalar' preserves the R callback in the loaded Rducks DuckDB extension and executes through the nanoarrow scalar adapter over DuckDB Arrow C Data. Supports default NULL-in/NULL-out or special NA-passing null handling, return-null exception handling, and DuckDB volatility via side_effects.

## `rducks_is_type`

- Kind: `r-wrapper/S7`
- Category: `types`
- Signature: `rducks_is_type(x)`
- Returns: `logical scalar`

Check whether an object is a structurally valid Rducks DuckDB type descriptor.

