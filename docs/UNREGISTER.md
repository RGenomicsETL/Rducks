# Rducks No-Unregister Policy

DuckDB function catalog entries registered by the Rducks extension are
**database-scoped**. A UDF registered through one DBI connection can be visible to
sibling connections that use the same in-process DuckDB database. Rducks
therefore does not expose `rducks_unregister()`: removing a function would be a
destructive database-catalog operation with process-wide R-closure lifetime
consequences, not ordinary connection cleanup.

## Current blocker

DuckDB currently reports extension-created scalar functions as internal catalog
entries. Ordinary SQL removal fails with an error like:

```text
Catalog Error: Cannot drop internal catalog entry "drop_me"!
```

Because the extension uses the DuckDB C API/C extension surface only, Rducks does
not currently have a supported public C API path to remove those catalog entries
safely after registration. Even if such a path appears, unregister is not planned
for the current package surface because the safer default is to keep catalog UDF
metadata and preserved R closures alive for the database/runtime lifetime.

## Current behavior

- `rducks_release(con)` / `rducks_detach(con)` is non-destructive.
- Releasing a connection clears only connection-local Rducks state and R-side
  registry views.
- Registered database-catalog functions remain callable while their DuckDB
  catalog metadata exists.
- Preserved R closures remain owned by native catalog metadata and may live until
  the DuckDB catalog metadata is destroyed or the R process exits. This
  catalog-lifetime retention is intentional; it avoids releasing a closure while
  sibling connections can still call the database-scoped UDF.
- Re-registering the same SQL name/signature replaces the callable
  implementation. Use replacement or a new function name instead of expecting a
  destructive unregister API.

## Why not unregister?

A safe unregister would need to identify an exact database-catalog entry by
schema, function name, argument type vector, return type, and generation; update
native and R-side database-runtime metadata atomically; and release preserved R
objects only through the recorded main-thread release path. DuckDB's current C
extension API does not provide the required removal/close hooks, and name-only
removal would be ambiguous in the presence of overloads or replacement.

Keeping the preserved closure for catalog/runtime lifetime is simpler and safer
than trying to drop a database-scoped function from one connection's cleanup
path. This is a bounded process-lifetime tradeoff for an embedded R/DuckDB UDF
bridge, not a connection-local resource ownership model.

## Non-goals

- Do not use `rducks_release(con)` as an unregister shortcut.
- Do not drop functions by connection-local state only; the catalog is
  database-scoped.
- Do not call private DuckDB C++ catalog APIs from the extension.
- Do not expose raw native pointers or preserved `SEXP` addresses as unregister
  handles.

`rducks_unregister()` is intentionally not part of the supported Rducks API.
