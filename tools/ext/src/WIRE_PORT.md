# Extension wire port — remaining work

quack_core.{c,h} now compiles into the extension; it is thread-safe and may
run on DuckDB execution threads. Remaining surgery, in order:

1. rducks_wire.c (new): DuckDB DataChunk <-> rdx_qk_chunk adapters via the
   C API (duckdb_data_chunk_get_vector, duckdb_vector_get_data/validity,
   duckdb_list_vector_*, duckdb_struct_vector_get_child), then
   rdx_qk_chunk_encode/decode for RIPC task payloads and the direct-evaluator
   slow path (replaces tools/ext/src/rducks_arrow.c entirely; delete it).
2. rducks_rc.c: replace the internal ArrowArray/ArrowSchema carriers with
   rdx_qk_vector and the format-string schema plumbing with rdx_qk_type;
   the fast-path SEXP fills are unaffected. The R-side bundle already expects
   quack payloads on the slow path (prepare_inputs/result fields).
3. rducks_query_stream.c / rducks_table.c: emit/consume quack payloads
   (R side already does: rducks_table_result_payload, wire decode).
4. Byte fixtures against upstream DuckDB BinarySerializer before claiming
   cross-implementation Quack compatibility (pair field ids 0/1, enum field
   ordering, validity word width) — see ducknng's protocol study.
