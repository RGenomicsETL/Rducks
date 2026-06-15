# Internal engine vocabulary. "direct" is the in-process evaluator that
# materializes DuckDB vectors to SEXPs in extension C on the recorded main R
# thread; "wire" is the serialized worker-process data plane (Quack-style
# DuckDB BinarySerializer chunk payloads over NNG).
rducks_plan_marshalling <- function(x) {
  match.arg(x, c("direct", "wire"))
}

rducks_plan_transport <- function(x) {
  match.arg(x, c("inproc", "ipc"))
}

rducks_plan_concurrency <- function(x) {
  match.arg(x, c("serial", "inproc_concurrent", "multiprocess_parallel"))
}

rducks_plan_backend <- function(concurrency) {
  switch(
    concurrency,
    serial = "single",
    inproc_concurrent = "concurrent_inproc",
    multiprocess_parallel = "multiprocess_parallel",
    stop("unsupported Rducks execution-plan concurrency: ", concurrency, call. = FALSE)
  )
}

rducks_plan_serialization <- function(marshalling) {
  if (identical(marshalling, "wire")) "quack" else "none"
}

rducks_plan_ipc_provider <- function(x) {
  match.arg(x, "nng")
}

rducks_ipc_defaults <- list(
  timeout = 30
)

rducks_ipc_default_timeout <- function() rducks_ipc_defaults$timeout

rducks_validate_ipc_globals <- function(globals) {
  if (identical(globals, "auto") || isTRUE(globals) || identical(globals, FALSE)) {
    return(globals)
  }
  if (is.character(globals)) {
    if (anyNA(globals) || any(!nzchar(globals))) {
      stop("ipc_globals character names must be non-missing, non-empty strings", call. = FALSE)
    }
    return(unique(globals))
  }
  if (is.list(globals)) {
    names <- names(globals)
    if (length(globals) && (is.null(names) || anyNA(names) || any(!nzchar(names)) || anyDuplicated(names))) {
      stop("ipc_globals supplied as a list must have unique non-empty names", call. = FALSE)
    }
    return(globals)
  }
  stop("ipc_globals must be 'auto', TRUE, FALSE, a character vector, or a named list", call. = FALSE)
}

rducks_validate_ipc_packages <- function(packages) {
  if (is.null(packages)) return(character())
  if (!is.character(packages) || anyNA(packages) || any(!nzchar(packages))) {
    stop("ipc_packages must be NULL or a character vector of non-empty package names", call. = FALSE)
  }
  unique(packages)
}

rducks_validate_ipc_globals_share <- function(share) {
  if (is.null(share)) share <- "none"
  if (!is.character(share) || length(share) != 1L || is.na(share) || !share %in% c("none", "mori")) {
    stop("ipc_globals_share must be one of: none, mori", call. = FALSE)
  }
  share
}

rducks_plan_engine_id <- function(marshalling, concurrency, ipc_provider = "nng") {
  key <- paste(marshalling, concurrency, sep = "+")
  if (identical(key, "wire+multiprocess_parallel")) {
    ipc_provider <- rducks_plan_ipc_provider(ipc_provider)
    return("ipc_nng_pool")
  }
  switch(
    key,
    `direct+serial` = "direct_serial",
    `direct+inproc_concurrent` = "direct_main_queue",
    stop("unsupported Rducks execution-plan pair: ", key, call. = FALSE)
  )
}

rducks_plan_implemented <- function(marshalling, concurrency) {
  (identical(marshalling, "direct") && concurrency %in% c("serial", "inproc_concurrent")) ||
    (identical(marshalling, "wire") && identical(concurrency, "multiprocess_parallel"))
}

rducks_plan_supported_call_shapes <- function(marshalling, concurrency) {
  if (!rducks_plan_implemented(marshalling, concurrency)) {
    return(character())
  }
  switch(
    marshalling,
    direct = c("scalar", "vectorized"),
    wire = c("scalar", "vectorized"),
    character()
  )
}

