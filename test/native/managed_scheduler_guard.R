# Run only in a timeout-supervised fresh R process with guarded duckdb v2.
library(Rducks)
mode <- commandArgs(trailingOnly = TRUE)[[1L]]
say <- function(...) { cat(..., '\n'); flush.console() }
drv <- duckdb::duckdb(config = list(allow_unsigned_extensions = 'true'), shared_home = FALSE)
con <- DBI::dbConnect(drv)
sibling <- DBI::dbConnect(drv)
rducks_enable(con, threads = 'single')
stopifnot(Rducks:::rducks_query_stream_driver_available(con))
settings <- function() {
  x <- DBI::dbGetQuery(sibling, paste(
    "SELECT current_setting('threads') AS threads,",
    "current_setting('external_threads') AS external_threads,",
    "current_setting('lock_configuration') AS locked,",
    "current_setting('allowed_configs') AS allowed"
  ))
  list(threads = x$threads, external_threads = x$external_threads,
       locked = x$locked, allowed = sort(as.character(x$allowed[[1L]])))
}
reject <- function(expr, label) {
  say('TRY', label)
  error <- tryCatch({ force(expr); NULL }, error = identity)
  stopifnot(inherits(error, 'error'), grepl('locked', conditionMessage(error), fixed = TRUE))
  say('REJECTED', label)
}
zero_queue <- function() {
  stats <- rducks_inproc_stats(con)
  stopifnot(stats$pending_current == 0, stats$running_current == 0, stats$timeouts == 0)
}
enable <- function() rducks_enable_inproc(con, threads = 4L, external_threads = 1L)

