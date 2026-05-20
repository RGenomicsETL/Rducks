# Rducks Function Catalog

Generated from `inst/function_catalog/functions.json` by
`tools/generate_function_catalog.R`.

## `rducks_enable`

- Kind: `R function`
- Category: `connection`
- Signature: `rducks_enable(con, extension_path = rducks_extension_path(), threads = c('single', 'multi'))`
- Returns: `duckdb_connection invisibly`
- Lifecycle: `experimental`
- Since: `0.1.0`

Load the bundled Rducks DuckDB extension into a DuckDB connection and configure Arrow conversion options required by Rducks typed marshalling.

Notes:

- R-backed registration requires the recorded R thread; use threads = 'single' for ordinary R callback work.
- The extension installs native SQL support functions used by the R wrappers.

## `rducks_release`

- Kind: `R function`
- Category: `connection`
- Signature: `rducks_release(con)`
- Returns: `duckdb_connection invisibly`
- Aliases: `rducks_detach`
- Lifecycle: `experimental`
- Since: `0.1.0`

Detach connection-local Rducks state and stop local IPC workers associated with the connection's DuckDB runtime when the last attachment is released.

Notes:

- This does not drop DuckDB catalog functions or release closures still owned by native catalog metadata.

## `rducks_extension_path`

- Kind: `R function`
- Category: `connection`
- Signature: `rducks_extension_path()`
- Returns: `character scalar`
- Lifecycle: `experimental`
- Since: `0.1.0`

Return the installed path to the bundled rducks.duckdb_extension artifact used by rducks_enable().

## `rducks_register_scalar_udf`

- Kind: `R function / DuckDB scalar UDF registration`
- Category: `registration`
- Signature: `rducks_register_scalar_udf(con, name, fun, args, returns, mode = c('scalar', 'vectorized'), null_handling, exception_handling, side_effects, ...)`
- Returns: `rducks_scalar_udf_registration`
- Lifecycle: `experimental`
- Since: `0.1.0`

Register an R function as a DuckDB scalar UDF. DuckDB receives one SQL value per logical row; Rducks mode controls whether R is called once per row or once per DuckDB chunk.

Notes:

- If args is omitted, DuckDB binds concrete argument types at each SQL call site and Rducks uses those descriptors for marshalling.
- The return type must be explicit because DuckDB requires a known scalar return type at bind/planning time.
- Execution plans choose marshalling and concurrency without changing SQL type, NULL, or result semantics.

## `rducks_register_table`

- Kind: `R function / DuckDB table-function registration`
- Category: `registration`
- Signature: `rducks_register_table(con, name, fun, parameter_count = NULL, chunk_size = 2048L)`
- Returns: `rducks_table_registration`
- Lifecycle: `experimental`
- Since: `0.1.0`

Register an R function as a DuckDB table function. The R function is called at table-function bind time and may return a data frame, list, nanoarrow batch/stream, or rducks_table_stream().

## `rducks_table_stream`

- Kind: `R function / table result constructor`
- Category: `registration`
- Signature: `rducks_table_stream(prototype, next_batch, close = NULL, cardinality = NULL, exact = FALSE)`
- Returns: `rducks_table_stream`
- Lifecycle: `experimental`
- Since: `0.1.0`

Create a scan-time streaming result object for rducks_register_table(). next_batch() is called repeatedly and returns batches until it returns NULL.

Notes:

- The prototype supplies the table schema without materializing all rows up front.
- Returned batches can be data frames, named lists, nanoarrow arrays, or one-batch nanoarrow streams.

## `rducks_register_aggregate`

- Kind: `R function / DuckDB aggregate registration`
- Category: `registration`
- Signature: `rducks_register_aggregate(con, name, initialize, update, combine, finalize, args, state, returns)`
- Returns: `rducks_aggregate_registration`
- Lifecycle: `experimental`
- Since: `0.1.0`

Register an R aggregate function in DuckDB using explicit state and return descriptors.

## `rducks_query_stream`

- Kind: `R function / native DuckDB query stream`
- Category: `query consumption`
- Signature: `rducks_query_stream(con, sql, batch_size = 1024L, format = c('data.frame', 'record_batch', 'nanoarrow'))`
- Returns: `rducks_query_stream`
- Lifecycle: `experimental`
- Since: `0.1.0`

Open a true native DuckDB streaming-result cursor and consume it as R data-frame batches or owned nanoarrow record batches.

Notes:

- Only one active native query stream is supported per Rducks runtime connection in the current implementation.
- format = 'record_batch' and format = 'nanoarrow' return a nanoarrow_array with schema metadata.

