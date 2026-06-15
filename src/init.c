#ifndef R_NO_REMAP
#define R_NO_REMAP
#endif
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>

#include <stdint.h>
#include <stdio.h>
#include <string.h>

SEXP RDUCKS_decimal_string_add_small(SEXP x, SEXP addend_sexp);
SEXP RDUCKS_decimal_string_multiply_small(SEXP x, SEXP multiplier_sexp);
SEXP RDUCKS_decimal_string_from_unsigned_bytes(SEXP bytes_sexp);
SEXP RDUCKS_normalize_integer_string(SEXP x, SEXP unsigned_sexp, SEXP what_sexp);
SEXP RDUCKS_compare_integer_strings(SEXP a, SEXP b);
SEXP RDUCKS_integer_add_strings(SEXP a, SEXP b);
SEXP RDUCKS_integer_negate_strings(SEXP x);
SEXP RDUCKS_integer_strings_to_double(SEXP x);
SEXP RDUCKS_integer_strings_to_int32(SEXP x);
SEXP RDUCKS_normalize_decimal_string(SEXP x, SEXP width_sexp, SEXP scale_sexp);
SEXP RDUCKS_decimal_storage_strings(SEXP x, SEXP scale_sexp);
SEXP RDUCKS_decimal_unscale_strings(SEXP x, SEXP scale_sexp);
SEXP RDUCKS_decimal_from_scaled_integer_strings(SEXP x, SEXP width_sexp, SEXP scale_sexp);
SEXP RDUCKS_decimal_scaled_integer_strings(SEXP x);
SEXP RDUCKS_decimal_compare_values(SEXP a, SEXP b);
SEXP RDUCKS_fixed_width_bytes_from_decimal_strings(SEXP values, SEXP width_sexp, SEXP signed_sexp);
SEXP RDUCKS_decimal_strings_from_fixed_width_bytes(SEXP bytes_sexp, SEXP valid_sexp, SEXP offset_sexp,
                                                   SEXP n_sexp, SEXP width_sexp, SEXP signed_sexp);
SEXP RDUCKS_interval_values_from_bytes(SEXP bytes_sexp, SEXP valid_sexp, SEXP offset_sexp, SEXP n_sexp);
SEXP RDUCKS_interval_bytes_from_values(SEXP values);
SEXP RDUCKS_pack_bits(SEXP bits_sexp);
SEXP RDUCKS_unpack_bits(SEXP data_sexp, SEXP bit_length_sexp);
SEXP RDUCKS_bits_to_character(SEXP data_sexp, SEXP bit_length_sexp);
SEXP RDUCKS_bits_binary_raw(SEXP a_sexp, SEXP b_sexp, SEXP bit_length_sexp, SEXP op_sexp);
SEXP RDUCKS_bits_not_raw(SEXP data_sexp, SEXP bit_length_sexp);
SEXP RDUCKS_bits_from_character(SEXP x_sexp);
SEXP RDUCKS_bit_payloads_to_values(SEXP data_sexp, SEXP offsets_sexp, SEXP valid_sexp,
                                   SEXP offset_sexp, SEXP n_sexp);
SEXP RDUCKS_bit_values_to_payloads(SEXP values);
SEXP RDUCKS_uuid_bytes_from_strings(SEXP values_sexp);
SEXP RDUCKS_uuid_strings_from_bytes(SEXP bytes_sexp, SEXP valid_sexp, SEXP offset_sexp, SEXP n_sexp);
SEXP RDUCKS_uuid_normalize_strings(SEXP values_sexp);
SEXP RDUCKS_quack_encode_chunk(SEXP rows, SEXP types, SEXP columns);
SEXP RDUCKS_quack_decode_chunk(SEXP payload, SEXP expected);
SEXP RDUCKS_type_inherits_names(SEXP x, SEXP names);
SEXP RDUCKS_vectorized_fast_scalar_rows(SEXP type, SEXP value, SEXP n_sexp);

#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif

#ifndef _WIN32
static pthread_t rducks_main_thread_id;
#endif

SEXP RDUCKS_current_thread_token(void) {
    char buf[128];
#ifdef _WIN32
    snprintf(buf, sizeof(buf), "win:%lu", (unsigned long)GetCurrentThreadId());
#else
    /* This value is only a handshake token passed to the DuckDB extension.
     * Store pthread_t in package-owned native storage and pass its address; the
     * extension compares the pointed-to pthread_t with pthread_equal().
     */
    rducks_main_thread_id = pthread_self();
    snprintf(buf, sizeof(buf), "posix-pthread-ptr:%llu",
             (unsigned long long)(uintptr_t)&rducks_main_thread_id);
#endif
    buf[sizeof(buf) - 1U] = '\0';
    return Rf_mkString(buf);
}

SEXP RDUCKS_sexp_addr(SEXP x) {
    char buf[32];
    snprintf(buf, sizeof(buf), "%llu", (unsigned long long)(uintptr_t)x);
    return Rf_mkString(buf);
}

