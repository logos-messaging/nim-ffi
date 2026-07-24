use std::os::raw::{c_char, c_int, c_void};

pub type FFICallback = unsafe extern "C" fn(
    ret: c_int,
    msg: *const c_char,
    len: usize,
    user_data: *mut c_void,
);

#[link(name = "my_timer")]
extern "C" {
    /// Creates the FFIContext + MyTimer; async via chronos.
    pub fn my_timer_create(req_cbor: *const u8, req_cbor_len: usize, callback: FFICallback, user_data: *mut c_void) -> *mut c_void;
    /// Sleeps `delayMs` then echoes the message back, firing `on_echo_fired`.
    pub fn my_timer_echo(ctx: *mut c_void, callback: FFICallback, user_data: *mut c_void, req_cbor: *const u8, req_cbor_len: usize) -> c_int;
    /// Returns the library's version string.
    pub fn my_timer_version(ctx: *mut c_void, callback: FFICallback, user_data: *mut c_void, req_cbor: *const u8, req_cbor_len: usize) -> c_int;
    pub fn my_timer_lib_version(callback: FFICallback, user_data: *mut c_void, req_cbor: *const u8, req_cbor_len: usize) -> c_int;
    pub fn my_timer_complex(ctx: *mut c_void, callback: FFICallback, user_data: *mut c_void, req_cbor: *const u8, req_cbor_len: usize) -> c_int;
    /// Three object-typed params (`job`, `retry`, `schedule`) packed into one CBOR envelope.
    pub fn my_timer_schedule(ctx: *mut c_void, callback: FFICallback, user_data: *mut c_void, req_cbor: *const u8, req_cbor_len: usize) -> c_int;
    /// Tears down the FFI context; blocks until FFI + watchdog threads join.
    pub fn my_timer_destroy(ctx: *mut c_void) -> c_int;
    pub fn my_timer_add_event_listener(ctx: *mut c_void, event_name: *const c_char, callback: FFICallback, user_data: *mut c_void) -> u64;
    pub fn my_timer_remove_event_listener(ctx: *mut c_void, listener_id: u64) -> c_int;
}
