#!/usr/bin/env Rscript
#
# Minimal reprex for NNG WS transport issues on Windows.
# Uses nanonext only — no Rducks dependency.
#
# Findings:
#
# Same-process WS (listen + dial in one R process) works on all
# three platforms — Linux, macOS, Windows — all complete in <0.2s.
#
# The hang in Rducks CI occurs during cross-process WS: a mirai
# worker (separate R process) creates a rep WS listener, then the
# main process dials it.  The main process's socket() or request()
# call hangs indefinitely even with a timeout set.
#
# Suspected NNG code path (nanonext src/comms.c ~line 127):
#   nng_dial(*sock, url, dp,
#            start == 1 ? NNG_FLAG_NONBLOCK : 0)
# With autostart=TRUE, start=1 => NONBLOCK, so nng_dial()
# returns immediately.  The hang likely occurs in the NNG event
# loop on Windows IOCP when the WS transport's internal TCP/HTTP
# state machine is not cancelled by nng_aio_stop().
#
# Versions:
#   nanonext 1.8.2  => bundles NNG 1.11.0 + Mbed TLS 3.6.5
#   nanonext 1.9.0+ => bundles NNG 1.11.1-pre
#   NNG source: https://github.com/nanomsg/nng
#   WS transport: src/sp/transport/ws/ws_dial.c
#   nanonext repo: https://github.com/r-lib/nanonext

library(nanonext)
cat("nanonext:", as.character(packageVersion("nanonext")), "\n")
cat("nng:", paste(nng_version(), collapse = " "), "\n")
cat("platform:", R.version$platform, "\n")
cat("os:", R.version$os, "\n")

# -----------------------------------------------------------------------------
# Test: same-process WS (listen + dial)
# -----------------------------------------------------------------------------
cat("\n=== same-process WS ===\n")
cat(sprintf("[%.2f] rep socket listen ws://127.0.0.1:18771\n", proc.time()[["elapsed"]]))
rep <- socket("rep", listen = "ws://127.0.0.1:18771")

cat(sprintf("[%.2f] req socket dial\n", proc.time()[["elapsed"]]))
req <- socket("req", dial = "ws://127.0.0.1:18771", autostart = TRUE)

cat(sprintf("[%.2f] create context\n", proc.time()[["elapsed"]]))
ctx <- context(req)

cat(sprintf("[%.2f] request (timeout=1s)\n", proc.time()[["elapsed"]]))
res <- request(ctx, charToRaw("ping"), timeout = 1000L)

if (inherits(res$data, "errorValue")) {
  cat(sprintf("[%.2f] request result: %s\n", proc.time()[["elapsed"]], res$data))
} else if (is.raw(res$data)) {
  cat(sprintf("[%.2f] request result: %d raw bytes\n", proc.time()[["elapsed"]], length(res$data)))
} else {
  cat(sprintf("[%.2f] request result: type=%s\n", proc.time()[["elapsed"]], typeof(res$data)))
}

close(req)
close(rep)
cat(sprintf("[%.2f] DONE\n", proc.time()[["elapsed"]]))
quit(save = "no", status = 0L)