rducks_ipc_options <- function(globals = "auto",
                                packages = NULL,
                                timeout = NULL,
                                endpoints = NULL,
                                transport = NULL,
                                globals_share = "none") {
  globals <- rducks_validate_ipc_globals(globals)
  packages <- rducks_validate_ipc_packages(packages)
  globals_share <- rducks_validate_ipc_globals_share(globals_share)
  timeout <- rducks_nng_check_seconds(timeout, "ipc_timeout", default = rducks_ipc_default_timeout())
  endpoints <- rducks_nng_validate_endpoints(endpoints)
  if (!is.null(endpoints) && !is.null(transport)) {
    stop("ipc_transport only applies when ipc_endpoints is NULL", call. = FALSE)
  }
  transport <- if (is.null(endpoints)) rducks_nng_normalize_transport(transport, runtime = TRUE) else NULL
  list(
    globals = globals,
    packages = unique(c("Rducks", packages)),
    timeout = timeout,
    endpoints = endpoints,
    transport = transport,
    globals_share = globals_share
  )
}

rducks_validate_execution_plan_values <- function(marshalling, concurrency) {
  if (identical(marshalling, "wire") && !identical(concurrency, "multiprocess_parallel")) {
    stop("marshalling = 'wire' requires concurrency = 'multiprocess_parallel'", call. = FALSE)
  }
  if (!identical(marshalling, "wire") && identical(concurrency, "multiprocess_parallel")) {
    stop("concurrency = 'multiprocess_parallel' requires marshalling = 'wire'", call. = FALSE)
  }
  invisible(TRUE)
}

