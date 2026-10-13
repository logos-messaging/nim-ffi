/* Answers a reverse call from ANY thread. ret_code 0 = ok (reply_cbor is
   the CBOR reply), non-zero = error (reply_cbor is a UTF-8 message).
   The first reply for a call_id wins; a later one, or one for a call that
   already timed out, is dropped. Returns NIMFFI_REVERSE_ACCEPTED, _INVALID_CTX,
   _NOT_ACTIVE, _PAYLOAD_TOO_LARGE, _MAILBOX_FULL, _OUT_OF_MEMORY, or _INVALID_ARGUMENT (NULL
   reply_cbor with a non-zero reply_len). */
int {{LIB}}_reverse_reply(void* ctx, uint64_t call_id, int ret_code, const uint8_t* reply_cbor, size_t reply_len);
