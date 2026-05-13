rducks_plan_marshalling <- function(x) {
  match.arg(x, c("arrow_r", "arrow_c", "arrow_ipc"))
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
  if (identical(marshalling, "arrow_ipc")) "arrow_ipc" else "none"
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
  if (identical(key, "arrow_ipc+multiprocess_parallel")) {
    ipc_provider <- rducks_plan_ipc_provider(ipc_provider)
    return("ipc_nng_pool")
  }
  switch(
    key,
    `arrow_r+serial` = "arrow_r_serial",
    `arrow_r+inproc_concurrent` = "arrow_r_main_queue",
    `arrow_c+serial` = "arrow_c_direct_serial",
    `arrow_c+inproc_concurrent` = "arrow_c_direct_main_queue",
    NA_character_
  )
}

rducks_plan_implemented <- function(marshalling, concurrency) {
  (marshalling %in% c("arrow_r", "arrow_c") &&
    concurrency %in% c("serial", "inproc_concurrent")) ||
    (identical(marshalling, "arrow_ipc") && identical(concurrency, "multiprocess_parallel"))
}

rducks_plan_supported_call_shapes <- function(marshalling, concurrency) {
  if (!rducks_plan_implemented(marshalling, concurrency)) {
    return(character())
  }
  switch(
    marshalling,
    arrow_r = c("scalar", "vectorized"),
    arrow_c = c("scalar", "vectorized"),
    arrow_ipc = c("scalar", "vectorized"),
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
  if (identical(marshalling, "arrow_ipc") && !identical(concurrency, "multiprocess_parallel")) {
    stop("marshalling = 'arrow_ipc' requires concurrency = 'multiprocess_parallel'", call. = FALSE)
  }
  if (!identical(marshalling, "arrow_ipc") && identical(concurrency, "multiprocess_parallel")) {
    stop("concurrency = 'multiprocess_parallel' requires marshalling = 'arrow_ipc'", call. = FALSE)
  }
  invisible(TRUE)
}

#' Define an Rducks execution plan
#'
#' An execution plan describes how Rducks should marshal DuckDB chunks and what
#' concurrency model is allowed. When stored on a connection it is the default
#' for future \code{\link[=rducks_register_scalar_udf]{rducks_register_scalar_udf()}}
#' calls; the selected evaluator/marshalling is frozen into each registered
#' scalar UDF's database-catalog metadata. It is separate from DuckDB function
#' kind and from scalar-UDF registration semantics such as Rducks evaluation
#' mode (`"scalar"` row calls versus `"vectorized"` chunk calls),
#' argument/return types, NULL handling, error handling, and side effects.
#'
#' `arrow_r + serial` is the reference implementation used for conformance.
#' Other plans must be explicitly implemented and validated against that
#' reference; Rducks does not silently switch from one plan to another.
#' `arrow_ipc + multiprocess_parallel` uses the native NNG path with vendored
#' nanoarrow C/IPC encoding. Each valid pair maps to a concrete internal `engine_id` such as
#' `"arrow_c_direct_serial"` or `"ipc_nng_pool"`.
#'
#' @param marshalling Chunk marshalling implementation. `"arrow_r"` uses Arrow C
#'   Data plus nanoarrow/R materialization and is the reference implementation.
#'   `"arrow_c"` uses native C/DuckDB-vector materialization for supported
#'   scalar-UDF evaluation modes. `"arrow_ipc"` uses Arrow IPC bytes as
#'   the explicit task/result payload for the NNG multiprocess path.
#' @param concurrency Concurrency contract. `"serial"` evaluates one chunk at a
#'   time in the calling process. `"inproc_concurrent"` allows in-process DuckDB
#'   callback concurrency while keeping R API work serialized on the recorded
#'   main R thread. `"multiprocess_parallel"` uses persistent NNG/nanonext
#'   workers for process-isolated chunk work and requires `marshalling = "arrow_ipc"`.
#'   When `ipc_endpoints` is `NULL`, Rducks starts local worker loops with
#'   mirai daemons; otherwise the endpoint URLs are passed through unchanged.
#' @param ipc_globals,ipc_packages,ipc_timeout,ipc_endpoints,ipc_transport Arrow IPC worker options.
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
#' @param ipc_provider Worker provider for `arrow_ipc + multiprocess_parallel`.
#'   Only `"nng"` is supported. The NNG provider broadcasts each registered scalar UDF
#'   closure plus discovered globals/packages to every worker in the shared
#'   database-runtime provider pool, so avoid capturing large objects in UDF
#'   environments unless that memory cost is intended or `ipc_globals_share =
#'   "mori"` is appropriate.
#' @param ipc_workers Number of persistent NNG workers.
#' @param ipc_max_pending Maximum simultaneous native NNG requests admitted per
#'   registered scalar-UDF client pool. The current provider still uses synchronous
#'   request/reply per callback rather than collect-many batching, but this value
#'   is enforced as a bounded pending/in-flight guard before a callback enters
#'   the native request path.
#' @return An object of class `rducks_execution_plan`.
#' @export
rducks_execution_plan <- function(marshalling = c("arrow_r", "arrow_c", "arrow_ipc"),
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
  if (identical(marshalling, "arrow_ipc")) {
    ipc_provider <- rducks_plan_ipc_provider(ipc_provider)
  } else {
    if (!identical(ipc_provider, "nng")) {
      stop("ipc_provider only applies to marshalling = 'arrow_ipc'", call. = FALSE)
    }
    ipc_provider <- "none"
  }
  ipc_workers <- rducks_validate_thread_count(ipc_workers, "ipc_workers")
  if (!is.null(ipc_max_pending) &&
      (!is.numeric(ipc_max_pending) || length(ipc_max_pending) != 1L || is.na(ipc_max_pending) || ipc_max_pending <= 0)) {
    stop("ipc_max_pending must be NULL or a positive numeric scalar", call. = FALSE)
  }
  rducks_validate_execution_plan_values(marshalling, concurrency)
  backend <- rducks_plan_backend(concurrency)
  serialization <- rducks_plan_serialization(marshalling)
  implemented <- rducks_plan_implemented(marshalling, concurrency)
  engine_id <- rducks_plan_engine_id(marshalling, concurrency, ipc_provider = ipc_provider)
  supported_call_shapes <- rducks_plan_supported_call_shapes(marshalling, concurrency)
  ipc_options <- if (identical(marshalling, "arrow_ipc")) {
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
      marshalling = marshalling,
      concurrency = concurrency,
      plan_id = paste(marshalling, concurrency, sep = "+"),
      engine_id = engine_id,
      reference = identical(marshalling, "arrow_r") && identical(concurrency, "serial"),
      implemented = implemented,
      supported_call_shapes = supported_call_shapes,
      backend = backend,
      serialization = serialization,
      ipc_options = ipc_options,
      ipc_provider = if (identical(marshalling, "arrow_ipc")) ipc_provider else "none",
      ipc_workers = if (identical(marshalling, "arrow_ipc")) ipc_workers else NA_integer_,
      ipc_max_pending = if (identical(marshalling, "arrow_ipc")) ipc_max_pending else NA_real_,
      in_process = !identical(concurrency, "multiprocess_parallel"),
      uses_r_thread = !identical(marshalling, "arrow_ipc")
    ),
    class = "rducks_execution_plan"
  )
}