#' Define an Rducks execution plan
#'
#' An execution plan describes where Rducks evaluates registered scalar-UDF
#' chunks: in the current R process (`transport = "inproc"`) or in persistent
#' worker R processes (`transport = "ipc"`). When stored on a connection it is
#' the default for future
#' \code{\link[=rducks_register_scalar_udf]{rducks_register_scalar_udf()}}
#' calls and updates the native runtime backend used for matching concurrent
#' execution; the resolved transport metadata is frozen into each registered
#' scalar UDF's database-catalog metadata. It is separate from DuckDB function
#' kind and from scalar-UDF registration semantics such as Rducks evaluation
#' mode (`"scalar"` row calls versus `"vectorized"` chunk calls),
#' argument/return types, NULL handling, error handling, and side effects.
#'
#' `"inproc"` keeps all R API work serialized on the recorded main R thread
#' while allowing DuckDB callback concurrency; DuckDB vectors are materialized
#' to SEXPs directly in extension C with no intermediate columnar format. It
#' maps to the internal `"direct_main_queue"` engine.
#'
#' `"ipc"` uses persistent NNG/nanonext worker R processes that exchange
#' Quack-style binary chunk payloads (a DuckDB BinarySerializer subset): the
#' extension encodes each input chunk to wire bytes, the worker decodes them,
#' runs the R function, and returns wire-encoded results that the extension
#' writes back to DuckDB. Worker-process types currently cover fixed-width
#' scalars, `VARCHAR`/`BLOB`, `DECIMAL`, `INTERVAL`, `ENUM`, `BIT`, `GEOMETRY`, `MAP`, `UNION`, and
#' `LIST`/`ARRAY`/`STRUCT` of supported types; `VARIANT` is rejected at registration until the
#' native bridge covers it. It maps to the internal `"ipc_nng_pool"` engine.
#'
#' @param transport Placement/transport. `"inproc"` evaluates in the current R
#'   process with the in-process queued backend. `"ipc"` evaluates in persistent
#'   worker R processes over NNG; when `ipc_endpoints` is `NULL`, Rducks starts
#'   local worker loops with mirai daemons.
#' @param ipc_globals,ipc_packages,ipc_timeout,ipc_endpoints,ipc_transport IPC worker options (used when `transport = "ipc"`).
#'   By default (`ipc_globals = "auto"`), Rducks discovers scalar-UDF globals
#'   once at registration-wrapper creation and broadcasts them to each NNG worker
#'   when the scalar UDF is registered with the shared provider pool. Automatic capture
#'   estimates the serialized globals payload and warns when it exceeds option
#'   `rducks.ipc_globals.warn_bytes` (8 MiB by default); option
#'   `rducks.ipc_globals.max_bytes` can set a hard byte limit. Set
#'   `ipc_globals_share = "mori"` to pass selected globals through mori shared
#'   memory references for same-host workers; Rducks keeps the shared objects
#'   anchored for the registered scalar UDF lifetime. Use `ipc_packages` for packages
#'   that workers should attach, `ipc_globals = FALSE` to rely only on the
#'   serialized UDF closure and explicit task state, or a character vector /
#'   named list for explicit extra globals. `ipc_timeout` is the positive finite
#'   provider wait timeout in seconds; `NULL` uses a finite default of 30 seconds.
#'   `ipc_endpoints` optionally supplies NNG endpoint URLs for worker processes
#'   that the caller starts and stops; those processes must run the Rducks NNG
#'   worker loop. Any NNG URL transport supported by both endpoints is allowed.
#'   When endpoints are not
#'   supplied, `ipc_transport` selects the transport used for the mirai-launched
#'   local worker endpoints and must be left as `NULL` when explicit
#'   `ipc_endpoints` are supplied. Rducks retries local TCP/WebSocket startup
#'   with fresh endpoint bundles after startup-ping failure; caller-supplied
#'   endpoints remain caller-owned and fail fast. `"abstract"` means Linux abstract IPC, `"ipc"`
#'   means NNG IPC (Unix-domain sockets on POSIX and named pipes on Windows),
#'   `"unix"` means the POSIX Unix-domain alias, and `"tcp"` / `"ws"` use
#'   loopback TCP / WebSocket endpoints. The default is `"abstract"` on Linux
#'   and `"ipc"` elsewhere.
#' @param ipc_globals_share How selected IPC globals are represented before
#'   worker broadcast. `"none"` serializes them into the registration payload.
#'   `"mori"` applies `mori::share()` to each selected global before
#'   serialization, which can turn large atomic vectors, lists, and data frames
#'   into same-host shared-memory references. This requires the optional mori
#'   package and workers on the same machine.
#' @param ipc_provider Worker provider for `transport = "ipc"`.
#'   Only `"nng"` is supported. The NNG provider broadcasts each registered scalar UDF
#'   closure plus discovered globals/packages to every worker in the shared
#'   database-runtime provider pool, so avoid capturing large objects in UDF
#'   environments unless that memory cost is intended or `ipc_globals_share =
#'   "mori"` is appropriate.
#' @param ipc_workers Number of persistent NNG workers.
#' @param ipc_max_pending Maximum simultaneous native NNG requests admitted per
#'   registered scalar-UDF client pool. `NULL` uses the provider default of 64.
#'   Non-IPC plans store `NA_integer_` for this field. The current provider still
#'   uses synchronous request/reply per callback rather than collect-many
#'   batching, but this value is enforced as a bounded pending/in-flight guard
#'   before a callback enters the native request path.
#' @return An object of class `rducks_execution_plan`.
#' @examples
#' rducks_execution_plan("inproc")
#' @export
rducks_execution_plan <- function(transport = "inproc",
                                  ipc_globals = "auto",
                                  ipc_packages = NULL,
                                  ipc_timeout = NULL,
                                  ipc_endpoints = NULL,
                                  ipc_transport = NULL,
                                  ipc_globals_share = "none",
                                  ipc_provider = "nng",
                                  ipc_workers = 1L,
                                  ipc_max_pending = 64L) {
  transport <- rducks_plan_transport(transport)
  if (identical(transport, "ipc")) {
    marshalling <- "wire"
    concurrency <- "multiprocess_parallel"
  } else {
    marshalling <- "direct"
    concurrency <- "inproc_concurrent"
  }
  rducks_execution_plan_internal(
    marshalling, concurrency,
    ipc_globals = ipc_globals,
    ipc_packages = ipc_packages,
    ipc_timeout = ipc_timeout,
    ipc_endpoints = ipc_endpoints,
    ipc_transport = ipc_transport,
    ipc_globals_share = ipc_globals_share,
    ipc_provider = ipc_provider,
    ipc_workers = ipc_workers,
    ipc_max_pending = ipc_max_pending
  )
}

