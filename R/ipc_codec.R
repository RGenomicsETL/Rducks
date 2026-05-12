rducks_as_raw_payload <- function(payload, what = "payload") {
  if (is.raw(payload)) return(payload)
  if (!is.numeric(payload) || anyNA(payload) || any(!is.finite(payload)) ||
      any(payload < 0 | payload > 255 | payload != floor(payload))) {
    stop(what, " must be a raw vector or byte-valued numeric vector", call. = FALSE)
  }
  as.raw(payload)
}

rducks_arrow_ipc_encode <- function(data) {
  if (!inherits(data, "nanoarrow_array")) {
    stop("Arrow IPC native path requires a nanoarrow_array", call. = FALSE)
  }
  .Call(RDUCKS_arrow_ipc_encode_array, data)
}

rducks_arrow_ipc_decode_stream <- function(payload, lazy = FALSE) {
  payload <- rducks_as_raw_payload(payload, "Arrow IPC payload")
  nanoarrow::read_nanoarrow(payload, lazy = lazy)
}

rducks_arrow_ipc_decode_array <- function(payload) {
  stream <- rducks_arrow_ipc_decode_stream(payload, lazy = FALSE)
  schema <- stream$get_schema()
  array <- stream$get_next(schema)
  if (is.null(array)) {
    stop("Arrow IPC payload did not contain a record batch", call. = FALSE)
  }
  extra <- stream$get_next(schema)
  if (!is.null(extra)) {
    stop("Arrow IPC payload contained more than one record batch", call. = FALSE)
  }
  nanoarrow::nanoarrow_array_set_schema(array, schema)
  list(array = array, schema = schema)
}

rducks_arrow_schema_to_spec <- function(schema) {
  schema <- nanoarrow::as_nanoarrow_schema(schema)
  list(
    format = schema$format %||% "",
    name = schema$name %||% "",
    metadata = as.list(schema$metadata %||% list()),
    flags = as.integer(schema$flags %||% 0L),
    children = lapply(schema$children %||% list(), rducks_arrow_schema_to_spec),
    dictionary = if (is.null(schema$dictionary)) NULL else rducks_arrow_schema_to_spec(schema$dictionary)
  )
}

rducks_arrow_schema_from_spec <- function(spec) {
  children <- lapply(spec$children %||% list(), rducks_arrow_schema_from_spec)
  dictionary <- if (is.null(spec$dictionary)) NULL else rducks_arrow_schema_from_spec(spec$dictionary)
  nanoarrow::nanoarrow_schema_modify(
    nanoarrow::as_nanoarrow_schema(nanoarrow::na_na()),
    list(
      format = spec$format %||% "n",
      name = spec$name %||% "",
      metadata = as.list(spec$metadata %||% list()),
      flags = as.integer(spec$flags %||% 0L),
      children = children,
      dictionary = dictionary
    ),
    validate = TRUE
  )
}