#' @export
print.rducks_execution_plan <- function(x, ...) {
  cat("<rducks_execution_plan>\n")
  cat("  plan_id:     ", x$plan_id, "\n", sep = "")
  cat("  engine_id:   ", x$engine_id %||% "<unknown>", "\n", sep = "")
  cat("  marshalling: ", x$marshalling, "\n", sep = "")
  cat("  concurrency: ", x$concurrency, "\n", sep = "")
  if (identical(x$marshalling, "arrow_ipc")) {
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
      reference = rducks_execution_plan("arrow_r", "serial"),
      serial = rducks_execution_plan("arrow_r", "serial"),
      inproc_concurrent = rducks_execution_plan("arrow_r", "inproc_concurrent"),
      arrow_r = rducks_execution_plan("arrow_r", "serial"),
      arrow_c = rducks_execution_plan("arrow_c", "serial"),
      arrow_r_serial = rducks_execution_plan("arrow_r", "serial"),
      arrow_r_main_queue = rducks_execution_plan("arrow_r", "inproc_concurrent"),
      arrow_c_direct_serial = rducks_execution_plan("arrow_c", "serial"),
      arrow_c_direct_main_queue = rducks_execution_plan("arrow_c", "inproc_concurrent"),
      ipc_nng_pool = rducks_execution_plan("arrow_ipc", "multiprocess_parallel", ipc_provider = "nng"),
      stop("unknown Rducks execution plan shortcut: ", plan, call. = FALSE)
    ))
  }
  stop("plan must be an rducks_execution_plan object", call. = FALSE)
}