# Internal constructor over the implementation engine vocabulary. Conformance
# tests and internal helpers may construct serial reference plans here; the
# public constructor only exposes the transport axis.
rducks_execution_plan_internal <- function(marshalling = c("direct", "wire"),
                                  concurrency = c("serial", "inproc_concurrent", "multiprocess_parallel"),
                                  ipc_globals = "auto",
                                  ipc_packages = NULL,
                                  ipc_timeout = NULL,
                                  ipc_endpoints = NULL,
                                  ipc_transport = NULL,
                                  ipc_globals_share = "none",
                                  ipc_provider = "nng",
                                  ipc_workers = 1L,
                                  ipc_max_pending = 64L) {
  marshalling <- rducks_plan_marshalling(marshalling)
  concurrency <- rducks_plan_concurrency(concurrency)
  if (identical(marshalling, "wire")) {
    ipc_provider <- rducks_plan_ipc_provider(ipc_provider)
  } else {
    if (!identical(ipc_provider, "nng")) {
      stop("ipc_provider only applies to transport = 'ipc'", call. = FALSE)
    }
    ipc_provider <- "none"
  }
  ipc_workers <- rducks_validate_thread_count(ipc_workers, "ipc_workers")
  if (is.null(ipc_max_pending)) {
    ipc_max_pending <- 64L
  } else if (!is.numeric(ipc_max_pending) || length(ipc_max_pending) != 1L || is.na(ipc_max_pending) ||
      ipc_max_pending <= 0 || ipc_max_pending != floor(ipc_max_pending)) {
    stop("ipc_max_pending must be NULL or a positive integer-like numeric scalar", call. = FALSE)
  } else {
    ipc_max_pending <- as.integer(ipc_max_pending)
  }
  rducks_validate_execution_plan_values(marshalling, concurrency)
  backend <- rducks_plan_backend(concurrency)
  serialization <- rducks_plan_serialization(marshalling)
  implemented <- rducks_plan_implemented(marshalling, concurrency)
  engine_id <- rducks_plan_engine_id(marshalling, concurrency, ipc_provider = ipc_provider)
  supported_call_shapes <- rducks_plan_supported_call_shapes(marshalling, concurrency)
  ipc_options <- if (identical(marshalling, "wire")) {
    rducks_ipc_options(
      globals = ipc_globals,
      packages = ipc_packages,
      timeout = ipc_timeout,
      endpoints = ipc_endpoints,
      transport = ipc_transport,
      globals_share = ipc_globals_share
    )
  } else {
    NULL
  }
  structure(
    list(
      transport = if (identical(marshalling, "wire")) "ipc" else "inproc",
      marshalling = marshalling,
      concurrency = concurrency,
      plan_id = paste(marshalling, concurrency, sep = "+"),
      engine_id = engine_id,
      reference = identical(marshalling, "direct") && identical(concurrency, "serial"),
      implemented = implemented,
      supported_call_shapes = supported_call_shapes,
      backend = backend,
      serialization = serialization,
      ipc_options = ipc_options,
      ipc_provider = if (identical(marshalling, "wire")) ipc_provider else "none",
      ipc_workers = if (identical(marshalling, "wire")) ipc_workers else NA_integer_,
      ipc_max_pending = if (identical(marshalling, "wire")) ipc_max_pending else NA_integer_,
      in_process = !identical(concurrency, "multiprocess_parallel"),
      uses_r_thread = !identical(marshalling, "wire")
    ),
    class = "rducks_execution_plan"
  )
}

