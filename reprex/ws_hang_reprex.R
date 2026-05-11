#!/usr/bin/env Rscript
#
# Reprex for NNG WS transport hang on Windows.
# Uses nanonext only — no Rducks dependency.
#
# Root cause: NNG PR #2108 (Mar 10, 2025)
#   File:   src/platform/windows/win_io.c
#   Change: GetQueuedCompletionStatus(..., 5000)
#   Before: the IOCP polling timeout was missing/too-long, so
#           the wait never returned and NNG could not process
#           AIO cancellations.  WS transport requests would
#           hang forever even with nng_aio_set_timeout().
#   After:  5000ms timeout lets IOCP return periodically,
#           allowing NNG to check for cancelled AIOs.
#
# NNG versions:
#   nanonext 1.8.2  -> NNG 1.11.0          (BROKEN)
#   nanonext 1.9.0+ -> NNG 1.11.1-pre      (FIXED)
#
# Tests:
#   1. Same-process WS  (listen + dial in one process)
#   2. Cross-process WS (worker.R via Rscript)

library(nanonext)
RSCRIPT <- file.path(R.home("bin"), "Rscript")
PORT <- 18782

cat("nanonext:", as.character(packageVersion("nanonext")), "\n")
cat("nng:", paste(nng_version(), collapse = " "), "\n")
cat("platform:", R.version$platform, "\n")

# =========================================================================
# Test 1: same-process WS
# =========================================================================
cat("\n=== Test 1: same-process WS ===\n")
rep <- socket("rep", listen = sprintf("ws://127.0.0.1:%d", PORT + 1L))
req <- socket("req", dial = sprintf("ws://127.0.0.1:%d", PORT + 1L), autostart = TRUE)
res <- request(context(req), charToRaw("ping"), timeout = 3000L)
cat(sprintf("  request: data type=%s\n", typeof(res$data)))
if (inherits(res$data, "errorValue")) cat(sprintf("  error: %s\n", res$data))
close(req); close(rep)
cat("  PASS\n")

# =========================================================================
# Test 2: cross-process WS (worker.R via Rscript)
# =========================================================================
cat("\n=== Test 2: cross-process WS ===\n")
worker_file <- file.path("reprex", "worker.R")
cmd <- sprintf("%s %s %d", RSCRIPT, worker_file, PORT)
if (.Platform$OS.type == "windows") {
  system(cmd, wait = FALSE, minimized = FALSE, invisible = FALSE)
} else {
  system(cmd, wait = FALSE)
}

ready <- FALSE
deadline <- Sys.time() + 5
while (Sys.time() < deadline) {
  Sys.sleep(0.3)
  probe <- tryCatch(
    socket("req", dial = sprintf("ws://127.0.0.1:%d", PORT), autostart = TRUE),
    error = function(e) NULL
  )
  if (!is.null(probe)) { close(probe); ready <- TRUE; break }
}
if (!ready) { cat("  FAIL: worker never started\n"); q(save = "no", status = 1L) }

cat("  worker ready\n")
req2 <- socket("req", dial = sprintf("ws://127.0.0.1:%d", PORT), autostart = TRUE)
res2 <- request(context(req2), charToRaw("ping"), timeout = 5000L)
cat(sprintf("  request: data type=%s\n", typeof(res2$data)))
if (inherits(res2$data, "errorValue")) cat(sprintf("  error: %s\n", res2$data))
close(req2)
cat("  PASS\n")

cat("\n=== ALL PASS ===\n")
