#ifndef R_NO_REMAP
#define R_NO_REMAP
#endif
#include <R.h>
#include <Rinternals.h>

#include "rducks_native.h"

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

static void rducks_decimal_limbs_mul_add(uint32_t *limbs, size_t *nlimbs, size_t cap,
                                          uint32_t multiplier, uint32_t addend,
                                          const char *what) {
    uint64_t carry = addend;
    for (size_t i = 0; i < *nlimbs; i++) {
        uint64_t value = (uint64_t)limbs[i] * (uint64_t)multiplier + carry;
        limbs[i] = (uint32_t)(value % RDUCKS_DEC_BASE);
        carry = value / RDUCKS_DEC_BASE;
    }
    while (carry > 0) {
        if (*nlimbs >= cap) Rf_error("%s overflowed internal buffer", what);
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
        rducks_decimal_limbs_mul_add(limbs, &nlimbs, cap, 256U, (uint32_t)raw[i - 1],
                                     "decimal byte conversion");
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

static int rducks_decimal_get_width(SEXP width_sexp) {
    int width = Rf_asInteger(width_sexp);
    if (width == NA_INTEGER || width < 1 || width > 38) Rf_error("width must be an integer from 1 to 38");
    return width;
}

static int rducks_decimal_get_scale(SEXP scale_sexp, int width) {
    int scale = Rf_asInteger(scale_sexp);
    if (scale == NA_INTEGER || scale < 0 || scale > width) Rf_error("scale must be an integer from 0 to width");
    return scale;
}

static const char *rducks_decimal_trim_char(SEXP ch, size_t *len) {
    const char *start = CHAR(ch);
    const char *end = start + strlen(start);
    while (start < end && isspace((unsigned char)*start)) start++;
    while (end > start && isspace((unsigned char)*(end - 1))) end--;
    *len = (size_t)(end - start);
    return start;
}

static int rducks_decimal_parse_fixed(const char *s, size_t len, int allow_plus, int *neg,
                                      const char **whole, size_t *whole_len,
                                      const char **frac, size_t *frac_len) {
    *neg = 0;
    if (len > 0 && *s == '+' && allow_plus) {
        s++;
        len--;
    } else if (len > 0 && *s == '-') {
        *neg = 1;
        s++;
        len--;
    }
    const char *dot = NULL;
    for (size_t i = 0; i < len; i++) {
        if (s[i] == '.') {
            if (dot) return 0;
            dot = s + i;
        } else if (s[i] < '0' || s[i] > '9') {
            return 0;
        }
    }
    if (dot) {
        *whole = s;
        *whole_len = (size_t)(dot - s);
        *frac = dot + 1;
        *frac_len = len - *whole_len - 1U;
        if (*whole_len == 0 || *frac_len == 0) return 0;
    } else {
        *whole = s;
        *whole_len = len;
        *frac = NULL;
        *frac_len = 0;
        if (*whole_len == 0) return 0;
    }
    return 1;
}

static const char *rducks_decimal_skip_zeros(const char *x, size_t *len) {
    while (*len > 0 && *x == '0') {
        x++;
        (*len)--;
    }
    return x;
}

static void rducks_decimal_set_string(SEXP out, R_xlen_t i, const char *buf, size_t len) {
    SET_STRING_ELT(out, i, Rf_mkCharLenCE(buf, (int)len, CE_UTF8));
}

SEXP RDUCKS_normalize_decimal_string(SEXP x, SEXP width_sexp, SEXP scale_sexp) {
    int width = rducks_decimal_get_width(width_sexp);
    int scale = rducks_decimal_get_scale(scale_sexp, width);
    SEXP input = rducks_as_character_protect(x);
    R_xlen_t n = XLENGTH(input);
    SEXP out = PROTECT(Rf_allocVector(STRSXP, n));

    for (R_xlen_t i = 0; i < n; i++) {
        SEXP ch = STRING_ELT(input, i);
        if (ch == NA_STRING) {
            SET_STRING_ELT(out, i, NA_STRING);
            continue;
        }
        size_t len = 0;
        const char *s = rducks_decimal_trim_char(ch, &len);
        int neg = 0;
        const char *whole;
        const char *frac;
        size_t whole_len;
        size_t frac_len;
        if (!rducks_decimal_parse_fixed(s, len, 1, &neg, &whole, &whole_len, &frac, &frac_len)) {
            Rf_error("DECIMAL values must be fixed-point decimal strings");
        }
        if ((int)frac_len > scale) Rf_error("DECIMAL value has more fractional digits than scale");
        const char *int_norm = rducks_decimal_skip_zeros(whole, &whole_len);
        int int_is_zero = whole_len == 0;
        size_t int_out_len = int_is_zero ? 1U : whole_len;
        size_t significant = int_out_len + (frac_len > (size_t)scale ? frac_len : (size_t)scale);
        if (int_is_zero) {
            size_t fs = frac_len > (size_t)scale ? frac_len : (size_t)scale;
            significant = fs > 1U ? fs : 1U;
        }
        if (significant > (size_t)width) Rf_error("DECIMAL value exceeds declared width");

        size_t out_len = (neg ? 1U : 0U) + int_out_len + (scale > 0 ? 1U + (size_t)scale : 0U);
        char *buf = (char *)R_alloc(out_len + 1U, sizeof(char));
        size_t pos = 0;
        if (neg) buf[pos++] = '-';
        if (int_is_zero) {
            buf[pos++] = '0';
        } else {
            memcpy(buf + pos, int_norm, whole_len);
            pos += whole_len;
        }
        if (scale > 0) {
            buf[pos++] = '.';
            if (frac_len > 0) {
                memcpy(buf + pos, frac, frac_len);
                pos += frac_len;
            }
            while (pos < out_len) buf[pos++] = '0';
        }
        buf[pos] = '\0';
        rducks_decimal_set_string(out, i, buf, out_len);
    }

    UNPROTECT(1);
    rducks_maybe_unprotect_character(x, input);
    return out;
}

SEXP RDUCKS_decimal_storage_strings(SEXP x, SEXP scale_sexp) {
    int scale = Rf_asInteger(scale_sexp);
    if (scale == NA_INTEGER || scale < 0) Rf_error("scale must be a non-negative integer");
    SEXP input = rducks_as_character_protect(x);
    R_xlen_t n = XLENGTH(input);
    SEXP out = PROTECT(Rf_allocVector(STRSXP, n));
    for (R_xlen_t i = 0; i < n; i++) {
        SEXP ch = STRING_ELT(input, i);
        if (ch == NA_STRING) {
            SET_STRING_ELT(out, i, NA_STRING);
            continue;
        }
        size_t len = 0;
        const char *s = rducks_decimal_trim_char(ch, &len);
        int neg = 0;
        const char *whole;
        const char *frac;
        size_t whole_len;
        size_t frac_len;
        if (!rducks_decimal_parse_fixed(s, len, 1, &neg, &whole, &whole_len, &frac, &frac_len)) {
            Rf_error("DECIMAL values must be fixed-point decimal strings");
        }
        size_t digit_len = whole_len + (size_t)scale;
        char *digits = (char *)R_alloc(digit_len + 1U, sizeof(char));
        memcpy(digits, whole, whole_len);
        size_t pos = whole_len;
        size_t copy_frac = frac_len < (size_t)scale ? frac_len : (size_t)scale;
        if (copy_frac) {
            memcpy(digits + pos, frac, copy_frac);
            pos += copy_frac;
        }
        while (pos < digit_len) digits[pos++] = '0';
        digits[pos] = '\0';
        const char *norm = rducks_decimal_skip_zeros(digits, &digit_len);
        if (digit_len == 0) {
            norm = "0";
            digit_len = 1;
        }
        size_t out_len = digit_len + (neg ? 1U : 0U);
        char *buf = (char *)R_alloc(out_len + 1U, sizeof(char));
        pos = 0;
        if (neg) buf[pos++] = '-';
        memcpy(buf + pos, norm, digit_len);
        pos += digit_len;
        buf[pos] = '\0';
        rducks_decimal_set_string(out, i, buf, out_len);
    }
    UNPROTECT(1);
    rducks_maybe_unprotect_character(x, input);
    return out;
}

static void rducks_decimal_unscale_one(const char *s, size_t len, int scale, char **buf_out, size_t *len_out) {
    int neg = 0;
    if (len > 0 && s[0] == '-') {
        neg = 1;
        s++;
        len--;
    }
    s = rducks_decimal_skip_zeros(s, &len);
    if (len == 0) {
        s = "0";
        len = 1;
    }
    if (scale == 0) {
        size_t out_len = len + (neg ? 1U : 0U);
        char *buf = (char *)R_alloc(out_len + 1U, sizeof(char));
        size_t pos = 0;
        if (neg) buf[pos++] = '-';
        memcpy(buf + pos, s, len);
        buf[out_len] = '\0';
        *buf_out = buf;
        *len_out = out_len;
        return;
    }
    size_t padded_len = len <= (size_t)scale ? (size_t)scale + 1U : len;
    char *padded = (char *)R_alloc(padded_len + 1U, sizeof(char));
    size_t pad = padded_len - len;
    memset(padded, '0', pad);
    memcpy(padded + pad, s, len);
    padded[padded_len] = '\0';
    size_t whole_len = padded_len - (size_t)scale;
    const char *whole = rducks_decimal_skip_zeros(padded, &whole_len);
    if (whole_len == 0) {
        whole = "0";
        whole_len = 1;
    }
    const char *frac = padded + padded_len - (size_t)scale;
    size_t out_len = (neg ? 1U : 0U) + whole_len + 1U + (size_t)scale;
    char *buf = (char *)R_alloc(out_len + 1U, sizeof(char));
    size_t pos = 0;
    if (neg) buf[pos++] = '-';
    memcpy(buf + pos, whole, whole_len);
    pos += whole_len;
    buf[pos++] = '.';
    memcpy(buf + pos, frac, (size_t)scale);
    pos += (size_t)scale;
    buf[pos] = '\0';
    *buf_out = buf;
    *len_out = out_len;
}

SEXP RDUCKS_decimal_unscale_strings(SEXP x, SEXP scale_sexp) {
    int scale = Rf_asInteger(scale_sexp);
    if (scale == NA_INTEGER || scale < 0) Rf_error("scale must be a non-negative integer");
    SEXP input = rducks_as_character_protect(x);
    R_xlen_t n = XLENGTH(input);
    SEXP out = PROTECT(Rf_allocVector(STRSXP, n));
    for (R_xlen_t i = 0; i < n; i++) {
        SEXP ch = STRING_ELT(input, i);
        if (ch == NA_STRING) {
            SET_STRING_ELT(out, i, NA_STRING);
            continue;
        }
        size_t len = 0;
        const char *s = rducks_decimal_trim_char(ch, &len);
        char *buf;
        size_t out_len;
        rducks_decimal_unscale_one(s, len, scale, &buf, &out_len);
        rducks_decimal_set_string(out, i, buf, out_len);
    }
    UNPROTECT(1);
    rducks_maybe_unprotect_character(x, input);
    return out;
}

SEXP RDUCKS_decimal_from_scaled_integer_strings(SEXP x, SEXP width_sexp, SEXP scale_sexp) {
    int width = rducks_decimal_get_width(width_sexp);
    (void)rducks_decimal_get_scale(scale_sexp, width);
    SEXP chars = PROTECT(RDUCKS_decimal_unscale_strings(x, scale_sexp));
    SEXP out = PROTECT(RDUCKS_normalize_decimal_string(chars, width_sexp, scale_sexp));
    UNPROTECT(2);
    return out;
}

SEXP RDUCKS_decimal_scaled_integer_strings(SEXP x) {
    SEXP input = rducks_as_character_protect(x);
    R_xlen_t n = XLENGTH(input);
    SEXP out = PROTECT(Rf_allocVector(STRSXP, n));
    for (R_xlen_t i = 0; i < n; i++) {
        SEXP ch = STRING_ELT(input, i);
        if (ch == NA_STRING) {
            SET_STRING_ELT(out, i, NA_STRING);
            continue;
        }
        const char *s = CHAR(ch);
        size_t len = strlen(s);
        char *tmp = (char *)R_alloc(len + 1U, sizeof(char));
        size_t pos = 0;
        for (size_t j = 0; j < len; j++) if (s[j] != '.') tmp[pos++] = s[j];
        tmp[pos] = '\0';

        const char *digits = tmp;
        size_t digit_len = pos;
        int neg = 0;
        if (digit_len > 0 && digits[0] == '+') {
            digits++;
            digit_len--;
        } else if (digit_len > 0 && digits[0] == '-') {
            neg = 1;
            digits++;
            digit_len--;
        }
        for (size_t j = 0; j < digit_len; j++) {
            if (digits[j] < '0' || digits[j] > '9') Rf_error("DECIMAL values must be fixed-point decimal strings");
        }
        digits = rducks_decimal_skip_zeros(digits, &digit_len);
        if (digit_len == 0) {
            SET_STRING_ELT(out, i, Rf_mkChar("0"));
        } else if (neg) {
            char *buf = (char *)R_alloc(digit_len + 2U, sizeof(char));
            buf[0] = '-';
            memcpy(buf + 1, digits, digit_len);
            buf[digit_len + 1U] = '\0';
            rducks_decimal_set_string(out, i, buf, digit_len + 1U);
        } else {
            rducks_decimal_set_string(out, i, digits, digit_len);
        }
    }
    UNPROTECT(1);
    rducks_maybe_unprotect_character(x, input);
    return out;
}

static int rducks_decimal_compare_scaled_strings(SEXP ach, SEXP bch) {
    if (ach == NA_STRING || bch == NA_STRING) return NA_INTEGER;
    const char *a = CHAR(ach);
    const char *b = CHAR(bch);
    size_t alen = strlen(a);
    size_t blen = strlen(b);
    char *aa = (char *)R_alloc(alen + 1U, sizeof(char));
    char *bb = (char *)R_alloc(blen + 1U, sizeof(char));
    size_t apos = 0, bpos = 0;
    for (size_t i = 0; i < alen; i++) if (a[i] != '.') aa[apos++] = a[i];
    for (size_t i = 0; i < blen; i++) if (b[i] != '.') bb[bpos++] = b[i];
    aa[apos] = '\0';
    bb[bpos] = '\0';

    const char *ad = aa;
    const char *bd = bb;
    size_t adn = apos;
    size_t bdn = bpos;
    int as = 1;
    int bs = 1;
    if (adn > 0 && ad[0] == '-') {
        as = -1;
        ad++;
        adn--;
    } else if (adn > 0 && ad[0] == '+') {
        ad++;
        adn--;
    }
    if (bdn > 0 && bd[0] == '-') {
        bs = -1;
        bd++;
        bdn--;
    } else if (bdn > 0 && bd[0] == '+') {
        bd++;
        bdn--;
    }
    ad = rducks_decimal_skip_zeros(ad, &adn);
    bd = rducks_decimal_skip_zeros(bd, &bdn);
    if (adn == 0) as = 1;
    if (bdn == 0) bs = 1;
    if (as != bs) return as < bs ? -1 : 1;
    int cmp;
    if (adn != bdn) {
        cmp = adn < bdn ? -1 : 1;
    } else if (adn == 0) {
        cmp = 0;
    } else {
        int raw_cmp = memcmp(ad, bd, adn);
        cmp = raw_cmp < 0 ? -1 : (raw_cmp > 0 ? 1 : 0);
    }
    return cmp * as;
}

SEXP RDUCKS_decimal_compare_values(SEXP a, SEXP b) {
    SEXP aa = rducks_as_character_protect(a);
    SEXP bb = rducks_as_character_protect(b);
    R_xlen_t na = XLENGTH(aa);
    R_xlen_t nb = XLENGTH(bb);
    R_xlen_t n = na > nb ? na : nb;
    SEXP out = PROTECT(Rf_allocVector(INTSXP, n));
    for (R_xlen_t i = 0; i < n; i++) {
        SEXP ach = na == 0 ? NA_STRING : STRING_ELT(aa, i % na);
        SEXP bch = nb == 0 ? NA_STRING : STRING_ELT(bb, i % nb);
        INTEGER(out)[i] = rducks_decimal_compare_scaled_strings(ach, bch);
    }
    UNPROTECT(1);
    rducks_maybe_unprotect_character(b, bb);
    rducks_maybe_unprotect_character(a, aa);
    return out;
}

static void rducks_decimal_abs_to_unsigned_bytes(const char *digits, size_t len, int width, Rbyte *out) {
    memset(out, 0, (size_t)width);
    digits = rducks_decimal_skip_zeros(digits, &len);
    if (len == 0) return;
    unsigned char *work = (unsigned char *)R_alloc(len, sizeof(unsigned char));
    for (size_t i = 0; i < len; i++) {
        if (digits[i] < '0' || digits[i] > '9') Rf_error("expected an unsigned decimal integer string");
        work[i] = (unsigned char)(digits[i] - '0');
    }
    size_t ndigits = len;
    int byte_pos = 0;
    while (ndigits > 0) {
        if (byte_pos >= width) Rf_error("integer value does not fit in fixed-width storage");
        int carry = 0;
        size_t write = 0;
        int started = 0;
        for (size_t i = 0; i < ndigits; i++) {
            int value = carry * 10 + work[i];
            int q = value / 256;
            carry = value % 256;
            if (q != 0 || started) {
                work[write++] = (unsigned char)q;
                started = 1;
            }
        }
        out[byte_pos++] = (Rbyte)carry;
        ndigits = write;
    }
}

SEXP RDUCKS_fixed_width_bytes_from_decimal_strings(SEXP values, SEXP width_sexp, SEXP signed_sexp) {
    int width = Rf_asInteger(width_sexp);
    if (width == NA_INTEGER || width <= 0) Rf_error("width must be positive");
    int signed_flag = Rf_asLogical(signed_sexp) == TRUE;
    SEXP input = rducks_as_character_protect(values);
    R_xlen_t n = XLENGTH(input);
    R_xlen_t out_len = rducks_xlen_mul(n, (R_xlen_t)width, "fixed-width byte");
    SEXP out = PROTECT(Rf_allocVector(RAWSXP, out_len));
    Rbyte *raw = RAW(out);
    memset(raw, 0, (size_t)out_len);
    for (R_xlen_t i = 0; i < n; i++) {
        SEXP ch = STRING_ELT(input, i);
        Rbyte *dest = raw + i * (R_xlen_t)width;
        if (ch == NA_STRING) continue;
        size_t len = 0;
        const char *s = rducks_decimal_trim_char(ch, &len);
        int neg = 0;
        if (len > 0 && s[0] == '+') {
            s++;
            len--;
        } else if (len > 0 && s[0] == '-') {
            neg = 1;
            s++;
            len--;
        }
        if (neg && !signed_flag) Rf_error("unsigned integer value is negative");
        rducks_decimal_abs_to_unsigned_bytes(s, len, width, dest);
        if (neg) {
            for (int j = 0; j < width; j++) dest[j] = (Rbyte)(255U - dest[j]);
            int carry = 1;
            for (int j = 0; j < width; j++) {
                int value = (int)dest[j] + carry;
                dest[j] = (Rbyte)(value & 0xff);
                carry = value >> 8;
                if (!carry) break;
            }
        }
    }
    UNPROTECT(1);
    rducks_maybe_unprotect_character(values, input);
    return out;
}

static size_t rducks_unsigned_bytes_to_decimal_buf(const Rbyte *raw, size_t n, char *out, size_t out_cap) {
    size_t cap = n + 1U;
    uint32_t *limbs = (uint32_t *)R_alloc(cap, sizeof(uint32_t));
    memset(limbs, 0, cap * sizeof(uint32_t));
    size_t nlimbs = 1U;
    for (size_t i = n; i > 0; i--) {
        rducks_decimal_limbs_mul_add(limbs, &nlimbs, cap, 256U, (uint32_t)raw[i - 1U],
                                     "decimal byte conversion");
    }
    while (nlimbs > 1U && limbs[nlimbs - 1U] == 0U) nlimbs--;
    if (nlimbs == 1U && limbs[0] == 0U) {
        if (out_cap < 2U) Rf_error("decimal output buffer too small");
        out[0] = '0';
        out[1] = '\0';
        return 1U;
    }
    size_t pos = 0;
    pos += (size_t)snprintf(out + pos, out_cap - pos, "%u", limbs[nlimbs - 1U]);
    for (size_t j = nlimbs - 1U; j > 0; j--) {
        pos += (size_t)snprintf(out + pos, out_cap - pos, "%09u", limbs[j - 1U]);
    }
    return pos;
}

SEXP RDUCKS_decimal_strings_from_fixed_width_bytes(SEXP bytes_sexp, SEXP valid_sexp, SEXP offset_sexp,
                                                   SEXP n_sexp, SEXP width_sexp, SEXP signed_sexp) {
    if (TYPEOF(bytes_sexp) != RAWSXP) Rf_error("bytes must be raw");
    if (TYPEOF(valid_sexp) != LGLSXP) Rf_error("valid must be logical");
    int offset = Rf_asInteger(offset_sexp);
    int n = Rf_asInteger(n_sexp);
    int width = Rf_asInteger(width_sexp);
    int signed_flag = Rf_asLogical(signed_sexp) == TRUE;
    if (offset < 0 || n < 0 || width <= 0) Rf_error("invalid fixed-width byte conversion parameters");
    rducks_require_raw_span(bytes_sexp, (R_xlen_t)offset, (R_xlen_t)n, (R_xlen_t)width, "fixed-width byte");
    rducks_require_len(valid_sexp, (R_xlen_t)n, "valid");
    SEXP out = PROTECT(Rf_allocVector(STRSXP, n));
    const Rbyte *bytes = RAW(bytes_sexp);
    for (int i = 0; i < n; i++) {
        if (LOGICAL(valid_sexp)[i] != TRUE) {
            SET_STRING_ELT(out, i, NA_STRING);
            continue;
        }
        const Rbyte *src = bytes + ((R_xlen_t)offset + i) * (R_xlen_t)width;
        Rbyte *tmp = (Rbyte *)R_alloc((size_t)width, sizeof(Rbyte));
        memcpy(tmp, src, (size_t)width);
        int neg = signed_flag && width > 0 && tmp[width - 1] >= 128;
        if (neg) {
            for (int j = 0; j < width; j++) tmp[j] = (Rbyte)(255U - tmp[j]);
            int carry = 1;
            for (int j = 0; j < width; j++) {
                int value = (int)tmp[j] + carry;
                tmp[j] = (Rbyte)(value & 0xff);
                carry = value >> 8;
                if (!carry) break;
            }
        }
        size_t out_cap = (size_t)width * RDUCKS_DEC_BASE_DIGITS + 3U;
        char *buf = (char *)R_alloc(out_cap, sizeof(char));
        size_t pos = 0;
        if (neg) buf[pos++] = '-';
        pos += rducks_unsigned_bytes_to_decimal_buf(tmp, (size_t)width, buf + pos, out_cap - pos);
        rducks_decimal_set_string(out, i, buf, pos);
    }
    UNPROTECT(1);
    return out;
}

static int32_t rducks_read_i32_le(const Rbyte *src) {
    return (int32_t)rducks_load_u32_le(src);
}

static size_t rducks_decimal_divide_integer_to_buf(const char *s, size_t len, int divisor, char *out) {
    int neg = 0;
    if (len > 0 && s[0] == '-') {
        neg = 1;
        s++;
        len--;
    } else if (len > 0 && s[0] == '+') {
        s++;
        len--;
    }
    s = rducks_decimal_skip_zeros(s, &len);
    if (len == 0) {
        out[0] = '0';
        out[1] = '\0';
        return 1U;
    }
    size_t pos = 0;
    size_t qpos = neg ? 1U : 0U;
    int started = 0;
    int carry = 0;
    for (size_t i = 0; i < len; i++) {
        if (s[i] < '0' || s[i] > '9') Rf_error("expected a decimal integer string");
        int value = carry * 10 + (s[i] - '0');
        int digit = value / divisor;
        carry = value % divisor;
        if (digit != 0 || started) {
            out[qpos++] = (char)('0' + digit);
            started = 1;
        }
    }
    if (!started) {
        out[0] = '0';
        out[1] = '\0';
        return 1U;
    }
    if (neg) {
        out[0] = '-';
        pos = qpos;
    } else {
        pos = qpos;
    }
    out[pos] = '\0';
    return pos;
}

SEXP RDUCKS_interval_values_from_bytes(SEXP bytes_sexp, SEXP valid_sexp, SEXP offset_sexp, SEXP n_sexp) {
    if (TYPEOF(bytes_sexp) != RAWSXP) Rf_error("bytes must be raw");
    if (TYPEOF(valid_sexp) != LGLSXP) Rf_error("valid must be logical");
    int offset = Rf_asInteger(offset_sexp);
    int n = Rf_asInteger(n_sexp);
    if (offset < 0 || n < 0) Rf_error("invalid INTERVAL conversion parameters");
    rducks_require_raw_span(bytes_sexp, (R_xlen_t)offset, (R_xlen_t)n, 16, "INTERVAL byte");
    rducks_require_len(valid_sexp, (R_xlen_t)n, "valid");

    SEXP months = PROTECT(Rf_allocVector(INTSXP, n));
    SEXP days = PROTECT(Rf_allocVector(INTSXP, n));
    SEXP micros = PROTECT(Rf_allocVector(STRSXP, n));
    const Rbyte *bytes = RAW(bytes_sexp);

    for (int i = 0; i < n; i++) {
        if (LOGICAL(valid_sexp)[i] != TRUE) {
            INTEGER(months)[i] = NA_INTEGER;
            INTEGER(days)[i] = NA_INTEGER;
            SET_STRING_ELT(micros, i, NA_STRING);
            continue;
        }
        const Rbyte *src = bytes + ((R_xlen_t)offset + i) * 16;
        INTEGER(months)[i] = (int)rducks_read_i32_le(src);
        INTEGER(days)[i] = (int)rducks_read_i32_le(src + 4);

        Rbyte tmp[8];
        memcpy(tmp, src + 8, 8U);
        int neg = tmp[7] >= 128;
        if (neg) {
            for (int j = 0; j < 8; j++) tmp[j] = (Rbyte)(255U - tmp[j]);
            int carry = 1;
            for (int j = 0; j < 8; j++) {
                int value = (int)tmp[j] + carry;
                tmp[j] = (Rbyte)(value & 0xff);
                carry = value >> 8;
                if (!carry) break;
            }
        }
        size_t dec_cap = 8U * RDUCKS_DEC_BASE_DIGITS + 3U;
        char *dec = (char *)R_alloc(dec_cap, sizeof(char));
        size_t dec_pos = 0;
        if (neg) dec[dec_pos++] = '-';
        dec_pos += rducks_unsigned_bytes_to_decimal_buf(tmp, 8U, dec + dec_pos, dec_cap - dec_pos);
        dec[dec_pos] = '\0';

        char *mic = (char *)R_alloc(dec_pos + 2U, sizeof(char));
        size_t mic_len = rducks_decimal_divide_integer_to_buf(dec, dec_pos, 1000, mic);
        SET_STRING_ELT(micros, i, Rf_mkCharLenCE(mic, (int)mic_len, CE_UTF8));
    }

    SEXP out = PROTECT(Rf_allocVector(VECSXP, 3));
    SET_VECTOR_ELT(out, 0, months);
    SET_VECTOR_ELT(out, 1, days);
    SET_VECTOR_ELT(out, 2, micros);
    SEXP names = PROTECT(Rf_allocVector(STRSXP, 3));
    SET_STRING_ELT(names, 0, Rf_mkChar("months"));
    SET_STRING_ELT(names, 1, Rf_mkChar("days"));
    SET_STRING_ELT(names, 2, Rf_mkChar("micros"));
    Rf_setAttrib(out, R_NamesSymbol, names);
    UNPROTECT(5);
    return out;
}
