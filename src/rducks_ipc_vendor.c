/* Compile the vendored nanoarrow C/IPC implementation into the R package
 * shared library. Keep this in a dedicated translation unit so ordinary R-side
 * IPC code does not include vendored implementation .c files directly.
 */
#include "../tools/ext/src/rducks_vendor_nanoarrow.c"
#include "../tools/ext/src/rducks_vendor_ipc_helpers.h"

#include "rducks_ipc_vendor.h"

int rducks_r_arrow_ipc_encode_borrowed_array(const struct ArrowSchema *schema,
                                             const struct ArrowArray *array,
                                             uint8_t **bytes_out,
                                             size_t *size_out,
                                             char *err_msg,
                                             size_t err_cap) {
    return rducks_arrow_ipc_encode_borrowed_array(schema, array, bytes_out, size_out,
                                                  err_msg, err_cap);
}
