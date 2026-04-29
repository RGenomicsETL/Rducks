#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>

SEXP RDUCKS_callback_register(SEXP fun);
SEXP RDUCKS_callback_close(SEXP xptr);
SEXP RDUCKS_callback_invoke(SEXP xptr, SEXP args);
SEXP RDUCKS_pump(void);

static const R_CallMethodDef CallEntries[] = {
    {"RDUCKS_callback_register", (DL_FUNC) &RDUCKS_callback_register, 1},
    {"RDUCKS_callback_close",    (DL_FUNC) &RDUCKS_callback_close,    1},
    {"RDUCKS_callback_invoke",   (DL_FUNC) &RDUCKS_callback_invoke,   2},
    {"RDUCKS_pump",              (DL_FUNC) &RDUCKS_pump,              0},
    {NULL, NULL, 0}
};

void R_init_Rducks(DllInfo *dll) {
    R_registerRoutines(dll, NULL, CallEntries, NULL, NULL);
    R_useDynamicSymbols(dll, FALSE);
    R_forceSymbols(dll, TRUE);
}