## `rducks_execution_plan`

- Kind: `R function / execution-plan descriptor`
- Category: `execution plans`
- Signature: `rducks_execution_plan(marshalling = c('arrow_r', 'arrow_c', 'arrow_ipc'), concurrency = c('serial', 'inproc_concurrent', 'multiprocess_parallel'), ...)`
- Returns: `rducks_execution_plan`
- Lifecycle: `experimental`
- Since: `0.1.0`

Build a scalar-UDF execution-plan descriptor that selects the marshalling backend and concurrency model used at registration time.

Notes:

- Supported combinations are arrow_r/serial, arrow_r/inproc_concurrent, arrow_c/serial, arrow_c/inproc_concurrent, and arrow_ipc/multiprocess_parallel.
- The Arrow IPC plan uses native NNG request/reply transport with persistent R worker processes.

## `rducks_set_execution_plan`

- Kind: `R function`
- Category: `execution plans`
- Signature: `rducks_set_execution_plan(con, plan, threads = NULL, external_threads = NULL)`
- Returns: `rducks_execution_plan invisibly`
- Lifecycle: `experimental`
- Since: `0.1.0`

Set the current scalar-UDF execution plan for future registrations on a connection and optionally update DuckDB thread settings.

Notes:

- Already-registered scalar UDFs keep the plan captured in their catalog metadata.

## `rducks_current_execution_plan`

- Kind: `R function`
- Category: `execution plans`
- Signature: `rducks_current_execution_plan(con)`
- Returns: `rducks_execution_plan`
- Lifecycle: `experimental`
- Since: `0.1.0`

Inspect the default execution plan that will be used for later scalar-UDF registrations on a connection.

## `rducks_native_execution_backend`

- Kind: `R function`
- Category: `execution plans`
- Signature: `rducks_native_execution_backend(con)`
- Returns: `character scalar`
- Lifecycle: `experimental`
- Since: `0.1.0`

Inspect the native execution backend currently recorded by the loaded extension for the connection.

## `rducks_mode_semantics`

- Kind: `R function`
- Category: `execution plans`
- Signature: `rducks_mode_semantics(mode = NULL)`
- Returns: `data.frame or list`
- Lifecycle: `experimental`
- Since: `0.1.0`

Describe the semantics of scalar and vectorized Rducks scalar-UDF evaluation modes.

## `rducks_ipc_workers`

- Kind: `R function`
- Category: `diagnostics`
- Signature: `rducks_ipc_workers(con = NULL, ping = FALSE, timeout = 1)`
- Returns: `rducks_ipc_workers data.frame`
- Lifecycle: `experimental`
- Since: `0.1.0`

List Rducks-managed Arrow IPC/NNG worker providers currently known to this R process, optionally filtered to one DuckDB runtime and optionally pinged.

Notes:

- The result has one row per configured worker endpoint and includes provider backend, compute name, transport, endpoint, task state, and ping status.
- Caller-supplied ipc_endpoints are shown as external providers.

## `rducks_explain_udf`

- Kind: `R function`
- Category: `diagnostics`
- Signature: `rducks_explain_udf(con, name)`
- Returns: `data.frame`
- Lifecycle: `experimental`
- Since: `0.1.0`

Explain a registered Rducks scalar UDF, including its mode, plan, signature, counters, and native/R-side metadata where available.

## `rducks_list_udfs`

- Kind: `R function`
- Category: `diagnostics`
- Signature: `rducks_list_udfs(con)`
- Returns: `data.frame`
- Lifecycle: `experimental`
- Since: `0.1.0`

List scalar UDFs known to the Rducks registry for a connection's DuckDB runtime.

Notes:

- This is an Rducks scalar-UDF registry view, not a complete DuckDB catalog listing.

## `rducks_reset_udf_counters`

- Kind: `R function`
- Category: `diagnostics`
- Signature: `rducks_reset_udf_counters(con, name = NULL)`
- Returns: `logical scalar`
- Lifecycle: `experimental`
- Since: `0.1.0`

Reset native scalar-UDF execution counters for one registered function or for all functions in the runtime registry.

## `rducks_inproc_stats`

- Kind: `R function`
- Category: `diagnostics`
- Signature: `rducks_inproc_stats(con)`
- Returns: `data.frame`
- Lifecycle: `experimental`
- Since: `0.1.0`

Inspect counters for the in-process queued scalar-UDF execution path.

## `rducks_release_stats`

- Kind: `R function`
- Category: `diagnostics`
- Signature: `rducks_release_stats(con)`
- Returns: `data.frame`
- Lifecycle: `experimental`
- Since: `0.1.0`

