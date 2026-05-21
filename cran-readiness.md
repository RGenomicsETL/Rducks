# CRAN Readiness Review — Rducks

Reference: [CRAN Cookbook](https://contributor.r-project.org/cran-cookbook/) (r-devel/cran-cookbook)

Reviewed: 2026-05-21 | Package version: 0.1.0

---

## Summary

| Category | Status | Critical? |
|---|---|---|
| `\examples{}` in Rd files | **FAIL** — none present | Yes |
| DESCRIPTION software-name quoting | **FAIL** — unquoted names | Yes |
| DESCRIPTION acronyms unexplained | **WARN** — IPC, NNG, UDF | Likely |
| `\value` tags in Rd files | **PASS** — all 46 exported-function Rd files covered | — |
| `cat()`/`print()` outside print methods | **PASS** — all inside `print.*` S3 methods | — |
| `T`/`F` instead of `TRUE`/`FALSE` | **PASS** | — |
| `set.seed()` in functions | **PASS** | — |
| `installed.packages()` usage | **PASS** | — |
| `options(warn = -1)` | **PASS** | — |
| `options()`/`par()`/`setwd()` without restore | **PASS** | — |
| Writing to `.GlobalEnv` via `<<-` | **PASS** — all closures, not global scope | — |
| Writing to user home filespace | **PASS** | — |
| Package tarball size | **PASS** — 2.6 MB (limit: 5 MB soft / 10 MB hard) | — |
| License field | **PASS** — `GPL (>= 3)`, no extraneous `+ file LICENSE` | — |
| Title case | **PASS** | — |
| `Authors@R` field | **PASS** | — |

---

## Critical Issues

### 1. No `\examples{}` sections in any Rd file

**Cookbook reference:** [Manuals & Documentation Issues — Missing `\value`-tags / Structuring of Examples](https://contributor.r-project.org/cran-cookbook/docs_issues.html)

All 47 Rd files (46 exported-function pages + `Rducks-package.Rd`) have **zero** `\examples{}` sections. CRAN expects runnable examples for exported functions. Their absence will generate a NOTE and is likely to draw a rejection comment along the lines of:

> "Please add small runnable examples to the exported functions."

**What to do:**

Add `@examples` blocks (via roxygen2) to at least the primary user-facing functions:

- `rducks_enable()` / `rducks_detach()`
- `rducks_register_scalar_udf()`
- `rducks_register_table()` / `rducks_register_aggregate()`
- `rducks_execution_plan()` / `rducks_set_execution_plan()`
- Type constructors: `rducks_bigint()`, `rducks_decimal()`, `rducks_bits()`, etc.
- `rducks_query_stream()` / `rducks_table_stream()`

Examples that require a live DuckDB connection should be wrapped in `\donttest{}` (executed infrequently on CRAN, still run on `example()`). Examples that genuinely cannot run without external state (e.g. a loaded extension binary not present on CRAN machines) should use `\dontrun{}` with a comment explaining why.

Type constructors and pure value-class functions (e.g. `rducks_bigint()`, `rducks_interval()`) can have simple, always-runnable unwrapped examples:

```r
#' @examples
#' rducks_bigint(c("9223372036854775807", "-1"))
```

**Minimum bar:** At least one unwrapped or `\donttest{}` example per exported function. Toy/minimal data is preferred.

---

### 2. DESCRIPTION — Software names not quoted

**Cookbook reference:** [DESCRIPTION File Issues — Formatting Software Names](https://contributor.r-project.org/cran-cookbook/description_issues.html)

> "Please always write package names, software names and API names in single quotes in title and description."

Current `Description` field:

```
Description: R package and DuckDB extension bridge for registering R functions
    as DuckDB user-defined functions. The package is designed around
    a loaded DuckDB extension, declarative type descriptors, nanoarrow
    marshalling over DuckDB Arrow C Data, and a calling-R-thread execution
    discipline for safe interaction with R from DuckDB execution.
```

The following names should be wrapped in single quotes:

| Unquoted | Should be |
|---|---|
| `DuckDB` (×3) | `'DuckDB'` |
| `nanoarrow` | `'nanoarrow'` |
| `Arrow C Data` | `'Arrow C Data'` |

Corrected text:

```
Description: R package and 'DuckDB' extension bridge for registering R functions
    as 'DuckDB' user-defined functions. The package is designed around
    a loaded 'DuckDB' extension, declarative type descriptors, 'nanoarrow'
    marshalling over 'Arrow C Data', and a calling-R-thread execution
    discipline for safe interaction with R from 'DuckDB' execution.
```

---

## Warnings (Likely to Draw Review Comments)

### 3. DESCRIPTION — Unexplained acronyms

**Cookbook reference:** [DESCRIPTION File Issues — Explaining Acronyms](https://contributor.r-project.org/cran-cookbook/description_issues.html)

The following acronyms appear in the `Description` field or package documentation and are not explained on first use in `DESCRIPTION`:

| Acronym | Used in | Expansion |
|---|---|---|
| `UDF` | Title and Description | User-Defined Function |
| `IPC` | Various Rd files, Description (implicit) | Inter-Process Communication |
| `NNG` | Rd files, Description (implicit) | Nanomsg Next Generation |

`UDF` is used in the Title without ever being spelled out. CRAN reviewers will often ask that acronyms be explained in the Description text. Either expand on first use or document them in `cran-comments.md`.

Suggested addition to Description:

```
... using user-defined functions (UDFs). ...
... The optional Arrow IPC (inter-process communication) transport uses NNG
(nanomsg next generation) for worker communication. ...
```

---

## Passes (No Action Needed)

### `cat()` / `print()` usage

All 57 occurrences of `cat()` and `print()` in the R source are inside named `print.*` S3 methods:

- `print.rducks_bigint`, `print.rducks_ubigint`, `print.rducks_uuid`, `print.rducks_hugeint`, `print.rducks_uhugeint`, `print.rducks_decimal`, `print.rducks_interval`, `print.rducks_bits`, `print.rducks_enum`, `print.rducks_union_list`, `print.rducks_union` (in `R/exotic_classes.R`)
- `print.rducks_execution_plan` (in `R/execution_plan.R`)
- `print.rducks_scalar_udf_registration`, `print.rducks_table_registration`, `print.rducks_aggregate_registration` (in `R/register.R`)
- `print.rducks_query_stream` (in `R/query_stream.R`)
- `print.rducks_ipc_workers` (in `R/provider_nng.R`)

The CRAN cookbook explicitly exempts `print` methods: *"except for print, summary, interactive functions"*. No action needed.

### `<<-` / `.GlobalEnv` usage

All `<<-` assignments in `R/provider_nng.R` (lines 375, 492, 508, 511, 535, 963, 993) operate inside factory closures where the target variables (`last_error`, `last_record`, `provider`, `provider_registered`, `shutdown_status`) are defined in the immediately enclosing scope — not in `.GlobalEnv`. This is idiomatic R closure programming and is **not** writing to the global environment.

The `.GlobalEnv` references in `R/ipc_worker.R` (lines 101, 148, 277) and `R/provider_nng.R` (line 265) are read-only fallbacks: `environment(fun) %||% .GlobalEnv`. These do not write to the global environment. No action needed.

### `\value` tags

All 46 exported-function Rd files contain `\value` tags. The `Rducks-package.Rd` file has `\docType{package}` and lacks `\value`, which is the correct treatment (same exemption as `\docType{data}`). No action needed.

### License

`License: GPL (>= 3)` with no `+ file LICENSE` — correct. The `Copyright:` field points to `inst/LICENSE.note` for bundled third-party components. This is acceptable; the field documents third-party copyrights without adding a non-standard license restriction.

### Title and Authors@R

- `Title: Register R User-Defined Functions in DuckDB` — correct Title Case ("in" as a short preposition is appropriately lowercase).
- `Authors@R` is present and properly structured with `aut`/`cre` roles and copyright holders for all bundled libraries.

### Package size

Built tarball: **2.6 MB**. Well within the 5 MB soft limit and 10 MB hard limit.

### `T`/`F`, `set.seed()`, `options(warn=-1)`, `installed.packages()`, `setwd()`

No occurrences found in `R/` sources. No action needed.

### File I/O

`tempdir()` is used for NNG socket paths (`R/provider_nng.R:181,190`). No writes to the user home filespace or current working directory detected. No action needed.

---

## Recommendations by Priority

1. **High — add `\examples{}` to exported functions.** Start with type constructors (trivial, no connection needed) and the main `rducks_register_scalar_udf()` / `rducks_enable()` workflow (use `\donttest{}`). This is the single most impactful change for CRAN acceptance.

2. **High — quote software names in `DESCRIPTION`.** Two-minute fix; prevents an automatic spell-check NOTE.

3. **Medium — expand acronyms** (UDF, IPC, NNG) in `DESCRIPTION` or document them in `cran-comments.md` prior to submission.

4. **Low — `cran-comments.md`.** Create this file before submission to explain: (a) why some examples are in `\donttest{}` (require a compiled DuckDB extension), (b) package size, (c) any remaining NOTEs from `R CMD check`.