if (mode == 'pending') {
  # Parameterized DBI statements really are prepared now and executed later.
  # PREPARE ... AS SET is not accepted by the DuckDB SQL parser.
  cached <- lapply(c('threads', 'worker_threads', 'external_threads', 'lock_configuration', 'allowed_configs'), function(setting) {
    DBI::dbSendStatement(sibling, paste('SET', setting, '= ?'))
  })
  rducks_register_scalar_udf(con, 'scheduler_identity', function(x) { Sys.sleep(0.005); x },
    args = INTEGER, returns = INTEGER, mode = 'vectorized', side_effects = TRUE)
  DBI::dbExecute(con, 'CREATE TABLE scheduler_input AS SELECT i::INTEGER AS i FROM range(10000000) t(i)')
  rducks_enable_inproc(con, threads = 8L, external_threads = 1L)
  DBI::dbExecute(con, 'SET preserve_insertion_order=false')
  before <- settings()
  stream <- rducks_query_stream(con, 'SELECT scheduler_identity(i) AS i FROM scheduler_input')
  pending <- FALSE
  for (attempt in seq_len(100L)) {
    stopifnot(nrow(stream$next_batch()) > 0L)
    Sys.sleep(0.01)
    pending <- rducks_inproc_stats(con)$pending_current > 0
    if (pending) break
  }
  stopifnot(pending)
  say('PENDING_CALLBACK_CONFIRMED')
  protected <- c('SET threads=1', 'SET worker_threads=1', 'SET external_threads=2',
    'PRAGMA threads=1', 'PRAGMA worker_threads=1', 'PRAGMA external_threads=2',
    'PRAGMA lock_configuration=false', "PRAGMA allowed_configs=['threads']", 'RESET threads', 'RESET worker_threads',
    'RESET external_threads', 'SET lock_configuration=false', 'RESET lock_configuration',
    "SET allowed_configs=['threads']", 'RESET allowed_configs')
  for (connection in list(con, sibling)) {
    for (sql in protected) reject(DBI::dbExecute(connection, sql), sql)
  }
  for (i in seq_along(cached)) {
    params <- if (i == 5L) list(list('threads')) else list(if (i == 4L) FALSE else 1L)
    reject(DBI::dbBind(cached[[i]], params), paste('cached bind', i))
    DBI::dbClearResult(cached[[i]])
  }
  current <- settings()
  stopifnot(identical(current$threads, before$threads),
            identical(current$external_threads, before$external_threads), isTRUE(current$locked))
  DBI::dbExecute(sibling, 'SET enable_progress_bar=false')
  stopifnot(nrow(stream$next_batch()) > 0L)
  stream$close()
  stopifnot(identical(settings(), before))
  zero_queue()
  DBI::dbExecute(sibling, 'SET threads=1')
  stopifnot(DBI::dbGetQuery(sibling, "SELECT current_setting('threads') AS n")$n == 1)
} else if (mode == 'callback') {
  state <- new.env(parent = emptyenv())
  state$checked <- FALSE
  rducks_register_scalar_udf(con, 'scheduler_reentrant', function(x) {
    if (!state$checked) {
      reject(DBI::dbExecute(sibling, 'SET threads=1'), 'callback sibling SET threads')
      reject(DBI::dbExecute(con, 'RESET external_threads'), 'callback same RESET external_threads')
      state$checked <- TRUE
    }
    x
  }, args = INTEGER, returns = INTEGER, mode = 'vectorized', side_effects = TRUE)
  enable()
  before <- settings()
  stream <- rducks_query_stream(con, 'SELECT scheduler_reentrant(i::INTEGER) AS i FROM range(10000) t(i)')
  stopifnot(nrow(stream$next_batch()) > 0L, state$checked)
  stream$close()
  stopifnot(identical(settings(), before))
  zero_queue()
} else if (mode == 'cleanup') {
  rducks_register_scalar_udf(con, 'scheduler_failure', function(x) stop('callback failure'),
    args = INTEGER, returns = INTEGER, mode = 'vectorized', side_effects = TRUE)
  enable()
  DBI::dbExecute(sibling, "SET allowed_configs=['enable_progress_bar']")
  before <- settings()
  for (sql in c('SELECT this_table_does_not_exist', 'SELECT scheduler_failure(i::INTEGER) FROM range(10000) t(i)')) {
    error <- tryCatch({
      stream <- rducks_query_stream(con, sql)
      stream$next_batch()
      stream$close()
      NULL
    }, error = identity)
    stopifnot(inherits(error, 'error'), identical(settings(), before))
    zero_queue()
  }
  local({
    abandoned <- rducks_query_stream(con, 'SELECT i::INTEGER FROM range(100000) t(i)')
    stopifnot(nrow(abandoned$next_batch()) > 0L)
  })
  invisible(gc()); invisible(gc())
  stopifnot(identical(settings(), before))
  zero_queue()
  released <- rducks_query_stream(con, 'SELECT i::INTEGER FROM range(100000) t(i)')
  rducks_release(con)
  stopifnot(identical(settings(), before))
  released$close()
  DBI::dbExecute(sibling, 'SET threads=1')
} else if (mode == 'shadow') {
  DBI::dbExecute(con, 'CREATE MACRO duckdb_r_managed_stream_guard_acquire(x) AS x')
  enable()
  before <- settings()
  stream <- rducks_query_stream(con, 'SELECT i::INTEGER FROM range(10000) t(i)')
  stopifnot(isTRUE(settings()$locked))
  reject(DBI::dbExecute(sibling, 'SET threads=1'), 'shadowed user macro does not bypass native guard')
  stopifnot(nrow(stream$next_batch()) > 0L)
  stream$close()
  stopifnot(identical(settings(), before))
} else if (mode == 'prelocked') {
  enable()
  DBI::dbExecute(sibling, "SET allowed_configs=['threads','external_threads','enable_progress_bar']")
  DBI::dbExecute(sibling, 'SET lock_configuration=true')
  before <- settings()
  stream <- rducks_query_stream(con, 'SELECT i::INTEGER FROM range(10000) t(i)')
  reject(DBI::dbExecute(sibling, 'SET threads=1'), 'prelocked scheduler')
  reject(DBI::dbExecute(sibling, "SET memory_limit='1GB'"), 'preexisting memory restriction')
  reject(DBI::dbExecute(sibling, 'SET lock_configuration=false'), 'preexisting security lock')
  DBI::dbExecute(sibling, 'SET enable_progress_bar=false')
  stream$close()
  stopifnot(identical(settings(), before))
  reject(DBI::dbExecute(sibling, "SET memory_limit='1GB'"), 'restored memory restriction')
  reject(DBI::dbExecute(sibling, 'SET lock_configuration=false'), 'restored security lock')
  DBI::dbExecute(sibling, 'SET threads=1')
} else stop('Unknown mode: ', mode)

try(rducks_release(con), silent = TRUE)
DBI::dbDisconnect(sibling)
DBI::dbDisconnect(con, shutdown = TRUE)
say('PASS scheduler guard:', mode)