rducks_connection_plan_store <- function() {
  store <- .rducks_state$connection_plans
  if (is.null(store)) {
    store <- new.env(parent = emptyenv())
    .rducks_state$connection_plans <- store
  }
  store
}

rducks_connection_ref_token_store <- function() {
  store <- .rducks_state$connection_ref_tokens
  if (is.null(store)) {
    store <- new.env(parent = emptyenv())
    .rducks_state$connection_ref_tokens <- store
  }
  store
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
  store <- .rducks_state$runtime_anchors
  if (is.null(store)) {
    store <- new.env(parent = emptyenv())
    .rducks_state$runtime_anchors <- store
  }
  store
}

rducks_connection_runtime_token_store <- function() {
  store <- .rducks_state$connection_runtime_tokens
  if (is.null(store)) {
    store <- new.env(parent = emptyenv())
    .rducks_state$connection_runtime_tokens <- store
  }
  store
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
  rducks_query_stream_close_for_token(token)
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
#' has been recorded yet, this returns the reference plan `arrow_r + serial`.
#'
#' @param con A `duckdb_connection`.
#' @return An object of class `rducks_execution_plan`.
#' @export
rducks_current_execution_plan <- function(con) {
  rducks_assert_duckdb_connection(con)
  key <- rducks_connection_key(con)
  store <- rducks_connection_plan_store()
  if (exists(key, envir = store, inherits = FALSE)) {
    get(key, envir = store, inherits = FALSE)
  } else {
    rducks_execution_plan("arrow_r", "serial")
  }
}

rducks_assert_execution_plan_implemented <- function(plan) {
  if (!isTRUE(plan$implemented)) {
    stop("Rducks execution plan is not implemented yet: ", plan$plan_id, call. = FALSE)
  }
  invisible(TRUE)
}

rducks_arrow_ipc_unsupported_types <- function(type) {
  type <- if (inherits(type, "rducks_type")) type else rducks_type_object(rducks_type_normalize(type))
  kind <- rducks_type_kind(type)
  if (identical(kind, "scalar")) {
    return(if (rducks_type_token(type) %in% rducks_all_scalar_type_names()) character() else rducks_type_duckdb_sql(type))
  }
  if (identical(kind, "decimal") || identical(kind, "enum")) {
    return(character())
  }
  if (kind %in% c("list", "array", "struct", "map", "union")) {
    children <- rducks_type_children(type)
    out <- unlist(lapply(children, rducks_arrow_ipc_unsupported_types), use.names = FALSE)
    return(if (is.null(out)) character() else unique(out))
  }
  rducks_type_duckdb_sql(type)
}

rducks_arrow_ipc_mapping_supported <- function(type) {
  !length(rducks_arrow_ipc_unsupported_types(type))
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
  if (identical(plan$marshalling, "arrow_c")) {
    types <- c(spec$arg_types, list(spec$return_type))
    unsupported <- unique(unlist(lapply(types, rducks_arrow_c_direct_unsupported_types), use.names = FALSE))
    if (length(unsupported)) {
      stop(
        "arrow_c direct marshalling is not implemented for: ",
        paste(unsupported, collapse = ", "),
        "; use marshalling = 'arrow_r' for these types",
        call. = FALSE
      )
    }
  }
  if (identical(plan$marshalling, "arrow_ipc")) {
    unsupported <- unique(unlist(lapply(c(spec$arg_types, list(spec$return_type)), rducks_arrow_ipc_unsupported_types), use.names = FALSE))
    unsupported <- unsupported[nzchar(unsupported)]
    if (length(unsupported)) {
      stop(
        "Rducks execution plan ", plan$plan_id,
        " cannot use Arrow IPC marshalling for: ",
        paste(unsupported, collapse = ", "),
        call. = FALSE
      )
    }
  }
  if (identical(spec$mode, "vectorized") && !length(spec$arg_types)) {
    stop("mode = 'vectorized' currently requires at least one declared argument", call. = FALSE)
  }
  invisible(TRUE)
}

rducks_plan_native_evaluator_token <- function(plan, mode = "scalar") {
  mode <- rducks_match_mode(mode)
  switch(
    plan$marshalling,
    arrow_r = "R",
    arrow_c = if (identical(mode, "vectorized")) "RCV" else "RC",
    arrow_ipc = "RIPC",
    stop("unsupported Rducks execution-plan marshalling: ", plan$marshalling, call. = FALSE)
  )
}