#' @export
print.rducks_execution_plan <- function(x, ...) {
  cat("<rducks_execution_plan>\n")
  cat("  plan_id:     ", x$plan_id, "\n", sep = "")
  cat("  engine_id:   ", x$engine_id %||% "<unknown>", "\n", sep = "")
  cat("  transport:   ", x$transport %||% "<unknown>", "\n", sep = "")
  cat("  concurrency: ", x$concurrency, "\n", sep = "")
  if (identical(x$marshalling, "wire")) {
    cat("  ipc provider: ", x$ipc_provider %||% "nng", "\n", sep = "")
  }
  cat("  reference:   ", if (isTRUE(x$reference)) "yes" else "no", "\n", sep = "")
  cat("  implemented: ", if (isTRUE(x$implemented)) "yes" else "no", "\n", sep = "")
  cat("  call shapes: ", paste(x$supported_call_shapes, collapse = ", "), "\n", sep = "")
  invisible(x)
}

rducks_as_execution_plan <- function(plan) {
  if (inherits(plan, "rducks_execution_plan")) {
    return(plan)
  }
  if (is.character(plan) && length(plan) == 1L) {
    return(switch(
      plan,
      reference = rducks_execution_plan_internal("direct", "serial"),
      direct_serial = rducks_execution_plan_internal("direct", "serial"),
      direct_main_queue = rducks_execution_plan_internal("direct", "inproc_concurrent"),
      inproc = rducks_execution_plan("inproc"),
      ipc = rducks_execution_plan("ipc"),
      ipc_nng_pool = rducks_execution_plan("ipc", ipc_provider = "nng"),
      stop("unknown Rducks execution plan shortcut: ", plan, call. = FALSE)
    ))
  }
  stop("plan must be an rducks_execution_plan object", call. = FALSE)
}

rducks_connection_plan_store <- function() {
  rducks_get_or_init_store("connection_plans")
}

rducks_connection_ref_token_store <- function() {
  rducks_get_or_init_store("connection_ref_tokens")
}

rducks_connection_ref <- function(con) {
  rducks_assert_duckdb_connection(con)
  # Read-only access to duckdb-r's connection external pointer. Do not mutate
  # its tag, protected value, attributes, or finalizer list outside
  # reg.finalizer().
  methods::slot(con, "conn_ref")
}

rducks_connection_ref_key <- function(conn_ref) {
  .Call(RDUCKS_sexp_addr, conn_ref)
}

rducks_next_connection_token <- function() {
  counter <- .rducks_state$connection_token_counter %||% 0
  counter <- counter + 1
  .rducks_state$connection_token_counter <- counter
  paste0("rducks-connection-", counter)
}

rducks_existing_connection_token <- function(con) {
  conn_ref <- rducks_connection_ref(con)
  ref_key <- rducks_connection_ref_key(conn_ref)
  token_store <- .rducks_state$connection_ref_tokens
  if (is.null(token_store) || !exists(ref_key, envir = token_store, inherits = FALSE)) {
    return(NA_character_)
  }
  get(ref_key, envir = token_store, inherits = FALSE)
}

rducks_attached_runtime_token <- function(con) {
  token <- rducks_existing_connection_token(con)
  if (is.na(token)) return(NA_character_)
  runtime_store <- .rducks_state$connection_runtime_tokens
  if (is.null(runtime_store) || !exists(token, envir = runtime_store, inherits = FALSE)) {
    return(NA_character_)
  }
  get(token, envir = runtime_store, inherits = FALSE)
}

rducks_runtime_anchor_store <- function() {
  rducks_get_or_init_store("runtime_anchors")
}

rducks_connection_runtime_token_store <- function() {
  rducks_get_or_init_store("connection_runtime_tokens")
}

