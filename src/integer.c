#ifndef R_NO_REMAP
#define R_NO_REMAP
#endif
#include <R.h>
#include <Rinternals.h>

#include <ctype.h>
#include <stdint.h>
#include <string.h>

static SEXP rducks_integer_as_character_protect(SEXP x) {
    if (TYPEOF(x) == STRSXP) return x;
    return PROTECT(Rf_coerceVector(x, STRSXP));
}

static void rducks_integer_maybe_unprotect_character(SEXP original, SEXP coerced) {
    if (coerced != original) UNPROTECT(1);
}

static const char *rducks_integer_what(SEXP what_sexp) {
    if (TYPEOF(what_sexp) != STRSXP || XLENGTH(what_sexp) < 1 || STRING_ELT(what_sexp, 0) == NA_STRING) {
        return "integer";
    }
    return CHAR(STRING_ELT(what_sexp, 0));
}

static const char *rducks_trim_string(SEXP ch, size_t *len) {
    const char *start = CHAR(ch);
    const char *end = start + strlen(start);
    while (start < end && isspace((unsigned char)*start)) start++;
    while (end > start && isspace((unsigned char)*(end - 1))) end--;
    *len = (size_t)(end - start);
    return start;
}

static const char *rducks_skip_zero_digits(const char *x, size_t *len) {
    while (*len > 0 && *x == '0') {
        x++;
        (*len)--;
    }
    return x;
}

static int rducks_integer_abs_is_zero(const char *x, size_t len) {
    if (len == 0) return 1;
    for (size_t i = 0; i < len; i++) if (x[i] != '0') return 0;
    return 1;
}

static int rducks_integer_string_sign_and_abs(SEXP ch, const char **digits, size_t *len) {
    if (ch == NA_STRING) return 0;
    const char *x = CHAR(ch);
    size_t n = strlen(x);
    int sign = 1;
    if (n > 0 && x[0] == '-') {
        sign = -1;
        x++;
        n--;
    } else if (n > 0 && x[0] == '+') {
        x++;
        n--;
    }
    if (rducks_integer_abs_is_zero(x, n)) sign = 1;
    *digits = x;
    *len = n;
    return sign;
}

static int rducks_integer_abs_compare(const char *a, size_t alen, const char *b, size_t blen) {
    a = rducks_skip_zero_digits(a, &alen);
    b = rducks_skip_zero_digits(b, &blen);
    if (alen != blen) return alen < blen ? -1 : 1;
    if (alen == 0) return 0;
    int cmp = memcmp(a, b, alen);
    if (cmp < 0) return -1;
    if (cmp > 0) return 1;
    return 0;
}

static SEXP rducks_mkchar_scalar_or_na(const char *x, size_t n, int is_na) {
    SEXP out = PROTECT(Rf_allocVector(STRSXP, 1));
    SET_STRING_ELT(out, 0, is_na ? NA_STRING : Rf_mkCharLenCE(x, (int)n, CE_UTF8));
    UNPROTECT(1);
    return out;
}

SEXP RDUCKS_normalize_integer_string(SEXP x, SEXP unsigned_sexp, SEXP what_sexp) {
    int unsigned_flag = Rf_asLogical(unsigned_sexp) == TRUE;
    const char *what = rducks_integer_what(what_sexp);
    SEXP input = rducks_integer_as_character_protect(x);
    R_xlen_t n = XLENGTH(input);
    SEXP out = PROTECT(Rf_allocVector(STRSXP, n));

    for (R_xlen_t i = 0; i < n; i++) {
        SEXP ch = STRING_ELT(input, i);
        if (ch == NA_STRING) {
            SET_STRING_ELT(out, i, NA_STRING);
            continue;
        }
        size_t len = 0;
        const char *s = rducks_trim_string(ch, &len);
        int sign = 1;
        if (len > 0 && *s == '+') {
            s++;
            len--;
        } else if (len > 0 && *s == '-') {
            sign = -1;
            s++;
            len--;
        }
        if (len == 0) Rf_error("%s values must be integer strings", what);
        for (size_t j = 0; j < len; j++) {
            if (s[j] < '0' || s[j] > '9') Rf_error("%s values must be integer strings", what);
        }
        if (unsigned_flag && sign < 0) Rf_error("%s values must be unsigned", what);
        s = rducks_skip_zero_digits(s, &len);
        if (len == 0) {
            SET_STRING_ELT(out, i, Rf_mkChar("0"));
        } else if (sign < 0) {
            char *buf = (char *)R_alloc(len + 2U, sizeof(char));
            buf[0] = '-';
            memcpy(buf + 1, s, len);
            buf[len + 1U] = '\0';
            SET_STRING_ELT(out, i, Rf_mkCharLenCE(buf, (int)(len + 1U), CE_UTF8));
        } else {
            SET_STRING_ELT(out, i, Rf_mkCharLenCE(s, (int)len, CE_UTF8));
        }
    }

    UNPROTECT(1);
    rducks_integer_maybe_unprotect_character(x, input);
    return out;
}

