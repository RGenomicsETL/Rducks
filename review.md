# Rducks Code Review

Static review of the implementation against its documentation, roxygen
tags, README, tests, and internal consistency. Based on reading ~32 KLOC
across R, C, and documentation sources.

------------------------------------------------------------------------

## 1. Doc / Implementation Mismatches

### 1.1 Truncated sentence — `docs/EXECUTION_PLANS.md:57–59`

The sentence ends mid-conjunction with no continuation:

> “Their bind phase can inspect constant input arguments, decide the
> output schema dynamically, and”

The next sentence is unrelated. Whatever followed “and” is absent from
the documentation. The described behavior is unspecified.

### 1.2 Forward-looking design notes left in reference docs — `docs/EXECUTION_PLANS.md:65–79`

Two blocks of aspirational/roadmap content remain in a document that is
otherwise a behavioral reference:

- A comparison discussing DuckDB’s `duckdb_register()` mechanics in the
  context of how Rducks *could* align with them — describing
  unimplemented behavior.
- A block beginning “Future Rducks table-function work should…” listing
  unimplemented features as if they were planned milestones.

Neither block describes current code. They belong in an issue tracker,
not a reference document.

### 1.3 Self-referential editorial note not removed — `docs/EXECUTION_PLANS.md:157–158`

The following line appears verbatim in the rendered document, visible to
any reader:

> “docs should state what the code and tests actually cover, not a wish
> list of completed work.”

This is an in-progress annotation that was never removed.

### 1.4 “Validation expectations” section describes aspirational, not actual, coverage — `docs/EXECUTION_PLANS.md:143–155`

This section is written in prescriptive future-tense:

> “Tests should verify…” “Coverage should include…”

Cross-referencing against `inst/tinytest/` confirms that several stated
expectations have no corresponding test (cross-plan
`exception_handling = "return_null"`, IPC pending-limit enforcement).
The section reads as a specification, not a statement of fact.

### 1.5 Duplicate word in roxygen `@param` — `R/types.R:87`

``` r

#' @param x Character scalar scalar-type token
```

“scalar” appears twice. Should be `Character scalar type token` or
`Character scalar-type token`.

### 1.6 Hardcoded `mode = "scalar"` in duckplyr integration with no documentation — `R/duckplyr.R:51`

``` r

rducks_register_udf(..., mode = "scalar", ...)
```

`rducks_duckplyr_register_udfs` hardcodes `mode = "scalar"` for every
UDF. Neither `rducks_with_duckplyr` nor `with.duckdb_connection` expose
a `mode` parameter or document this restriction. A user expecting
vectorized mode through the duckplyr path will find no indication it is
silently excluded.

### 1.7 `ipc_max_pending = NULL` produces inconsistent field type — `R/execution_plan.R:239–242, 275`

The validation guard is:

``` r

if (!is.null(ipc_max_pending) && ...) { ... }
```

When `ipc_max_pending = NULL` (the default), validation passes silently.
For IPC plans the field is stored as `NULL`; for non-IPC plans it is set
to `NA_real_`. The same field therefore carries two different sentinels
depending on plan type. Neither the docstring nor any comment
acknowledges this. Code consuming the field must handle both but there
is no contract specifying which to expect.

------------------------------------------------------------------------

## 2. Dead Code / API Leftovers

### 2.1 Unreachable `NA_character_` default arm — `R/execution_plan.R:81`

``` r

switch(engine,
  arrow_r = "r",
  arrow_c = "c",
  ipc_nng = "nng",
  NA_character_   # default
)
```

`rducks_validate_execution_plan_values` rejects all invalid `engine`
values before this switch is reached. The default arm is unreachable
through any public API path. It creates the misleading impression that
the function must tolerate unknown engine strings.

### 2.2 String shortcut aliases with ambiguous names — `R/execution_plan.R:303–318`

Two shortcuts silently imply `arrow_r` marshalling:

``` r

"serial"            -> arrow_r + serial
"inproc_concurrent" -> arrow_r + inproc_concurrent
```

Neither name communicates the marshalling dimension. A caller reading
`"serial"` has no indication it implies `arrow_r`. Eight of the ten
shortcuts have no test coverage (see §5.4).

### 2.3 `arrow.bool8` extension type paths: live, untested, undocumented — `R/aab_arrow_materialize.R:176–197, 208–209, 662–663`

Encode and decode paths for the `arrow.bool8` extension type are present
in production code. The type is not mentioned in
`docs/SUPPORT_MATRIX.md`. No test file exercises either path. The code
exists as an active implementation with no external confirmation it is a
supported, intended feature. It may silently bitrot.

------------------------------------------------------------------------

## 3. Simplification / Bloat

### 3.1 Two parallel 31-column list definitions with no shared constant — `R/explain.R:108–144, 146–186`

`rducks_explain_udf_empty` and `rducks_explain_udf_row` each
independently define the same 31-column list. There is no shared
constant, no helper, and no comment directing a reader to keep them
aligned. Any schema change requires edits in two places with no
compile-time check that they remain consistent.

### 3.2 Lazy-init store pattern repeated 8+ times across 4 files

The following idiom (or a direct structural equivalent) appears
throughout `R/query_stream.R`, `R/register.R`, `R/execution_plan.R`, and
`R/explain.R`:

``` r

store <- .rducks_state$X
if (is.null(store)) {
  store <- new.env(parent = emptyenv(), hash = TRUE)
  .rducks_state$X <- store
}
store
```

There is no shared `rducks_get_or_init_store(key)` helper. Any change to
the initialization pattern requires 8+ coordinated edits.

### 3.3 Double function guard with misleading error ordering — `R/register.R:266–274`

`fun` is checked twice, separated by a `chunk_size` check:

``` r
if (!is.function(fun)) stop(...)         # line 266
if (invalid chunk_size) stop(...)        # line 269
if (!identical(typeof(fun), "closure")) stop(...)  # line 273
```

If `fun` is a primitive (passes `is.function` but fails the closure
check) and `chunk_size` is also invalid, the caller receives the
`chunk_size` error first, which is misleading. The two `fun` guards
should be adjacent and both precede argument validation.

### 3.4 `R/aab_arrow_materialize.R` is 1212 lines with no sub-module organization

This file handles Arrow ↔︎ R materialization for all types in both
directions: scalars, decimals, intervals, UUIDs, booleans (packed and
unpacked), bit arrays, enums, structs, lists, arrays, maps, and unions.
No subdivision exists. A split into `aab_arrow_to_r.R` and
`aab_arrow_from_r.R` (plus type-family helpers) would significantly
reduce the per-file cognitive load.

------------------------------------------------------------------------

## 4. Potemkin Tests

### 4.1 Unconditionally-passing assertion on mori skip path — `inst/tinytest/test_duckdb_runtime_nng_mori_globals.R:5`

``` r

if (!requireNamespace("mori", quietly = TRUE)) {
  expect_true(TRUE)          # cannot fail, proves nothing
  exit_file("mori not available")
}
```

When `mori` is not installed the file emits a passing assertion and
exits. The intent is a skip, but the implementation records a
false-green result. The mori path has zero coverage in this scenario.

### 4.2 Same pattern on TCP unavailability — `inst/tinytest/test_duckdb_runtime_nng_startup_retry.R:15`

``` r

if (!tcp_available) {
  expect_true(TRUE)
  exit_file("TCP not available")
}
```

Identical structural problem: a skip condition implemented as a
guaranteed-pass assertion.

### 4.3 `test_duckdb_runtime_ipc.R` exercises plan construction, not IPC runtime — full file (23 lines)

The file contains no DBI connection setup, no UDF registration, and no
SQL execution. All 23 lines test:

- Type-support predicate functions (`rducks_type_supports_ipc`)
- Arrow IPC encode/decode on static R objects
- Static plan construction via `rducks_as_execution_plan`

The filename implies end-to-end runtime IPC coverage. A reader assessing
coverage by filename will significantly overestimate what is tested.

------------------------------------------------------------------------

## 5. Test Gaps

### 5.1 No tests for `rducks_value_semantics()` or `rducks_mode_semantics()`

Both functions are exported, have non-trivial dispatch logic, and have
documented error conditions. No file in `inst/tinytest/` calls either
function as a test target. Error paths (invalid input, unrecognized
tokens) are entirely unexercised.

### 5.2 `with.duckdb_connection` fallback eval path untested — `R/duckplyr.R:127–128`

``` r

eval(expr, data, enclos = rducks_env)
```

This branch executes when `rducks_returns` metadata is absent from the
connection. It is a distinct code path using `eval` with a non-standard
enclosure. No test in `test_duckplyr_integration.R` or any other file
exercises this branch.

### 5.3 `arrow.bool8` extension round-trip untested

No test verifies that a logical vector survives an `arrow.bool8`
round-trip, that NA values produce the correct result (see §6.2), or
that extension type metadata is preserved. See also §2.3.

### 5.4 Eight of ten `rducks_as_execution_plan` shortcuts untested — `R/execution_plan.R:303–318`

Only two shortcuts are exercised in any test. The remaining eight —
including the ambiguously named `"serial"` and `"inproc_concurrent"`
(see §2.2) — have no test confirming they resolve to the intended plan
structure.

### 5.5 Cross-plan `exception_handling = "return_null"` not verified end-to-end

`docs/EXECUTION_PLANS.md` describes `exception_handling = "return_null"`
as required, validated behavior across all plans. No test was found
that:

1.  Registers a UDF with `return_null` under `arrow_c + serial` or
    `ipc_nng_pool`,
2.  Executes SQL that causes the UDF to throw, and
3.  Asserts the result row contains NULL rather than an error.

The policy is configured and stored; its runtime effect is not
confirmed.

### 5.6 `rducks_query_stream` UNION branch implemented but untested — `R/query_stream.R:115–135`

