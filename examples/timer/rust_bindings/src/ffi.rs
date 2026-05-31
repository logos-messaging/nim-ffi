use std::os::raw::{c_char, c_int, c_void};

pub type FFICallback = unsafe extern "C" fn(
    ret: c_int,
    msg: *const c_char,
    len: usize,
    user_data: *mut c_void,
);

#[link(name = "my_timer")]
extern "C" {
    pub fn my_timer_create_cbor(req_cbor: *const u8, req_cbor_len: usize, callback: FFICallback, user_data: *mut c_void) -> *mut c_void;
    pub fn my_timer_echo_cbor(ctx: *mut c_void, callback: FFICallback, user_data: *mut c_void, req_cbor: *const u8, req_cbor_len: usize) -> c_int;
    pub fn my_timer_version_cbor(ctx: *mut c_void, callback: FFICallback, user_data: *mut c_void, req_cbor: *const u8, req_cbor_len: usize) -> c_int;
    pub fn my_timer_complex_cbor(ctx: *mut c_void, callback: FFICallback, user_data: *mut c_void, req_cbor: *const u8, req_cbor_len: usize) -> c_int;
    pub fn my_timer_schedule_cbor(ctx: *mut c_void, callback: FFICallback, user_data: *mut c_void, req_cbor: *const u8, req_cbor_len: usize) -> c_int;
    pub fn my_timer_destroy(ctx: *mut c_void) -> c_int;
    pub fn my_timer_add_event_listener_cbor(ctx: *mut c_void, event_name: *const c_char, callback: FFICallback, user_data: *mut c_void) -> u64;
    pub fn my_timer_remove_event_listener(ctx: *mut c_void, listener_id: u64) -> c_int;
}
