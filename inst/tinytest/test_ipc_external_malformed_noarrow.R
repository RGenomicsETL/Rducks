library(Rducks)

# Native-path defense against a malformed/buggy external ipc endpoint. A fake NNG
# worker returns a UNION result whose tag is out of range; the native writeback
# must reject it ("RIPC union result tag is out of range") rather than index a
# non-existent member. Gated (spawns mirai daemons + an NNG socket) like the
# other worker-process tests.
if (!identical(tolower(Sys.getenv("RDUCKS_RUN_IPC_TESTS", "")), "true")) {
  exit_file("external-endpoint malformed test disabled (set RDUCKS_RUN_IPC_TESTS=true)")
}
if (!requireNamespace("duckdb", quietly = TRUE) || !requireNamespace("DBI", quietly = TRUE) ||
    !requireNamespace("mirai", quietly = TRUE) || !requireNamespace("nanonext", quietly = TRUE)) {
  exit_file("ipc dependencies not available")
}

# Fake REP worker: replies OK to ping/register/stop; for an execute request it
# returns a valid UNION(a, b) result with one tag byte corrupted to 255.
fake_worker <- function(ep) {
  suppressMessages({library(Rducks); library(nanonext)})
  sock <- nanonext::socket("rep", listen = ep)
  ctx <- nanonext::context(sock)
  ut <- UNION(a = INTEGER, b = VARCHAR)
  repeat {
    rr <- nanonext::recv(ctx, mode = "raw", block = TRUE)
    if (nanonext::is_error_value(rr)) next
    stopf <- FALSE
    resp <- tryCatch({
      req <- Rducks:::rducks_nng_wire_decode_request(rr)
      if (identical(req$type, Rducks:::rducks_nng_wire_type_execute)) {
        n <- req$row_count
        vals <- lapply(seq_len(n), function(i) rducks_union("a", i))
        p <- Rducks:::rducks_wire_encode_values(list(ut), list(vals), n)
        pat <- c(0x67L, 0x00L, 0x03L, 0x64L, 0x00L, 0x00L, 0x66L, 0x00L, 0x01L)
        ti <- which(vapply(seq_len(length(p) - length(pat)),
                           function(k) all(as.integer(p[k:(k + length(pat) - 1)]) == pat),
                           logical(1)))[1]
        p[ti + length(pat)] <- as.raw(255L)  # out-of-range union tag
        Rducks:::rducks_nng_wire_encode_response("ok", p)
      } else {
        if (identical(req$type, Rducks:::rducks_nng_wire_type_stop)) stopf <- TRUE
        Rducks:::rducks_nng_wire_encode_response("ok", raw())
      }
    }, error = function(e) Rducks:::rducks_nng_wire_encode_response("error", raw(), conditionMessage(e)))
    nanonext::send(ctx, resp, mode = "raw", block = 3000)
    if (stopf) break
  }
}

local({
  sock_path <- tempfile("rducks_fake_", fileext = ".sock")
  ep <- paste0("ipc://", sock_path)
  on.exit(try(unlink(sock_path, force = TRUE), silent = TRUE), add = TRUE)
  mirai::daemons(1L)
  on.exit(try(mirai::daemons(0L), silent = TRUE), add = TRUE)
  mirai::mirai(fake_worker(ep), fake_worker = fake_worker, ep = ep)  # async; runs in the daemon
  # Wait until the worker has created its listening socket (readiness), rather
  # than sleeping a fixed interval.
  ready <- FALSE
  for (i in seq_len(200L)) {
    if (file.exists(sock_path)) { ready <- TRUE; break }
    Sys.sleep(0.05)
  }
  expect_true(ready, info = "fake ipc endpoint became ready")

  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")
  plan <- rducks_execution_plan("ipc", ipc_endpoints = ep, ipc_timeout = 20)
  rducks_set_execution_plan(con, plan, threads = 1L, external_threads = 1L)
  rducks_register_scalar_udf(con, "u_ext", function(x) x,
                             args = list(UNION(a = INTEGER, b = VARCHAR)),
                             returns = UNION(a = INTEGER, b = VARCHAR))
  rducks_set_execution_plan(con, plan, threads = 2L, external_threads = 1L)

  expect_error(
    DBI::dbGetQuery(con, "SELECT union_extract(u_ext(union_value(a := i::INTEGER)), 'a') v FROM range(1) t(i)"),
    pattern = "union result tag is out of range",
    info = "native writeback rejects an out-of-range union tag from an external endpoint"
  )
})