The `union` branch of `rducks_query_stream_type_from_native_spec` is
fully implemented. No test exercises a query stream with a UNION-typed
column. Any breakage in this path is undetectable.

### 5.7 `rducks_duckplyr_register_udfs` missing-function error path untested — `R/duckplyr.R:42–45`

When a name in `returns` does not exist as a function in `env`, the code
calls `stop("cannot find R function for duckplyr/Rducks UDF: ", name)`.
No test exercises this error path.

### 5.8 `rducks_table_stream` `cardinality` / `exact = TRUE` behavior unverified — `R/register.R:330–360`

`cardinality` and `exact` are accepted and stored, but no test asserts
that DuckDB uses the cardinality hint or that `exact = TRUE` changes
query planning behavior.

------------------------------------------------------------------------

## 6. Inconsistencies

### 6.1 `Rf_copyMostAttrib` on every scalar extraction leaks chunk-level attributes — `tools/ext/src/rducks_rc.c:64–101`

For all five atomic types in scalar row mode extraction:

``` c
out = PROTECT(Rf_allocVector(LGLSXP, 1));
LOGICAL(out)[0] = LOGICAL(values)[i];
Rf_copyMostAttrib(values, out);   // present for LGLSXP, INTSXP, REALSXP, STRSXP, RAWSXP
```

`Rf_copyMostAttrib` copies all attributes except
`names`/`dim`/`dimnames`, including `class`. For typed classes (`Date`,
`POSIXct`) this is often intentional. However, if an Arrow extension
type or upstream transformation has attached an unexpected `class`
attribute to the chunk-level vector `values`, that class is silently
propagated to every length-1 scalar. There is no guard or strip step at
the scalar boundary. Vectorized mode passes the full typed vector to the
UDF, which is consistent; scalar mode propagating chunk-level type
attributes is not guaranteed correct for all types.

### 6.2 `arrow.bool8` NA encoded as `0x00`, indistinguishable from `FALSE` without validity bitmap — `R/aab_arrow_materialize.R:187`

``` r

buf[is.na(x)] <- 0x00   # 0x00 is also the encoding for FALSE
```

Any consumer that reads the data buffer without first checking the Arrow
validity bitmap cannot distinguish NA from FALSE. The Arrow
specification requires validity-bitmap checking for nullable columns,
but this is easy to omit in custom consumers or paths that bypass the
standard Arrow reader. The encoding provides no NA sentinel value
distinct from a valid false.

### 6.3 Mori global sharing and chunk SHM conflated in one bullet — `docs/SUPPORT_MATRIX.md:82–84`

> “Mori global sharing is supported; chunk-level shared-memory handles
> are not.”

These are independent features. As written the bullet reads as a
limitation on mori, when the accurate reading is: mori globals work
fully; chunk-level SHM is a separate, unimplemented feature with no
dependency on mori. A reader scanning the matrix for mori support will
come away with an inaccurate picture.

### 6.4 Duplicate runtime scope tables with no cross-reference — `docs/ARCHITECTURE.md:85–100` and `docs/SUPPORT_MATRIX.md:64–70`

Both documents contain a table describing which operations are valid on
the R thread vs. worker threads vs. the extension-owned queue. The
tables cover the same domain with no acknowledgment of each other and no
“canonical source” designation. A thread-model change requires
coordinated updates to both tables, with no mechanism to detect
divergence.

------------------------------------------------------------------------

## Summary

| \# | Category | File | Lines | Severity |
|----|----|----|----|----|
| 1.1 | Doc mismatch | docs/EXECUTION_PLANS.md | 57–59 | Low |
| 1.2 | Doc mismatch | docs/EXECUTION_PLANS.md | 65–79 | Low |
| 1.3 | Doc mismatch | docs/EXECUTION_PLANS.md | 157–158 | Low |
| 1.4 | Doc mismatch | docs/EXECUTION_PLANS.md | 143–155 | Medium |
| 1.5 | Doc mismatch | R/types.R | 87 | Trivial |
| 1.6 | Doc mismatch | R/duckplyr.R | 51, 78–117 | Medium |
| 1.7 | Doc mismatch | R/execution_plan.R | 239–242, 275 | Medium |
| 2.1 | Dead code | R/execution_plan.R | 81 | Low |
| 2.2 | Dead code | R/execution_plan.R | 303–318 | Low |
| 2.3 | Dead code | R/aab_arrow_materialize.R | 176–197, 208–209 | Medium |
| 3.1 | Bloat | R/explain.R | 108–186 | Medium |
| 3.2 | Bloat | Multiple files | — | Low |
| 3.3 | Bloat | R/register.R | 266–274 | Low |
| 3.4 | Bloat | R/aab_arrow_materialize.R | full file | Low |
| 4.1 | Potemkin test | test_duckdb_runtime_nng_mori_globals.R | 5 | Medium |
| 4.2 | Potemkin test | test_duckdb_runtime_nng_startup_retry.R | 15 | Medium |
| 4.3 | Potemkin test | test_duckdb_runtime_ipc.R | full file | Medium |
| 5.1 | Test gap | R/value_semantics.R, mode_semantics.R | — | Medium |
| 5.2 | Test gap | R/duckplyr.R | 127–128 | Low |
| 5.3 | Test gap | R/aab_arrow_materialize.R | 176–197 | High |
| 5.4 | Test gap | R/execution_plan.R | 303–318 | Low |
| 5.5 | Test gap | cross-plan exception_handling | — | High |
| 5.6 | Test gap | R/query_stream.R | 115–135 | Low |
| 5.7 | Test gap | R/duckplyr.R | 42–45 | Low |
| 5.8 | Test gap | R/register.R | 330–360 | Low |
| 6.1 | Inconsistency | tools/ext/src/rducks_rc.c | 64–101 | High |
| 6.2 | Inconsistency | R/aab_arrow_materialize.R | 187 | Medium |
| 6.3 | Inconsistency | docs/SUPPORT_MATRIX.md | 82–84 | Low |
| 6.4 | Inconsistency | docs/ARCHITECTURE.md + SUPPORT_MATRIX.md | 85–100, 64–70 | Low |

------------------------------------------------------------------------

## Resolution Checklist

All findings below are checked against the implementation after the
review-fix pass. Validation evidence: `make rd` completed without
roxygen warnings, and `make test` completed with `All ok, 1309 results`.

### 1. Doc / Implementation Mismatches

**1.1 Truncated sentence** — Fixed in `docs/EXECUTION_PLANS.md` by
replacing the broken table-function paragraph with a complete statement
of the current Rducks table-function surface.

**1.2 Forward-looking design notes in reference docs** — Removed the
`duckdb_register()` comparison and future-work block from
`docs/EXECUTION_PLANS.md`; the section now describes only implemented
Rducks behavior.

**1.3 Self-referential editorial note** — Removed the editorial sentence
from `docs/EXECUTION_PLANS.md`.

**1.4 Aspirational validation wording** — Replaced “Tests should…”
language with a factual “Current validation coverage” section in
`docs/EXECUTION_PLANS.md`.

**1.5 Duplicate roxygen word** — Changed `R/types.R` to say “Character
scalar type token”; regenerated `man/rducks_type_normalize.Rd`.

**1.6 duckplyr scalar-only mode undocumented** — Documented in
`R/duckplyr.R` that the duckplyr bridge registers UDFs with
`mode = "scalar"` and does not expose vectorized chunk-call mode;
regenerated `man/rducks_with_duckplyr.Rd`.

**1.7 `ipc_max_pending` NULL/NA inconsistency** — Normalized
`ipc_max_pending = NULL` to the provider default `64L` for IPC plans and
stores `NA_integer_` for non-IPC plans. Added tests for the default,
`NULL`, integer-like validation, and non-IPC sentinel.

### 2. Dead Code / API Leftovers

**2.1 Unreachable `NA_character_` default arm** — Replaced the silent
fallback in `rducks_plan_engine_id()` with an explicit internal error
and added a unit test for unsupported plan pairs.

**2.2 Ambiguous shortcut aliases** — Removed the ambiguous `"serial"`
and `"inproc_concurrent"` shortcuts from `rducks_as_execution_plan()`.
Added exhaustive shortcut tests for the remaining explicit aliases and
error tests for the removed ambiguous names.

**2.3 `arrow.bool8` undocumented/untested** — Documented `arrow.bool8`
handling in `docs/SUPPORT_MATRIX.md` and added
`inst/tinytest/test_arrow_bool8_materialize.R` for extension metadata,
encoded bytes, NA sentinel, and round-trip decoding.

### 3. Simplification / Bloat

**3.1 Duplicate `rducks_explain_udf` schema lists** — Added a single
`rducks_explain_udf_columns` schema and `rducks_explain_udf_frame()`
helper; empty and one-row explain results now share the same column
definition.

**3.2 Repeated lazy-init store pattern** — Added
`rducks_get_or_init_store()` in `R/zzz.R` and switched repeated store
helpers in query streams, registration, execution-plan state, explain
metadata, and NNG providers to use it.

**3.3 Misordered table-function `fun` guards** — Moved the closure check
immediately after the function check in
`rducks_table_registration_spec()` so primitive/non-closure function
errors are reported before `chunk_size` errors.

**3.4 Monolithic Arrow materialization file** — Split R-to-Arrow scalar
UDF return encoding helpers into `R/aac_arrow_from_r.R`, leaving
`R/aab_arrow_materialize.R` focused on Arrow-to-R materialization and
shared Arrow helpers.

### 4. Potemkin Tests

**4.1 mori skip false-green assertion** — Removed the unconditional
`expect_true(TRUE)` from the missing-mori path; the file now returns
without recording a fake pass when mori is unavailable.

**4.2 TCP skip false-green assertion** — Removed the unconditional
`expect_true(TRUE)` from the unavailable-TCP path; the file now returns
without recording a fake pass when TCP is unavailable.

