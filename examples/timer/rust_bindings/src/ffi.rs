#![allow(dead_code)]

use std::os::raw::{c_char, c_int, c_void};

// What `my_timer_poll` hands out, emitted from ffi/ffi_msg.nim.
#[repr(C)]
pub struct NimFfiMsg {
    pub struct_size: u32,
    pub kind: u32,
    pub seq: u64,
    pub id: u64,
    pub name_id: u64,
    pub aux: u64,
    pub ret_code: i32,
    pub flags: u32,
    pub payload: *const u8,
    pub len: usize,
}

pub const NIMFFI_MSG_REPLY: u32 = 1;
pub const NIMFFI_MSG_STALE_WARN: u32 = 3;
pub const NIMFFI_MSG_EVENT: u32 = 2;
pub const NIMFFI_MSG_NOT_RESPONDING: u32 = 5;
pub const NIMFFI_MSG_RESPONDING: u32 = 6;
pub const NIMFFI_MSG_CLOSED: u32 = 7;
pub const NIMFFI_NOT_RESPONDING_HEARTBEAT: u64 = 1;
pub const NIMFFI_NOT_RESPONDING_EVENT_QUEUE_FULL: u64 = 2;

// A request returns once it is queued. NIMFFI_RET_OK promises one
// NIMFFI_MSG_REPLY whose `id` is `*req_id_out`; any other return means no
// reply will come, and `my_timer_last_error` says why.
#[link(name = "my_timer")]
extern "C" {
    /// Creates the FFIContext + MyTimer; async via chronos.
    pub fn my_timer_create(req_cbor: *const u8, req_cbor_len: usize, ctx_out: *mut *mut c_void, req_id_out: *mut u64) -> c_int;
    /// Sleeps `delayMs` then echoes the message back, firing `on_echo_fired`.
    pub fn my_timer_echo(ctx: *mut c_void, req_cbor: *const u8, req_cbor_len: usize, req_id_out: *mut u64) -> c_int;
    /// Returns the library's version string.
    pub fn my_timer_version(ctx: *mut c_void, req_cbor: *const u8, req_cbor_len: usize, req_id_out: *mut u64) -> c_int;
    pub fn my_timer_lib_version(req_cbor: *const u8, req_cbor_len: usize, req_id_out: *mut u64) -> c_int;
    pub fn my_timer_complex(ctx: *mut c_void, req_cbor: *const u8, req_cbor_len: usize, req_id_out: *mut u64) -> c_int;
    /// Three object-typed params (`job`, `retry`, `schedule`) packed into one CBOR envelope.
    pub fn my_timer_schedule(ctx: *mut c_void, req_cbor: *const u8, req_cbor_len: usize, req_id_out: *mut u64) -> c_int;
    /// Tears down the FFI context; blocks until FFI + watchdog threads join.
    pub fn my_timer_destroy(ctx: *mut c_void) -> c_int;
    /// Take the context's next message, waiting up to `timeout_ms` (0 never blocks,
    /// negative waits until a message or the end of the context). One consumer per
    /// context: a second concurrent poll gets NIMFFI_RET_BUSY.
    /// `msg` and its payload belong to the library and stay valid until the next poll
    /// on the same context.
    /// Returns NIMFFI_RET_OK, NIMFFI_RET_TIMEOUT, NIMFFI_RET_CLOSED (`msg` holds the
    /// CLOSED message), NIMFFI_RET_INVALID_CTX, NIMFFI_RET_BUSY or NIMFFI_RET_ERR.
    pub fn my_timer_poll(ctx: *mut c_void, timeout_ms: i32, msg: *mut *const NimFfiMsg) -> c_int;
    /// A wake handle the caller owns and closes: an epoll fd on Linux, a kqueue fd
    /// on macOS/BSD, an Event HANDLE on Windows; -1 on failure. It is ready while a
    /// message waits or the context is closed: wait on it, then poll with a timeout of
    /// 0 until NIMFFI_RET_TIMEOUT.
    pub fn my_timer_poll_fd(ctx: *mut c_void) -> isize;
    /// The token of the static context, where the reply of every static request
    /// arrives; poll it like any other context. Null on failure.
    pub fn my_timer_static_ctx() -> *mut c_void;
    /// Why the calling thread's last request was refused. Never null, empty when
    /// nothing was refused; valid until the thread's next refusal.
    pub fn my_timer_last_error() -> *const c_char;
    /// Stop every context the library still holds and join their threads.
    /// Call it before the process exits when a context is still alive, or when a
    /// static proc built the shared context.
    /// Returns 0 when every context stopped, 1 when one was left running.
    pub fn my_timer_shutdown() -> c_int;
}
