# No Unregister API

Rducks does not expose `rducks_unregister()`.

DuckDB function catalog entries registered by the extension are database-scoped.
A scalar UDF registered through one DBI connection can be visible to sibling connections
using the same in-process DuckDB database. Removing it from one connection's
cleanup path would be a destructive catalog operation with native/R lifetime
consequences.

## Current behavior

- `rducks_release(con)` and detach paths are non-destructive for the DuckDB
  catalog.
- Release clears connection-local default plans, finalizer bookkeeping, and the
  R-side registry view for that attachment.
- For the worker-process `ipc` transport, releasing the last Rducks
  attachment to a runtime also closes native client pools for Rducks-launched local workers
  and stops those local mirai/NNG workers. If `ipc_endpoints` was supplied,
  those URLs name user-owned worker processes; Rducks does not send stop
  requests to them during release.
- For file-backed databases, last-attachment release also closes Rducks'
  extension-owned DuckDB connections so the database can be fully closed and
  reopened in the same R process on strict file-locking platforms. This is still
  not an unregister: catalog functions remain until DuckDB drops their catalog
  metadata.
- Registered DuckDB catalog functions remain callable while their catalog
  metadata exists; after last-anchor cleanup of a Rducks-launched local IPC
  provider, IPC scalar UDFs need a live IPC route from a new registration before they
  can execute again.
- Preserved R closures remain owned by native scalar-UDF metadata while that metadata
  can call them.
- Re-registering the same SQL name/signature replaces the callable
  implementation.

## Why not remove catalog functions directly?

A safe unregister would need to identify a precise overloaded catalog entry,
update native and R-side metadata consistently, handle sibling connections, and
release preserved R objects only through a safe R-thread path. Rducks does not
currently provide that API.

## Rules

- Do not use `rducks_release(con)` as an unregister shortcut.
- Do not drop functions based only on connection-local state.
- Do not call private DuckDB C++ catalog APIs from the extension.
- Do not expose raw native pointers or preserved `SEXP` addresses as unregister
  handles.