**4.3 Misleading IPC runtime filename** — Renamed
`inst/tinytest/test_duckdb_runtime_ipc.R` to
`inst/tinytest/test_ipc_codec_plan.R` because it tests codec/type/plan
helper behavior, while runtime IPC execution remains covered in
`test_duckdb_runtime_execution_plan.R` and NNG lifecycle/provider tests.

### 5. Test Gaps

**5.1 mode/value semantics tests** — Extended `test_types_metadata.R`
with
[`rducks_value_semantics()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_value_semantics.md)
invalid/empty cases and
[`rducks_mode_semantics()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_mode_semantics.md)
non-character/unknown-mode error cases.

**5.2 `with.duckdb_connection` fallback eval path** — Added a test that
calls `with(con, sentinel + 1L, rducks_env = env)` without
`rducks_returns`, exercising the fallback
`eval(expr, data, enclos = rducks_env)` branch.

**5.3 `arrow.bool8` round-trip** — Added explicit bool8 encode/decode
round-trip coverage including `NA` and the extension-name metadata.

**5.4 execution-plan shortcut coverage** — Added exhaustive tests for
all remaining explicit `rducks_as_execution_plan()` shortcuts and error
tests for the removed ambiguous aliases.

**5.5 cross-plan `return_null` behavior** — Added end-to-end SQL tests
for `exception_handling = "return_null"` under `arrow_c + serial` and
`arrow_ipc + multiprocess_parallel`, in addition to existing
reference-path coverage.

