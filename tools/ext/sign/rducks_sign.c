/* Sign a DuckDB extension file with a key that exists only while this program
 * runs.
 *
 *   rducks_sign <extension-in> <extension-out> <public-key-out>
 *
 * DuckDB verifies an extension by hashing every byte except the trailing
 * 256-byte signature field: each 1 MiB segment is hashed with SHA-256, and the
 * concatenated segment digests are hashed again. The signature is RSA-2048
 * PKCS#1 v1.5 over that SHA-256 digest. This program generates a fresh RSA
 * key, signs the input, verifies the signature, writes the signed file and the
 * base64 DER public key, and frees the private key without writing it.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mbedtls/base64.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/entropy.h"
#include "mbedtls/pk.h"
#include "mbedtls/rsa.h"
#include "mbedtls/sha256.h"

#define RDUCKS_SIGNATURE_SIZE 256u
#define RDUCKS_FOOTER_SIZE 512u
#define RDUCKS_SEGMENT_SIZE (1024u * 1024u)
#define RDUCKS_DIGEST_SIZE 32u
#define RDUCKS_PUBKEY_DER_MAX 1024u

static int fail(const char *what, int code) {
  fprintf(stderr, "rducks_sign: %s (code %d)\n", what, code);
  return 1;
}

static int read_file(const char *path, unsigned char **out, size_t *out_size) {
  FILE *fp = fopen(path, "rb");
  long size;
  unsigned char *buf;
  if (!fp) return fail("cannot open input file", 0);
  if (fseek(fp, 0, SEEK_END) != 0 || (size = ftell(fp)) < 0 || fseek(fp, 0, SEEK_SET) != 0) {
    fclose(fp);
    return fail("cannot size input file", 0);
  }
  if ((unsigned long) size < RDUCKS_FOOTER_SIZE) {
    fclose(fp);
    return fail("input file is smaller than the DuckDB metadata footer", 0);
  }
  buf = malloc((size_t) size);
  if (!buf) {
    fclose(fp);
    return fail("out of memory", 0);
  }
  if (fread(buf, 1, (size_t) size, fp) != (size_t) size) {
    free(buf);
    fclose(fp);
    return fail("cannot read input file", 0);
  }
  fclose(fp);
  *out = buf;
  *out_size = (size_t) size;
  return 0;
}

static int write_file(const char *path, const unsigned char *buf, size_t size) {
  FILE *fp = fopen(path, "wb");
  int ok;
  if (!fp) return fail("cannot open output file", 0);
  ok = fwrite(buf, 1, size, fp) == size;
  ok = (fclose(fp) == 0) && ok;
  return ok ? 0 : fail("cannot write output file", 0);
}

/* DuckDB's two-level digest over buf[0, size). */
static int extension_digest(const unsigned char *buf, size_t size, unsigned char digest[RDUCKS_DIGEST_SIZE]) {
  size_t n_segments = (size + RDUCKS_SEGMENT_SIZE - 1u) / RDUCKS_SEGMENT_SIZE;
  unsigned char *segment_digests;
  size_t i;
  int rc;
  if (n_segments == 0u || n_segments > ((size_t) -1) / RDUCKS_DIGEST_SIZE) {
    return fail("invalid extension size", 0);
  }
  segment_digests = malloc(n_segments * RDUCKS_DIGEST_SIZE);
  if (!segment_digests) return fail("out of memory", 0);
  for (i = 0; i < n_segments; i++) {
    size_t offset = i * RDUCKS_SEGMENT_SIZE;
    size_t len = size - offset < RDUCKS_SEGMENT_SIZE ? size - offset : RDUCKS_SEGMENT_SIZE;
    rc = mbedtls_sha256(buf + offset, len, segment_digests + i * RDUCKS_DIGEST_SIZE, 0);
    if (rc != 0) {
      free(segment_digests);
      return fail("SHA-256 failed", rc);
    }
  }
  rc = mbedtls_sha256(segment_digests, n_segments * RDUCKS_DIGEST_SIZE, digest, 0);
  free(segment_digests);
  return rc == 0 ? 0 : fail("SHA-256 failed", rc);
}

static int write_public_key(mbedtls_pk_context *pk, const char *path) {
  unsigned char der[RDUCKS_PUBKEY_DER_MAX];
  unsigned char b64[2u * RDUCKS_PUBKEY_DER_MAX + 1u];
  size_t b64_len = 0;
  int der_len = mbedtls_pk_write_pubkey_der(pk, der, sizeof(der));
  int rc;
  if (der_len <= 0) return fail("cannot export public key", der_len);
  /* mbedtls_pk_write_pubkey_der writes at the end of the buffer. */
  rc = mbedtls_base64_encode(b64, sizeof(b64) - 1u, &b64_len, der + sizeof(der) - (size_t) der_len, (size_t) der_len);
  if (rc != 0) return fail("cannot encode public key", rc);
  b64[b64_len++] = '\n';
  return write_file(path, b64, b64_len);
}

int main(int argc, char **argv) {
  static const char personalization[] = "rducks_sign";
  mbedtls_entropy_context entropy;
  mbedtls_ctr_drbg_context drbg;
  mbedtls_pk_context pk;
  unsigned char digest[RDUCKS_DIGEST_SIZE];
  unsigned char *buf = NULL;
  size_t size = 0, body_size, sig_len = 0;
  int rc, status = 1;

  if (argc != 4) {
    fprintf(stderr, "usage: rducks_sign <extension-in> <extension-out> <public-key-out>\n");
    return 2;
  }
  mbedtls_entropy_init(&entropy);
  mbedtls_ctr_drbg_init(&drbg);
  mbedtls_pk_init(&pk);

  if (read_file(argv[1], &buf, &size) != 0) goto cleanup;
  body_size = size - RDUCKS_SIGNATURE_SIZE;
  if (extension_digest(buf, body_size, digest) != 0) goto cleanup;

  rc = mbedtls_ctr_drbg_seed(&drbg, mbedtls_entropy_func, &entropy,
                             (const unsigned char *) personalization, sizeof(personalization) - 1u);
  if (rc != 0) { fail("cannot seed random generator", rc); goto cleanup; }
  rc = mbedtls_pk_setup(&pk, mbedtls_pk_info_from_type(MBEDTLS_PK_RSA));
  if (rc != 0) { fail("cannot set up RSA key", rc); goto cleanup; }
  rc = mbedtls_rsa_gen_key(mbedtls_pk_rsa(pk), mbedtls_ctr_drbg_random, &drbg, 2048, 65537);
  if (rc != 0) { fail("cannot generate RSA key", rc); goto cleanup; }

  rc = mbedtls_pk_sign(&pk, MBEDTLS_MD_SHA256, digest, sizeof(digest), buf + body_size, RDUCKS_SIGNATURE_SIZE,
                       &sig_len, mbedtls_ctr_drbg_random, &drbg);
  if (rc != 0 || sig_len != RDUCKS_SIGNATURE_SIZE) { fail("cannot sign extension", rc); goto cleanup; }
  rc = mbedtls_pk_verify(&pk, MBEDTLS_MD_SHA256, digest, sizeof(digest), buf + body_size, sig_len);
  if (rc != 0) { fail("signature does not verify", rc); goto cleanup; }

  if (write_file(argv[2], buf, size) != 0) goto cleanup;
  if (write_public_key(&pk, argv[3]) != 0) goto cleanup;
  status = 0;

cleanup:
  free(buf);
  mbedtls_pk_free(&pk);
  mbedtls_ctr_drbg_free(&drbg);
  mbedtls_entropy_free(&entropy);
  return status;
}
