#ifndef NIM_FFI_REVERSE_IMPL_DEFINED
#define NIM_FFI_REVERSE_IMPL_DEFINED
/* Status of <lib>_set_<wire>_impl and <lib>_reverse_reply. */
{{REVERSE_CODES}}
/* Runs on a reverse worker thread and may block. ctx is the token of the
   context that made the call: answer with it, now or later and from any
   thread, via <lib>_reverse_reply or <lib>_reverse_reply_<wire>; it stays
   safe to use after the context is destroyed (the reply then fails with
   _INVALID_CTX). args is valid only until the impl returns: copy what a
   deferred reply needs. */
typedef void (*FFIReverseImpl)(void* ctx, uint64_t call_id, const uint8_t* args, size_t args_len, void* user_data);
/* Frees an impl's user_data once no invocation uses it. It runs on whichever
   thread drops the last reference (a reverse worker, the set_impl caller or
   the library's own thread at teardown), so it must be thread-safe. */
typedef void (*FFIReverseRelease)(void* user_data);
#endif
/* Destroying a context from inside one of its own impls fails at once with
   RET_ERR: that destroy would wait for the very impl that calls it. */
/* <lib>_set_<wire>_impl registers impl (NULL unregisters). With a release the
   library owns user_data, and release(user_data) runs once the replaced impl's
   last running invocation returns. With a NULL release the host keeps ownership
   and the library never frees it: keep it valid until the context is destroyed.
   The call never waits. Returns NIMFFI_REVERSE_ACCEPTED, _INVALID_CTX,
   _WORKERS_FAILED, _OUT_OF_MEMORY or _REGISTRY_FULL; on any error the caller
   still owns user_data and release is never called. */
