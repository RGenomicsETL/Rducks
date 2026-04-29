#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct rducks_callback {
    SEXP fun;
    int closed;
} rducks_callback_t;

static rducks_callback_t *rducks_callback_from_xptr(SEXP xptr) {
    if (TYPEOF(xptr) != EXTPTRSXP) {
        Rf_error("expected external pointer");
    }
    rducks_callback_t *cb = (rducks_callback_t *) R_ExternalPtrAddr(xptr);
    if (!cb || cb->closed) {
        Rf_error("Rducks callback is closed");
    }
    return cb;
}

static void rducks_callback_finalizer(SEXP xptr) {
    rducks_callback_t *cb = (rducks_callback_t *) R_ExternalPtrAddr(xptr);
    if (!cb) {
        return;
    }
    if (!cb->closed && cb->fun != R_NilValue) {
        R_ReleaseObject(cb->fun);
    }
    cb->closed = 1;
    cb->fun = R_NilValue;
    free(cb);
    R_ClearExternalPtr(xptr);
}

SEXP RDUCKS_callback_register(SEXP fun) {
    if (!Rf_isFunction(fun)) {
        Rf_error("fun must be a function");
    }
    rducks_callback_t *cb = (rducks_callback_t *) calloc(1, sizeof(rducks_callback_t));
    if (!cb) {
        Rf_error("out of memory");
    }
    cb->fun = fun;
    cb->closed = 0;
    R_PreserveObject(fun);

    SEXP tag = PROTECT(Rf_install("rducks_callback"));
    SEXP xptr = PROTECT(R_MakeExternalPtr(cb, tag, R_NilValue));
    R_RegisterCFinalizerEx(xptr, rducks_callback_finalizer, TRUE);
    UNPROTECT(2);
    return xptr;
}

SEXP RDUCKS_callback_close(SEXP xptr) {
    rducks_callback_finalizer(xptr);
    return R_NilValue;
}

static SEXP rducks_build_call(SEXP fun, SEXP args) {
    if (args == R_NilValue || TYPEOF(args) != VECSXP || XLENGTH(args) == 0) {
        return Rf_lang1(fun);
    }

    R_xlen_t n = XLENGTH(args);
    if (n == 1) {
        return Rf_lang2(fun, VECTOR_ELT(args, 0));
    }
    if (n == 2) {
        return Rf_lang3(fun, VECTOR_ELT(args, 0), VECTOR_ELT(args, 1));
    }
    if (n == 3) {
        return Rf_lang4(fun, VECTOR_ELT(args, 0), VECTOR_ELT(args, 1), VECTOR_ELT(args, 2));
    }

    SEXP pair = R_NilValue;
    for (R_xlen_t i = n; i > 0; --i) {
        pair = PROTECT(Rf_cons(VECTOR_ELT(args, i - 1), pair));
    }
    SEXP call = PROTECT(Rf_lcons(fun, pair));
    UNPROTECT((int)n + 1);
    return call;
}

SEXP RDUCKS_callback_invoke(SEXP xptr, SEXP args) {
    rducks_callback_t *cb = rducks_callback_from_xptr(xptr);
    if (args != R_NilValue && TYPEOF(args) != VECSXP) {
        Rf_error("args must be a list");
    }

    SEXP call = PROTECT(rducks_build_call(cb->fun, args));
    int err = 0;
    SEXP result = PROTECT(R_tryEvalSilent(call, R_GlobalEnv, &err));
    if (err) {
        UNPROTECT(2);
        Rf_error("Rducks callback raised an error");
    }
    UNPROTECT(2);
    return result;
}

SEXP RDUCKS_pump(void) {
    /* The DuckDB-extension request queue is introduced in the next native
     * milestone. Returning zero reports that no queued worker requests were
     * processed by this minimal DuckTinyCC-backed implementation. */
    return Rf_ScalarInteger(0);
}

SEXP RDUCKS_sexp_addr(SEXP x) {
    char buf[32];
    snprintf(buf, sizeof(buf), "%llu", (unsigned long long)(uintptr_t)x);
    return Rf_mkString(buf);
}

SEXP RDUCKS_extptr_addr(SEXP x) {
    if (TYPEOF(x) != EXTPTRSXP) {
        Rf_error("expected external pointer");
    }
    char buf[32];
    snprintf(buf, sizeof(buf), "%llu", (unsigned long long)(uintptr_t)R_ExternalPtrAddr(x));
    return Rf_mkString(buf);
}

SEXP RDUCKS_callback_fun_addr(SEXP xptr) {
    rducks_callback_t *cb = rducks_callback_from_xptr(xptr);
    char buf[32];
    snprintf(buf, sizeof(buf), "%llu", (unsigned long long)(uintptr_t)cb->fun);
    return Rf_mkString(buf);
}