rducks_remove_store_entry <- function(store, key) {
  if (!is.null(store) && exists(key, envir = store, inherits = FALSE)) {
    rm(list = key, envir = store)
  }
  invisible(NULL)
}

rducks_runtime_anchor_empty <- function(anchor_env) {
  is.null(anchor_env) || !length(ls(envir = anchor_env, all.names = TRUE))
}

rducks_cleanup_runtime_anchor <- function(db_token, token) {
  rducks_remove_store_entry(.rducks_state$connection_runtime_tokens, token)
  store <- .rducks_state$runtime_anchors
  if (is.null(store) || !exists(db_token, envir = store, inherits = FALSE)) {
    return(invisible(NULL))
  }
  anchor_env <- get(db_token, envir = store, inherits = FALSE)
  rducks_remove_store_entry(anchor_env, token)
  if (rducks_runtime_anchor_empty(anchor_env)) {
    rducks_nng_stop_runtime_providers(db_token, quiet = TRUE)
    rducks_remove_store_entry(store, db_token)
    rducks_remove_store_entry(.rducks_state$registrations, db_token)
  }
  invisible(NULL)
}

rducks_runtime_anchor_finalizer <- function(db_token, token) {
  env <- new.env(parent = environment(rducks_runtime_anchor_finalizer))
  env$db_token <- db_token
  env$token <- token
  finalizer <- function(e) {
    finalizer_env <- parent.env(environment())
    rducks_cleanup_runtime_anchor(finalizer_env$db_token, finalizer_env$token)
    invisible(NULL)
  }
  environment(finalizer) <- env
  finalizer
}

rducks_register_runtime_anchor <- function(conn_ref, db_token, token) {
  store <- rducks_runtime_anchor_store()
  if (!exists(db_token, envir = store, inherits = FALSE)) {
    assign(db_token, new.env(parent = emptyenv()), envir = store)
  }
  anchor_env <- get(db_token, envir = store, inherits = FALSE)
  assign(token, db_token, envir = rducks_connection_runtime_token_store())
  if (!exists(token, envir = anchor_env, inherits = FALSE)) {
    assign(token, TRUE, envir = anchor_env)
    # onexit = FALSE: do not run this finalizer during R session exit.
    # Mirai daemon processes are children of the main R process and are
    # terminated automatically by the OS when R exits.  Running the finalizer
    # at exit calls nanonext C code on AIO objects that may already have been
    # garbage-collected, causing crashes.  Mid-session GC (e.g. after an
    # explicit dbDisconnect) is safe and will still trigger this finalizer.
    reg.finalizer(conn_ref, rducks_runtime_anchor_finalizer(db_token, token), onexit = FALSE)
  }
  invisible(db_token)
}

rducks_attach_runtime_anchor <- function(con) {
  conn_ref <- rducks_connection_ref(con)
  token <- rducks_connection_key(con)
  db_token <- rducks_runtime_token(con)
  rducks_register_runtime_anchor(conn_ref, db_token, token)
}

rducks_detach_connection_token <- function(con) {
  conn_ref <- rducks_connection_ref(con)
  ref_key <- rducks_connection_ref_key(conn_ref)
  token_store <- .rducks_state$connection_ref_tokens
  if (is.null(token_store) || !exists(ref_key, envir = token_store, inherits = FALSE)) {
    return(invisible(NULL))
  }
  token <- get(ref_key, envir = token_store, inherits = FALSE)
  db_token <- NULL
  runtime_store <- .rducks_state$connection_runtime_tokens
  if (!is.null(runtime_store) && exists(token, envir = runtime_store, inherits = FALSE)) {
    db_token <- get(token, envir = runtime_store, inherits = FALSE)
  }
  rducks_cleanup_connection_token(ref_key, token)
  if (!is.null(db_token)) {
    rducks_cleanup_runtime_anchor(db_token, token)
  }
  invisible(NULL)
}

