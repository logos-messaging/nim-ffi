#ifndef NIM_FFI_PRELUDE_H_INCLUDED
#define NIM_FFI_PRELUDE_H_INCLUDED
/* Generated C binding for a nim-ffi library. Requests/responses travel as
 * CBOR (encoded with vendored TinyCBOR on this side, matching the Nim-side
 * cbor_serial codec on the wire — both ends speak RFC 8949).
 *
 * The API is asynchronous: every method/constructor takes a result callback
 * and returns immediately. The callback fires exactly once — synchronously on
 * a submit-time failure, otherwise from the Nim dispatch thread when the reply
 * arrives.
 *
 * Events and liveness reports use no callback. The library queues them and the
 * host takes them out with <lib>_ctx_dispatch_next(), on a thread of its choice:
 * the binding starts no thread. <Lib>Handlers in <lib>.h lists every message
 * the library can send.
 *
 * Memory ownership contract:
 *   - Request-side strings/sequences are *borrowed*: the binding only reads
 *     them while encoding, so a plain string literal is fine and is never
 *     freed by the binding.
 *   - Response values and error strings passed into a result callback are
 *     *owned by the binding* and valid only for the duration of that callback;
 *     the binding reclaims them once the callback returns. The caller never
 *     frees them. The same holds for an event handed to a <Lib>Handlers entry.
 *   - A value the caller decodes itself with <lib>_decode_<event>() is the
 *     caller's, released with the <lib>_free_<Type>() helper of its type.
 *   - A context handle delivered to a constructor callback is the exception:
 *     ownership transfers to the caller, who releases it with
 *     <lib>_ctx_destroy(). It is a lifecycle handle, not returned data.
 *
 * Trust boundary: the decoders assume the CBOR they parse was produced by the
 * paired Nim library. They reject malformed input rather than trusting it, but
 * they are not hardened against a hostile peer feeding crafted payloads through
 * the raw nimffi_decode_from_buf entry point.
 */
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <tinycbor/cbor.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Nim `string`/`cstring` crosses as a plain NUL-terminated C string. A request
 * field borrows the caller's storage, which must outlive the call that encodes
 * it; a decoded response string is heap-allocated, and the binding frees it
 * once the result callback returns. Because the wire form is NUL-terminated
 * here, a Nim string carrying embedded NUL bytes is truncated at the first
 * one — use `seq[byte]` for binary payloads. */

/* Owned, length-delimited byte buffer (Nim `seq[byte]`). */
typedef struct {
    uint8_t* data;
    size_t len;
} NimFfiBytes;

static inline void nimffi_free_bytes(NimFfiBytes* v) {
    if (!v || !v->data) {
        return;
    }
    free(v->data);
    v->data = NULL;
    v->len = 0;
}

/* What <lib>_poll() hands out: one message from the library to the host. */
{{MSG_DECL}}

#ifdef __cplusplus
}
#endif

#endif /* NIM_FFI_PRELUDE_H_INCLUDED */
