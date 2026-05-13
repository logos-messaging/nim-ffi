use std::os::raw::{c_char, c_int, c_void};

pub type FfiCallback = unsafe extern "C" fn(
    ret: c_int,
    msg: *const c_char,
    len: usize,
    user_data: *mut c_void,
);

#[link(name = "nimtimer")]
extern "C" {
    pub fn nimtimer_create(req_cbor: *const u8, req_cbor_len: usize, callback: FfiCallback, user_data: *mut c_void) -> *mut c_void;
    pub fn nimtimer_echo(ctx: *mut c_void, callback: FfiCallback, user_data: *mut c_void, req_cbor: *const u8, req_cbor_len: usize) -> c_int;
    pub fn nimtimer_version(ctx: *mut c_void, callback: FfiCallback, user_data: *mut c_void, req_cbor: *const u8, req_cbor_len: usize) -> c_int;
    pub fn nimtimer_complex(ctx: *mut c_void, callback: FfiCallback, user_data: *mut c_void, req_cbor: *const u8, req_cbor_len: usize) -> c_int;
    pub fn nimtimer_destroy(ctx: *mut c_void, callback: FfiCallback, user_data: *mut c_void) -> c_int;
}
