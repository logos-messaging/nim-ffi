/* Answers a reverse call; callable from any thread. ret_code 0: reply_cbor is
   the CBOR reply; non-zero: a UTF-8 error message. First reply per call_id
   wins; later or expired ones are dropped. Returns NIMFFI_RET_OK or
   _INVALID_CTX, _NOT_ACTIVE, _TOO_LARGE, _QUEUE_FULL, _OUT_OF_MEMORY,
   _INVALID_ARGUMENT (NULL reply_cbor with a non-zero reply_len). */
int {{LIB}}_reverse_reply(void* ctx, uint64_t call_id, int ret_code, const uint8_t* reply_cbor, size_t reply_len);
