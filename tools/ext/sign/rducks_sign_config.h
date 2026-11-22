/* Minimal Mbed TLS configuration for tools/ext/sign/rducks_sign.c: RSA key
 * generation, PKCS#1 v1.5 SHA-256 signatures, DER public key export, and the
 * platform entropy source.
 */
#ifndef RDUCKS_SIGN_CONFIG_H
#define RDUCKS_SIGN_CONFIG_H

#define MBEDTLS_AES_C
#define MBEDTLS_ASN1_PARSE_C
#define MBEDTLS_ASN1_WRITE_C
#define MBEDTLS_BASE64_C
#define MBEDTLS_BIGNUM_C
#define MBEDTLS_CTR_DRBG_C
#define MBEDTLS_ENTROPY_C
#define MBEDTLS_GENPRIME
#define MBEDTLS_MD_C
#define MBEDTLS_OID_C
#define MBEDTLS_PK_C
#define MBEDTLS_PK_PARSE_C
#define MBEDTLS_PK_WRITE_C
#define MBEDTLS_PKCS1_V15
#define MBEDTLS_RSA_C
#define MBEDTLS_SHA224_C
#define MBEDTLS_SHA256_C

#endif
