rducks_make_native_engine <- function(fun, spec, null_handling, exception_handling,
                                      plan, eval_rows) {
  force(fun)
  force(spec)
  force(null_handling)
  force(exception_handling)
  force(plan)
  force(eval_rows)
  list(
    fun = fun,
    arg_types = spec$arg_types,
    return_type = spec$return_type,
    null_handling = null_handling,
    exception_handling = exception_handling,
    plan = plan,
    prepare_inputs = rducks_wire_prepared_inputs,
    eval_rows = eval_rows,
    results_to_wire = rducks_scalar_results_to_wire,
    serialization = if (identical(plan$serialization, "quack")) list(
      kind = "quack",
      encode = rducks_wire_encode_values,
      decode = rducks_wire_decode_values
    ) else NULL
  )
}

rducks_make_scalar_engine <- function(fun, spec, null_handling, exception_handling,
                                      plan = rducks_execution_plan()) {
  rducks_make_native_engine(fun, spec, null_handling, exception_handling, plan, rducks_scalar_eval_prepared_rows)
}

rducks_make_vectorized_engine <- function(fun, spec, null_handling, exception_handling,
                                          plan = rducks_execution_plan()) {
  rducks_make_native_engine(fun, spec, null_handling, exception_handling, plan, rducks_vectorized_eval_prepared_chunk)
}

# Direct-evaluator bundle, consumed by the extension by index (see
# RDUCKS_RC_BUNDLE_* in the extension sources). The slow path hands the
# recorded R thread a self-describing quack payload; the fast path keeps
# building SEXP columns directly in C.
rducks_rc_prepare_inputs <- rducks_wire_prepared_inputs

rducks_make_rc_bundle <- function(fun, spec, null_handling, exception_handling, plan, engine, eval_rows) {
  list(
    fun = fun,
    arg_types = spec$arg_types,
    return_type = spec$return_type,
    prepare_inputs = rducks_wire_prepared_inputs,
    check_return = rducks_check_scalar_udf_return,
    result_array = rducks_scalar_results_to_wire,
    eval_rows = eval_rows,
    engine = engine,
    plan = plan,
    null_handling = null_handling,
    exception_handling = exception_handling
  )
}

rducks_make_rc_scalar_bundle <- function(fun, spec,
                                         null_handling = "default",
                                         exception_handling = "rethrow",
                                         plan = rducks_execution_plan()) {
  engine <- rducks_make_scalar_engine(
    fun, spec,
    null_handling = null_handling,
    exception_handling = exception_handling,
    plan = plan
  )
  rducks_make_rc_bundle(
    fun, spec,
    null_handling = null_handling,
    exception_handling = exception_handling,
    plan = plan,
    engine = engine,
    eval_rows = rducks_scalar_eval_prepared_rows
  )
}

rducks_make_rc_vectorized_bundle <- function(fun, spec,
                                             null_handling = "default",
                                             exception_handling = "rethrow",
                                             plan = rducks_execution_plan()) {
  engine <- rducks_make_vectorized_engine(
    fun, spec,
    null_handling = null_handling,
    exception_handling = exception_handling,
    plan = plan
  )
  rducks_make_rc_bundle(
    fun, spec,
    null_handling = null_handling,
    exception_handling = exception_handling,
    plan = plan,
    engine = engine,
    eval_rows = rducks_vectorized_eval_prepared_chunk
  )
}
