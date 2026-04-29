# What Rducks Copies From DuckTinyCC

DuckTinyCC is the closest working architecture precedent. Rducks should copy the
architecture selectively, not the whole extension.

## Copy/adapt

### 1. Extension entrypoint registry

Source precedent:

- `DuckTinyCC/src/ducktinycc.c`

Rducks needs the same idea: when the extension is loaded into a DuckDB database,
key long-lived state by database handle, open/keep a persistent extension
connection, and register SQL surfaces idempotently.

### 2. Generic DuckDB scalar bridge

Source precedent:

- `DuckTinyCC/src/tcc_module.c::tcc_execute_compiled_scalar_udf`

Rducks needs an equivalent `rducks_generic_scalar_callback()` that DuckDB calls
for many UDF shapes. It should read metadata from `extra_info`, decode DuckDB
vectors/chunks, call a shape-specific wrapper, and write output vectors.

### 3. Compiled signature registration

Source precedent:

- `DuckTinyCC/src/tcc_module.c::ducktinycc_register_signature`

Rducks needs an equivalent `rducks_register_compiled_signature()` that receives a
compiled wrapper pointer plus type metadata, creates a DuckDB scalar function,
sets logical argument/return types, attaches metadata, and registers the generic
bridge.

### 4. Type token to DuckDB logical type conversion

Source precedent:

- `tcc_typedesc_parse_token()`
- `tcc_typedesc_create_logical_type()`

Rducks can start with scalar tokens, then port the typedesc tree for list,
struct, map, union, and nested types when needed.

### 5. Wrapper generation pattern

Source precedent:

- `tcc_codegen_generate_wrapper_source()`

Rducks should generate small per-shape wrappers, but their target is an Rducks R
callback runtime rather than an arbitrary user C symbol.

## Do not copy initially

- the public `tcc_module` SQL surface
- pointer helper SQL functions
- system path and library probe functions
- arbitrary C source/session management
- full pointer registry
- broad TinyCC CLI/configuration surface
- all composite bridges before scalar UDFs are proven

## License note

DuckTinyCC code is MIT-licensed. If implementation code is copied verbatim,
retain attribution and license notices. Rducks is currently GPL-compatible
because it is expected to integrate tightly with Rtinycc.