rducks_cleanup_connection_token <- function(ref_key, token) {
  token_store <- .rducks_state$connection_ref_tokens
  if (!is.null(token_store) && exists(ref_key, envir = token_store, inherits = FALSE)) {
    current <- get(ref_key, envir = token_store, inherits = FALSE)
    if (identical(current, token)) {
      rm(list = ref_key, envir = token_store)
    }
  }
  rducks_remove_store_entry(.rducks_state$connection_plans, token)
  invisible(NULL)
}

rducks_connection_finalizer <- function(ref_key, token) {
  # Build the finalizer in an environment that contains only scalar keys. If the
  # finalizer closure captures `con` or `conn_ref`, the weak-reference key stays
  # reachable and cleanup never runs.
  env <- new.env(parent = environment(rducks_connection_finalizer))
  env$ref_key <- ref_key
  env$token <- token
  finalizer <- function(e) {
    rducks_cleanup_connection_token(ref_key, token)
    invisible(NULL)
  }
  environment(finalizer) <- env
  finalizer
}

rducks_register_connection_finalizer <- function(conn_ref, ref_key, token) {
  reg.finalizer(conn_ref, rducks_connection_finalizer(ref_key, token), onexit = TRUE)
  invisible(token)
}

rducks_connection_key <- function(con) {
  conn_ref <- rducks_connection_ref(con)
  ref_key <- rducks_connection_ref_key(conn_ref)
  store <- rducks_connection_ref_token_store()
  if (exists(ref_key, envir = store, inherits = FALSE)) {
    return(get(ref_key, envir = store, inherits = FALSE))
  }
  token <- rducks_next_connection_token()
  assign(ref_key, token, envir = store)
  rducks_register_connection_finalizer(conn_ref, ref_key, token)
  token
}

rducks_store_connection_plan <- function(con, plan) {
  assign(rducks_connection_key(con), plan, envir = rducks_connection_plan_store())
  invisible(plan)
}

#' Inspect the current Rducks execution plan
#'
#' Returns the R-side execution plan recorded for a DuckDB connection. If no plan
#' has been recorded yet, this returns the reference plan `direct + serial`.
#'
#' @param con A `duckdb_connection`.
#' @return An object of class `rducks_execution_plan`.
#' @examples
#' \donttest{
#' db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
#' rducks_enable(db)
#' rducks_current_execution_plan(db)
#' rducks_release(db)
#' DBI::dbDisconnect(db)
#' }
#' @export
rducks_current_execution_plan <- function(con) {
  rducks_assert_duckdb_connection(con)
  key <- rducks_connection_key(con)
  store <- rducks_connection_plan_store()
  if (exists(key, envir = store, inherits = FALSE)) {
    get(key, envir = store, inherits = FALSE)
  } else {
    rducks_execution_plan_internal("direct", "serial")
  }
}

rducks_assert_execution_plan_implemented <- function(plan) {
  if (!isTRUE(plan$implemented)) {
    stop("Rducks execution plan is not implemented yet: ", plan$plan_id, call. = FALSE)
  }
  invisible(TRUE)
}

# Scalar types the native wire/RIPC bridge (tools/ext/src/rducks_ripc.c) encodes
# and decodes end-to-end, including BIT (transported as DuckDB's physical bit
# storage; DECIMAL and ENUM are handled separately below, and LIST/ARRAY/STRUCT
# recurse on their children; GEOMETRY rides as a BLOB column; MAP rides as
# LIST(STRUCT(key, value)); UNION rides as the physical STRUCT(tag, members)).
# VARIANT is not yet wired through the native bridge (and is unsupported on the
# direct path of this DuckDB build), so it is rejected at registration
# (strict-plan rule: no register-then-fail-at-execution).
rducks_wire_supported_scalar_types <- function() {
  c("bool", "i8", "u8", "i16", "u16", "i32", "u32", "i64", "u64", "f32", "f64",
    "varchar", "blob", "bit", "geometry", "date", "time", "timestamp", "hugeint",
    "uhugeint", "uuid", "interval")
}

