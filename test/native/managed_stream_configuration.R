# Run only in a timeout-supervised fresh R process with a guarded duckdb-r.
# A managed stream must leave the user's configuration alone, and the thread
# count must be changeable between fetches.
library(Rducks)
mode <- commandArgs(trailingOnly = TRUE)[[1L]]
say <- function(...) { cat(..., '\n'); flush.console() }
drv <- duckdb::duckdb(config = Rducks::rducks_duckdb_config(), shared_home = FALSE)
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
  error <- tryCatch({ force(expr); NULL }, error = identity)
  stopifnot(inherits(error, 'error'), grepl('locked', conditionMessage(error), fixed = TRUE))
  say('REJECTED', label)
}
zero_queue <- function() {
  stats <- rducks_inproc_stats(con)
  stopifnot(stats$pending_current == 0, stats$running_current == 0, stats$timeouts == 0)
}
enable <- function(threads = 4L) rducks_enable_inproc(con, threads = threads, external_threads = 1L)

if (mode == 'between') {
  # Changing the thread count joins every DuckDB worker. That is safe only
  # when no worker waits for R, which holds between fetches: the engine does
  # not produce a streaming result while no fetch is running.
  rducks_register_scalar_udf(con, 'stream_identity', function(x) { Sys.sleep(0.003); x },
    args = INTEGER, returns = INTEGER, mode = 'vectorized', side_effects = TRUE)
  DBI::dbExecute(con, 'CREATE TABLE stream_input AS SELECT i::INTEGER AS i FROM range(4000000) t(i)')
  enable(8L)
  DBI::dbExecute(con, 'SET preserve_insertion_order=false')
  shapes <- c(
    project = 'SELECT stream_identity(i) AS i FROM stream_input',
    filter = 'SELECT i FROM stream_input WHERE stream_identity(i) % 3 = 0',
    union = 'SELECT stream_identity(i) AS i FROM stream_input UNION ALL SELECT stream_identity(i + 1) FROM stream_input',
    join = 'SELECT stream_identity(a.i) AS i FROM stream_input a JOIN (SELECT i FROM stream_input WHERE i < 200000) b USING (i)'
  )
  for (shape in names(shapes)) {
    stream <- rducks_query_stream(con, shapes[[shape]])
    stopifnot(!isTRUE(settings()$locked))
    for (round in seq_len(24L)) {
      stopifnot(nrow(stream$next_batch()) > 0L)
      Sys.sleep(0.005)
      zero_queue()
      target <- c(2L, 8L, 1L, 4L)[[round %% 4L + 1L]]
      DBI::dbExecute(if (round %% 2L) con else sibling, sprintf('SET threads = %d', target))
      stopifnot(settings()$threads == target)
    }
    stopifnot(rducks_inproc_stats(con)$submitted > 0)
    stream$close()
    zero_queue()
    say('BETWEEN_FETCHES_OK', shape)
  }
} else if (mode == 'untouched') {
  # Open, failed, abandoned and released streams leave every setting as found.
  rducks_register_scalar_udf(con, 'stream_failure', function(x) stop('callback failure'),
    args = INTEGER, returns = INTEGER, mode = 'vectorized', side_effects = TRUE)
  enable()
  DBI::dbExecute(sibling, "SET allowed_configs=['threads','enable_progress_bar']")
  before <- settings()
  stream <- rducks_query_stream(con, 'SELECT i::INTEGER FROM range(100000) t(i)')
  stopifnot(nrow(stream$next_batch()) > 0L, identical(settings(), before))
  stream$close()
  stopifnot(identical(settings(), before))
  for (sql in c('SELECT this_table_does_not_exist', 'SELECT stream_failure(i::INTEGER) FROM range(10000) t(i)')) {
    error <- tryCatch({
      failing <- rducks_query_stream(con, sql)
      failing$next_batch()
      failing$close()
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
} else if (mode == 'prelocked') {
  # A configuration lock set by the user stays the user's: Rducks neither
  # widens nor narrows it, during the stream or after it.
  enable()
  DBI::dbExecute(sibling, "SET allowed_configs=['threads','enable_progress_bar']")
  DBI::dbExecute(sibling, 'SET lock_configuration=true')
  before <- settings()
  stream <- rducks_query_stream(con, 'SELECT i::INTEGER FROM range(100000) t(i)')
  stopifnot(nrow(stream$next_batch()) > 0L, identical(settings(), before))
  reject(DBI::dbExecute(sibling, "SET memory_limit='1GB'"), 'user memory restriction during the stream')
  reject(DBI::dbExecute(sibling, 'SET lock_configuration=false'), 'user lock during the stream')
  DBI::dbExecute(sibling, 'SET enable_progress_bar=false')
  DBI::dbExecute(sibling, 'SET threads=2')
  stopifnot(settings()$threads == 2)
  stream$close()
  reject(DBI::dbExecute(sibling, "SET memory_limit='1GB'"), 'user memory restriction after the stream')
  stopifnot(isTRUE(settings()$locked), identical(settings()$allowed, before$allowed))
} else if (mode == 'rducks-calls') {
  # Rducks' own configuration entry points refuse to change the scheduler from
  # a callback of an open stream, without any configuration lock.
  state <- new.env(parent = emptyenv())
  state$errors <- NULL
  rducks_register_scalar_udf(con, 'stream_reentrant', function(x) {
    if (is.null(state$errors)) {
      state$errors <- vapply(list(
        function() rducks_enable_inproc(con, threads = 2L, external_threads = 1L),
        function() rducks_enable(con, threads = 'single'),
        function() rducks_set_execution_plan(con, 'serial')
      ), function(f) tryCatch({ f(); NA_character_ }, error = conditionMessage), character(1L))
    }
    x
  }, args = INTEGER, returns = INTEGER, mode = 'vectorized', side_effects = TRUE)
  enable()
  before <- settings()
  stream <- rducks_query_stream(con, 'SELECT stream_reentrant(i::INTEGER) AS i FROM range(10000) t(i)')
  stopifnot(nrow(stream$next_batch()) > 0L, length(state$errors) == 3L, !anyNA(state$errors))
  say('REJECTED', paste(unique(state$errors), collapse = ' | '))
  stream$close()
  stopifnot(identical(settings(), before))
  zero_queue()
} else stop('Unknown mode: ', mode)

try(rducks_release(con), silent = TRUE)
DBI::dbDisconnect(sibling)
DBI::dbDisconnect(con, shutdown = TRUE)
say('PASS managed stream configuration:', mode)