Inspect counters for preserved R objects that were queued and released by Rducks native cleanup paths.

## `rducks_runtime_stats`

- Kind: `R function`
- Category: `diagnostics`
- Signature: `rducks_runtime_stats(con)`
- Returns: `data.frame`
- Lifecycle: `experimental`
- Since: `0.1.0`

Inspect native runtime registry counters such as active entries, stale entries, and extension-owned connection opens/closes.

## `rducks_enable_inproc`

- Kind: `R function`
- Category: `execution plans`
- Signature: `rducks_enable_inproc(con, threads = NULL, external_threads = NULL)`
- Returns: `logical scalar invisibly`
- Lifecycle: `experimental`
- Since: `0.1.0`

Compatibility helper that enables the in-process queued scalar-UDF backend for later registrations.

Notes:

- Prefer rducks_set_execution_plan(con, rducks_execution_plan('arrow_r', 'inproc_concurrent')) for new code.

## `rducks_disable_inproc`

- Kind: `R function`
- Category: `execution plans`
- Signature: `rducks_disable_inproc(con, threads = NULL, external_threads = NULL)`
- Returns: `logical scalar invisibly`
- Lifecycle: `experimental`
- Since: `0.1.0`

Compatibility helper that restores the serial native backend for later registrations.

Notes:

- Prefer rducks_set_execution_plan(con, rducks_execution_plan('arrow_r', 'serial')) for new code.

## `rducks_inproc_self_test`

- Kind: `R function`
- Category: `diagnostics`
- Signature: `rducks_inproc_self_test(con, iterations = 1L)`
- Returns: `numeric scalar`
- Lifecycle: `experimental`
- Since: `0.1.0`

Exercise the native in-process queue and return the number of self-test iterations completed by the extension.

## `rducks_with_duckplyr`

- Kind: `R function / duckplyr integration`
- Category: `integration`
- Signature: `rducks_with_duckplyr(con, expr, returns, mode = c('scalar', 'vectorized'), ...)`
- Returns: `value of expr`
- Aliases: `with.duckdb_connection`
- Lifecycle: `experimental`
- Since: `0.1.0`

Evaluate duckplyr code with ordinary R calls in expressions resolved to dynamic Rducks scalar UDFs instead of falling back to local R execution.

Notes:

- DuckDB still requires explicit return descriptors through returns/rducks_returns.
- The bridge defaults to scalar row-call mode; vectorized mode is available for helpers that accept full chunks and return same-length vectors.
- The selected connection execution plan controls arrow_r, arrow_c, or arrow_ipc marshalling.

## `rducks_type_objects`

- Kind: `R type descriptors / constructors`
- Category: `types`
- Signature: `BOOLEAN; INTEGER; DOUBLE; DECIMAL(width, scale); ENUM(levels); LIST(type); ARRAY(type, size); MAP(key, value); STRUCT(...); UNION(...)`
- Returns: `rducks_type descriptor`
- Aliases: `rducks_is_type`, `BOOLEAN`, `TINYINT`, `UTINYINT`, `SMALLINT`, `USMALLINT`, `INTEGER`, `UINTEGER`, `BIGINT`, `UBIGINT`, `FLOAT`, `DOUBLE`, `VARCHAR`, `BLOB`, `DATE`, `TIME`, `TIMESTAMP`, `HUGEINT`, `UHUGEINT`, `UUID`, `INTERVAL`, `BIT`, `DECIMAL`, `ENUM`, `LIST`, `ARRAY`, `MAP`, `STRUCT`, `UNION`
- Lifecycle: `experimental`
- Since: `0.1.0`

Provide formal Rducks descriptors for DuckDB scalar, exact, temporal, and composite SQL types used in registrations and value checks.

## `rducks_type_token`

- Kind: `R function`
- Category: `types`
- Signature: `rducks_type_token(type); rducks_type_sql(type); rducks_type_kind(type); rducks_type_children(type); rducks_type_child_names(type); rducks_type_size(type); rducks_type_parameters(type)`
- Returns: `character, integer, list, or descriptor metadata`
- Aliases: `rducks_type_sql`, `rducks_type_kind`, `rducks_type_children`, `rducks_type_child_names`, `rducks_type_size`, `rducks_type_parameters`
- Lifecycle: `experimental`
- Since: `0.1.0`

Inspect normalized Rducks type descriptors and their DuckDB SQL spelling, kind, child descriptors, child names, size, and parameters.

## `rducks_type_normalize`

