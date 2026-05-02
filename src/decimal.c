#ifndef R_NO_REMAP
#define R_NO_REMAP
#endif
#include <R.h>
#include <Rinternals.h>

#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define RDUCKS_DEC_BASE 1000000000U
#define RDUCKS_DEC_BASE_DIGITS 9U

static SEXP rducks_string_scalar_result(const char *x, size_t n) {
    SEXP out = PROTECT(Rf_allocVector(STRSXP, 1));
    SET_STRING_ELT(out, 0, Rf_mkCharLenCE(x, (int)n, CE_UTF8));
    UNPROTECT(1);
    return out;
}

static SEXP rducks_na_string_scalar(void) {
    SEXP out = PROTECT(Rf_allocVector(STRSXP, 1));
    SET_STRING_ELT(out, 0, NA_STRING);
    UNPROTECT(1);
    return out;
}

static SEXP rducks_as_character_protect(SEXP x) {
    if (TYPEOF(x) == STRSXP) return x;
    return PROTECT(Rf_coerceVector(x, STRSXP));
}

static void rducks_maybe_unprotect_character(SEXP original, SEXP coerced) {
    if (coerced != original) UNPROTECT(1);
}

static const char *rducks_first_trimmed_string(SEXP x, size_t *len, int *is_na, SEXP *coerced_out) {
    SEXP coerced = rducks_as_character_protect(x);
    *coerced_out = coerced;
    if (XLENGTH(coerced) < 1) {
        Rf_error("expected a non-empty character vector");
    }
    SEXP ch = STRING_ELT(coerced, 0);
    if (ch == NA_STRING) {
        *is_na = 1;
        *len = 0;
        return NULL;
    }
    const char *start = CHAR(ch);
    const char *end = start + strlen(start);
    while (start < end && isspace((unsigned char)*start)) start++;
    while (end > start && isspace((unsigned char)*(end - 1))) end--;
    *is_na = 0;
    *len = (size_t)(end - start);
    return start;
}

static const char *rducks_skip_leading_zeros(const char *x, size_t *len) {
    while (*len > 0 && *x == '0') {
        x++;
        (*len)--;
    }
    return x;
}

SEXP RDUCKS_decimal_string_add_small(SEXP x, SEXP addend_sexp) {
    int addend = Rf_asInteger(addend_sexp);
    if (addend < 0 || addend == NA_INTEGER) {
        Rf_error("addend must be a non-negative integer");
    }

    size_t len = 0;
    int is_na = 0;
    SEXP coerced = R_NilValue;
    const char *digits = rducks_first_trimmed_string(x, &len, &is_na, &coerced);
    if (is_na) {
        rducks_maybe_unprotect_character(x, coerced);
        return rducks_na_string_scalar();
    }
    digits = rducks_skip_leading_zeros(digits, &len);
    if (len == 0) {
        static const char zero[] = "0";
        digits = zero;
        len = 1;
    }
    for (size_t i = 0; i < len; i++) {
        if (digits[i] < '0' || digits[i] > '9') {
            rducks_maybe_unprotect_character(x, coerced);
            Rf_error("expected an unsigned decimal integer string");
        }
    }

    size_t cap = len + 32U;
    char *rev_digits = (char *)R_alloc(cap + 1U, sizeof(char));
    size_t pos = 0;
    int64_t carry = (int64_t)addend;
    while (pos < len || carry > 0) {
        int64_t digit = pos < len ? (int64_t)(digits[len - pos - 1U] - '0') : 0;
        int64_t value = digit + carry;
        rev_digits[pos++] = (char)('0' + (value % 10));
        carry = value / 10;
        if (pos >= cap && carry > 0) {
            rducks_maybe_unprotect_character(x, coerced);
            Rf_error("decimal string addition overflowed internal buffer");
        }
    }
    while (pos > 1U && rev_digits[pos - 1U] == '0') pos--;

    char *out = (char *)R_alloc(pos + 1U, sizeof(char));
    for (size_t i = 0; i < pos; i++) out[i] = rev_digits[pos - i - 1U];
    out[pos] = '\0';

    rducks_maybe_unprotect_character(x, coerced);
    return rducks_string_scalar_result(out, pos);
}

