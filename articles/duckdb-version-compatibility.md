# DuckDB Version Compatibility

## Two versions

Rducks needs duckdb 2.0.0 or later. Two versions apply:

- **C API version, v1.5.6.** Rducks builds its extension against
  DuckDB’s stable C extension API, with `C_STRUCT` metadata. DuckDB
  loads such an extension on every engine release that supports that API
  version, so each platform needs only one build.
- **Minimum engine version, v2.0.0.**
  [`rducks_enable()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_enable.md)
  loads the extension from a signed local extension repository.
  Extension repositories need DuckDB v2.0.0.

The installed package contains one extension and its public key:

``` text
rducks_extension/build/rducks.duckdb_extension
rducks_extension/build/rducks.pub
```

``` r

basename(rducks_extension_path())
#> [1] "rducks.duckdb_extension"
rducks_extension_capi_version()
#> [1] "v1.5.6"
```

## Signed local repository

Installation signs the extension with a key generated for that
installation and keeps only the public key. Nothing else can be signed
with that key after installation.

`rducks_enable(con)` then:

1.  checks that `con` runs DuckDB v2.0.0 or later and that the engine
    supports the C API version of the extension;
2.  copies the extension below
    [`tempdir()`](https://rdrr.io/r/base/tempfile.html) in the
    repository layout `<version>/<platform>/rducks.duckdb_extension`,
    where `<version>` is the release tag of the engine, or its source id
    for a development build;
3.  sets `allow_extension_repositories` to `'allowed'` if it has
    DuckDB’s default (`'undecided'` in 2.0.0, `'hosts'` from 2.0.1), and
    registers the repository with the public key;
4.  runs `INSTALL` and `LOAD` from the repository, with
    `extension_directory` pointed below
    [`tempdir()`](https://rdrr.io/r/base/tempfile.html) during
    `INSTALL`;
5.  restores `extension_directory` and removes the repository record.

DuckDB’s signature checks stay enabled: `allow_unsigned_extensions` is
not needed, and a modified file fails to load.

DuckDB writes the repository record to `extension_repository_directory`,
which it accepts only at startup. Open connections with
[`rducks_duckdb_config()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_duckdb_config.md)
to keep the record below
[`tempdir()`](https://rdrr.io/r/base/tempfile.html):

``` r

con <- DBI::dbConnect(duckdb::duckdb(config = rducks_duckdb_config()))
rducks_enable(con)
```

On a connection opened without it, such as the default connection of
duckplyr, the record goes to `~/.duckdb/extension_repositories` until
`LOAD` finishes.
[`rducks_enable()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_enable.md)
does this only with `home_registry = TRUE`. A connection with
`allow_extension_repositories` set to `'forbidden'` or `'hosts_only'`
cannot load Rducks: DuckDB only tightens that setting while the database
runs.

## Diagnostics

``` r

DBI::dbGetQuery(con, "SELECT library_version, source_id FROM pragma_version()")
DBI::dbGetQuery(con, "SELECT current_setting('allow_extension_repositories')")
DBI::dbGetQuery(con, "SELECT current_setting('extension_repository_directory')")
rducks_extension_capi_version()
```

An explicit `extension_path` skips the repository and runs a plain
`LOAD`, so DuckDB must accept the signature of that file or the
connection must allow unsigned extensions.

## DuckDB 1.5.6

The `backport/duckdb-1.5` branch keeps a release line for duckdb 1.5.6.
It builds the same stable C API extension, does not sign it, and loads
it with a plain `LOAD`, so connections need `allow_unsigned_extensions`.

## Maintainer workflow

The DuckDB C API headers are vendored in `tools/ext/duckdb_capi/`. The
`duckdb_ref` release recorded in `duckdb_headers.json` is the C API
version that `configure` and `configure.win` target. To change it,
vendor the headers of another release:

``` sh
Rscript tools/fetch_duckdb_headers.R --ref v1.5.6
```

The C API version must not be newer than the minimum engine version. The
minimum engine version is `rducks_min_duckdb_version` in
`R/extension_repository.R` and the `duckdb` requirement in
`DESCRIPTION`; a test checks that they agree. The build fails if
`DUCKDB_EXTENSION_API_VERSION_UNSTABLE` is defined, because an unstable
build would tie the artifact to one exact engine release. See
`docs/BUILD.md` in the source repository for the native build details.
