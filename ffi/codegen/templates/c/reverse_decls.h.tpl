#ifndef NIM_FFI_REVERSE_IMPL_DEFINED
#define NIM_FFI_REVERSE_IMPL_DEFINED
/* Runs on a reverse worker thread; may block. Reply with ctx via
   <lib>_reverse_reply*, from any thread, now or later (after the context is
   destroyed: NIMFFI_RET_INVALID_CTX). args lives only until the impl returns. */
typedef void (*FFIReverseImpl)(void* ctx, uint64_t call_id, const uint8_t* args, size_t args_len, void* user_data);
/* Frees user_data after its last invocation; runs on any thread, so it must be
   thread-safe. */
typedef void (*FFIReverseRelease)(void* user_data);
#endif
/* Destroying a context from one of its own impls returns RET_ERR (it would
   deadlock). */
/* <lib>_set_<wire>_impl registers impl (NULL unregisters); never blocks. With a
   release the library owns user_data and frees it after the replaced impl's last
   call; with NULL the host keeps it valid until the context is destroyed. On
   error the caller keeps user_data.
   Returns NIMFFI_RET_OK, _INVALID_CTX, _WORKERS_FAILED or _OUT_OF_MEMORY. */
