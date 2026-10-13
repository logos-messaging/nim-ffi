/* <lib>_emit_<wire> queues a host event for the library's own thread and
   returns NIMFFI_RET_OK once queued; NIMFFI_RET_ERR for a bad ctx, a payload
   over the request limit, or NULL payload_cbor with a length. */
