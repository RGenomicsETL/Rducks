library(Rducks)

# Native-path defenses against a malformed/buggy external ipc endpoint. Fake NNG
# workers return results whose embedded indices are out of range (a union tag
# past the member count, an enum code past the dictionary); the native writeback
# must reject them rather than index a non-existent member / dictionary entry.
# Gated (spawns mirai daemons + an NNG socket) like the other worker tests.
if (!identical(tolower(Sys.getenv("RDUCKS_RUN_IPC_TESTS", "")), "true")) {
  exit_file("external-endpoint malformed test disabled (set RDUCKS_RUN_IPC_TESTS=true)")
}
if (!requireNamespace("duckdb", quietly = TRUE) || !requireNamespace("DBI", quietly = TRUE) ||
    !requireNamespace("mirai", quietly = TRUE) || !requireNamespace("nanonext", quietly = TRUE)) {
  exit_file("ipc dependencies not available")
}

# A fake REP worker that, for an execute request, returns `make_result(n)` (a raw
# Quack chunk payload) verbatim; replies OK to ping/register/stop.
fake_worker <- function(ep, make_result) {
  suppressMessages({library(Rducks); library(nanonext)})
  sock <- nanonext::socket("rep", listen = ep)
  ctx <- nanonext::context(sock)
  repeat {
    rr <- nanonext::recv(ctx, mode = "raw", block = TRUE)
    if (nanonext::is_error_value(rr)) next
    stopf <- FALSE
    resp <- tryCatch({
      req <- Rducks:::rducks_nng_wire_decode_request(rr)
      if (identical(req$type, Rducks:::rducks_nng_wire_type_execute)) {
        Rducks:::rducks_nng_wire_encode_response("ok", make_result(req$row_count))
      } else {
        if (identical(req$type, Rducks:::rducks_nng_wire_type_stop)) stopf <- TRUE
        Rducks:::rducks_nng_wire_encode_response("ok", raw())
      }
    }, error = function(e) Rducks:::rducks_nng_wire_encode_response("error", raw(), conditionMessage(e)))
    nanonext::send(ctx, resp, mode = "raw", block = 3000)
    if (stopf) break
  }
}

run_external_malformed <- function(make_result, register, query, expect_pattern, info) {
  sock_path <- tempfile("rducks_fake_", fileext = ".sock")
  ep <- paste0("ipc://", sock_path)
  on.exit(try(unlink(sock_path, force = TRUE), silent = TRUE), add = TRUE)
  mirai::daemons(1L)
  on.exit(try(mirai::daemons(0L), silent = TRUE), add = TRUE)
  mirai::mirai(fake_worker(ep, make_result), fake_worker = fake_worker, ep = ep, make_result = make_result)
  ready <- FALSE
  for (i in seq_len(200L)) {
    if (file.exists(sock_path)) { ready <- TRUE; break }
    Sys.sleep(0.05)
  }
  expect_true(ready, info = paste0("fake ipc endpoint ready: ", info))

  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")
  plan <- rducks_execution_plan("ipc", ipc_endpoints = ep, ipc_timeout = 20)
  rducks_set_execution_plan(con, plan, threads = 1L, external_threads = 1L)
  register(con)
  rducks_set_execution_plan(con, plan, threads = 2L, external_threads = 1L)
  expect_error(query(con), pattern = expect_pattern, info = info)
}

# UNION result with a tag past the member count.
run_external_malformed(
  make_result = function(n) {
    p <- Rducks:::rducks_wire_encode_values(
      list(UNION(a = INTEGER, b = VARCHAR)),
      list(lapply(seq_len(n), function(i) rducks_union("a", i))), n)
    pat <- c(0x67L, 0x00L, 0x03L, 0x64L, 0x00L, 0x00L, 0x66L, 0x00L, 0x01L)
    ti <- which(vapply(seq_len(length(p) - length(pat)),
                       function(k) all(as.integer(p[k:(k + length(pat) - 1)]) == pat), logical(1)))[1]
    if (is.na(ti)) stop("fake endpoint: union tag byte pattern not found")
    p[ti + length(pat)] <- as.raw(255L)
    p
  },
  register = function(con) rducks_register_scalar_udf(con, "u_ext", function(x) x,
                            args = list(UNION(a = INTEGER, b = VARCHAR)),
                            returns = UNION(a = INTEGER, b = VARCHAR)),
  query = function(con) DBI::dbGetQuery(con,
            "SELECT union_extract(u_ext(union_value(a := i::INTEGER)), 'a') v FROM range(1) t(i)"),
  expect_pattern = "union result tag is out of range",
  info = "native writeback rejects an out-of-range union tag from an external endpoint"
)

# ENUM result with a dictionary index past the declared label count.
run_external_malformed(
  make_result = function(n) {
    p <- Rducks:::rducks_wire_encode_values(
      list(ENUM(c("a", "b", "c"))),
      list(rducks_enum(rep("a", n), levels = c("a", "b", "c"))), n)
    idxs <- which(vapply(seq_len(length(p) - 1L),
                         function(k) all(as.integer(p[k:(k + 1L)]) == c(0x66L, 0x00L)), logical(1)))
    di <- idxs[length(idxs)]  # last field-102 block is the enum vector data
    if (is.na(di)) stop("fake endpoint: enum data field not found")
    p[di + 3L] <- as.raw(200L)  # first code byte out of range
    p
  },
  register = function(con) {
    DBI::dbExecute(con, "CREATE TYPE e3 AS ENUM ('a','b','c')")
    rducks_register_scalar_udf(con, "e_ext", function(x) x,
      args = list(ENUM(c("a", "b", "c"))), returns = ENUM(c("a", "b", "c")))
  },
  query = function(con) DBI::dbGetQuery(con, "SELECT e_ext('a'::e3) v FROM range(1) t(i)"),
  expect_pattern = "enum result index is out of range",
  info = "native writeback rejects an out-of-range enum index from an external endpoint"
)
