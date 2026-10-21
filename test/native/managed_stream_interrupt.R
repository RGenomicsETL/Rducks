# Run by run_managed_stream_interrupt.py in an isolated process. The supervisor
# sends a real SIGINT only after the operation under test reports readiness.
library(Rducks)
args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) == 2L)
mode <- args[[1L]]
ready_file <- args[[2L]]
con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
rducks_enable(con, threads = "single")
rducks_enable_inproc(con, threads = 1L, external_threads = 1L)
if (!Rducks:::rducks_query_stream_driver_available(con)) {
  stop("interrupt integration test requires duckdb-r off-main guard capability v2")
}
ready <- function() writeLines("ready", ready_file)
stream <- NULL
if (identical(mode, "native")) {
  # Test-only constant-folding probe: readiness must come from a callback
  # serviced by the managed driver, after its prepare command has started.
  # The callback returns immediately, leaving the native aggregate running.
  rducks_register_scalar_udf(con, "interrupt_native_ready", function(x) { ready(); x },
    args = INTEGER, returns = INTEGER, mode = "vectorized")
  query <- paste(
    "SELECT sum(sin(a.i::DOUBLE + b.i::DOUBLE)) + interrupt_native_ready(0::INTEGER) AS value",
    "FROM range(100000000) a(i), range(100000000) b(i)"
  )
} else if (mode %in% c("scalar", "callback", "coalesced")) {
  state <- new.env(parent = emptyenv())
  state$calls <- 0L
  state$fused <- FALSE
  # Test-only observation and delay establish a real in-flight output allocation.
  # The returned numerical mapping is identity; no production coalescing policy
  # should use callback timing or call shape as part of its function semantics.
  callback <- function(x) {
    state$calls <- state$calls + 1L
    if (identical(mode, "coalesced") && length(x) <= 2048L) {
      # Let other native workers queue so a later evaluation contains peers.
      Sys.sleep(0.1)
    } else {
      state$fused <- length(x) > 2048L
      ready()
      Sys.sleep(30)
    }
    x
  }
  rducks_register_scalar_udf(con, "interrupt_callback", callback,
    args = INTEGER, returns = INTEGER,
    mode = if (identical(mode, "scalar")) "scalar" else "vectorized",
    coalesce = identical(mode, "coalesced"))
  DBI::dbExecute(con, "CREATE TABLE interrupt_input AS SELECT i::INTEGER AS i FROM range(10000000) t(i)")
  query <- "SELECT sum(interrupt_callback(i))::DOUBLE AS value FROM interrupt_input"
} else {
  stop("unknown interrupt test mode")
}
rducks_enable_inproc(con, threads = 4L, external_threads = 1L)
condition <- tryCatch({
  stream <- rducks_query_stream(con, query)
  stream$next_batch()
  NULL
}, error = identity, interrupt = identity)
stopifnot(inherits(condition, "condition"))
if (identical(mode, "coalesced")) stopifnot(isTRUE(state$fused))
if (!is.null(stream)) stream$close()
# The result is checked after cancellation; no helper may still own the
# connection and no RUNNING callback may still reference a submitter's stack.
reused <- rducks_query_stream(con, "SELECT i::INTEGER AS i FROM range(1, 4) t(i)")
stopifnot(identical(reused$next_batch()$i, 1:3), is.null(reused$next_batch()))
reused$close()
stats <- rducks_inproc_stats(con)
stopifnot(stats$pending_current == 0, stats$running_current == 0, stats$timeouts == 0)
rducks_release(con)
DBI::dbDisconnect(con, shutdown = TRUE)
cat("PASS managed stream interrupt:", mode, "\n")
