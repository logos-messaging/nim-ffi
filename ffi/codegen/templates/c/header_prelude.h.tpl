/* clock_gettime / CLOCK_REALTIME (used by the sync-call helper) live behind
 * POSIX feature-test macros that strict `-std=c11` would otherwise hide. This
 * self-guard only takes effect when this header is included before any libc
 * header (once <features.h> is pulled in, the level is fixed). For include-
 * order independence, define _POSIX_C_SOURCE>=200809L on the command line — the
 * bundled CMakeLists.txt does this on the headers target. */
#if !defined(_POSIX_C_SOURCE) || (_POSIX_C_SOURCE < 200809L)
#  undef _POSIX_C_SOURCE
#  define _POSIX_C_SOURCE 200809L
#endif

#ifndef NIM_FFI_PRELUDE_H_INCLUDED
#define NIM_FFI_PRELUDE_H_INCLUDED
/* Generated C binding for a nim-ffi library. Requests/responses travel as
 * CBOR (encoded with vendored TinyCBOR on this side, matching the Nim-side
 * cbor_serial codec on the wire — both ends speak RFC 8949).
 *
 * Memory ownership contract:
 *   - Request-side strings/sequences are *borrowed*: the binding only reads
 *     them while encoding, so a string literal wrapped with nimffi_str() is
 *     fine and is never freed by the binding.
 *   - Response-side values returned through an out-parameter are *owned* by
 *     the caller. Release them with the generated <lib>_free_<Type>() helper.
 *   - Error strings handed back through a `char** err` out-parameter are
 *     heap-allocated; release them with free().
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
#include <pthread.h>
#include <time.h>
#include <tinycbor/cbor.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Owned, length-delimited UTF-8 text (Nim `string`/`cstring`). On the request
 * side `data` may point at borrowed storage (see nimffi_str); on the response
 * side it is heap-allocated and freed by nimffi_free_str. Always NUL-padded by
 * one byte after decode so `data` is usable as a C string when it has no
 * embedded NULs. */
typedef struct {
    char* data;
    size_t len;
} NimFfiStr;

/* Owned, length-delimited byte buffer (Nim `seq[byte]`). */
typedef struct {
    uint8_t* data;
    size_t len;
} NimFfiBytes;

/* Wrap a borrowed C string for use as a request field. The returned view is
 * not owned by the binding and must outlive the call that encodes it. */
static inline NimFfiStr nimffi_str(const char* s) {
    NimFfiStr v;
    v.data = (char*)s;
    v.len = s ? strlen(s) : 0;
    return v;
}

static inline void nimffi_free_str(NimFfiStr* v) {
    if (!v || !v->data) {
        return;
    }
    free(v->data);
    v->data = NULL;
    v->len = 0;
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
