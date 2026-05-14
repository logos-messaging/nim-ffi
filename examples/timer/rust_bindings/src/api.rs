use std::os::raw::{c_char, c_int, c_void};
use std::slice;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;
use serde::de::DeserializeOwned;
use serde::Serialize;
use super::ffi;
use super::types::*;

fn encode_cbor<T: Serialize>(value: &T) -> Result<Vec<u8>, String> {
    let mut buf = Vec::new();
    ciborium::ser::into_writer(value, &mut buf).map_err(|e| e.to_string())?;
    Ok(buf)
}

fn decode_cbor<T: DeserializeOwned>(bytes: &[u8]) -> Result<T, String> {
    ciborium::de::from_reader(bytes).map_err(|e| e.to_string())
}

#[derive(Default)]
struct FfiCallbackResult {
    payload: Option<Result<Vec<u8>, String>>,
}

type Pair = Arc<(Mutex<FfiCallbackResult>, Condvar)>;

// Reconstruct the (ret, msg, len) tuple delivered by the C callback
// into a Result<Vec<u8>, String>: payload on success, UTF-8 message on error.
unsafe fn ffi_payload(ret: c_int, msg: *const c_char, len: usize) -> Result<Vec<u8>, String> {
    let bytes = if msg.is_null() || len == 0 {
        Vec::new()
    } else {
        slice::from_raw_parts(msg as *const u8, len).to_vec()
    };
    if ret == 0 { Ok(bytes) }
    else        { Err(String::from_utf8_lossy(&bytes).into_owned()) }
}

unsafe extern "C" fn on_result(
    ret: c_int,
    msg: *const c_char,
    len: usize,
    user_data: *mut c_void,
) {
    // from_raw reclaims the strong ref that ffi_call's into_raw left behind;
    // letting `pair` drop at end of scope releases it.
    let pair = Arc::from_raw(user_data as *const (Mutex<FfiCallbackResult>, Condvar));
    let (lock, cvar) = &*pair;
    let mut state = lock.lock().unwrap();
    state.payload = Some(ffi_payload(ret, msg, len));
    cvar.notify_one();
}

fn ffi_call<F>(timeout: Duration, f: F) -> Result<Vec<u8>, String>
where
    F: FnOnce(ffi::FfiCallback, *mut c_void) -> c_int,
{
    let pair: Pair = Arc::new((Mutex::new(FfiCallbackResult::default()), Condvar::new()));
    let raw = Arc::into_raw(pair.clone()) as *mut c_void;
    let ret = f(on_result, raw);
    if ret == 2 {
        return Err("RET_MISSING_CALLBACK (internal error)".into());
    }
    let (lock, cvar) = &*pair;
    let guard = lock.lock().unwrap();
    let (guard, timed_out) = cvar
        .wait_timeout_while(guard, timeout, |s| s.payload.is_none())
        .unwrap();
    if timed_out.timed_out() {
        return Err(format!("timed out after {:?}", timeout));
    }
    guard.payload.clone().unwrap()
}

unsafe extern "C" fn on_result_async(
    ret: c_int,
    msg: *const c_char,
    len: usize,
    user_data: *mut c_void,
) {
    // This fn represents the callback called internally in the Nim library function.
    // We use a oneshot channel to deliver the result from the Nim-managed thread
    // to the awaiting tokio task in ffi_call_async; the tx side is passed through
    // the user_data pointer. The heap allocation behind Box::from_raw is released
    // when `tx` drops (either consumed by `send` or at end of scope).
    let tx = Box::from_raw(
        user_data as *mut tokio::sync::oneshot::Sender<Result<Vec<u8>, String>>,
    );

    // `tx.send` returns Err only if the awaiting future was dropped (and with it
    // the Receiver): e.g. tokio::time::timeout elapsed, a tokio::select! branch
    // lost the race, or the future was dropped before being awaited. This cannot
    // happen with the current rust_client demo but may occur in arbitrary
    // downstream consumers, so we discard the Err safely.
    // Given that this is invoked from a Nim thread, we can't propagate the error by panicking or
    // returning a Result. Furthermore, an API dev may intentionally set a timeout in the await,
    // in which case is also fine to discard the send error in this case because the API user will
    // handle the timeout expiry in their own code.
    // The important part is to ensure that the callback doesn't panic or block indefinitely if the
    // receiver is gone.
    let _ = tx.send(ffi_payload(ret, msg, len));
}

async fn ffi_call_async<F>(f: F) -> Result<Vec<u8>, String>
where
    F: FnOnce(ffi::FfiCallback, *mut c_void) -> c_int,
{
    let rx = {
        let (tx, rx) = tokio::sync::oneshot::channel::<Result<Vec<u8>, String>>();
        let raw = Box::into_raw(Box::new(tx)) as *mut c_void;
        let ret = f(on_result_async, raw);
        if ret == 2 {
            drop(unsafe {
                Box::from_raw(
                    raw as *mut tokio::sync::oneshot::Sender<Result<Vec<u8>, String>>,
                )
            });
            return Err("RET_MISSING_CALLBACK (internal error)".into());
        }
        rx
    };
    rx.await.map_err(|_| "channel closed before callback fired".to_string())?
}

