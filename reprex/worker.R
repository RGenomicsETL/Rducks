# Background WS worker — launched by ws_hang_reprex.R
library(nanonext)
port <- as.integer(commandArgs(trailingOnly = TRUE)[[1]])

rep <- socket("rep", listen = sprintf("ws://127.0.0.1:%d", port))
cat("WORKER_READY\n")
flush(stdout())

# Wait for a request, echo it back, then exit
ctx <- context(rep)
msg <- request(ctx, charToRaw("ack"), timeout = 15000L)
close(rep)
