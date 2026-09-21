#ifndef NIM_FFI_PRELUDE_H_INCLUDED
#define NIM_FFI_PRELUDE_H_INCLUDED
/* Generated C binding for a nim-ffi library. Requests/responses travel as
 * CBOR (encoded with vendored TinyCBOR on this side, matching the Nim-side
 * cbor_serial codec on the wire — both ends speak RFC 8949).
 *
 * The library never calls into the host and the binding starts no thread.
 * A request returns as soon as it is queued. Its reply, like every event and
 * liveness report, waits inside the library until the host takes it out with
 * <lib>_ctx_pump_once(), which calls the request's reply callback or the
 * matching entry of <Lib>Handlers on the calling thread. <lib>.h lists every
 * request and every message the library can send.
 *
 * Each request comes in two shapes: <lib>_ctx_<proc>(..., on_reply, user_data)
 * for a host with a loop, and <lib>_ctx_<proc>_sync(..., &out, &err, timeout)
 * for a sequential program, which pumps until its own reply arrives.
 *
 * Threads: a context of this binding is single-threaded by design. Submit and
 * pump it from one thread, or hold one lock around both. A host that wants
 * something else uses the raw <lib>_<proc>() and <lib>_poll() exports with the
 * typed <lib>_decode_*() decoders.
 *
 * Memory ownership contract:
 *   - Request-side strings/sequences are *borrowed*: the binding only reads
 *     them while encoding, so a plain string literal is fine and is never
 *     freed by the binding.
 *   - Response values and error strings passed into a reply callback are
 *     *owned by the binding* and valid only for the duration of that callback;
 *     the binding reclaims them once the callback returns. The caller never
 *     frees them. The same holds for an event handed to a <Lib>Handlers entry.
 *   - A value the caller decodes itself, with <lib>_decode_<event>() or
 *     <lib>_decode_<proc>_reply(), or receives from a `_sync` helper, is the
 *     caller's: released with the <lib>_free_<Type>() helper of its type (a
 *     bare string with free()). An error text handed out through a `char**`
 *     is the caller's too, released with free().
 *   - A context handle is the caller's from the moment the constructor hands
 *     it out, whatever the constructor's reply says; it is released with
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
 * once the reply callback returns. Because the wire form is NUL-terminated
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