rducks_wire_unsupported_types <- function(type) {
  type <- if (rducks_type_inherits(type, "rducks_type")) type else rducks_type_object(rducks_type_normalize(type))
  kind <- rducks_type_kind(type)
  if (identical(kind, "scalar") && rducks_type_token(type) %in% rducks_wire_supported_scalar_types()) {
    return(character())
  }
  # DECIMAL and ENUM are their own kinds but the native bridge encodes them as
  # fixed-width wire columns (scaled integer for DECIMAL, 0-based dictionary
  # index for ENUM), so they round-trip end-to-end.
  if (identical(kind, "decimal") || identical(kind, "enum")) {
    return(character())
  }
  # LIST/ARRAY/STRUCT/MAP/UNION are marshalled recursively by the native bridge;
  # they are supported as long as every child (member) type is.
  if (kind %in% c("list", "array", "struct", "map", "union")) {
    children <- rducks_type_children(type)
    unsupported <- unlist(lapply(children, rducks_wire_unsupported_types), use.names = FALSE)
    return(if (length(unsupported)) unique(unsupported) else character())
  }
  rducks_type_duckdb_sql(type)
}

rducks_wire_mapping_supported <- function(type) {
  !length(rducks_wire_unsupported_types(type))
}

rducks_validate_execution_plan_for_registration <- function(plan, spec) {
  rducks_assert_execution_plan_implemented(plan)
  if (!identical(spec$mode, "scalar") && !identical(spec$mode, "vectorized")) {
    stop("unknown Rducks UDF call shape: ", spec$mode, call. = FALSE)
  }
  if (!spec$mode %in% plan$supported_call_shapes) {
    stop(
      "Rducks execution plan ", plan$plan_id,
      " does not support mode = '", spec$mode, "'",
      call. = FALSE
    )
  }
  if (identical(plan$marshalling, "direct")) {
    types <- c(spec$arg_types %||% list(), list(spec$return_type))
    unsupported <- unique(unlist(lapply(types, rducks_direct_unsupported_types), use.names = FALSE))
    if (length(unsupported)) {
      stop(
        "direct in-process marshalling is not implemented for: ",
        paste(unsupported, collapse = ", "),
        call. = FALSE
      )
    }
  }
  if (identical(plan$marshalling, "wire")) {
    # Dynamic (omitted-args) UDFs resolve their concrete argument types per call
    # site at DuckDB bind time, so the argument types cannot be wire-validated at
    # registration; the native bind resolves them and carries the resolved tokens
    # to the worker in the RDT1 dynamic payload, and a type the wire codec cannot
    # encode fails cleanly at the first chunk encode. Only the declared return
    # type is checked here (the args list is empty for dynamic UDFs).
    unsupported <- unique(unlist(lapply(c(spec$arg_types %||% list(), list(spec$return_type)), rducks_wire_unsupported_types), use.names = FALSE))
    unsupported <- unsupported[nzchar(unsupported)]
    if (length(unsupported)) {
      stop(
        "Rducks execution plan ", plan$plan_id,
        " cannot use the Quack wire marshalling for: ",
        paste(unsupported, collapse = ", "),
        call. = FALSE
      )
    }
  }
  if (identical(spec$mode, "vectorized") && !isTRUE(spec$dynamic_args) && !length(spec$arg_types %||% list())) {
    stop("mode = 'vectorized' currently requires at least one declared argument or omitted args for dynamic arguments", call. = FALSE)
  }
  invisible(TRUE)
}

rducks_plan_native_evaluator_token <- function(plan, mode = "scalar") {
  mode <- rducks_match_mode(mode)
  switch(
    plan$marshalling,
    direct = if (identical(mode, "vectorized")) "RCV" else "RC",
    wire = "RIPC",
    stop("unsupported Rducks execution-plan marshalling: ", plan$marshalling, call. = FALSE)
  )
}