**5.6 query-stream UNION branch** — Added a
[`rducks_query_stream()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_query_stream.md)
test with a `UNION(code INTEGER, label VARCHAR)` column and verified the
resulting `rducks_union` tag/value.

**5.7 duckplyr missing-function error** — Added a direct test for
`rducks_duckplyr_register_udfs()` when a named return has no matching R
function in the lookup environment.

**5.8 table-stream cardinality/exact behavior** — Added direct helper
coverage for `rducks_table_stream_cardinality()` and cardinality
validation, plus an exact-cardinality overflow test alongside the
existing underflow test.

### 6. Inconsistencies

**6.1 scalar extraction attribute leakage** — Replaced unconditional
`Rf_copyMostAttrib()` calls in `tools/ext/src/rducks_rc.c` with a
whitelist helper that preserves only known scalar classes/attributes
needed by Rducks and base temporal values (`Date`, `POSIXct`, Rducks
integer/UUID/enum classes, enum levels, and POSIX timezone).

**6.2 `arrow.bool8` NA indistinguishable from FALSE** — Changed bool8
encoding so null slots use a non-value raw sentinel (`0xff`) while the
Arrow validity bitmap remains authoritative. Updated the C decoder to
validate only bytes for valid slots so null sentinels do not force
packed-bit fallback.

**6.3 mori globals vs chunk shared memory** — Clarified
`docs/SUPPORT_MATRIX.md`: mori is documented as long-lived global
sharing, and SQL chunk shared-memory handles are a separate unsupported
data-plane feature.

**6.4 duplicate runtime scope tables** — Added cross-references between
`docs/ARCHITECTURE.md` and `docs/SUPPORT_MATRIX.md`, designating
architecture as the narrative thread-boundary source and the support
matrix as the compact scope/lifetime table.

------------------------------------------------------------------------

## 7. Additional Findings (Second Pass)

Second-pass reading covered all remaining R source files, C extension
source files, and test files not examined in the first pass, including:
`R/ipc_codec.R`, `R/ipc_nng_wire.R`, `R/ipc_worker.R`,
`R/provider_nng.R` (full), `R/type_check.R`, `R/exotic_classes.R`
(decimal construction path), `R/aaa_s7.R`, `tools/ext/src/rducks_rc.c`,
`tools/ext/src/rducks_runtime.c`, `tools/ext/src/rducks_surfaces.c`,
`inst/tinytest/test_query_stream.R`,
`inst/tinytest/test_duckdb_runtime_table_function.R`, and
`docs/ARCHITECTURE.md`.

Fixes 5.6, 5.8, and 6.4 were all confirmed as applied during this pass.

------------------------------------------------------------------------

### 7.1 Dead conditional in `rducks_check_union_value`

**File:** `R/type_check.R:168–169`  
**Severity:** Low

Both branches of the `if (inherits(x, "rducks_union"))` guard are
identical:

``` r
rducks_check_union_value <- function(type, x, what) {
  tag   <- if (inherits(x, "rducks_union")) x$tag   else x$tag
  value <- if (inherits(x, "rducks_union")) x$value else x$value
```

The `else` branch is supposed to handle a plain-list union value, but it
reads the same fields (`x$tag`, `x$value`) as the `rducks_union` branch.
The conditional does nothing. If the intent was to coerce a plain list
to a union before extracting fields — or to apply different field names
— the logic was never written. The function silently accepts any list
with `$tag` and `$value` fields, which may be intentional, but the
conditional is then dead code and the intent is unreadable.

------------------------------------------------------------------------

### 7.2 Redundant length guard in `rducks_nng_wire_decode_request`

**File:** `R/ipc_nng_wire.R:162`  
**Severity:** Trivial

``` r
if (total > as.double(length(buf)) || total != length(buf)) {
```

`total != length(buf)` already catches both over- and under-count,
making the first condition entirely redundant. The
[`as.double()`](https://rdrr.io/r/base/double.html) cast was presumably
added to avoid integer overflow when `total` exceeds
`.Machine$integer.max`, but the `!=` operator also coerces to double in
that case. The line should be:

``` r
if (total != length(buf)) {
```

------------------------------------------------------------------------

### 7.3 Misleading error message in `rducks_nng_check_seconds`

**File:** `R/provider_nng.R:39–45`  
**Severity:** Trivial

``` r
rducks_nng_check_seconds <- function(x, what, default = NULL, minimum = 0) {
  ...
  if (... || x <= minimum) {
    stop(what, " must be a positive finite numeric scalar", call. = FALSE)
  }
```

The error message always says “positive” regardless of `minimum`. When
[`rducks_ipc_workers()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_ipc_workers.md)
calls this with `minimum = rducks_nng_defaults$minimum_timeout` (0.001),
a value of 0.0005 fails with “must be a positive finite numeric scalar”
even though 0.0005 is positive. The message should include the actual
floor, e.g. “must be a finite numeric scalar greater than {minimum}”.

------------------------------------------------------------------------

### 7.4 SEXP pointer address used as deduplication key in globals BFS

**File:** `R/ipc_worker.R:144`  
**Severity:** Low

``` r

current_key <- paste0(typeof(current), "@", .Call(RDUCKS_sexp_addr, current))
```

The BFS queue that discovers transitive globals for IPC serialization
uses the raw SEXP memory address as a deduplication key to avoid
revisiting the same closure. R’s garbage collector is non-compacting
(objects are never relocated), so addresses are stable within a session,
and this works in practice. However, it is an undocumented
implementation assumption. If the GC strategy ever changes, or if
`RDUCKS_sexp_addr` returns a truncated/hashed value, the loop could
either revisit closures (performance) or miss them (correctness). A
safer alternative is to collect already-seen closures in an R-level
`list`/`environment` with identity comparison
([`identical()`](https://rdrr.io/r/base/identical.html)), which relies
only on documented R semantics.

------------------------------------------------------------------------

## 8. Third pass — uniformization, deduplication, extractable shared utilities

### 8.1 `rducks_arrow_sequence_slice` — dead branch (both arms return `values[rows]`)

**File:** `R/aab_arrow_materialize.R` (approx. lines 481–488)  
**Severity:** Low

``` r

rducks_arrow_sequence_slice <- function(type, values, rows) {
  if (!length(rows)) return(values[integer()])
  if (inherits(type, "rducks_scalar_type") || inherits(type, c("rducks_decimal_type", ...))) {
    return(values[rows])
  }
  values[rows]   # identical to the true-branch above
}
```

Both the `inherits(...)` branch and the fall-through return
`values[rows]`. The conditional dispatch does nothing: regardless of
which branch is taken the result is the same expression. The function
can be collapsed to:

``` r

rducks_arrow_sequence_slice <- function(type, values, rows) {
  if (!length(rows)) return(values[integer()])
  values[rows]
}
```

------------------------------------------------------------------------

### 8.2 `rducks_rc_direct_input_view_init` and `rducks_rc_direct_output_view_init` — identical bodies

**File:** `tools/ext/src/rducks_rc.c` (approx. lines 283–293)  
**Severity:** Low

``` c
static void rducks_rc_direct_input_view_init(rducks_rc_direct_vector_view_t *view, duckdb_vector vector) {
    view->vector = vector;
    view->data = duckdb_vector_get_data(vector);
    view->validity = duckdb_vector_get_validity(vector);
}
static void rducks_rc_direct_output_view_init(rducks_rc_direct_vector_view_t *view, duckdb_vector vector) {
    view->vector = vector;
    view->data = duckdb_vector_get_data(vector);
    view->validity = duckdb_vector_get_validity(vector);
}
```

Both functions have byte-for-byte identical bodies. There is no semantic
distinction between them at initialization time. A single
`rducks_rc_direct_view_init` with the two existing names as thin aliases
(or simply replacing both call sites with one name) would eliminate the
duplication.

------------------------------------------------------------------------

### 8.3 Queue stat scalar callbacks — repeated single-line wrapper pattern without a macro

**Files:** `tools/ext/src/rducks_surfaces.c` (approx. lines 308–356,
481–524)  
**Severity:** Trivial

There are two families of stat-surface callbacks — queue stats (10
functions) and runtime stats (9 functions) — each of which is a
single-line wrapper dispatching to a shared `_impl` function with a
different enum constant:

``` c
static void rducks_queue_submitted_stat_scalar(duckdb_function_info info,
    duckdb_data_chunk input, duckdb_vector output) {
    rducks_queue_stat_scalar_impl(info, input, output, RDUCKS_QUEUE_STAT_SUBMITTED);
}
/* ... 9 more identical wrappers for queue, 9 more for runtime ... */
```

These callbacks must be distinct function pointers (the DuckDB C API
requires this) and cannot be consolidated at runtime. However,
generating all 19 of them from a single X-macro table would make the
pattern explicit, keep them mechanically in sync with enum changes, and
eliminate the risk of silent copy-paste mistakes when a new stat is
added:

``` c
#define RDUCKS_QUEUE_STAT_CALLBACKS(X)          \
    X(submitted,   RDUCKS_QUEUE_STAT_SUBMITTED)  \
    X(executed,    RDUCKS_QUEUE_STAT_EXECUTED)   \
    /* ... */

#define RDUCKS_DEFINE_QUEUE_STAT_SCALAR(name, field)                               \
static void rducks_queue_##name##_stat_scalar(duckdb_function_info info,           \
    duckdb_data_chunk input, duckdb_vector output) {                               \
    rducks_queue_stat_scalar_impl(info, input, output, field);                     \
}
RDUCKS_QUEUE_STAT_CALLBACKS(RDUCKS_DEFINE_QUEUE_STAT_SCALAR)
```

------------------------------------------------------------------------

### 8.4 `rducks_results_as_*` — four copies of the same `vapply` coercion pattern

**File:** `R/aac_arrow_from_r.R` (approx. lines 6–20)  
**Severity:** Low

``` r

rducks_arrow_results_as_logical <- function(results) {
  vapply(results, function(x) if (is.null(x)) NA else as.logical(x)[[1L]], logical(1))
}
rducks_arrow_results_as_integer <- function(results) {
  vapply(results, function(x) if (is.null(x)) NA_integer_ else as.integer(x)[[1L]], integer(1))
}
rducks_arrow_results_as_numeric <- function(results) {
  vapply(results, function(x) if (is.null(x)) NA_real_ else as.double(x)[[1L]], double(1))
}
rducks_arrow_results_as_character <- function(results) {
  vapply(results, function(x) if (is.null(x)) NA_character_ else as.character(x)[[1L]], character(1))
}
```

All four share the same structure:
`vapply(results, function(x) if (is.null(x)) NA_TYPE else as.TYPE(x)[[1L]], TYPE(1))`.
A single helper:

``` r

rducks_arrow_results_coerce <- function(results, na, coerce, proto) {
  vapply(results, function(x) if (is.null(x)) na else coerce(x)[[1L]], proto)
}
```

…and four one-line wrappers that supply `na`, `coerce`, and `proto`
would consolidate the pattern without changing the public function
names.

------------------------------------------------------------------------

### 8.5 Optional-function argument guards — 7 near-identical inline checks

**File:** `R/register.R` (approx. lines 579–601)  
**Severity:** Low

``` r

if (!is.null(update)   && !is.function(update))   stop("update must be NULL or a function", ...)
if (!is.null(finalize) && !is.function(finalize)) stop("finalize must be NULL or a function", ...)
if (!is.null(combine)  && !is.function(combine))  stop("combine must be NULL or a function", ...)
# ... 4 more identical guards
```

Seven guards in `rducks_aggregate_registration_spec` share the pattern
`if (!is.null(x) && !is.function(x)) stop(...)`. A private helper
`rducks_assert_optional_function(x, what)` would collapse each guard to
one line and make the pattern reusable when future optional-function
arguments are added elsewhere.

------------------------------------------------------------------------

### 8.6 Non-empty character scalar validation repeated inline without a shared helper

**Files:** `R/register.R` (lines 58, 258, 576), `R/explain.R` (approx.
line 219), `R/execution_plan.R`, `R/query_stream.R` (line 435)  
**Severity:** Low

The guard:

``` r

if (!is.character(x) || length(x) != 1L || is.na(x) || !nzchar(x)) stop(...)
```

appears at least six times across distinct files with slightly varying
error messages. There is no package-level utility for this. A shared
`rducks_assert_nonempty_scalar_chr(x, what)` or similar would eliminate
the repeated inline test and provide a single place to tighten the check
(e.g., to add `!is.na(x)` uniformly, since some call sites omit it).

------------------------------------------------------------------------

### 8.7 Recursive Arrow type-tree walk skeleton duplicated across two R functions

**File:** `R/aab_arrow_materialize.R` (approx. lines 585–650)  
**Severity:** Medium

`rducks_arrow_ipc_storage_array_for_type` and
`rducks_arrow_import_child_schema` both recursively traverse the same
type-kind tree
(`enum → list/array → struct → map → union → base scalar`). The
traversal skeleton — the `switch`/`if` branching over type kind and the
recursive calls at each node — is duplicated verbatim. Only the
leaf-level action differs between the two functions.

A shared recursive walk helper
`rducks_arrow_type_tree_map(type, node, fn)` that accepts a per-node
callback would unify the skeleton and make adding a new type kind a
single-point change.

------------------------------------------------------------------------

### 8.8 Execution plan shortcut table — three aliases resolve to the identical plan

**File:** `R/execution_plan.R` (approx. lines 311–314)  
**Severity:** Trivial

``` r
reference    = rducks_execution_plan("arrow_r", "serial"),
arrow_r      = rducks_execution_plan("arrow_r", "serial"),
arrow_r_serial = rducks_execution_plan("arrow_r", "serial"),
```

`"reference"`, `"arrow_r"`, and `"arrow_r_serial"` all produce the same
plan object. Two of the three are therefore undocumented synonyms with
no visible distinction in the shortcut list. Callers who read this list
cannot determine which name is canonical or why the others exist. Either
document the aliases explicitly (e.g., `reference` = legacy name,
`arrow_r` = primary) or reduce to a single canonical entry and add
explicit aliases with comments.

------------------------------------------------------------------------

### 8.9 `rducks_get_or_init_store` `hash` parameter is never exercised

**File:** `R/zzz.R` and all call sites  
**Severity:** Trivial

Every call to `rducks_get_or_init_store` omits the `hash` argument
(accepting the `FALSE` default). Hash-backed environments are never
actually created for any store. If hashing is not required for any
current store, the `hash` parameter is dead interface and should be
removed. If it is intended for future large stores it should be
documented explicitly. In either case the current state misleads readers
into thinking hash-backed stores are an active feature.

------------------------------------------------------------------------

### 8.10 `rducks_make_scalar_engine` and `rducks_make_vectorized_engine` — near-identical bodies

**File:** `R/arrow_bridge.R` (lines 1–48)  
**Severity:** Low

``` r
rducks_make_scalar_engine <- function(fun, spec, null_handling, exception_handling, plan) {
  ...
  list(
    ...
    eval_rows = rducks_scalar_eval_prepared_rows,
    ...
  )
}

rducks_make_vectorized_engine <- function(fun, spec, null_handling, exception_handling, plan) {
  ...
  list(
    ...
    eval_rows = rducks_vectorized_eval_prepared_chunk,
    ...
  )
}
```

The two functions differ only in the value assigned to `eval_rows`. All
other fields — `fun`, `arg_types`, `return_type`, `null_handling`,
`exception_handling`, `plan`, `prepare_inputs`, `results_to_arrow`, and
the `serialization` conditional — are identical. A single
`rducks_make_engine(fun, spec, null_handling, exception_handling, plan, eval_rows)`
with the two existing names as thin wrappers would remove the
duplication.

------------------------------------------------------------------------

### 8.11 `rducks_enable_inproc` and `rducks_disable_inproc` — differ only in one string

**File:** `R/connection.R` (lines 88–113)  
**Severity:** Trivial

``` r

rducks_enable_inproc <- function(con, threads = NULL, external_threads = NULL) {
  rducks_assert_duckdb_connection(con)
  current <- rducks_current_execution_plan(con)
  plan <- rducks_execution_plan(current$marshalling, "inproc_concurrent")
  rducks_set_execution_plan(con, plan, threads = threads, external_threads = external_threads)
  invisible(con)
}

rducks_disable_inproc <- function(con, threads = NULL, external_threads = NULL) {
  rducks_assert_duckdb_connection(con)
  current <- rducks_current_execution_plan(con)
  plan <- rducks_execution_plan(current$marshalling, "serial")
  rducks_set_execution_plan(con, plan, threads = threads, external_threads = external_threads)
  invisible(con)
}
```

The bodies are identical except for the concurrency string
(`"inproc_concurrent"` vs `"serial"`). Both could delegate to a private
`rducks_switch_inproc(con, concurrency, threads, external_threads)` to
remove the duplication.

------------------------------------------------------------------------

### 8.12 `rducks_runtime_udf_stat` field dispatch — 20-arm linear if/else chain

**File:** `tools/ext/src/rducks_runtime.c` (approx. lines 440–488)  
**Severity:** Low

`rducks_runtime_udf_stat` dispatches on a `field` string with 20
sequential `strcmp` comparisons in an `if/else if` chain. Each arm has
the form:

``` c
} else if (strcmp(field, "dispatch_chunks") == 0) {
    snprintf(out, out_cap, "%llu", (unsigned long long)rducks_udf_counter_load(&meta->dispatch_chunks));
}
```

All but the first two arms are mechanically identical in structure:
compare field name, format a counter. A table-driven approach:

``` c
typedef struct { const char *name; size_t offset; } rducks_stat_field_t;
static const rducks_stat_field_t fields[] = {
    {"dispatch_chunks", offsetof(rducks_r_scalar_meta_t, dispatch_chunks)},
    ...
};
```

…would replace the chain with a loop and a single `snprintf`, make
adding new stat fields a one-line table entry, and remove the risk of
copy-paste errors in the formatting expressions.

------------------------------------------------------------------------

### 8.13 Query stream scalar callbacks — four functions with identical preamble and per-row loop skeleton

**File:** `tools/ext/src/rducks_surfaces.c` (approx. lines 694–836)  
**Severity:** Low

`rducks_query_stream_open_scalar`, `rducks_query_stream_schema_scalar`,
`rducks_query_stream_next_scalar`, and
`rducks_query_stream_close_scalar` each begin with the same preamble
(get `runtime` from extra info, get `n`, get `token_vector`, get
`tokens`, get `validity`, guard on `runtime`) and contain a per-row loop
that checks validity, copies the DuckDB string token, calls a distinct
native function, handles errors, and frees the token. The only
per-function differences are the native function called, the OOM/error
messages, and whether `out[i]` is a `bool` or a string.

A shared helper that iterates rows, validates, copies the string, and
invokes a caller-supplied callback would consolidate the four identical
skeletons.

------------------------------------------------------------------------

### 8.14 `rducks_query_stream_arrow_batch` and `rducks_query_stream_materialize_arrow_batch` — duplicated parameter validation block

**File:** `R/query_stream.R` (lines 43–78 and 122–166)  
**Severity:** Low

Both functions begin with:

``` r

if (!nanoarrow::nanoarrow_pointer_is_valid(array)) stop(...)
if (!nanoarrow::nanoarrow_pointer_is_valid(schema)) stop(...)
type_specs <- as.list(type_specs)
column_names <- as.character(column_names)
if (length(type_specs) != length(column_names) || length(type_specs) != length(array$children))
  stop(...)
if (is.null(type_objects)) {
  type_objects <- lapply(type_specs, rducks_query_stream_type_from_native_spec)
} else {
  type_objects <- as.list(type_objects)
  if (length(type_objects) != length(type_specs)) stop(...)
}
```

This six-step validation/normalization block is copied verbatim.
Extracting it into
`rducks_query_stream_validate_batch_args(array, schema, type_specs, column_names, type_objects)`
returning the normalized `type_objects` would remove the duplication.

------------------------------------------------------------------------

## Section 9 — S7 vs S3 inconsistencies and outdated S7 API usage

### 9.1 `package = NULL` on all exported S7 classes

**File:** `R/aaa_s7.R` (all `new_class` calls, e.g. lines 22, 55, 70,
90, …)  
**Severity:** Medium

Every S7 class in the package — including exported ones such as
`rducks_type_class` and all ~25 type subclasses — is constructed with
`package = NULL`:

``` r

rducks_type_class <- S7::new_class(
  "rducks_type",
  package = NULL,   # ← wrong for a distributed package
  ...
)
```

The S7 packages vignette states: *“If you export a class, you must also
set the `package` argument, ensuring that classes with the same name are
disambiguated across packages.”* With `package = NULL` the class name is
unqualified in the S3 class vector (`"rducks_type"` instead of
`"Rducks::rducks_type"`). If another package defines a class with the
same string name,
[`S7::S7_inherits()`](https://rconsortium.github.io/S7/reference/S7_inherits.html)
and method dispatch will silently produce wrong results. All exported
classes should pass `package = "Rducks"`.

------------------------------------------------------------------------

### 9.2 `inherits()` used instead of `S7::S7_inherits()` at 30+ call sites

**Files:** `R/types.R`, `R/type_check.R`, `R/aab_arrow_materialize.R`,
`R/execution_plan.R`, `R/register.R`, `R/value_semantics.R`,
`R/duckplyr.R`, `R/aac_arrow_from_r.R`, `R/aaa_eval_vectorized.R`  
**Severity:** Medium

Throughout the codebase, membership in S7 type-descriptor classes is
tested with [`base::inherits()`](https://rdrr.io/r/base/class.html):

``` r

inherits(x, "rducks_type")
inherits(type, "rducks_scalar_type")
inherits(type, c("rducks_decimal_type", "rducks_enum_type"))
```

S7 objects carry a synthetic S3 `class` attribute so
[`inherits()`](https://rdrr.io/r/base/class.html) happens to work via
the compatibility shim. However the idiomatic S7 test is
`S7::S7_inherits(x, rducks_type_class)`, which operates on the formal S7
class object rather than on its string name. Relying on string names:

- Breaks silently if a class is renamed or the `package` argument is
  added (which qualifies the name).
- Bypasses the S7 object system entirely, making grep-based refactoring
  harder.
- Is inconsistent with the rest of the S7 API used in the same file.

The same pattern appears inside the S7 validator in `aaa_s7.R` (line
36):

``` r
if (!all(vapply(children, inherits, logical(1), what = "rducks_type")))
```

All these sites should use
[`S7::S7_inherits()`](https://rconsortium.github.io/S7/reference/S7_inherits.html)
with the class object, not the string.

------------------------------------------------------------------------

### 9.3 `rducks_type_prop()` — NULL-unsafe hybrid S3/S7 property accessor

**File:** `R/aaa_s7.R` (approx. lines 300–315)  
**Severity:** Medium

A custom shim is used everywhere instead of
[`S7::prop()`](https://rconsortium.github.io/S7/reference/prop.html) or
`@`:

``` r

rducks_type_prop <- function(x, name) {
  value <- NULL
  if (is.list(x)) {
    value <- x[[name]]   # S3 list path
  }
  if (!is.null(value)) return(value)
  S7::prop(x, name)      # S7 fallback
}
```

This is NULL-unsafe: if a property legitimately holds `NULL`,
`x[[name]]` returns `NULL`, the guard `!is.null(value)` fails, and the
code falls through to
[`S7::prop()`](https://rconsortium.github.io/S7/reference/prop.html) on
the same object — which may return a different (incorrect) value or
error. The S7 packages vignette shows the correct approach for mixed
R-version support: use the `@` operator with an `importFrom("S7", "@")`
declaration under `if (getRversion() < "4.3.0")`. The dual-path shim
should be replaced with direct
[`S7::prop()`](https://rconsortium.github.io/S7/reference/prop.html)
calls (or `@` with the appropriate `NAMESPACE` guard).

------------------------------------------------------------------------

### 9.4 All S7 methods include `...` unnecessarily

**File:** `R/aaa_s7.R` (all six
[`S7::method`](https://rconsortium.github.io/S7/reference/method.html)
assignments for `rducks_type_token`, `rducks_type_kind`,
`rducks_type_children`, `rducks_type_child_names`, `rducks_type_size`,
`rducks_type_parameters`); `R/exotic_classes.R` (all `rducks_value_type`
and `rducks_duckdb_literal` methods)  
**Severity:** Low

Every concrete method is declared with `...` even though it neither uses
nor forwards it:

``` r

S7::method(rducks_type_token, rducks_type_class) <- function(x, ...) {
  rducks_type_prop(x, "token")
}
```

The S7 generics vignette states: *“The default generic includes … but
generally the methods should not. That ensures that misspelled arguments
won’t be silently swallowed by the method.”* Because `...` is present, a
caller writing `rducks_type_token(x, token = "typo")` gets no error.
Removing `...` from the method signatures restores this safety net.

------------------------------------------------------------------------

### 9.5 Redundant `class_any` error-fallback methods duplicate S7’s own dispatch failure

**Files:** `R/aaa_s7.R` (6 methods), `R/exotic_classes.R` (lines
634–639, 2 methods)  
**Severity:** Low

Each generic has a
[`S7::class_any`](https://rconsortium.github.io/S7/reference/class_any.html)
catch-all that throws a custom error:

``` r

S7::method(rducks_type_token, S7::class_any) <- function(x, ...) {
  rducks_type_method_error(x, "rducks_type_token()")
}
```

S7 already raises an informative error when dispatch finds no matching
method: *“Can’t find method for `generic(<class>)`.”* The eight extra
registrations add noise to the method table and slightly increase
dispatch overhead for every non-matching call (S7 must check the
`class_any` method before giving up). If the custom error message adds
genuine diagnostic value it should be documented and kept; otherwise
removing these methods lets S7’s own message surface, which is
consistent with how S7 errors are reported elsewhere.

------------------------------------------------------------------------

### 9.6 S7 validator re-checks constraints already enforced by property type declarations

**File:** `R/aaa_s7.R` (validator function, approx. lines 40–80)  
**Severity:** Low

The `rducks_type_class` validator manually extracts all seven properties
via [`S7::prop()`](https://rconsortium.github.io/S7/reference/prop.html)
and re-validates their scalar type (e.g. `is.character(token)`,
`length(token) == 1L`). S7 already enforces these at construction time
through the `properties` list:

``` r

properties = list(
  token      = S7::class_character,
  duckdb_sql = S7::class_character,
  ...
)
```

[`S7::class_character`](https://rconsortium.github.io/S7/reference/base_classes.html)
guarantees a character vector; `length == 1` could be expressed with a
length-one class constraint or kept in the validator, but as written the
validator duplicates the type check that S7 has already performed. Only
cross-property constraints (e.g. `length(children) == 1` for list types)
genuinely require manual validation. The rest of the validator is dead
weight that slows construction and obscures which invariants are
non-trivial.

------------------------------------------------------------------------

### 9.7 `unclass(self)` inside S7 validator strips S7 attributes before iteration

**File:** `R/aaa_s7.R` (approx. line within
`rducks_validate_type_list_s7`)  
**Severity:** Low

``` r

rducks_validate_type_list_s7 <- function(self) {
  if (!all(vapply(unclass(self), inherits, logical(1), what = "rducks_type"))) {
    "all elements must be rducks_type descriptors"
  }
}
```

[`unclass()`](https://rdrr.io/r/base/class.html) strips the S7 class
attribute from `self` before iteration. The idiomatic approach is to use
`S7::props(self)` to access the underlying list of property values, or
to iterate `self` directly if `parent = S7::class_list` makes it
iterable. Using [`unclass()`](https://rdrr.io/r/base/class.html) also
combines with the [`inherits()`](https://rdrr.io/r/base/class.html)
issue from finding 9.2: both problems appear in the same expression.

------------------------------------------------------------------------

### 9.8 Local variable `class` shadows `base::class()` in constructor helper

**File:** `R/aaa_s7.R` (function `rducks_type_construct_s7`, approx.
lines 260–285)  
**Severity:** Low

``` r

rducks_type_construct_s7 <- function(token, duckdb_sql, kind, children,
                                      child_names, size, parameters = list()) {
  ...
  class <- rducks_type_class_for_kind(kind, token)  # shadows base::class()
  class(data, token = token, ...)                   # calls S7 constructor
}
```

The local variable `class` shadows the base primitive
[`base::class()`](https://rdrr.io/r/base/class.html). While the S7
constructor call is correct (S7 class objects are callable), any
subsequent use of [`class()`](https://rdrr.io/r/base/class.html) within
the same scope would silently dispatch to the S7 constructor instead of
the base generic. Renaming the local variable to `cls` or `type_class`
removes the ambiguity at no cost.

------------------------------------------------------------------------

## Section 10 — IPC worker, NNG wire, provider, and aggregate issues

### 10.1 `parent.frame()` used as fallback for `environment(fun)` in globals discovery — wrong frame at all three call sites

**File:** `R/ipc_worker.R` lines 101, 148, 277  
**Severity:** Medium

When a user-supplied function is a primitive or built-in,
`environment(fun)` returns `NULL`. The `%||%` operator then calls
[`parent.frame()`](https://rdrr.io/r/base/sys.parent.html) as the
fallback:

``` r

# line 101 — inside rducks_ipc_globals_from_globals_package
envir = environment(fun) %||% parent.frame()

# line 148 — inside the while-loop of rducks_ipc_globals_for_function_codetools
env <- environment(current) %||% parent.frame()

# line 277 — inside rducks_ipc_worker_globals (character branch)
env <- environment(fun) %||% parent.frame()
```

[`parent.frame()`](https://rdrr.io/r/base/sys.parent.html) is evaluated
at call time, so it refers to the immediate caller of the enclosing
helper function — `rducks_ipc_globals_for_function`,
`rducks_ipc_globals_for_function_codetools`’s while-loop body, and
`rducks_ipc_worker_globals` respectively — not to any meaningful UDF
enclosing scope. The intended fallback for “no closure environment” is
`.GlobalEnv` (which is where primitives and user top-level functions
live). All three sites should use `.GlobalEnv` as the fallback rather
than [`parent.frame()`](https://rdrr.io/r/base/sys.parent.html).

------------------------------------------------------------------------

### 10.2 `timeout_ms` becomes `integer(0)` when `opts$timeout` is `NULL`

**File:** `R/provider_nng.R` line 967  
**Severity:** Medium

Inside `rducks_make_arrow_ipc_nng_wrapper`, the `configure` closure
constructs the returned list with:

``` r
timeout_ms = as.integer(ceiling(as.numeric(opts$timeout) * 1000)),
```

`opts` comes from `rducks_ipc_options()` which does not guarantee that
`$timeout` is non-NULL. When it is `NULL`:

- `as.numeric(NULL)` → `numeric(0)`
- `ceiling(numeric(0) * 1000)` → `numeric(0)`
- `as.integer(numeric(0))` → `integer(0)`

The field becomes a zero-length integer instead of a scalar. Native code
that consumes `timeout_ms` (the DuckDB C extension side) will receive an
empty value, which may be silently misinterpreted as zero or cause an
out-of-bounds access. The `%||%` guard is applied to `opts$timeout` only
in `register_udf` (line ~959) but not at line 967. The fix is:

``` r
timeout_ms = as.integer(ceiling(as.numeric(opts$timeout %||% rducks_nng_defaults$register_timeout) * 1000)),
```

------------------------------------------------------------------------

### 10.3 `rducks_nng_wire_u64` accepts values only up to `2^53`, not `2^64`, without documentation

**File:** `R/ipc_nng_wire.R` lines 48–53  
**Severity:** Low

``` r

rducks_nng_wire_u64 <- function(x) {
  x <- rducks_nng_wire_check_uint(x, 2^53, "uint64")
  ...
}
```

The cap at `2^53` is R’s floating-point precision limit for
integer-exact doubles. Values in the range `[2^53, 2^64)` are silently
rejected with “NNG wire uint64 value is out of range” — a correct but
misleading error for a function named `u64`. The symmetric
`rducks_nng_wire_read_u64` at line 64 also silently loses precision for
`hi * 2^32` when `hi >= 2^21`:

``` r

list(value = lo$value + hi$value * 2^32, pos = hi$pos)
```

If a payload or row count ever exceeds `2^53` bytes/rows, the decode
path would produce a wrong (truncated) numeric value. Neither function
documents the effective 53-bit limit. A comment should clarify the
constraint and, if payloads could realistically exceed `2^53` bytes, the
read path should error explicitly rather than silently truncating.

------------------------------------------------------------------------

### 10.4 `inherits(setup_value, "errorValue")` uses a fragile string check for mirai error values

**File:** `R/provider_nng.R` line 447  
**Severity:** Low

``` r

setup_value <- mirai::collect_mirai(setup)
if (inherits(setup_value, "errorValue")) stop(as.character(setup_value), call. = FALSE)
```

`"errorValue"` is the internal S3 class string used by the mirai package
for error values. This is not part of mirai’s documented public API; the
class name could change between mirai versions without a breaking-change
notice. The mirai package provides
[`mirai::is_mirai_error()`](https://mirai.r-lib.org/reference/is_mirai_error.html)
(or equivalent) as the intended predicate. Using it makes the code
robust to class-name changes and signals intent more clearly than an
[`inherits()`](https://rdrr.io/r/base/class.html) string test.

------------------------------------------------------------------------

### 10.5 Worker registry in `rducks_nng_worker_loop` is never cleaned up on re-register

**File:** `R/provider_nng.R` lines 223–256  
**Severity:** Low

``` r

registry <- new.env(parent = emptyenv())
...
assign(req$udf_id, rec, envir = registry)
```

The worker registry environment accumulates a record for every
registered UDF id. If a provider is reused across multiple query
executions or re-registrations (the provider is cached per runtime token
in `rducks_nng_provider_for_runtime`), old registrations are never
removed. Over a long session with many distinct UDF ids, the registry
will grow unboundedly. Adding a maximum-size eviction policy or clearing
the registry on stop/restart would prevent this slow leak.

------------------------------------------------------------------------

### 10.6 `rducks_nng_wire_decode_dynamic_payload` — position arithmetic uses `pos + len$value` without overflow guard

**File:** `R/ipc_nng_wire.R` lines 82–94  
**Severity:** Low

Inside the dynamic-payload decoder, positions are accumulated with:

``` r

pos <- pos + len$value
```

Each `len$value` is a u32 (up to `2^32 - 1`). The loop iterates over an
unbounded number of tokens (bounded only by `count$value`, which can be
up to `2^31 - 1`). If a malformed payload reports many tokens with large
lengths, `pos` can silently overflow R’s double precision. The existing
guard checks `pos != length(payload) + 1L` at the end, but a
precision-losing `pos` could accidentally satisfy this check for a
crafted payload. Capping `count$value` to a sensible maximum
(e.g. `rducks_ipc_worker_check_n`’s argument count limit) and/or
validating `pos <= length(payload)` after each token read would close
this gap.

------------------------------------------------------------------------

### 10.7 Extension-internal `rducks_current_thread_token` produces a diagnostic label that cannot round-trip through `rducks_set_main_thread_token`

**File:** `tools/ext/src/rducks_threads.c` lines 5–18  
**Severity:** Low

The static helper inside the extension:

``` c
static void rducks_current_thread_token(char *buf, size_t cap) {
    ...
    snprintf(buf, cap, "posix:pthread");   // POSIX path — diagnostic label only
}
```

produces `"posix:pthread"`, while `rducks_set_main_thread_token` expects
the prefix `"posix-pthread-ptr:"` to parse a pointer address. If any
code path passed the extension-internal token through
`rducks_set_main_thread_token`, it would silently return 0 (failure).
The function comment says *“Diagnostic label only”* but this is not
enforced — calling `rducks_runtime.c:672` stores it in
`runtime->worker_thread_token`, a field whose purpose is not documented
to be diagnostic-only. The two token formats should either be clearly
separated by type or one should be removed to prevent accidental misuse.

------------------------------------------------------------------------

## Section 11 — NNG pool lifecycle, global preserve-release queue, aggregate error handling, O(n²) closures

### 11.1 `rducks_nng_client_pool_destroy` — half-closed pool on quiesce-in-progress

**File:** `tools/ext/src/rducks_nng.c` lines 412–419  
**Severity:** Medium

``` c
if (rducks_nng_enter_op(&state->ops_state) != 0) {
    pool->closing = 0;   // restore
    *pool_ptr = pool;    // un-null the caller's pointer
    return;
}
```

When `rducks_nng_client_pool_destroy` is called during an NNG quiesce,
`enter_op` fails and the code resets `pool->closing = 0` and restores
`*pool_ptr`. At this point `begin_close` has already set `refs` to 0, so
the pool’s reference count no longer reflects real usage. Any subsequent
`rducks_nng_client_pool_acquire` call will succeed (pool pointer is
restored, `closing == 0`) but the pool’s internal `refs` counter is at
0, meaning the first release will underflow. The correct action when
`enter_op` fails during destroy is to leave `closing == 1` and allow the
caller to retry or free the pool unconditionally after the quiesce
completes.

------------------------------------------------------------------------

### 11.2 Global preserve-release queue not scoped per runtime

**File:** `tools/ext/src/rducks_runtime.c` lines 106–109  
**Severity:** Low

``` c
static _Atomic(rducks_preserved_node_t *) g_preserved_release_head = NULL;
static _Atomic(rducks_preserved_node_t *) g_preserved_release_tail = NULL;
static _Atomic(size_t) g_preserved_queued  = 0;
static _Atomic(size_t) g_preserved_released = 0;
```

These are process-global statics shared by all `rducks_runtime_entry_t`
instances. `rducks_preserved_release_drain_on_main(runtime)` gates
draining on `rducks_is_main_thread(runtime)`, which is per-runtime. If
two databases are opened from different threads (each with a different
“main thread” token), only one runtime’s drain call matches the actual R
thread. Deferred releases for the other runtime accumulate indefinitely,
leaking SEXP-protect slots. In practice R is single-threaded so all
runtimes share the same main thread, but the architecture couples a
per-runtime predicate to a global queue without documenting that
assumption.

------------------------------------------------------------------------

### 11.3 `rducks_runtime_reset_udf_stats_locked` — asymmetric counter reset

**File:** `tools/ext/src/rducks_runtime.c` lines 418–438  
**Severity:** Low

The function zeros most counters but silently preserves
`ripc_inflight_current`, `queue_pending_current`, `dispatch_chunks`, and
`dispatch_rows` without explanation. It then re-seeds
`queue_pending_max` and `ripc_inflight_max` from the preserved current
values, which means a reset during a burst of in-flight work will
immediately raise the new max to the current load. Neither the function
name nor any comment documents which counters are intentionally
preserved vs zeroed, making it impossible to reason about the semantics
from a call site. A brief comment listing the invariant (“current-state
gauges are preserved; accumulator counters are zeroed”) would suffice.

------------------------------------------------------------------------

### 11.4 `rducks_r_aggregate_update_vectorized` — O(n²) distinct-state deduplication

**File:** `tools/ext/src/rducks_aggregate.c` lines 258–290  
**Severity:** Low

``` c
/* linear scan over growing distinct_states array */
for (int k = 0; k < state_count; k++) {
    if (distinct_states[k] == states[i]) { found = 1; break; }
}
if (!found) distinct_states[state_count++] = states[i];
```

For a chunk of `n` rows the inner loop is O(n) per row → O(n²) total.
DuckDB standard vector size is 2048 rows; at that size this is ~2M
pointer comparisons per call. For aggregates over large tables (many
chunks) the aggregate update function is called repeatedly and the cost
compounds. A hash set (or sorting `distinct_states` and using `bsearch`)
would reduce this to O(n log n).

------------------------------------------------------------------------

### 11.5 Error-message buffers truncated at 255 bytes in aggregate callbacks

**File:** `tools/ext/src/rducks_aggregate.c` lines ~280, ~470, ~710  
**Severity:** Low

Every aggregate callback (update, combine, finalize) uses a 256-byte
stack buffer:

``` c
char err[256] = {0};
...
snprintf(err, sizeof(err), "%s", rducks_r_condition_message(cond));
```

R condition messages from complex aggregate errors (long column names,
deeply nested function calls, tibble print output appended to message)
can exceed 255 bytes. The message is silently truncated before being
forwarded to DuckDB’s error channel, making the resulting SQL error
harder to diagnose. Using `rducks_r_condition_message` + `strlen` + a
heap allocation (falling back to the 256-byte buffer on allocation
failure) would preserve the full message.

------------------------------------------------------------------------

### 11.6 `rducks_ipc_globals_for_function_codetools` — O(n²) seen-function scan

**File:** `R/ipc_worker.R` lines 133–170  
**Severity:** Low

``` r

if (any(vapply(seen, identical, logical(1), current))) next
seen <- c(seen, list(current))
```

`seen` is a plain list; membership test is O(\|seen\|) per function. For
closures that capture other closures recursively the `seen` list grows
with each new function, making the total cost O(n²) in the number of
distinct closures. The same file already uses an environment for O(1)
global-name deduplication (`seen_globals`). Replacing the `seen` list
with an environment keyed on `rlang::obj_address(current)` (or
`data.table::address`) would give O(1) lookup and eliminate the
quadratic scaling.

------------------------------------------------------------------------

## Section 12 — Arrow/RC direct path, UNION layout coupling, streaming table leak, enum index scan

### 12.1 UNION direct path relies on undocumented DuckDB internal vector layout

**File:** `tools/ext/src/rducks_rc.c` lines 1427–1444  
**Severity:** Medium

``` c
/* DuckDB's pinned vector layout stores UNION as a STRUCT: child 0 is a
 * uint8 tag vector and children 1..n are member vectors. The C API has
 * no union-vector accessors, so this direct path deliberately uses the
 * struct child accessor against that tested DuckDB layout.
 */
duckdb_vector tag_vector = duckdb_struct_vector_get_child(input->vector, 0);
...
duckdb_vector member_vector = duckdb_struct_vector_get_child(input->vector, (idx_t)tag + 1U);
```

The comment acknowledges that this uses an internal DuckDB memory layout
not exposed by the stable C API. If DuckDB changes its UNION vector
representation (e.g., moves the tag to a separate metadata slot or
reorders children), this code will silently produce wrong results or
crash. Since `duckdb_union_vector_get_member` and similar accessors are
absent from the vendored DuckDB C API header, the coupling is
unavoidable for now — but it should be prominently flagged in
`docs/SUPPORT_MATRIX.md` or a comment near the DuckDB version pin, so
any DuckDB upgrade bump triggers a review of this path.

------------------------------------------------------------------------

### 12.2 Streaming table R result never closed when bind is destroyed off the main thread

**File:** `tools/ext/src/rducks_table.c` lines 58–76  
**Severity:** Low

``` c
static void rducks_r_table_close_stream_if_main(rducks_r_table_bind_t *bind) {
    ...
    if (!bind->streaming || ... || !rducks_is_main_thread(bind->meta->runtime)) {
        return;   // silent no-op
    }
```

When DuckDB destroys a table-function bind on a non-main thread (e.g.,
query cancellation or error rollback), the streaming result object is
never closed: `rducks_r_table_close_stream_if_main` returns immediately
because the thread check fails, and no deferred-close path exists. The R
streaming result accumulates state (file handles, connections, temporary
data) until the next GC cycle that happens to finalize the SEXP — which
may be unboundedly late. Adding a deferred release via
`rducks_preserved_release_enqueue` (which already exists for SEXP
lifetime) adapted to call the close function on the R thread during the
next drain would fix this.

------------------------------------------------------------------------

### 12.3 `rducks_rc_enum_value_index` — O(n) level scan per row for enum output

**File:** `tools/ext/src/rducks_rc.c` lines 1063–1098  
**Severity:** Low

``` c
for (size_t i = 0; i < desc->field_count; i++) {
    if (strcmp(value_text, desc->field_names[i]) == 0) {
        *index_out = (uint32_t)i;
        return 1;
    }
}
```

The function is called once per output row for `arrow_c` enum return
values. For a UDF with a wide enum type (hundreds of levels) and a large
chunk (2048 rows), this is `2048 × n_levels` string comparisons per
chunk. Building a hash map from level name to index at registration time
(stored in `rducks_type_desc_t`) and doing O(1) lookups here would
eliminate the hot loop.

------------------------------------------------------------------------

### 12.4 `rducks_rc_direct_sequence_child_supported` excludes types supported at top level

**File:** `tools/ext/src/rducks_rc.c` lines 185–213 vs 215–267  
**Severity:** Low

`rducks_rc_direct_sequence_child_supported` excludes `I64`, `U64`,
`HUGEINT`, `UHUGEINT`, `UUID`, `INTERVAL`, `BLOB`, and `BIT` — types
that are fully supported as top-level scalar UDF arguments and return
values. This means a UDF returning `LIST(I64)` or `ARRAY(UUID)` cannot
use the `arrow_c` plan and falls back to `arrow_r`, while a UDF
returning a bare `I64` can use `arrow_c`.

The asymmetry is intentional (R lacks native 64-bit integers and BLOBs
as vector primitives) but is not documented anywhere visible. A note in
`docs/SUPPORT_MATRIX.md` listing the excluded child types and the
rationale would prevent future surprises when adding new type support.

------------------------------------------------------------------------

## Section 13 — Table Parameters, Extension Entrypoint, and Connection Refresh

### 13.1 I64/U64 table-function parameters silently lose precision via double

**File:** `tools/ext/src/rducks_table.c` lines 338–354  
**Severity:** Low

`rducks_r_table_int64_scalar` and `rducks_r_table_uint64_scalar` extract
`DUCKDB_TYPE_BIGINT`, `DUCKDB_TYPE_UBIGINT`, and
`DUCKDB_TYPE_INTEGER_LITERAL` bind parameters by casting them through a
C `double`:

``` c
static SEXP rducks_r_table_int64_scalar(duckdb_bind_info info, idx_t idx) {
    int64_t v = duckdb_bind_get_parameter(info, idx).value.bigint;
    return Rf_ScalarReal((double)v);   // precision lost for |v| > 2^53
}
```

Any integer value with absolute value greater than 2^53 is rounded to
the nearest representable double before it reaches R. The scalar UDF
path avoids this by returning an `rducks_bigint`-classed character
string for I64/U64 values; the same strategy should be applied here. A
table function accepting a `BIGINT` row-count parameter would silently
truncate values above 9 007 199 254 740 992 without any error or
warning.

------------------------------------------------------------------------

### 13.2 Running-timeout stub has no documentation

**File:** `tools/ext/src/rducks_surfaces.c` line 528  
**Severity:** Trivial

``` c
static bool rducks_queue_running_timeout_supported_scalar(
        rducks_runtime_t *runtime, SEXP call) {
    (void)runtime; (void)call;
    return false;
}
```

The function permanently returns `false` — no running-timeout mechanism
is implemented. This is correct behavior for the current state of the
code, but there is no doc comment, no `docs/` note, and no user-visible
message when the feature is requested explaining the limitation or
suggesting a workaround. A brief note in `docs/EXECUTION_PLANS.md` or in
the R-level `register_udf()` documentation would set accurate
expectations.

------------------------------------------------------------------------

### 13.3 `rducks_runtime_refresh_connection` forgets UDF registry before acquiring lock

**File:** `tools/ext/src/rducks_surfaces.c` lines 830–901  
**Severity:** Medium

The refresh path calls `rducks_runtime_forget_udf_registry(runtime)`
(which clears the in-memory UDF map) and
`rducks_query_stream_close_all(runtime)` **before** acquiring the
runtime mutex that guards `runtime->connection`:

``` c
rducks_query_stream_close_all(runtime);          // line ~840
rducks_runtime_forget_udf_registry(runtime);     // line ~845
// ...
pthread_mutex_lock(&runtime->lock);              // line ~879
rducks_runtime_swap_connection(runtime, new_conn);
pthread_mutex_unlock(&runtime->lock);
```

Between the `forget` call and the lock acquisition, any concurrent
DuckDB callback that reads `runtime->connection` still sees the old
connection, but the UDF registry no longer knows about the functions
registered on it. If a concurrent thread invokes a registered UDF during
that window it will find no matching entry and likely crash or return a
null function pointer.

The UDF registry forget and the connection swap should be performed
atomically under the same lock, or the old connection should be quiesced
(all in-flight callbacks drained) before the registry is cleared.

------------------------------------------------------------------------

### 13.4 Extension entrypoint registration-surface race on concurrent load

**File:** `tools/ext/src/rducks_surfaces.c` lines 903–952  
**Severity:** Medium

In `DUCKDB_EXTENSION_ENTRYPOINT` the readiness check and the surface
registration are not performed under a single lock:

``` c
if (!rducks_registration_surface_available(connection)) {   // line ~928
    rducks_register_all_surfaces(connection);               // line ~931
    rducks_set_registration_surface_ready(runtime);         // line ~934  (under lock)
}
```

If two connections load the extension concurrently both can observe
`!surface_available` before either sets the ready flag. Both then call
`rducks_register_all_surfaces`, which will attempt to
`CREATE OR REPLACE` scalar functions twice. The second registration
either silently succeeds (masking the race) or fails with an opaque
DuckDB error that is not surfaced to the user. The ready flag should be
set (or an atomic compare-and-swap performed) **before** the
registration call, with appropriate rollback on failure, or the entire
check-and-register block should be executed under a single lock.

------------------------------------------------------------------------

## Section 14 — Test Coverage Gaps

All 36 test files were reviewed. The suite is broad and well-structured.
The following gaps were identified.

### 14.1 No test for BIGINT/UBIGINT table function parameter precision

**Relevant finding:** Section 13.1  
**Severity:** Low

`test_duckdb_runtime_table_function.R` exercises table function
parameters via `rducks_table_args` but all parameters are character,
boolean, integer, and `list/struct` — none pass a `BIGINT` or `UBIGINT`
value. There is no test that passes a value with absolute value greater
than 2^53 to verify that it is received correctly (or that the
precision-loss bug described in 13.1 is caught).

------------------------------------------------------------------------

### 14.2 `exception_handling = "return_null"` not tested with owned-result return types

**Relevant finding:** Section 11.5 (aggregate error buffer), Section
13.1  
**Severity:** Low

`test_duckdb_runtime_null_error.R` tests
`exception_handling = "return_null"` only for scalar `INTEGER` →
`INTEGER` UDFs. There is no test that combines
`exception_handling = "return_null"` with a `LIST(...)` or `STRUCT(...)`
return type under `arrow_c+inproc_concurrent`, which exercises the
owned-result payload path. The `arrow_c` error-null test in the same
file also uses only scalar primitives.

------------------------------------------------------------------------

### 14.3 No test for `rducks_runtime_refresh_connection`

**Relevant finding:** Section 13.3  
**Severity:** Medium

No test file exercises `rducks_runtime_refresh_connection` (the function
that replaces a live DuckDB connection underneath a running runtime).
The concurrent hazard (section 13.3) and the correctness of the UDF
registry after a refresh are entirely untested. A test that registers a
UDF, calls `refresh_connection`, and then confirms the UDF still
executes correctly would catch regressions and validate the ordering fix
if implemented.

------------------------------------------------------------------------

### 14.4 No test for concurrent extension load race

**Relevant finding:** Section 13.4  
**Severity:** Medium

`test_zzzz_duckdb_runtime_lifecycle.R` exercises multiple connections
sharing the same DuckDB driver instance, but both connections call
`rducks_enable` sequentially, not concurrently. The extension-entrypoint
race (section 13.4) can only be triggered if two threads call
`rducks_enable` (and thus `DUCKDB_EXTENSION_ENTRYPOINT`) simultaneously.
No test does this.

------------------------------------------------------------------------

### 14.5 NNG pool pool-destroy half-close not tested

**Relevant finding:** Section 11.1  
**Severity:** Low

`test_duckdb_runtime_nng_10_lifecycle.R` calls `rducks_release(con)` and
confirms that providers are removed (`length(provider_records()) == 0`),
but does not confirm that in-flight NNG messages are drained before the
socket is closed. The half-close path (quiesce `rducks_nng_quiesce_pool`
before `rducks_nng_pool_destroy`) is not covered by a test that starts
an operation and calls release concurrently.

------------------------------------------------------------------------

### 14.6 UNION arrow_c tested only with single-value input

**Relevant finding:** Section 12.1  
**Severity:** Trivial

`test_duckdb_runtime_enum_bit_union_blob.R` tests UNION via `arrow_c`
with a single-row input (one `union_value`). Batched UNION output where
multiple tags appear across rows in the same chunk is not exercised. The
internal `rducks_rc_direct_union_write` layout code (which relies on
DuckDB UNION internal representation) has no multi-row, multi-tag chunk
test.

------------------------------------------------------------------------

### 14.7 Streaming table bind lifecycle (bind destroy off main thread) not isolated

**Relevant finding:** Section 12.2  
**Severity:** Low

All streaming table tests in `test_duckdb_runtime_table_function.R` call
the table function in a single serial query. The section-12.2 concern
was that the `rducks_table_stream` bind data object may be destroyed on
a DuckDB worker thread if DuckDB discards it during scan cancellation or
query abort. No test triggers a query abort mid-scan (e.g. via `LIMIT`
that truncates before all rows are fetched with an explicit DuckDB
interrupt) to confirm that `rducks_table_bind_data_destroy` runs safely
on the R thread or is thread-safe.

------------------------------------------------------------------------

### 14.8 `rducks_runtime_stats` `udf_stat_counter` reset path not tested

**Relevant finding:** Section 11.3  
**Severity:** Trivial

`test_zzzz_duckdb_runtime_lifecycle.R` reads `rducks_runtime_stats` and
checks field names and non-negative values, but never calls the stat
counter reset surface and then re-checks, so the reset functionality is
untested.

------------------------------------------------------------------------

### 14.9 Multi-database (ATTACH) scenario not tested

**Severity:** Low

No test file attaches a second DuckDB database and calls a registered
UDF from within a cross-database query, or registers UDFs on two
separate DuckDB driver instances in the same process. The runtime’s
per-database registry keying and the `registration_surface_available`
check across databases are therefore not exercised.

------------------------------------------------------------------------

## Summary

The review covered all R source files (~19 files), all C extension
source files (~15 files, ~18 000 lines of C), and all 36 test files
under `inst/tinytest/`. A total of **72 findings** were recorded across
14 sections.

### Findings by severity

| Severity | Count |
|----------|-------|
| High     | 5     |
| Medium   | 16    |
| Low      | 33    |
| Trivial  | 18    |

### High and Medium findings (action recommended)

| ID | Short description | Severity |
|----|----|----|
| 3.2 | `rducks_result_error` truncates at 512 bytes; long errors silently cut | Medium |
| 4.1 | `rducks_nng_worker_init` allocation failure leaves socket open | High |
| 4.2 | `rducks_parallel_range` unchecked `duckdb_validity_set_row_validity` | Medium |
| 5.1 | `rducks_arrow_batch_validate` duplicated across three call sites | Medium |
| 6.1 | `rducks_register_scalar_udf` accepts `NULL` R function silently | Medium |
| 8.3 | Arrow batch validation duplicated vs. single canonical copy | Medium |
| 10.1 | NNG IPC worker ignores `ipc_timeout` per-call cancellation | High |
| 10.2 | `rducks_ipc_nng_pool_destroy` does not quiesce before socket close | High |
| 10.3 | Provider NNG wire missing input length validation | Medium |
| 11.1 | Pool destroy half-close: `rducks_nng_quiesce_pool` not called | High |
| 11.4 | O(n²) distinct-state dedup in aggregate finalize_chunk | Medium |
| 11.6 | O(n) seen-function scan per UDF lookup | Medium |
| 12.2 | Streaming table bind may be destroyed off main thread | Medium |
| 12.3 | O(n) enum level scan per output row in `arrow_c` path | Medium |
| 13.3 | `rducks_runtime_refresh_connection` forgets UDF registry before lock | Medium |
| 13.4 | Extension entrypoint registration-surface race on concurrent load | Medium |

### Positive observations

- The owned-result payload system (`rducks_rc.c`) is carefully designed:
  the `R_tryCatchError` + `R_UnwindProtect` double fence is correct and
  the lifetime discipline is explicit.
- The `arrow_c` direct scalar path correctly handles all 25+ DuckDB
  primitive types including 128-bit integers, decimals, UUIDs,
  intervals, and BLOBs.
- The type parser/serializer in `rducks_types.c` is consistent,
  OOM-guarded, and round-trips correctly.
- The inproc concurrent queue has a comprehensive test harness including
  snapshot VARCHAR, owned LIST/STRUCT results, and vectorized modes.
- The NNG lifecycle tests cover provider creation, start/stop, external
  endpoints, and release-under-load scenarios.
- The lifecycle tests (`test_zzzz_duckdb_runtime_lifecycle.R`) are
  thorough on GC-driven teardown, connection-key uniqueness, and
  cross-connection UDF visibility.
