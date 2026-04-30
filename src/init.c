#ifndef R_NO_REMAP
#define R_NO_REMAP
#endif
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>

#include <stdio.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif

SEXP RDUCKS_callback_register(SEXP fun);
SEXP RDUCKS_callback_close(SEXP xptr);
SEXP RDUCKS_callback_invoke(SEXP xptr, SEXP args);
SEXP RDUCKS_pump(void);
SEXP RDUCKS_callback_fun_addr(SEXP xptr);
SEXP RDUCKS_type_object_new(SEXP token, SEXP duckdb_sql, SEXP kind, SEXP children,
                            SEXP child_names, SEXP size, SEXP parameters,
                            SEXP s7_class, SEXP class_vector);
SEXP RDUCKS_type_object_is(SEXP x);

SEXP RDUCKS_current_thread_token(void) {
    char buf[128];
#ifdef _WIN32
    snprintf(buf, sizeof(buf), "win:%lu", (unsigned long)GetCurrentThreadId());
#else
    pthread_t self = pthread_self();
    unsigned char bytes[sizeof(self)];
    size_t pos = 0;
    memcpy(bytes, &self, sizeof(self));
    pos += (size_t)snprintf(buf + pos, sizeof(buf) - pos, "posix:");
    for (size_t i = 0; i < sizeof(self) && pos + 2U < sizeof(buf); i++) {
        pos += (size_t)snprintf(buf + pos, sizeof(buf) - pos, "%02x", bytes[i]);
    }
#endif
    buf[sizeof(buf) - 1U] = '\0';
    return Rf_mkString(buf);
}

static const R_CallMethodDef CallEntries[] = {
    {"RDUCKS_callback_register", (DL_FUNC) &RDUCKS_callback_register, 1},
    {"RDUCKS_callback_close",    (DL_FUNC) &RDUCKS_callback_close,    1},
    {"RDUCKS_callback_invoke",   (DL_FUNC) &RDUCKS_callback_invoke,   2},
    {"RDUCKS_pump",              (DL_FUNC) &RDUCKS_pump,              0},
    {"RDUCKS_callback_fun_addr", (DL_FUNC) &RDUCKS_callback_fun_addr, 1},
    {"RDUCKS_type_object_new",   (DL_FUNC) &RDUCKS_type_object_new,   9},
    {"RDUCKS_type_object_is",    (DL_FUNC) &RDUCKS_type_object_is,    1},
    {"RDUCKS_current_thread_token", (DL_FUNC) &RDUCKS_current_thread_token, 0},
    {NULL, NULL, 0}
};

void R_init_Rducks(DllInfo *dll) {
    R_registerRoutines(dll, NULL, CallEntries, NULL, NULL);
    R_useDynamicSymbols(dll, FALSE);
    R_forceSymbols(dll, TRUE);
}
