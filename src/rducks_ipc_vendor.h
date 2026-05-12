#ifndef RDUCKS_IPC_VENDOR_H
#define RDUCKS_IPC_VENDOR_H

#include <stddef.h>
#include <stdint.h>

struct ArrowArray;
struct ArrowSchema;

int rducks_r_arrow_ipc_encode_borrowed_array(const struct ArrowSchema *schema,
                                             const struct ArrowArray *array,
                                             uint8_t **bytes_out,
                                             size_t *size_out,
                                             char *err_msg,
                                             size_t err_cap);

#endif
