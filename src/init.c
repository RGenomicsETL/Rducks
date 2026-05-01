#ifndef R_NO_REMAP
#define R_NO_REMAP
#endif
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif

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

SEXP RDUCKS_sexp_addr(SEXP x) {
    char buf[32];
    snprintf(buf, sizeof(buf), "%llu", (unsigned long long)(uintptr_t)x);
    return Rf_mkString(buf);
}

static const R_CallMethodDef CallEntries[] = {
    {"RDUCKS_sexp_addr", (DL_FUNC) &RDUCKS_sexp_addr, 1},
    {"RDUCKS_current_thread_token", (DL_FUNC) &RDUCKS_current_thread_token, 0},
    {NULL, NULL, 0}
};

void R_init_Rducks(DllInfo *dll) {
    R_registerRoutines(dll, NULL, CallEntries, NULL, NULL);
    R_useDynamicSymbols(dll, FALSE);
    R_forceSymbols(dll, TRUE);
}
