/* Pumps `ctx` until `slot` is settled, handing every other message to
 * `handlers`. A request given up on is forgotten, so that its late reply is
 * dropped instead of written into a stack frame that is gone. */
static inline int {{LIB}}_ctx_await_({{CTX}}* ctx, uint64_t req_id, const NimFfiSyncSlot* slot, int32_t timeout_ms, const {{HANDLERS}}* handlers) {
    int64_t deadline = 0;
    if (timeout_ms >= 0) deadline = nimffi_now_ms() + timeout_ms;
    while (!slot->done) {
        int32_t wait_ms = -1;
        if (timeout_ms >= 0) {
            int64_t left = deadline - nimffi_now_ms();
            wait_ms = left > 0 ? (int32_t)left : 0;
        }
        int rc = {{LIB}}_ctx_pump_once(ctx, wait_ms, handlers);
        if (slot->done) break;
        /* A message that did not dispatch (-1) was not ours: keep waiting. */
        if (rc == NIMFFI_RET_OK || rc == -1) continue;
        if (rc == NIMFFI_RET_TIMEOUT && wait_ms != 0) continue;
        nimffi_pending_abandon(&ctx->pending, req_id);
        return rc;
    }
    return slot->ret;
}
