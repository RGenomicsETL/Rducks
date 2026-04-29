# Rducks Function Catalog

## `rducks_enable`

- Kind: `r-wrapper/native-extension`
- Category: `connection`
- Signature: `rducks_enable(con, extension_path, threads)`
- Returns: `duckdb_connection invisibly`

Load the Rducks DuckDB extension into a connection. The current direct callback path requires explicit single-thread execution via threads = 'single' or PRAGMA threads=1 before R UDF registration.

## `rducks_register`

- Kind: `r-wrapper/native-extension/Rtinycc`
- Category: `registration`
- Signature: `rducks_register(con, name, fun, args, returns, mode, null_handling, exception_handling, side_effects)`
- Returns: `rducks_registration`

Register an R function as a DuckDB UDF. The implemented mode = 'row' compiles a shape-specific scalar wrapper with Rtinycc, preserves the R callback, and registers the resulting function through the loaded Rducks DuckDB extension. The returned rducks_registration can be passed to rducks_unregister(). Supports default NULL-in/NULL-out or special NA-passing null handling, return-null exception handling, and DuckDB volatility via side_effects.

## `rducks_unregister`

- Kind: `r-wrapper/native-extension`
- Category: `registration`
- Signature: `rducks_unregister(registration)`
- Returns: `NULL invisibly`

Soft-unregister a previously registered Rducks UDF by replacing the DuckDB overload with an inactive stub and releasing Rducks' R-side callback and compiled-wrapper references. SQL DROP FUNCTION cannot remove these internal extension entries in current DuckDB.

## `rducks_pump`

- Kind: `r-wrapper/native`
- Category: `callback-runtime`
- Signature: `rducks_pump()`
- Returns: `integer`

Planned main-thread pump for future DuckDB worker-thread callback requests. The current direct-callback implementation still errors because the worker request queue is not implemented.

