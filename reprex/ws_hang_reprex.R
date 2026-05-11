#!/usr/bin/env Rscript
#
# Minimal reprex for NNG WS transport hang on Windows.
# Uses nanonext only — no Rducks dependency.
#
# Expected behaviour on Linux/macOS:
#   All operations complete within ~2s (last op times out with error).
#
# Expected behaviour on Windows (with the NNG bug):
#   Hangs at DIAL or CTX and gets killed by the CI timeout (2 min).

library(nanonext)

TIMEOUT_MS <- 3000L
ok <- TRUE

# Phase 1: WS listener (rep socket)
cat(sprintf("[%.1f] LISTEN: creating WS rep socket...\n", proc.time()[["elapsed"]]))
rep_sock <- tryCatch(
  socket("rep", listen = "ws://127.0.0.1:18765"),
  error = function(e) {
    cat(sprintf("[%.1f] LISTEN FAIL: %s\n", proc.time()[["elapsed"]], conditionMessage(e)))
    ok <<- FALSE
    NULL
  }
)

if (is.null(rep_sock)) {
  cat(sprintf("[%.1f] SKIP: WS rep socket creation failed\n", proc.time()[["elapsed"]]))
} else {
  url <- "ws://127.0.0.1:18765"
  cat(sprintf("[%.1f] LISTEN: rep socket on %s\n", proc.time()[["elapsed"]], url))

  # Phase 2: WS dialer (req socket)
  cat(sprintf("[%.1f] DIAL: creating WS req socket...\n", proc.time()[["elapsed"]]))
  req_sock <- tryCatch(
    socket("req", dial = url, autostart = TRUE),
    error = function(e) {
      cat(sprintf("[%.1f] DIAL FAIL: %s\n", proc.time()[["elapsed"]], conditionMessage(e)))
      ok <<- FALSE; NULL
    }
  )

  if (is.null(req_sock)) {
    cat(sprintf("[%.1f] SKIP: WS req socket creation failed\n", proc.time()[["elapsed"]]))
  } else {
    cat(sprintf("[%.1f] DIAL: req socket created OK\n", proc.time()[["elapsed"]]))

    # Phase 3: Context
    cat(sprintf("[%.1f] CTX: creating context...\n", proc.time()[["elapsed"]]))
    ctx <- tryCatch(
      context(req_sock),
      error = function(e) {
        cat(sprintf("[%.1f] CTX FAIL: %s\n", proc.time()[["elapsed"]], conditionMessage(e)))
        ok <<- FALSE; NULL
      }
    )

    if (is.null(ctx)) {
      cat(sprintf("[%.1f] SKIP: context creation failed\n", proc.time()[["elapsed"]]))
    } else {
      cat(sprintf("[%.1f] CTX: context created OK\n", proc.time()[["elapsed"]]))

      # Phase 4: Request
      cat(sprintf("[%.1f] REQ: sending with %dms timeout...\n", proc.time()[["elapsed"]], TIMEOUT_MS))
      result <- tryCatch(
        request(ctx, data = charToRaw("ping"), send_mode = "raw", recv_mode = "raw", timeout = TIMEOUT_MS),
        error = function(e) {
          cat(sprintf("[%.1f] REQ FAIL: %s\n", proc.time()[["elapsed"]], conditionMessage(e)))
          ok <<- FALSE; NULL
        }
      )

      if (!is.null(result)) {
        if (inherits(result$data, "errorValue")) {
          cat(sprintf("[%.1f] REQ: error = %s\n", proc.time()[["elapsed"]], result$data))
        } else if (is.raw(result$data)) {
          cat(sprintf("[%.1f] REQ: response = %s\n", proc.time()[["elapsed"]], rawToChar(result$data)))
        } else {
          cat(sprintf("[%.1f] REQ: data = %s\n", proc.time()[["elapsed"]], result$data))
        }
      }
      close(ctx)
    }
    close(req_sock)
  }
  close(rep_sock)
}

cat(sprintf("[%.1f] DONE (ok=%s)\n", proc.time()[["elapsed"]], ok))
quit(save = "no", status = if (ok) 0L else 1L)
