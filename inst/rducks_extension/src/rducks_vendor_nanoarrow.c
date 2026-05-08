/* Included by rducks_extension.c and by src/ipc_encode.c.
 * Vendored nanoarrow C + IPC implementation with prefixed flatcc symbols.
 */
#include "rducks_vendor_nanoarrow_prefix.h"

#include "../tp/na/thirdparty/flatcc/src/runtime/builder.c"
#include "../tp/na/thirdparty/flatcc/src/runtime/emitter.c"
#include "../tp/na/thirdparty/flatcc/src/runtime/refmap.c"
#include "../tp/na/thirdparty/flatcc/src/runtime/verifier.c"

#include "../tp/na/src/nanoarrow/common/utils.c"
#include "../tp/na/src/nanoarrow/common/schema.c"
#include "../tp/na/src/nanoarrow/common/array.c"
#include "../tp/na/src/nanoarrow/common/array_stream.c"

#include "../tp/na/src/nanoarrow/ipc/codecs.c"
#include "../tp/na/src/nanoarrow/ipc/decoder.c"
#include "../tp/na/src/nanoarrow/ipc/encoder.c"
#include "../tp/na/src/nanoarrow/ipc/reader.c"
#include "../tp/na/src/nanoarrow/ipc/writer.c"
