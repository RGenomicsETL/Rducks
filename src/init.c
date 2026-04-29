#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>

SEXP RDUCKS_callback_register(SEXP fun);
SEXP RDUCKS_callback_close(SEXP xptr);
SEXP RDUCKS_callback_invoke(SEXP xptr, SEXP args);
SEXP RDUCKS_pump(void);
SEXP RDUCKS_sexp_addr(SEXP x);
SEXP RDUCKS_extptr_addr(SEXP x);
SEXP RDUCKS_callback_fun_addr(SEXP xptr);

static const R_CallMethodDef CallEntries[] = {
    {"RDUCKS_callback_register", (DL_FUNC) &RDUCKS_callback_register, 1},
    {"RDUCKS_callback_close",    (DL_FUNC) &RDUCKS_callback_close,    1},
    {"RDUCKS_callback_invoke",   (DL_FUNC) &RDUCKS_callback_invoke,   2},
    {"RDUCKS_pump",              (DL_FUNC) &RDUCKS_pump,              0},
    {"RDUCKS_sexp_addr",         (DL_FUNC) &RDUCKS_sexp_addr,         1},
    {"RDUCKS_extptr_addr",       (DL_FUNC) &RDUCKS_extptr_addr,       1},
    {"RDUCKS_callback_fun_addr", (DL_FUNC) &RDUCKS_callback_fun_addr, 1},
    {NULL, NULL, 0}
};

void R_init_Rducks(DllInfo *dll) {
    R_registerRoutines(dll, NULL, CallEntries, NULL, NULL);
    R_useDynamicSymbols(dll, FALSE);
    R_forceSymbols(dll, TRUE);
}
