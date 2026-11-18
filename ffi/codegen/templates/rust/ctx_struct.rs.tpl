/// High-level context for `{{LIB_TYPE}}`.
pub struct {{CTX}} {
    ptr: *mut c_void,
    timeout: Duration,{{LISTENERS_FIELD}}
}

// SAFETY: The `ptr` field points to an FFIContext owned by the Nim runtime.
// Every call through the generated FFI proc goes through
// `sendRequestToFFIThread` on the Nim side, which only enqueues the request
// onto a mutex-guarded MPSC queue (sound from any number of threads) and
// wakes the single FFI thread that dispatches every handler. The context is
// thus never mutated non-atomically from the caller's thread. The Nim-side
// reentrancy guard (`onFFIThread` threadvar) prevents handlers from
// re-entering the dispatcher. These invariants make it sound to mark the
// wrapper as Send + Sync.
unsafe impl Send for {{CTX}} {}
unsafe impl Sync for {{CTX}} {}
