# Enable Rducks on a DuckDB connection

Loads the bundled Rducks DuckDB extension with DuckDB's signature checks
enabled. Installation signs the extension with a key generated for that
installation and keeps only the public key. `rducks_enable()` exposes
the signed file as a local DuckDB extension repository below
[`tempdir()`](https://rdrr.io/r/base/tempfile.html), registers the
public key for that repository, and runs `INSTALL` and `LOAD` from it.
This needs DuckDB 2.0.0 or later.

## Usage

``` r
rducks_enable(
  con,
  extension_path = NULL,
  threads = c("unchanged", "single"),
  home_registry = FALSE
)
```

## Arguments

- con:

  A `duckdb_connection`.

- extension_path:

  Optional explicit extension path. `NULL` loads the bundled signed
  extension from its local repository. A path is loaded with a plain
  `LOAD`, so DuckDB must accept its signature, or the connection must
  allow unsigned extensions. The engine behind `con` must be at least
  the C API version of the extension; see
  [`rducks_extension_capi_version()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_extension_capi_version.md).

- threads:

  Either `"unchanged"` or `"single"`.

- home_registry:

  `TRUE` to allow a repository record below
  `~/.duckdb/extension_repositories` while the bundled extension loads,
  on a connection that was not opened with
  [`rducks_duckdb_config()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_duckdb_config.md).

## Value

`con`, invisibly.

## Details

The load changes the connection as follows:
`allow_extension_repositories` moves from DuckDB's default
(`'undecided'` in DuckDB 2.0.0, `'hosts'` from 2.0.1) to `'allowed'`,
and DuckDB cannot move it back while the database runs. A connection set
to `'hosts_only'` or `'forbidden'` cannot load Rducks. The repository
record is removed after `LOAD`. `extension_directory` points to a
directory below [`tempdir()`](https://rdrr.io/r/base/tempfile.html)
during `INSTALL` and is then restored.

DuckDB writes the repository record to `extension_repository_directory`,
which it accepts only at startup. Open connections with
[`rducks_duckdb_config()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_duckdb_config.md)
to keep the record below
[`tempdir()`](https://rdrr.io/r/base/tempfile.html). On any other
connection, such as the default connection of duckplyr, the record goes
to `~/.duckdb/extension_repositories` until `LOAD` finishes, and
`rducks_enable()` does this only with `home_registry = TRUE`.

The registration-safe R UDF path requires R API work to happen on the
recorded main R thread; pass `threads = "single"` to set
`external_threads=1` and `PRAGMA threads=1` explicitly. Use
[`rducks_set_execution_plan()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_set_execution_plan.md)
before scalar-UDF registration to select direct serial or queued
in-process execution.

## Examples

``` r
# \donttest{
db <- duckdb::dbConnect(duckdb::duckdb(config = rducks_duckdb_config(list(threads = "2"))))
#> duckdb keeps downloaded extensions and secrets in a temporary directory:
#> ℹ /tmp/RtmpNxox63/duckdb
#> This is removed when the R session ends.
#> • Extensions are re-downloaded each session.
#> • Secrets are lost.
#> ℹ Run duckdb(shared_home = TRUE) (or create ~/.duckdb) to keep them (suitable for most users).
#> ℹ Run duckdb(shared_home = FALSE) to accept the temporary directory (and silence this message).
#> ℹ See ?duckdb_storage for details and alternatives.
rducks_enable(db)
rducks_release(db)
DBI::dbDisconnect(db)
# }
```
