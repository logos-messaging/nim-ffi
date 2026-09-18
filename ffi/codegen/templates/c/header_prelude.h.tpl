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
 * Memory ownership contract:
 *   - Request-side strings/sequences are *borrowed*: the binding only reads
 *     them while encoding, so a plain string literal is fine and is never
 *     freed by the binding.
 *   - Response values and error strings passed into a result callback are
 *     *owned by the binding* and valid only for the duration of that callback;
 *     the binding reclaims them once the callback returns. The caller never
 *     frees them. (The generated <lib>_free_<Type>() helpers are internal — the
 *     trampolines use them to reclaim decoded payloads.)
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
 * it; a decoded response string is heap-allocated and freed by
 * nimffi_free_cstr. Because the wire form is NUL-terminated here, a Nim string
 * carrying embedded NUL bytes is truncated at the first one — use `seq[byte]`
 * for binary payloads. */

/* Owned, length-delimited byte buffer (Nim `seq[byte]`). */
typedef struct {
    uint8_t* data;
    size_t len;
} NimFfiBytes;

static inline void nimffi_free_cstr(const char** v) {
    if (!v || !*v) {
        return;
    }
    free((void*)*v); /* decoded by nimffi_dec_str, which owns the allocation */
    *v = NULL;
}

static inline void nimffi_free_bytes(NimFfiBytes* v) {
    if (!v || !v->data) {
        return;
    }
    free(v->data);
    v->data = NULL;
    v->len = 0;
}

#ifdef __cplusplus
}
#endif

#endif /* NIM_FFI_PRELUDE_H_INCLUDED */
