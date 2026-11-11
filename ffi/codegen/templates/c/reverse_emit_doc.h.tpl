/* <lib>_emit_<wire> queues a host event for the library's thread. Returns
   NIMFFI_RET_OK once queued, or _INVALID_CTX, _TOO_LARGE, _INVALID_ARGUMENT,
   _OUT_OF_MEMORY or _ERR (the send failed). <lib>_ctx_emit_<wire> also
   returns _ERR when the payload does not encode, with the reason in *err. */