/// High-level context for `Timer`.
pub struct TimerCtx {
    ptr: *mut c_void,
    timeout: Duration,
}

// SAFETY: The `ptr` field points to an FFIContext owned by the Nim runtime.
// Every call through the generated FFI proc goes through
// `sendRequestToFFIThread` on the Nim side, which serialises every request
// behind `ctx.lock` and dispatches handlers on a single FFI thread, so the
// pointer is never accessed concurrently from Rust. The Nim-side reentrancy
// guard (`onFFIThread` threadvar) prevents handlers from re-entering the
// dispatcher and self-deadlocking. These invariants make it sound to mark
// the wrapper as Send + Sync.
unsafe impl Send for TimerCtx {}
unsafe impl Sync for TimerCtx {}

impl Drop for TimerCtx {
    fn drop(&mut self) {
        if !self.ptr.is_null() {
            unsafe { ffi::timer_destroy(self.ptr); }
            self.ptr = std::ptr::null_mut();
        }
    }
}

impl TimerCtx {
    pub fn create(config: TimerConfig, timeout: Duration) -> Result<Self, String> {
        let req = TimerCreateCtorReq { config };
        let req_bytes = encode_cbor(&req)?;
        let raw_bytes = ffi_call(timeout, |cb, ud| unsafe {
            ffi::timer_create(req_bytes.as_ptr(), req_bytes.len(), cb, ud)
        })?;
        let addr_str: String = decode_cbor(&raw_bytes)?;
        let addr: usize = addr_str.parse().map_err(|e: std::num::ParseIntError| e.to_string())?;
        Ok(Self { ptr: addr as *mut c_void, timeout })
    }

    pub async fn new_async(config: TimerConfig, timeout: Duration) -> Result<Self, String> {
        let req = TimerCreateCtorReq { config };
        let req_bytes = encode_cbor(&req)?;
        let raw_bytes = ffi_call_async(move |cb, ud| unsafe {
            ffi::timer_create(req_bytes.as_ptr(), req_bytes.len(), cb, ud)
        }).await?;
        let addr_str: String = decode_cbor(&raw_bytes)?;
        let addr: usize = addr_str.parse().map_err(|e: std::num::ParseIntError| e.to_string())?;
        Ok(Self { ptr: addr as *mut c_void, timeout })
    }

    pub fn echo(&self, req: EchoRequest) -> Result<EchoResponse, String> {
        let req = TimerEchoReq { req };
        let req_bytes = encode_cbor(&req)?;
        let raw_bytes = ffi_call(self.timeout, |cb, ud| unsafe {
            ffi::timer_echo(self.ptr, cb, ud, req_bytes.as_ptr(), req_bytes.len())
        })?;
        decode_cbor::<EchoResponse>(&raw_bytes)
    }

    pub async fn echo_async(&self, req: EchoRequest) -> Result<EchoResponse, String> {
        let req = TimerEchoReq { req };
        let req_bytes = encode_cbor(&req)?;
        let ptr = self.ptr as usize;
        let raw_bytes = ffi_call_async(move |cb, ud| unsafe {
            ffi::timer_echo(ptr as *mut c_void, cb, ud, req_bytes.as_ptr(), req_bytes.len())
        }).await?;
        decode_cbor::<EchoResponse>(&raw_bytes)
    }

    pub fn version(&self) -> Result<String, String> {
        let req = TimerVersionReq {};
        let req_bytes = encode_cbor(&req)?;
        let raw_bytes = ffi_call(self.timeout, |cb, ud| unsafe {
            ffi::timer_version(self.ptr, cb, ud, req_bytes.as_ptr(), req_bytes.len())
        })?;
        decode_cbor::<String>(&raw_bytes)
    }

    pub async fn version_async(&self) -> Result<String, String> {
        let req = TimerVersionReq {};
        let req_bytes = encode_cbor(&req)?;
        let ptr = self.ptr as usize;
        let raw_bytes = ffi_call_async(move |cb, ud| unsafe {
            ffi::timer_version(ptr as *mut c_void, cb, ud, req_bytes.as_ptr(), req_bytes.len())
        }).await?;
        decode_cbor::<String>(&raw_bytes)
    }

    pub fn complex(&self, req: ComplexRequest) -> Result<ComplexResponse, String> {
        let req = TimerComplexReq { req };
        let req_bytes = encode_cbor(&req)?;
        let raw_bytes = ffi_call(self.timeout, |cb, ud| unsafe {
            ffi::timer_complex(self.ptr, cb, ud, req_bytes.as_ptr(), req_bytes.len())
        })?;
        decode_cbor::<ComplexResponse>(&raw_bytes)
    }

    pub async fn complex_async(&self, req: ComplexRequest) -> Result<ComplexResponse, String> {
        let req = TimerComplexReq { req };
        let req_bytes = encode_cbor(&req)?;
        let ptr = self.ptr as usize;
        let raw_bytes = ffi_call_async(move |cb, ud| unsafe {
            ffi::timer_complex(ptr as *mut c_void, cb, ud, req_bytes.as_ptr(), req_bytes.len())
        }).await?;
        decode_cbor::<ComplexResponse>(&raw_bytes)
    }

}
