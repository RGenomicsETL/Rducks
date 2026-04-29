# Rducks Function Catalog

## `rducks_register`

- Kind: `r-wrapper`
- Category: `registration`
- Signature: `rducks_register(con, name, fun, args, returns, mode)`
- Returns: `rducks_registration`

Create metadata and callback state for an R UDF registration. Native DuckDB registration is staged behind the loaded extension.

## `rducks_pump`

- Kind: `r-wrapper/native`
- Category: `callback-runtime`
- Signature: `rducks_pump()`
- Returns: `integer`

Drain pending main-thread callback requests. The initial scaffold returns zero until the DuckDB extension queue is wired in.