static int rducks_compare_integer_one(SEXP ach, SEXP bch) {
    if (ach == NA_STRING || bch == NA_STRING) return NA_INTEGER;
    const char *a_digits;
    const char *b_digits;
    size_t alen;
    size_t blen;
    int as = rducks_integer_string_sign_and_abs(ach, &a_digits, &alen);
    int bs = rducks_integer_string_sign_and_abs(bch, &b_digits, &blen);
    if (as != bs) return as < bs ? -1 : 1;
    int cmp = rducks_integer_abs_compare(a_digits, alen, b_digits, blen);
    return cmp * as;
}

SEXP RDUCKS_compare_integer_strings(SEXP a, SEXP b) {
    SEXP aa = rducks_integer_as_character_protect(a);
    SEXP bb = rducks_integer_as_character_protect(b);
    R_xlen_t na = XLENGTH(aa);
    R_xlen_t nb = XLENGTH(bb);
    R_xlen_t n = na > nb ? na : nb;
    SEXP out = PROTECT(Rf_allocVector(INTSXP, n));
    for (R_xlen_t i = 0; i < n; i++) {
        SEXP ach = na == 0 ? NA_STRING : STRING_ELT(aa, i % na);
        SEXP bch = nb == 0 ? NA_STRING : STRING_ELT(bb, i % nb);
        INTEGER(out)[i] = rducks_compare_integer_one(ach, bch);
    }
    UNPROTECT(1);
    rducks_integer_maybe_unprotect_character(b, bb);
    rducks_integer_maybe_unprotect_character(a, aa);
    return out;
}

static size_t rducks_add_abs_digits(const char *a, size_t alen, const char *b, size_t blen, char *rev_out) {
    size_t pos = 0;
    int carry = 0;
    while (alen > 0 || blen > 0 || carry > 0) {
        int da = alen > 0 ? (a[--alen] - '0') : 0;
        int db = blen > 0 ? (b[--blen] - '0') : 0;
        int value = da + db + carry;
        rev_out[pos++] = (char)('0' + (value % 10));
        carry = value / 10;
    }
    return pos;
}

static size_t rducks_sub_abs_digits(const char *a, size_t alen, const char *b, size_t blen, char *rev_out) {
    size_t pos = 0;
    int borrow = 0;
    while (alen > 0) {
        int da = (a[--alen] - '0') - borrow;
        int db = blen > 0 ? (b[--blen] - '0') : 0;
        if (da < db) {
            da += 10;
            borrow = 1;
        } else {
            borrow = 0;
        }
        rev_out[pos++] = (char)('0' + (da - db));
    }
    while (pos > 1U && rev_out[pos - 1U] == '0') pos--;
    return pos;
}

