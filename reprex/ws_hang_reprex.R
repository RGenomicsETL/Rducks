#!/usr/bin/env Rscript
#
# Minimal reprex for NNG WS transport hang on Windows.
# Uses nanonext only — no Rducks dependency.
#
# Tests:
#   1. Same-process WS (listen + dial in one process)
#   2. Cross-process WS (worker.R via Rscript)
#
# Both tests now pass on all platforms with nanonext >= 1.9.0
# (NNG 1.11.1-pre).  The hang was originally observed in Rducks
# CI with nanonext 1.8.2 (NNG 1.11.0 + Mbed TLS 3.6.5) during
# the multiprocess WS transport test where a mirai-launched
# worker (loading the full Rducks + DuckDB extension) was the
# listener.
#
# If this reprex passes on Windows with the CI's nanonext, the
# fix is likely in NNG 1.11.1-pre and the WS exclusion can be
# removed from Rducks for users with nanonext >= 1.9.0.
#
# Versions:
#   nanonext 1.8.2  -> NNG 1.11.0 + Mbed TLS 3.6.5  (HUNG on Windows)
#   nanonext 1.9.0+ -> NNG 1.11.1-pre               (WORKS on Windows)
#   NNG source:      https://github.com/nanomsg/nng
#   WS transport:    src/sp/transport/ws/ws_dial.c
#   nanonext repo:   https://github.com/r-lib/nanonext
#   nanonext dial:   src/comms.c line 127

library(nanonext)
RSCRIPT <- file.path(R.home("bin"), "Rscript")
PORT <- 18782
TIMEOUT_MS <- 5000L

cat("nanonext:", as.character(packageVersion("nanonext")), "\n")
cat("nng:", paste(nng_version(), collapse = " "), "\n")
cat("platform:", R.version$platform, "\n")

# =========================================================================
# Test 1: same-process WS
# =========================================================================
cat("\n=== Test 1: same-process WS ===\n")
rep <- socket("rep", listen = sprintf("ws://127.0.0.1:%d", PORT + 1L))
req <- socket("req", dial = sprintf("ws://127.0.0.1:%d", PORT + 1L), autostart = TRUE)
res <- request(context(req), charToRaw("ping"), timeout = 1000L)
cat(sprintf("  request data type: %s\n", typeof(res$data)))
close(req); close(rep)
cat("  PASS\n")

# =========================================================================
# Test 2: cross-process WS (Rscript worker)
# =========================================================================
cat("\n=== Test 2: cross-process WS ===\n")
worker_file <- file.path("reprex", "worker.R")
cmd <- sprintf("%s %s %d", RSCRIPT, worker_file, PORT)
if (.Platform$OS.type == "windows") {
  system(cmd, wait = FALSE, minimized = FALSE, invisible = FALSE)
} else {
  system(cmd, wait = FALSE)
}

# probe loop
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
if (!ready) { cat("  FAIL: worker never ready\n"); q(save = "no", status = 1L) }

cat("  worker ready\n")
req2 <- socket("req", dial = sprintf("ws://127.0.0.1:%d", PORT), autostart = TRUE)
res2 <- request(context(req2), charToRaw("ping"), timeout = TIMEOUT_MS)
cat(sprintf("  request data type: %s\n", typeof(res2$data)))
close(req2)
cat("  PASS\n")

cat("\n=== ALL PASS ===\n")
