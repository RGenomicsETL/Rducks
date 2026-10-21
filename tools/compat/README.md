# duckdb-r guard companion for managed streaming

The managed `concurrent_inproc` query stream needs the capability supplied by
[`duckdb-r-off-main-guards-v1.5.6.patch`](duckdb-r-off-main-guards-v1.5.6.patch).
This is a reviewable companion patch against duckdb-r 1.5.6. It has not been
published or accepted upstream. Rducks rejects managed stream startup when
the capability is absent; ordinary serial and IPC execution remain available.

## Contract and scope

The patch records R's thread during database startup. Before touching R, native
callbacks reject calls from another thread with a DuckDB exception. Version 1
covers environment replacement scans, matched Arrow replacement scans, R Arrow
schema/stream factories, and R data-frame binding. These checks matter because
replacement scans belong to the database and are visible to the extension's
native connection, including when the caller's temporary views are not.

After startup, the package registers this native capability:

```c
/* R_GetCCallable("duckdb", "duckdb_r_off_main_guard_version") */
typedef uint32_t (*duckdb_r_off_main_guard_version_fn)(void);
/* Returns 1 for this patch. */
```

This capability means those R-backed binding paths fail before entering R from
the managed helper. It does not marshal R-backed tables or Arrow callbacks to R,
make arbitrary R extensions safe on workers, or expose a borrowed connection.
Managed streaming uses Rducks' database-scoped native connection. Caller-local
temporary objects, transactions and session settings are not transparently
shared. Ordinary DBI execution still needs upstream integration that retains
the caller's connection/result and services R callbacks and interrupts throughout
execution, fetch and teardown. The upstream
[producer-thread plan](https://github.com/duckdb/duckdb-r/blob/v1.5.6/plan/PLAN-streaming-thread.md)
separately defers asynchronous open/execute and a binding-complete barrier.

## Pinned sources

The patch changes five source files, with no generated cpp11 changes. Its base is
[duckdb-r v1.5.6](https://github.com/duckdb/duckdb-r/tree/f1f818b29aa8292f1623dae09b25264f93ad71c0),
commit `f1f818b29aa8292f1623dae09b25264f93ad71c0`. The CRAN source and official
library both embed DuckDB core commit `069cc9f9b5`.

| Input | SHA-256 |
| --- | --- |
| [duckdb_1.5.6.tar.gz](https://cran.r-project.org/src/contrib/duckdb_1.5.6.tar.gz) | `92a9b45b2994568d8d3f0173ecc3a085698f1241177719b79d7e3b4bcca5b0c9` |
| [libduckdb-linux-amd64.zip](https://github.com/duckdb/duckdb/releases/download/v1.5.6/libduckdb-linux-amd64.zip) | `b845005f5132a7d8180057c35e14a7626632258782f871a90861b19c1c03841b` |
| Companion patch | `9dd26bac02f4408106c41844b53e0387bcd1ab71807ad086346fe540fd674445` |

The installer falls back to the CRAN version archive when the current-source
URL expires. Every downloaded file must match its pinned checksum.

## Reproduce on Linux amd64

Prerequisites are R 4.2 or newer with DBI installed, a C/C++17 build toolchain,
`make`, `curl`, `git`, `tar`, `xz`, `unzip`, `sha256sum`, and `strings` (binutils).
This recipe was exercised with R 4.3.3 on Linux amd64. The source patch does not
depend on Linux APIs, but macOS and Windows have not been tested. The binary
recipe intentionally accepts Linux amd64 only.

From the Rducks checkout, choose a separate output library and an empty build
directory. Paths must not contain whitespace because upstream configure writes
them into linker flags. Existing ordinary duckdb installations are preserved;
the installer refuses an output library that already contains duckdb.

```sh
tools/compat/install-guarded-duckdb.sh \
  "$PWD/.local/r-library-guarded" \
  "$PWD/.local/duckdb-guarded-build"
```

The installer verifies archives, applies the patch with `git apply --check`, and
uses duckdb-r's supported system-library build:

```sh
TAR_OPTIONS=--no-same-owner \
  DUCKDB_R_USE_SYSTEM_LIB=1 \
  DUCKDB_R_LIB_DIR="$build_dir/libduckdb" \
  MAKEFLAGS=-j2 \
  R CMD INSTALL --library="$output_library" --no-byte-compile .
```

Upstream configure checks that the official `libduckdb.so` matches the exact
vendored core commit. No ABI check is bypassed, and no private connection pointer
is cast. Only R glue is compiled. The installed package uses an absolute runtime
library path: **retain the build directory's `libduckdb` subdirectory**. This is a
development/CI recipe, not a portable binary distribution. The script retains
`install.log`, source and objects, and verifies a SQL result and the actual
versioned C-callable before reporting success. `MAKEFLAGS` may be supplied to
change the default two compilation jobs.

## Managed and stock verification

Use fresh R processes to select a dependency. A loaded stock duckdb namespace
cannot be replaced by changing `.libPaths()` in that process. Put the guarded
library before the ordinary dependency library; if Rducks is installed separately,
put its library first. For example, after installing Rducks with its development
surfaces enabled:

```sh
R_LIBS_USER="$rducks_library:$guarded_library:$ordinary_library" \
  RDUCKS_DEV_SURFACES=true \
  Rscript -e 'for (f in c("test_query_stream_driver.R", "test_query_stream_host_guards.R", "test_query_stream_runtime_guards.R")) { x <- tinytest::run_test_file(file.path("inst/tinytest", f)); print(x); stopifnot(all(as.data.frame(x)$result)) }'
```

`test_query_stream_host_guards.R` covers missing-name replacement and persistent
R data-frame view rejection, main-thread access, and reuse after failed binding.
It also covers registered Arrow input when the optional Arrow package is
installed. `test_query_stream_runtime_guards.R` checks bootstrap after manual
extension loading, configuration guards for a second connection, final-anchor
release, and file-backed shutdown followed by stale-handle close/GC and reopen.
The lifecycle test covers scalar queue execution, error/reentrancy,
early close, garbage collection and reuse. The native SIGINT harness provides
separate interrupt/cleanup checks; see `test/native/run_managed_stream_interrupt.py`.

For the fail-closed case, run the lifecycle test again with only the ordinary
duckdb library in a fresh process. It verifies that the capability is absent and
managed startup fails clearly. Host/runtime tests skip on that dependency.
Run both dependency variants in CI: a guarded build passing managed tests must
not replace the stock-dependency absence check.
