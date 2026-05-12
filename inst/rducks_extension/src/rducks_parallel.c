/* Included by ../rducks_extension.c. */

#define RDUCKS_PARALLEL_RANGE_CHUNK 1024ULL

typedef struct rducks_parallel_range_bind {
    uint64_t total;
} rducks_parallel_range_bind_t;

typedef struct rducks_parallel_range_state {
    atomic_uint_fast64_t next;
    uint64_t total;
} rducks_parallel_range_state_t;

static void rducks_parallel_range_bind_destroy(void *ptr) {
    free(ptr);
}

static void rducks_parallel_range_state_destroy(void *ptr) {
    free(ptr);
}

static void rducks_parallel_range_bind(duckdb_bind_info info) {
    duckdb_value value;
    rducks_parallel_range_bind_t *bind;
    duckdb_logical_type ubigint_type;

    if (!info) return;
    if (duckdb_bind_get_parameter_count(info) != 1) {
        duckdb_bind_set_error(info, "rducks_parallel_range() expects one UBIGINT argument");
        return;
    }

    value = duckdb_bind_get_parameter(info, 0);
    if (!value) {
        duckdb_bind_set_error(info, "failed to read rducks_parallel_range() argument");
        return;
    }

    bind = (rducks_parallel_range_bind_t *)rducks_calloc_array(1, sizeof(*bind));
    if (!bind) {
        duckdb_destroy_value(&value);
        duckdb_bind_set_error(info, "out of memory allocating rducks_parallel_range bind data");
        return;
    }
    bind->total = duckdb_get_uint64(value);
    duckdb_destroy_value(&value);

    ubigint_type = duckdb_create_logical_type(DUCKDB_TYPE_UBIGINT);
    if (!ubigint_type) {
        free(bind);
        duckdb_bind_set_error(info, "failed to allocate rducks_parallel_range result type");
        return;
    }
    duckdb_bind_add_result_column(info, "i", ubigint_type);
    duckdb_destroy_logical_type(&ubigint_type);
    duckdb_bind_set_cardinality(info, (idx_t)bind->total, true);
    duckdb_bind_set_bind_data(info, bind, rducks_parallel_range_bind_destroy);
}

static void rducks_parallel_range_init(duckdb_init_info info) {
    rducks_parallel_range_bind_t *bind;
    rducks_parallel_range_state_t *state;
    idx_t max_threads;

    if (!info) return;
    bind = (rducks_parallel_range_bind_t *)duckdb_init_get_bind_data(info);
    if (!bind) {
        duckdb_init_set_error(info, "rducks_parallel_range bind data is missing");
        return;
    }

    state = (rducks_parallel_range_state_t *)rducks_calloc_array(1, sizeof(*state));
    if (!state) {
        duckdb_init_set_error(info, "out of memory allocating rducks_parallel_range state");
        return;
    }
    atomic_init(&state->next, 0);
    state->total = bind->total;
    max_threads = bind->total == 0 ? 1 : (idx_t)(bind->total < 64 ? bind->total : 64);
    if (max_threads < 1) max_threads = 1;
    duckdb_init_set_max_threads(info, max_threads);
    duckdb_init_set_init_data(info, state, rducks_parallel_range_state_destroy);
}

static void rducks_parallel_range_local_init(duckdb_init_info info) {
    int *local = (int *)rducks_calloc_array(1, sizeof(*local));
    if (!local) {
        duckdb_init_set_error(info, "out of memory allocating rducks_parallel_range local state");
        return;
    }
    duckdb_init_set_init_data(info, local, free);
}

static void rducks_parallel_range_function(duckdb_function_info info, duckdb_data_chunk output) {
    rducks_parallel_range_state_t *state;
    duckdb_vector vector;
    uint64_t *out;
    uint64_t start;
    uint64_t remaining;
    idx_t count;

    if (!info || !output) return;
    state = (rducks_parallel_range_state_t *)duckdb_function_get_init_data(info);
    if (!state) {
        duckdb_function_set_error(info, "rducks_parallel_range state is missing");
        return;
    }

    start = atomic_fetch_add_explicit(&state->next, RDUCKS_PARALLEL_RANGE_CHUNK, memory_order_relaxed);
    if (start >= state->total) {
        duckdb_data_chunk_set_size(output, 0);
        return;
    }
    remaining = state->total - start;
    count = (idx_t)(remaining < RDUCKS_PARALLEL_RANGE_CHUNK ? remaining : RDUCKS_PARALLEL_RANGE_CHUNK);

    vector = duckdb_data_chunk_get_vector(output, 0);
    out = (uint64_t *)duckdb_vector_get_data(vector);
    for (idx_t i = 0; i < count; i++) {
        out[i] = start + (uint64_t)i;
    }
    duckdb_data_chunk_set_size(output, count);
}