- Kind: `R function`
- Category: `types`
- Signature: `rducks_type_normalize(x)`
- Returns: `rducks_type descriptor`
- Lifecycle: `experimental`
- Since: `0.1.0`

Normalize quoted type tokens, descriptor objects, or descriptor lists into canonical Rducks type descriptors.

## `rducks_duckdb_types`

- Kind: `R function`
- Category: `types`
- Signature: `rducks_duckdb_types(types)`
- Returns: `character vector`
- Lifecycle: `experimental`
- Since: `0.1.0`

Convert Rducks type descriptors to DuckDB SQL type strings.

## `rducks_duckdb_signature`

- Kind: `R function`
- Category: `types`
- Signature: `rducks_duckdb_signature(name, args, returns)`
- Returns: `character scalar`
- Lifecycle: `experimental`
- Since: `0.1.0`

Format a DuckDB scalar function signature from an Rducks function name, argument descriptors, and return descriptor.

## `rducks_argument_type_mapping`

- Kind: `R function`
- Category: `semantics`
- Signature: `rducks_argument_type_mapping(type = NULL)`
- Returns: `data.frame or list`
- Lifecycle: `experimental`
- Since: `0.1.0`

Describe how Rducks argument descriptors are materialized and passed to R functions, including copy and borrow behavior.

## `rducks_check_value`

- Kind: `R function`
- Category: `types`
- Signature: `rducks_check_value(type, x, size = NULL, what = 'value')`
- Returns: `x invisibly on success`
- Aliases: `rducks_check_argument`, `rducks_check_return`
- Lifecycle: `experimental`
- Since: `0.1.0`

Validate that an R value is compatible with a DuckDB/Rducks type descriptor before using it as an argument or return value.

## `rducks_value_semantics`

- Kind: `R function`
- Category: `semantics`
- Signature: `rducks_value_semantics(topic = NULL)`
- Returns: `data.frame or list`
- Lifecycle: `experimental`
- Since: `0.1.0`

Describe Rducks NULL, NA, NaN, Inf, and exception-handling semantics for scalar-UDF arguments and returns.

## `rducks_value_type`

- Kind: `R function`
- Category: `value classes`
- Signature: `rducks_value_type(x); rducks_duckdb_literal(x)`
- Returns: `character scalar`
- Aliases: `rducks_duckdb_literal`
- Lifecycle: `experimental`
- Since: `0.1.0`

Inspect Rducks exact value classes and format them as DuckDB SQL literals when supported.

## `rducks_bigint`

- Kind: `R value constructor`
- Category: `value classes`
- Signature: `rducks_bigint(x = character())`
- Returns: `rducks_bigint vector`
- Lifecycle: `experimental`
- Since: `0.1.0`

Construct exact DuckDB BIGINT values backed by character strings for boundary-safe marshalling.

## `rducks_ubigint`

- Kind: `R value constructor`
- Category: `value classes`
- Signature: `rducks_ubigint(x = character())`
- Returns: `rducks_ubigint vector`
- Lifecycle: `experimental`
- Since: `0.1.0`

Construct exact DuckDB UBIGINT values backed by character strings for unsigned 64-bit values.

## `rducks_hugeint`

- Kind: `R value constructor`
- Category: `value classes`
- Signature: `rducks_hugeint(x = character())`
- Returns: `rducks_hugeint vector`
- Lifecycle: `experimental`
- Since: `0.1.0`

Construct exact DuckDB HUGEINT values backed by character strings for signed 128-bit values.

## `rducks_uhugeint`

- Kind: `R value constructor`
- Category: `value classes`
- Signature: `rducks_uhugeint(x = character())`
- Returns: `rducks_uhugeint vector`
- Lifecycle: `experimental`
- Since: `0.1.0`

Construct exact DuckDB UHUGEINT values backed by character strings for unsigned 128-bit values.

## `rducks_decimal`

- Kind: `R value constructor`
- Category: `value classes`
- Signature: `rducks_decimal(x = character(), width, scale = 0L)`
- Returns: `rducks_decimal vector`
- Lifecycle: `experimental`
- Since: `0.1.0`

Construct exact DuckDB DECIMAL values with explicit width and scale.

## `rducks_uuid`

- Kind: `R value constructor`
- Category: `value classes`
- Signature: `rducks_uuid(x = character())`
- Returns: `rducks_uuid vector`
- Lifecycle: `experimental`
- Since: `0.1.0`

Construct DuckDB UUID values from canonical UUID strings.

## `rducks_interval`

- Kind: `R value constructor`
- Category: `value classes`
- Signature: `rducks_interval(months = 0L, days = 0L, micros = 0L)`
- Returns: `rducks_interval vector`
- Lifecycle: `experimental`
- Since: `0.1.0`