SEXP RDUCKS_decimal_string_multiply_small(SEXP x, SEXP multiplier_sexp) {
    int multiplier = Rf_asInteger(multiplier_sexp);
    if (multiplier < 0 || multiplier == NA_INTEGER) {
        Rf_error("multiplier must be a non-negative integer");
    }

    size_t len = 0;
    int is_na = 0;
    SEXP coerced = R_NilValue;
    const char *digits = rducks_first_trimmed_string(x, &len, &is_na, &coerced);
    if (is_na) {
        rducks_maybe_unprotect_character(x, coerced);
        return rducks_na_string_scalar();
    }

    int neg = 0;
    if (len > 0 && *digits == '+') {
        digits++;
        len--;
    }
    if (len > 0 && *digits == '-') {
        neg = 1;
        digits++;
        len--;
    }
    digits = rducks_skip_leading_zeros(digits, &len);
    if (len == 0 || multiplier == 0) {
        rducks_maybe_unprotect_character(x, coerced);
        return rducks_string_scalar_result("0", 1);
    }
    for (size_t i = 0; i < len; i++) {
        if (digits[i] < '0' || digits[i] > '9') {
            rducks_maybe_unprotect_character(x, coerced);
            return rducks_string_scalar_result("0", 1);
        }
    }

    size_t cap = len + 32U;
    char *rev_digits = (char *)R_alloc(cap + 1U, sizeof(char));
    size_t pos = 0;
    uint64_t carry = 0;
    for (size_t i = 0; i < len; i++) {
        uint64_t digit = (uint64_t)(digits[len - i - 1U] - '0');
        uint64_t value = digit * (uint64_t)multiplier + carry;
        rev_digits[pos++] = (char)('0' + (value % 10U));
        carry = value / 10U;
    }
    while (carry > 0) {
        if (pos >= cap) {
            rducks_maybe_unprotect_character(x, coerced);
            Rf_error("decimal string multiplication overflowed internal buffer");
        }
        rev_digits[pos++] = (char)('0' + (carry % 10U));
        carry /= 10U;
    }
    while (pos > 1U && rev_digits[pos - 1U] == '0') pos--;

    size_t out_len = pos + (neg ? 1U : 0U);
    char *out = (char *)R_alloc(out_len + 1U, sizeof(char));
    size_t out_pos = 0;
    if (neg) out[out_pos++] = '-';
    for (size_t i = 0; i < pos; i++) out[out_pos++] = rev_digits[pos - i - 1U];
    out[out_pos] = '\0';

    rducks_maybe_unprotect_character(x, coerced);
    return rducks_string_scalar_result(out, out_len);
}

static void rducks_decimal_limbs_mul_add(uint32_t *limbs, size_t *nlimbs, uint32_t multiplier, uint32_t addend) {
    uint64_t carry = addend;
    for (size_t i = 0; i < *nlimbs; i++) {
        uint64_t value = (uint64_t)limbs[i] * (uint64_t)multiplier + carry;
        limbs[i] = (uint32_t)(value % RDUCKS_DEC_BASE);
        carry = value / RDUCKS_DEC_BASE;
    }
    while (carry > 0) {
        limbs[*nlimbs] = (uint32_t)(carry % RDUCKS_DEC_BASE);
        carry /= RDUCKS_DEC_BASE;
        (*nlimbs)++;
    }
}

SEXP RDUCKS_decimal_string_from_unsigned_bytes(SEXP bytes_sexp) {
    SEXP bytes = bytes_sexp;
    if (TYPEOF(bytes) != RAWSXP) {
        bytes = PROTECT(Rf_coerceVector(bytes_sexp, RAWSXP));
    }
    R_xlen_t n = XLENGTH(bytes);
    if (n == 0) {
        if (bytes != bytes_sexp) UNPROTECT(1);
        return rducks_string_scalar_result("0", 1);
    }

    size_t cap = (size_t)n + 1U;
    uint32_t *limbs = (uint32_t *)R_alloc(cap, sizeof(uint32_t));
    memset(limbs, 0, cap * sizeof(uint32_t));
    size_t nlimbs = 1U;

    const Rbyte *raw = RAW(bytes);
    for (R_xlen_t i = n; i > 0; i--) {
        rducks_decimal_limbs_mul_add(limbs, &nlimbs, 256U, (uint32_t)raw[i - 1]);
        if (nlimbs > cap) {
            if (bytes != bytes_sexp) UNPROTECT(1);
            Rf_error("decimal byte conversion overflowed internal buffer");
        }
    }

    while (nlimbs > 1U && limbs[nlimbs - 1U] == 0U) nlimbs--;
    if (nlimbs == 1U && limbs[0] == 0U) {
        if (bytes != bytes_sexp) UNPROTECT(1);
        return rducks_string_scalar_result("0", 1);
    }

    size_t out_cap = nlimbs * RDUCKS_DEC_BASE_DIGITS + 1U;
    char *out = (char *)R_alloc(out_cap + 1U, sizeof(char));
    size_t pos = 0;
    pos += (size_t)snprintf(out + pos, out_cap + 1U - pos, "%u", limbs[nlimbs - 1U]);
    for (size_t j = nlimbs - 1U; j > 0; j--) {
        pos += (size_t)snprintf(out + pos, out_cap + 1U - pos, "%09u", limbs[j - 1U]);
    }

    if (bytes != bytes_sexp) UNPROTECT(1);
    return rducks_string_scalar_result(out, strlen(out));
}
