# Quack wire payload helpers for the IPC data plane.
#
# Task payloads are self-describing quack DataChunk bytes (see
# src/quack_core.h): the worker decodes them, validates the decoded wire types
# against the declared signature, materializes Rducks values, evaluates, and
# returns a single-column quack payload for the declared return type. The chunk
# bytes carry their own types, so a task needs no separate schema alongside it.

rducks_wire_encode_values <- function(types, values_list, rows) {
  columns <- Map(function(type, values) {
    array <- rducks_native_array_from_values(type, values)
    rducks_quack_storage_from_array(array)
  }, types, values_list)
  rducks_quack_encode_columns(types, columns, rows)
}

rducks_wire_decode_values <- function(arg_types, payload) {
  # The payload is self-describing; validate its decoded wire types against the
  # declared signature (column count + per-column type) inside the decoder before
  # any column is materialized. The input boundary is native-produced and so
  # trusted, but the check is near-free here -- the decoder already reconstructs
  # the types -- and keeps the codec self-consistent against protocol drift.
  expected <- lapply(arg_types, rducks_quack_spec)
  decoded <- rducks_quack_decode_payload(payload, expected)
  list(rows = as.integer(decoded$rows),
       values = rducks_quack_columns_to_values(arg_types, decoded))
}
