/// Runs on a reverse worker thread and may block; answer with `ctx`, the calling owner's token, via `<lib>_reverse_reply`.
pub type FFIReverseImpl = unsafe extern "C" fn(
    ctx: *mut c_void,
    call_id: u64,
    args: *const u8,
    args_len: usize,
    user_data: *mut c_void,
);
/// Frees an impl's `user_data` once no invocation uses it; runs on any thread.
pub type FFIReverseRelease = unsafe extern "C" fn(user_data: *mut c_void);
