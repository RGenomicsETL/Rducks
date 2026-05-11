#!/usr/bin/env Rscript
#
# Minimal reprex for NNG WS transport hang on Windows.
# Uses nanonext only — no Rducks dependency.
#
# Test 1: same-process WS (listen + dial in one process).
# Test 2: cross-process WS (worker.R process listens, main dials).
#
# Findings:
#   Test 1 passes on all platforms (Linux, macOS, Windows).
#   Test 2 hangs on Windows CI during socket() or request().
#
# Suspected: NNG WS transport AIO timeout/cancel broken on IOCP.
#   nanonext src/comms.c line 127: nng_dial(s, url, dp, NONBLOCK)
#   returns immediately;  the hang is in nng_aio_wait() which
#   does not respect nng_aio_set_timeout() on Windows IOCP when
#   the WS TCP/HTTP state machine is in a specific state.
#
# Versions:
#   nanonext 1.8.2  => NNG 1.11.0 + Mbed TLS 3.6.5
#   nanonext 1.9.0+ => NNG 1.11.1-pre

library(nanonext)
RSCRIPT <- file.path(R.home("bin"), "Rscript")
PORT <- 18782
TIMEOUT <- 5  # seconds for each main-process operation

cat("nanonext:", as.character(packageVersion("nanonext")), "\n")
cat("nng:", paste(nng_version(), collapse = " "), "\n")
cat("platform:", R.version$platform, "\n")

# =========================================================================
# Test 1: same-process WS
# =========================================================================
cat("\n=== Test 1: same-process WS ===\n")
t0 <- Sys.time()
rep <- socket("rep", listen = sprintf("ws://127.0.0.1:%d", PORT + 1L))
req <- socket("req", dial = sprintf("ws://127.0.0.1:%d", PORT + 1L), autostart = TRUE)
ctx <- context(req)
res <- request(ctx, charToRaw("ping"), timeout = 1000L)
if (inherits(res$data, "errorValue")) {
  cat(sprintf("  request: %s\n", res$data))
} else {
  cat(sprintf("  request: data type=%s\n", typeof(res$data)))
}
close(req); close(rep)
cat(sprintf("  elapsed: %.2f s\n", as.numeric(difftime(Sys.time(), t0, units = "secs"))))

# =========================================================================
# Test 2: cross-process WS (worker.R in separate R process)
# =========================================================================
cat("\n=== Test 2: cross-process WS ===\n")

# launch background worker
worker_file <- file.path("reprex", "worker.R")
cmd <- sprintf("%s %s %d", RSCRIPT, worker_file, PORT)
cat(sprintf("  launching: %s\n", cmd))

if (.Platform$OS.type == "windows") {
  system(cmd, wait = FALSE, minimized = FALSE, invisible = FALSE)
} else {
  system(cmd, wait = FALSE)
}

# wait for worker to be ready
worker_ready <- FALSE
deadline <- Sys.time() + 5
while (Sys.time() < deadline) {
  cat("  waiting for worker...\n")
  Sys.sleep(0.3)
  probe <- tryCatch(
    socket("req", dial = sprintf("ws://127.0.0.1:%d", PORT), autostart = TRUE),
    error = function(e) NULL
  )
  if (!is.null(probe)) {
    close(probe)
    worker_ready <- TRUE
    break
  }
}

if (!worker_ready) {
  cat("  WORKER NEVER STARTED (or probe connection hung)\n")
  quit(save = "no", status = 1L)
}

cat(sprintf("  worker ready, dialing (timeout=%ds)...\n", TIMEOUT))
t0 <- Sys.time()

req2 <- tryCatch(
  socket("req", dial = sprintf("ws://127.0.0.1:%d", PORT), autostart = TRUE),
  error = function(e) {
    cat(sprintf("  socket ERROR: %s\n", conditionMessage(e)))
    NULL
  }
)

if (is.null(req2)) {
  cat("  FAIL: socket() returned NULL or errored\n")
  quit(save = "no", status = 1L)
}

cat(sprintf("  socket OK (%.1f s)\n", as.numeric(difftime(Sys.time(), t0, units = "secs"))))

ctx2 <- context(req2)
cat(sprintf("  context OK (%.1f s)\n", as.numeric(difftime(Sys.time(), t0, units = "secs"))))

cat("  sending request...\n")
res2 <- request(ctx2, charToRaw("ping"), timeout = TIMEOUT * 1000L)

if (inherits(res2$data, "errorValue")) {
  cat(sprintf("  request ERROR: %s\n", res2$data))
} else if (is.raw(res2$data)) {
  cat(sprintf("  request OK: %s\n", rawToChar(res2$data)))
} else {
  cat(sprintf("  request: data type=%s\n", typeof(res2$data)))
}

close(req2)
cat(sprintf("  elapsed: %.2f s\n", as.numeric(difftime(Sys.time(), t0, units = "secs"))))

cat("\n=== DONE ===\n")
quit(save = "no", status = 0L)
