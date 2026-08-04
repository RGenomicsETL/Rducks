# Package index

## All functions

- [`Ops(`*`<rducks_bits>`*`)`](https://rgenomicsetl.github.io/Rducks/reference/Ops.rducks_bits.md)
  [`rducks_bits_xor()`](https://rgenomicsetl.github.io/Rducks/reference/Ops.rducks_bits.md)
  : BIT logical operations
- [`rducks_argument_type_mapping()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_argument_type_mapping.md)
  : Describe how Rducks argument values are passed to R functions
- [`rducks_as_date()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_as_date.md)
  [`rducks_as_timestamp()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_as_date.md)
  [`rducks_as_time()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_as_date.md)
  [`rducks_as_interval()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_as_date.md)
  [`rducks_interval_between()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_as_date.md)
  : Convert R date/time values to Rducks scalar-UDF shapes
- [`rducks_bigint()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_bigint.md)
  : Construct exact DuckDB BIGINT values
- [`rducks_bits()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_bits.md)
  [`rducks_bits_raw()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_bits.md)
  : Construct DuckDB BIT values
- [`rducks_check_value()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_check_value.md)
  [`rducks_check_argument()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_check_value.md)
  [`rducks_check_return()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_check_value.md)
  : Check that an R value is compatible with a DuckDB type
- [`rducks_current_execution_plan()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_current_execution_plan.md)
  : Inspect the current Rducks execution plan
- [`rducks_decimal()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_decimal.md)
  : Construct exact DuckDB DECIMAL values
- [`rducks_disable_inproc()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_disable_inproc.md)
  : Disable in-process queued scalar-UDF execution
- [`rducks_duckdb_signature()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_duckdb_signature.md)
  : Format a DuckDB scalar function signature
- [`rducks_duckdb_types()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_duckdb_types.md)
  : Convert Rducks type descriptors to DuckDB SQL types
- [`rducks_enable()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_enable.md)
  : Enable Rducks on a DuckDB connection
- [`rducks_enable_inproc()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_enable_inproc.md)
  : Enable in-process queued scalar-UDF execution
- [`rducks_enum()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_enum.md)
  : Construct DuckDB ENUM values
- [`rducks_execution_plan()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_execution_plan.md)
  : Define an Rducks execution plan
- [`rducks_explain_udf()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_explain_udf.md)
  : Explain a registered Rducks scalar UDF
- [`rducks_extension_path()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_extension_path.md)
  : Locate a version-matched Rducks DuckDB extension
- [`rducks_hugeint()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_hugeint.md)
  : Construct exact DuckDB HUGEINT values
- [`rducks_inproc_self_test()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_inproc_self_test.md)
  : Exercise the in-process queue
- [`rducks_inproc_stats()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_inproc_stats.md)
  : Inspect in-process queue counters
- [`rducks_interval()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_interval.md)
  : Construct DuckDB INTERVAL values
- [`rducks_ipc_workers()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_ipc_workers.md)
  : List Rducks-managed IPC workers
- [`rducks_list_udfs()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_list_udfs.md)
  : List registered Rducks scalar UDFs
- [`rducks_mode_semantics()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_mode_semantics.md)
  : Describe Rducks scalar-UDF evaluation mode semantics
- [`rducks_native_execution_backend()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_native_execution_backend.md)
  : Inspect the native Rducks execution backend
- [`rducks_query_stream()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_query_stream.md)
  : Stream a DuckDB query as native data-frame batches
- [`rducks_register_aggregate()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_register_aggregate.md)
  : Register an R aggregate function in DuckDB
- [`rducks_register_scalar_udf()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_register_scalar_udf.md)
  : Register an R-backed DuckDB scalar UDF
- [`rducks_register_table()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_register_table.md)
  : Register an R table function in DuckDB
- [`rducks_release()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_release.md)
  [`rducks_detach()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_release.md)
  : Detach Rducks connection-local state
- [`rducks_release_stats()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_release_stats.md)
  : Inspect preserved-object release counters
- [`rducks_reset_udf_counters()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_reset_udf_counters.md)
  : Reset Rducks scalar-UDF counters
- [`rducks_runtime_stats()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_runtime_stats.md)
  : Inspect native runtime registry counters
- [`rducks_set_execution_plan()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_set_execution_plan.md)
  : Set the Rducks execution plan for a connection
- [`rducks_table_stream()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_table_stream.md)
  : Create a streaming result for an Rducks table function
- [`rducks_type_normalize()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_normalize.md)
  : Normalize an Rducks type token
- [`rducks_is_type()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`BOOLEAN`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`TINYINT`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`UTINYINT`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`SMALLINT`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`USMALLINT`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`INTEGER`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`UINTEGER`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`BIGINT`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`UBIGINT`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`FLOAT`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`DOUBLE`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`VARCHAR`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`BLOB`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`GEOMETRY`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`VARIANT`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`DATE`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`TIME`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`TIMESTAMP`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`HUGEINT`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`UHUGEINT`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`UUID`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`INTERVAL`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`BIT`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`DECIMAL()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`ENUM()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`UNION()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`LIST()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`ARRAY()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`MAP()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  [`STRUCT()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_objects.md)
  : Rducks DuckDB type descriptors and constructors
- [`rducks_type_token()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_token.md)
  [`rducks_type_sql()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_token.md)
  [`rducks_type_kind()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_token.md)
  [`rducks_type_children()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_token.md)
  [`rducks_type_child_names()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_token.md)
  [`rducks_type_size()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_token.md)
  [`rducks_type_parameters()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_type_token.md)
  : Rducks type descriptor helpers
- [`rducks_ubigint()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_ubigint.md)
  : Construct exact DuckDB UBIGINT values
- [`rducks_uhugeint()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_uhugeint.md)
  : Construct exact DuckDB UHUGEINT values
- [`rducks_union()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_union.md)
  : Construct DuckDB UNION values
- [`rducks_uuid()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_uuid.md)
  : Construct DuckDB UUID values
- [`rducks_value_semantics()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_value_semantics.md)
  : Describe Rducks NULL, NA, NaN, and Inf semantics
- [`rducks_value_type()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_value_type.md)
  [`rducks_duckdb_literal()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_value_type.md)
  : Generic helpers for Rducks value classes
- [`rducks_variant()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_variant.md)
  : Construct a DuckDB VARIANT storage object
- [`rducks_with_duckplyr()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_with_duckplyr.md)
  [`with(`*`<duckdb_connection>`*`)`](https://rgenomicsetl.github.io/Rducks/reference/rducks_with_duckplyr.md)
  : Evaluate a duckplyr pipeline with dynamic Rducks scalar UDFs