static SEXP rducks_integer_add_one(SEXP ach, SEXP bch) {
    if (ach == NA_STRING || bch == NA_STRING) return rducks_mkchar_scalar_or_na(NULL, 0, 1);
    const char *a_digits;
    const char *b_digits;
    size_t alen;
    size_t blen;
    int as = rducks_integer_string_sign_and_abs(ach, &a_digits, &alen);
    int bs = rducks_integer_string_sign_and_abs(bch, &b_digits, &blen);

    a_digits = rducks_skip_zero_digits(a_digits, &alen);
    b_digits = rducks_skip_zero_digits(b_digits, &blen);
    if (alen == 0) as = 1;
    if (blen == 0) bs = 1;

    size_t max_len = (alen > blen ? alen : blen) + 2U;
    char *rev = (char *)R_alloc(max_len, sizeof(char));
    size_t ndigits = 0;
    int out_sign = 1;

    if (as == bs) {
        ndigits = rducks_add_abs_digits(a_digits, alen, b_digits, blen, rev);
        out_sign = as;
    } else {
        int cmp = rducks_integer_abs_compare(a_digits, alen, b_digits, blen);
        if (cmp == 0) return rducks_mkchar_scalar_or_na("0", 1, 0);
        if (cmp > 0) {
            ndigits = rducks_sub_abs_digits(a_digits, alen, b_digits, blen, rev);
            out_sign = as;
        } else {
            ndigits = rducks_sub_abs_digits(b_digits, blen, a_digits, alen, rev);
            out_sign = bs;
        }
    }

    while (ndigits > 1U && rev[ndigits - 1U] == '0') ndigits--;
    int negative = out_sign < 0 && !(ndigits == 1U && rev[0] == '0');
    size_t out_len = ndigits + (negative ? 1U : 0U);
    char *out = (char *)R_alloc(out_len + 1U, sizeof(char));
    size_t pos = 0;
    if (negative) out[pos++] = '-';
    for (size_t i = 0; i < ndigits; i++) out[pos++] = rev[ndigits - i - 1U];
    out[pos] = '\0';
    return rducks_mkchar_scalar_or_na(out, out_len, 0);
}

SEXP RDUCKS_integer_add_strings(SEXP a, SEXP b) {
    SEXP aa = rducks_integer_as_character_protect(a);
    SEXP bb = rducks_integer_as_character_protect(b);
    R_xlen_t na = XLENGTH(aa);
    R_xlen_t nb = XLENGTH(bb);
    R_xlen_t n = na > nb ? na : nb;
    SEXP out = PROTECT(Rf_allocVector(STRSXP, n));
    for (R_xlen_t i = 0; i < n; i++) {
        SEXP ach = na == 0 ? NA_STRING : STRING_ELT(aa, i % na);
        SEXP bch = nb == 0 ? NA_STRING : STRING_ELT(bb, i % nb);
        SEXP one = PROTECT(rducks_integer_add_one(ach, bch));
        SET_STRING_ELT(out, i, STRING_ELT(one, 0));
        UNPROTECT(1);
    }
    UNPROTECT(1);
    rducks_integer_maybe_unprotect_character(b, bb);
    rducks_integer_maybe_unprotect_character(a, aa);
    return out;
}

SEXP RDUCKS_integer_negate_strings(SEXP x) {
    SEXP xx = rducks_integer_as_character_protect(x);
    R_xlen_t n = XLENGTH(xx);
    SEXP out = PROTECT(Rf_allocVector(STRSXP, n));
    for (R_xlen_t i = 0; i < n; i++) {
        SEXP ch = STRING_ELT(xx, i);
        if (ch == NA_STRING) {
            SET_STRING_ELT(out, i, NA_STRING);
            continue;
        }
        const char *digits;
        size_t len;
        int sign = rducks_integer_string_sign_and_abs(ch, &digits, &len);
        digits = rducks_skip_zero_digits(digits, &len);
        if (len == 0) {
            SET_STRING_ELT(out, i, Rf_mkChar("0"));
        } else if (sign < 0) {
            SET_STRING_ELT(out, i, Rf_mkCharLenCE(digits, (int)len, CE_UTF8));
        } else {
            char *buf = (char *)R_alloc(len + 2U, sizeof(char));
            buf[0] = '-';
            memcpy(buf + 1, digits, len);
            buf[len + 1U] = '\0';
            SET_STRING_ELT(out, i, Rf_mkCharLenCE(buf, (int)(len + 1U), CE_UTF8));
        }
    }
    UNPROTECT(1);
    rducks_integer_maybe_unprotect_character(x, xx);
    return out;
}
