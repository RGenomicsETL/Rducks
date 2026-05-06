# Rducks Unregister / Drop Design

DuckDB function catalog entries registered by the Rducks extension are
**database-scoped**. A UDF registered through one DBI connection can be visible to
sibling connections that use the same in-process DuckDB database. Therefore,
unregistering must be explicit, destructive, and database-scoped; it must never
be an implicit side effect of `rducks_release(con)` or `DBI::dbDisconnect(con)`.

## Current blocker

DuckDB currently reports extension-created scalar functions as internal catalog
entries. Ordinary SQL removal fails with an error like:

```text
Catalog Error: Cannot drop internal catalog entry "drop_me"!
```

Because the extension uses the DuckDB C API/C extension surface only, Rducks does
not currently have a supported public C API path to remove those catalog entries
safely after registration.

## Current behavior

- `rducks_release(con)` / `rducks_detach(con)` is non-destructive.
- Releasing a connection clears only connection-local Rducks state and R-side
  registry views.
- Registered database-catalog functions remain callable while their DuckDB
  catalog metadata exists.
- Preserved R closures remain owned by native catalog metadata and are released
  only when that metadata is destroyed or enqueued for main-thread release.

## Required semantics for a future `rducks_unregister()`

A future unregister API must be explicit about blast radius. The placeholder
shape below is not sufficient by itself; the final API must either accept an
exact Rducks registration id or derive one unambiguously from database-scoped
metadata:

```r
rducks_unregister(con, name, signature = NULL, schema = NULL, generation = NULL)
```

Required contract before exposing any implementation:

1. Destructive and database-scoped: all sibling connections to the same database
   lose the function/overload.
2. Never called implicitly by `rducks_release()` or connection finalizers.
3. Must identify the exact catalog entry by schema, function name, argument type
   vector, return type, and registration generation. Name-only removal may
   succeed only when exactly one database-scoped Rducks catalog entry matches;
   otherwise it must fail as ambiguous.
4. Must update native UDF metadata and R-side database-runtime registry metadata
   together or fail before partial removal. If DuckDB does not provide an atomic
   removal path, Rducks must not expose unregister as a supported operation.
5. Must release preserved evaluator objects only through the recorded main-thread
   release path; off-main destructors must enqueue release work.
6. Must produce ordinary Rducks/DuckDB errors for missing functions, ambiguous
   overloads, or unsupported DuckDB versions.

## Open design gaps

These are intentionally unresolved until a supported DuckDB C API removal path
exists:

- How callers obtain an exact registration id after `rducks_release()` has
  detached a connection-local R registry view.
- Where durable database-runtime metadata for schema, argument types, return
  type, and generation is retained when all R-side connection anchors are gone
  but native catalog metadata still exists.
- The native/R-side state machine for removal, including rollback or tombstone
  behavior if one side succeeds and the other fails.
- Version-specific DuckDB behavior for schemas, overloads, and replacement of
  extension-created scalar functions.

Because these gaps affect destructive database-scoped behavior, they are blockers
for implementation, not details to resolve after exposing an API.

## Non-goals

- Do not use `rducks_release(con)` as an unregister shortcut.
- Do not drop functions by connection-local state only; the catalog is
  database-scoped.
- Do not call private DuckDB C++ catalog APIs from the extension.
- Do not expose raw native pointers or preserved `SEXP` addresses as unregister
  handles.

Until DuckDB exposes a suitable C API or Rducks adopts a different registration
surface with removable indirection, `rducks_unregister()` remains intentionally
unimplemented.
