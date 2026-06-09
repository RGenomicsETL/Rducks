# Quack wire payload helpers for the IPC data plane.
#
# Task payloads are self-describing quack DataChunk bytes (see
# src/quack_core.h); the worker decodes them, materializes Rducks values for
# the declared argument types, evaluates, and returns a single-column quack
# payload for the declared return type. The output "schema spec" of the old
# Arrow IPC path is replaced by the declared return type token: the chunk
# bytes already carry their own types.

rducks_wire_encode_values <- function(types, values_list, rows) {
  columns <- Map(function(type, values) {
    array <- rducks_native_array_from_values(type, values, rows)
    rducks_quack_storage_from_array(array)
  }, types, values_list)
  rducks_quack_encode_columns(types, columns, rows)
}

rducks_wire_decode_values <- function(arg_types, payload) {
  decoded <- rducks_quack_decode_payload(payload)
  if (length(decoded$columns) != length(arg_types)) {
    stop("Rducks wire payload column count disagrees with the declared signature",
         call. = FALSE)
  }
  list(rows = as.integer(decoded$rows),
       values = rducks_quack_columns_to_values(arg_types, decoded))
}