static void rducks_parallel_thread_probe_bind(duckdb_bind_info info) {
    duckdb_value value;
    rducks_parallel_range_bind_t *bind;
    duckdb_logical_type ubigint_type;
    duckdb_logical_type bool_type;

    if (!info) return;
    value = duckdb_bind_get_parameter(info, 0);
    if (!value) {
        duckdb_bind_set_error(info, "failed to read rducks_parallel_thread_probe() argument");
        return;
    }
    bind = (rducks_parallel_range_bind_t *)rducks_calloc_array(1, sizeof(*bind));
    if (!bind) {
        duckdb_destroy_value(&value);
        duckdb_bind_set_error(info, "out of memory allocating rducks_parallel_thread_probe bind data");
        return;
    }
    bind->total = duckdb_get_uint64(value);
    duckdb_destroy_value(&value);

    ubigint_type = duckdb_create_logical_type(DUCKDB_TYPE_UBIGINT);
    bool_type = duckdb_create_logical_type(DUCKDB_TYPE_BOOLEAN);
    if (!ubigint_type || !bool_type) {
        if (ubigint_type) duckdb_destroy_logical_type(&ubigint_type);
        if (bool_type) duckdb_destroy_logical_type(&bool_type);
        free(bind);
        duckdb_bind_set_error(info, "failed to allocate rducks_parallel_thread_probe result types");
        return;
    }
    duckdb_bind_add_result_column(info, "i", ubigint_type);
    duckdb_bind_add_result_column(info, "is_main", bool_type);
    duckdb_destroy_logical_type(&ubigint_type);
    duckdb_destroy_logical_type(&bool_type);
    duckdb_bind_set_cardinality(info, (idx_t)bind->total, true);
    duckdb_bind_set_bind_data(info, bind, rducks_parallel_range_bind_destroy);
}

static void rducks_parallel_thread_probe_function(duckdb_function_info info, duckdb_data_chunk output) {
    rducks_parallel_range_state_t *state;
    rducks_runtime_entry_t *runtime;
    duckdb_vector i_vector;
    duckdb_vector main_vector;
    uint64_t *i_out;
    bool *main_out;
    uint64_t start;
    uint64_t remaining;
    idx_t count;
    bool is_main;

    if (!info || !output) return;
    state = (rducks_parallel_range_state_t *)duckdb_function_get_init_data(info);
    runtime = (rducks_runtime_entry_t *)duckdb_function_get_extra_info(info);
    if (!state) {
        duckdb_function_set_error(info, "rducks_parallel_thread_probe state is missing");
        return;
    }

    start = atomic_fetch_add_explicit(&state->next, RDUCKS_PARALLEL_RANGE_CHUNK, memory_order_relaxed);
    if (start >= state->total) {
        duckdb_data_chunk_set_size(output, 0);
        return;
    }
    remaining = state->total - start;
    count = (idx_t)(remaining < RDUCKS_PARALLEL_RANGE_CHUNK ? remaining : RDUCKS_PARALLEL_RANGE_CHUNK);

    i_vector = duckdb_data_chunk_get_vector(output, 0);
    main_vector = duckdb_data_chunk_get_vector(output, 1);
    i_out = (uint64_t *)duckdb_vector_get_data(i_vector);
    main_out = (bool *)duckdb_vector_get_data(main_vector);
    is_main = runtime && rducks_is_main_thread(runtime);
    for (idx_t i = 0; i < count; i++) {
        i_out[i] = start + (uint64_t)i;
        main_out[i] = is_main;
    }
    duckdb_data_chunk_set_size(output, count);
}

static bool rducks_register_parallel_thread_probe(duckdb_connection con, rducks_runtime_entry_t *runtime) {
    duckdb_table_function fn = duckdb_create_table_function();
    duckdb_logical_type ubigint_type = duckdb_create_logical_type(DUCKDB_TYPE_UBIGINT);
    duckdb_state rc;
    if (!fn || !ubigint_type) {
        if (fn) duckdb_destroy_table_function(&fn);
        if (ubigint_type) duckdb_destroy_logical_type(&ubigint_type);
        return false;
    }
    duckdb_table_function_set_name(fn, "rducks_parallel_thread_probe");
    duckdb_table_function_add_parameter(fn, ubigint_type);
    duckdb_table_function_set_extra_info(fn, runtime, NULL);
    duckdb_table_function_set_bind(fn, rducks_parallel_thread_probe_bind);
    duckdb_table_function_set_init(fn, rducks_parallel_range_init);
    duckdb_table_function_set_local_init(fn, rducks_parallel_range_local_init);
    duckdb_table_function_set_function(fn, rducks_parallel_thread_probe_function);
    rc = duckdb_register_table_function(con, fn);
    duckdb_destroy_table_function(&fn);
    duckdb_destroy_logical_type(&ubigint_type);
    return rc == DuckDBSuccess;
}

static bool rducks_register_parallel_range(duckdb_connection con) {
    duckdb_table_function fn = duckdb_create_table_function();
    duckdb_logical_type ubigint_type = duckdb_create_logical_type(DUCKDB_TYPE_UBIGINT);
    duckdb_state rc;
    if (!fn || !ubigint_type) {
        if (fn) duckdb_destroy_table_function(&fn);
        if (ubigint_type) duckdb_destroy_logical_type(&ubigint_type);
        return false;
    }
    duckdb_table_function_set_name(fn, "rducks_parallel_range");
    duckdb_table_function_add_parameter(fn, ubigint_type);
    duckdb_table_function_set_bind(fn, rducks_parallel_range_bind);
    duckdb_table_function_set_init(fn, rducks_parallel_range_init);
    duckdb_table_function_set_local_init(fn, rducks_parallel_range_local_init);
    duckdb_table_function_set_function(fn, rducks_parallel_range_function);
    rc = duckdb_register_table_function(con, fn);
    duckdb_destroy_table_function(&fn);
    duckdb_destroy_logical_type(&ubigint_type);
    return rc == DuckDBSuccess;
}