static const R_CallMethodDef CallEntries[] = {
    {"RDUCKS_sexp_addr", (DL_FUNC) &RDUCKS_sexp_addr, 1},
    {"RDUCKS_current_thread_token", (DL_FUNC) &RDUCKS_current_thread_token, 0},
    {"RDUCKS_decimal_string_add_small", (DL_FUNC) &RDUCKS_decimal_string_add_small, 2},
    {"RDUCKS_decimal_string_multiply_small", (DL_FUNC) &RDUCKS_decimal_string_multiply_small, 2},
    {"RDUCKS_decimal_string_from_unsigned_bytes", (DL_FUNC) &RDUCKS_decimal_string_from_unsigned_bytes, 1},
    {"RDUCKS_normalize_integer_string", (DL_FUNC) &RDUCKS_normalize_integer_string, 3},
    {"RDUCKS_compare_integer_strings", (DL_FUNC) &RDUCKS_compare_integer_strings, 2},
    {"RDUCKS_integer_add_strings", (DL_FUNC) &RDUCKS_integer_add_strings, 2},
    {"RDUCKS_integer_negate_strings", (DL_FUNC) &RDUCKS_integer_negate_strings, 1},
    {"RDUCKS_integer_strings_to_double", (DL_FUNC) &RDUCKS_integer_strings_to_double, 1},
    {"RDUCKS_integer_strings_to_int32", (DL_FUNC) &RDUCKS_integer_strings_to_int32, 1},
    {"RDUCKS_normalize_decimal_string", (DL_FUNC) &RDUCKS_normalize_decimal_string, 3},
    {"RDUCKS_decimal_storage_strings", (DL_FUNC) &RDUCKS_decimal_storage_strings, 2},
    {"RDUCKS_decimal_unscale_strings", (DL_FUNC) &RDUCKS_decimal_unscale_strings, 2},
    {"RDUCKS_decimal_from_scaled_integer_strings", (DL_FUNC) &RDUCKS_decimal_from_scaled_integer_strings, 3},
    {"RDUCKS_decimal_scaled_integer_strings", (DL_FUNC) &RDUCKS_decimal_scaled_integer_strings, 1},
    {"RDUCKS_decimal_compare_values", (DL_FUNC) &RDUCKS_decimal_compare_values, 2},
    {"RDUCKS_fixed_width_bytes_from_decimal_strings", (DL_FUNC) &RDUCKS_fixed_width_bytes_from_decimal_strings, 3},
    {"RDUCKS_decimal_strings_from_fixed_width_bytes", (DL_FUNC) &RDUCKS_decimal_strings_from_fixed_width_bytes, 6},
    {"RDUCKS_interval_values_from_bytes", (DL_FUNC) &RDUCKS_interval_values_from_bytes, 4},
    {"RDUCKS_interval_bytes_from_values", (DL_FUNC) &RDUCKS_interval_bytes_from_values, 1},
    {"RDUCKS_pack_bits", (DL_FUNC) &RDUCKS_pack_bits, 1},
    {"RDUCKS_unpack_bits", (DL_FUNC) &RDUCKS_unpack_bits, 2},
    {"RDUCKS_bits_to_character", (DL_FUNC) &RDUCKS_bits_to_character, 2},
    {"RDUCKS_bits_binary_raw", (DL_FUNC) &RDUCKS_bits_binary_raw, 4},
    {"RDUCKS_bits_not_raw", (DL_FUNC) &RDUCKS_bits_not_raw, 2},
    {"RDUCKS_bits_from_character", (DL_FUNC) &RDUCKS_bits_from_character, 1},
    {"RDUCKS_bit_payloads_to_values", (DL_FUNC) &RDUCKS_bit_payloads_to_values, 5},
    {"RDUCKS_bit_values_to_payloads", (DL_FUNC) &RDUCKS_bit_values_to_payloads, 1},
    {"RDUCKS_uuid_bytes_from_strings", (DL_FUNC) &RDUCKS_uuid_bytes_from_strings, 1},
    {"RDUCKS_uuid_strings_from_bytes", (DL_FUNC) &RDUCKS_uuid_strings_from_bytes, 4},
    {"RDUCKS_uuid_normalize_strings", (DL_FUNC) &RDUCKS_uuid_normalize_strings, 1},
    {"RDUCKS_quack_encode_chunk", (DL_FUNC) &RDUCKS_quack_encode_chunk, 3},
    {"RDUCKS_quack_decode_chunk", (DL_FUNC) &RDUCKS_quack_decode_chunk, 2},
    {"RDUCKS_type_inherits_names", (DL_FUNC) &RDUCKS_type_inherits_names, 2},
    {"RDUCKS_vectorized_fast_scalar_rows", (DL_FUNC) &RDUCKS_vectorized_fast_scalar_rows, 3},
    {NULL, NULL, 0}
};

#if defined(_WIN32)
__declspec(dllexport)
#elif defined(__GNUC__)
__attribute__((visibility("default")))
#endif
void R_init_Rducks(DllInfo *dll) {
    R_registerRoutines(dll, NULL, CallEntries, NULL, NULL);
    R_useDynamicSymbols(dll, FALSE);
    R_forceSymbols(dll, TRUE);
}
