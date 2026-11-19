/// High-level context for `{{LIB_TYPE}}`.
pub struct {{CTX}} {
    ptr: *mut c_void,
    timeout: Duration,
    calls: {{CALLS}}<'static>,{{LISTENERS_FIELD}}
}

/// The calls of a `{{LIB_TYPE}}` together with the limit each one waits for.
/// `ctx.method(..)` uses the ctx default; `ctx.with_timeout(limit).method(..)`
/// overrides it for that call (`None` waits with no Rust-side limit). A timeout
/// only stops the wait: the Nim handler keeps running to completion.
/// Not `Copy`/`Clone`, so it cannot outlive the ctx it borrows from.
pub struct {{CALLS}}<'a> {
    ptr: *mut c_void,
    timeout: Option<Duration>,
    _ctx: std::marker::PhantomData<&'a {{CTX}}>,
}

impl std::ops::Deref for {{CTX}} {
    type Target = {{CALLS}}<'static>;
    fn deref(&self) -> &Self::Target {
        &self.calls
    }
}

impl {{CTX}} {
    /// The same calls with another limit; `None` waits with no Rust-side limit.
    pub fn with_timeout(&self, timeout: Option<Duration>) -> {{CALLS}}<'_> {
        {{CALLS}} { ptr: self.ptr, timeout, _ctx: std::marker::PhantomData }
    }
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
// Same invariants: the view only holds the ctx pointer and a limit.
unsafe impl Send for {{CALLS}}<'_> {}
unsafe impl Sync for {{CALLS}}<'_> {}