Construct DuckDB INTERVAL values with month, day, and microsecond components.

## `rducks_bits`

- Kind: `R value constructor`
- Category: `value classes`
- Signature: `rducks_bits(x = raw(), length = NULL)`
- Returns: `rducks_bits vector`
- Aliases: `rducks_bits_raw`, `rducks_bits_xor`
- Lifecycle: `experimental`
- Since: `0.1.0`

Construct DuckDB BIT values and expose helpers for raw packed bytes and bitwise exclusive-or.

## `rducks_enum`

- Kind: `R value constructor`
- Category: `value classes`
- Signature: `rducks_enum(x, levels = NULL)`
- Returns: `rducks_enum vector`
- Lifecycle: `experimental`
- Since: `0.1.0`

Construct DuckDB ENUM values with explicit dictionary levels.

## `rducks_union`

- Kind: `R value constructor`
- Category: `value classes`
- Signature: `rducks_union(tag, value)`
- Returns: `rducks_union vector/list`
- Lifecycle: `experimental`
- Since: `0.1.0`

Construct DuckDB UNION values from a tag and corresponding payload value.

## `rducks_as_date`

- Kind: `R conversion helper`
- Category: `value classes`
- Signature: `rducks_as_date(x); rducks_as_timestamp(x); rducks_as_time(x); rducks_as_interval(x); rducks_interval_between(x, y)`
- Returns: `R value shaped for Rducks temporal marshalling`
- Aliases: `rducks_as_timestamp`, `rducks_as_time`, `rducks_as_interval`, `rducks_interval_between`
- Lifecycle: `experimental`
- Since: `0.1.0`

Convert R date/time values to the exact shapes expected by Rducks temporal scalar-UDF marshalling.

## `native SQL support functions`

- Kind: `DuckDB SQL scalar functions`
- Category: `native extension surface`
- Signature: `rducks_version(); rducks_runtime_token(); rducks_register_scalar(...); rducks_register_table(...); rducks_register_aggregate(...); rducks_query_stream_open(sql); rducks_query_stream_schema(token); rducks_query_stream_next(token); rducks_query_stream_close(token)`
- Returns: `DuckDB scalar values`
- Aliases: `rducks_version`, `rducks_runtime_token`, `rducks_register_scalar`, `rducks_register_table`, `rducks_register_aggregate`, `rducks_query_stream_open`, `rducks_query_stream_schema`, `rducks_query_stream_next`, `rducks_query_stream_close`
- Lifecycle: `internal/experimental`
- Since: `0.1.0`

Built-in SQL functions installed by the Rducks extension and used by the R wrappers for registration, runtime identity, and native query-stream control.

Notes:

- Most users should call the R wrappers rather than these SQL surfaces directly.

## `native diagnostic SQL functions`

- Kind: `DuckDB SQL scalar/table functions`
- Category: `native extension surface`
- Signature: `rducks_execution_backend(); rducks_set_execution_backend(name); rducks_udf_stat(name, field); rducks_reset_udf_stats(name); queue/runtime/nng diagnostics`
- Returns: `DuckDB scalar values or diagnostic rows`
- Aliases: `rducks_execution_backend`, `rducks_set_execution_backend`, `rducks_udf_stat`, `rducks_udf_stat_fields`, `rducks_reset_udf_stats`, `rducks_queue_submitted`, `rducks_queue_executed`, `rducks_queue_timeouts`, `rducks_queue_pending_current`, `rducks_queue_pending_max`, `rducks_queue_running_current`, `rducks_queue_running_max`, `rducks_release_queue_queued`, `rducks_release_queue_released`, `rducks_release_queue_failed`, `rducks_release_queue_pending`, `rducks_runtime_registry_entries`, `rducks_runtime_active_entries`, `rducks_runtime_stale_entries`, `rducks_runtime_entries_created`, `rducks_runtime_stale_aliases`, `rducks_runtime_connections_opened`, `rducks_runtime_connections_closed`, `rducks_runtime_connection_open_failed`, `rducks_runtime_queue_init_failed`, `rducks_nng_quiesce`, `rducks_parallel_range`, `rducks_parallel_thread_probe`
- Lifecycle: `internal/experimental`
- Since: `0.1.0`

Native diagnostics and test/development helpers exposed by the extension for R wrapper introspection and focused concurrency tests.

Notes:

- Development-only surfaces such as rducks_parallel_range and rducks_parallel_thread_probe require RDUCKS_DEV_SURFACES=true.

