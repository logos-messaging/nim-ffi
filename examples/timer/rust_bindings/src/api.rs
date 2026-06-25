use std::os::raw::{c_char, c_int, c_void};
use std::slice;
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

type FFIResult = Result<Vec<u8>, String>;
type FFISender = flume::Sender<FFIResult>;

// Reconstruct the (ret, msg, len) tuple delivered by the C callback
// into a Result<Vec<u8>, String>: payload on success, UTF-8 message on error.
// `from_utf8_lossy` accepts non-UTF-8 error bytes by inserting U+FFFD; the
// alternative would be to dispatch a separate Err for invalid UTF-8, but the
// codegen contract is that Nim handlers emit `string` error payloads, so
// invalid UTF-8 here would be a Nim-side bug.
unsafe fn ffi_payload(ret: c_int, msg: *const c_char, len: usize) -> FFIResult {
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
    // Take ownership of the boxed Sender — dropping it at end of scope
    // releases the only outstanding handle.
    let tx = Box::from_raw(user_data as *mut FFISender);

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

fn ffi_call_sync<F>(timeout: Duration, f: F) -> FFIResult
where
    F: FnOnce(ffi::FFICallback, *mut c_void) -> c_int,
{
    let (tx, rx) = flume::bounded::<FFIResult>(1);
    let raw = Box::into_raw(Box::new(tx)) as *mut c_void;
    let ret = f(on_result, raw);
    if ret == 2 {
        // Callback will never fire; reclaim the box to avoid a leak.
        drop(unsafe { Box::from_raw(raw as *mut FFISender) });
        return Err("RET_MISSING_CALLBACK (internal error)".into());
    }
    match rx.recv_timeout(timeout) {
        Ok(payload) => payload,
        Err(flume::RecvTimeoutError::Timeout) =>
            Err(format!("timed out after {:?}", timeout)),
        Err(flume::RecvTimeoutError::Disconnected) =>
            Err("callback channel disconnected before delivery".into()),
    }
}

async fn ffi_call_async<F>(timeout: Duration, f: F) -> FFIResult
where
    F: FnOnce(ffi::FFICallback, *mut c_void) -> c_int,
{
    let (tx, rx) = flume::bounded::<FFIResult>(1);
    let raw = Box::into_raw(Box::new(tx)) as *mut c_void;
    let ret = f(on_result, raw);
    if ret == 2 {
        drop(unsafe { Box::from_raw(raw as *mut FFISender) });
        return Err("RET_MISSING_CALLBACK (internal error)".into());
    }
    match tokio::time::timeout(timeout, rx.recv_async()).await {
        Ok(Ok(payload)) => payload,
        Ok(Err(_)) => Err("callback channel disconnected before delivery".into()),
        Err(_) => Err(format!("timed out after {:?}", timeout)),
    }
}

struct OnEchoFiredHandler {
    f: Box<dyn Fn(&EchoEvent) + Send + Sync>,
}

unsafe extern "C" fn on_echo_fired_trampoline(
    ret: c_int, msg: *const c_char, len: usize, ud: *mut c_void,
) {
    if ud.is_null() || ret != 0 || msg.is_null() || len == 0 {
        return;
    }
    let h = &*(ud as *const OnEchoFiredHandler);
    let bytes = slice::from_raw_parts(msg as *const u8, len);
    #[derive(serde::Deserialize)]
    struct Envelope { payload: EchoEvent }
    if let Ok(env) = ciborium::de::from_reader::<Envelope, _>(bytes) {
        (h.f)(&env.payload);
    }
}

#[derive(Debug, Clone, Copy)]
pub struct ListenerHandle { pub id: u64 }

/// High-level context for `MyTimer`.
pub struct MyTimerCtx {
    ptr: *mut c_void,
    timeout: Duration,
    listeners: std::sync::Mutex<std::collections::HashMap<u64, Box<dyn std::any::Any + Send>>>,
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
unsafe impl Send for MyTimerCtx {}
unsafe impl Sync for MyTimerCtx {}

impl Drop for MyTimerCtx {
    fn drop(&mut self) {
        if !self.ptr.is_null() {
            unsafe { ffi::my_timer_destroy(self.ptr); }
            self.ptr = std::ptr::null_mut();
        }
    }
}

impl MyTimerCtx {
    pub fn create(config: TimerConfig, timeout: Duration) -> Result<Self, String> {
        let req = MyTimerCreateCtorReq { config };
        let req_bytes = encode_cbor(&req)?;
        let raw_bytes = ffi_call_sync(timeout, |cb, ud| unsafe {
            let _ = ffi::my_timer_create(req_bytes.as_ptr(), req_bytes.len(), cb, ud);
            0
        })?;
        let addr_str: String = decode_cbor(&raw_bytes)?;
        let addr: usize = addr_str.parse().map_err(|e: std::num::ParseIntError| e.to_string())?;
        Ok(Self { ptr: addr as *mut c_void, timeout, listeners: std::sync::Mutex::new(std::collections::HashMap::new()) })
    }

    pub async fn new_async(config: TimerConfig, timeout: Duration) -> Result<Self, String> {
        let req = MyTimerCreateCtorReq { config };
        let req_bytes = encode_cbor(&req)?;
        let raw_bytes = ffi_call_async(timeout, move |cb, ud| unsafe {
            let _ = ffi::my_timer_create(req_bytes.as_ptr(), req_bytes.len(), cb, ud);
            0
        }).await?;
        let addr_str: String = decode_cbor(&raw_bytes)?;
        let addr: usize = addr_str.parse().map_err(|e: std::num::ParseIntError| e.to_string())?;
        Ok(Self { ptr: addr as *mut c_void, timeout, listeners: std::sync::Mutex::new(std::collections::HashMap::new()) })
    }

    fn add_listener_inner(
        &self,
        event_name: *const c_char,
        callback: ffi::FFICallback,
        raw: *mut c_void,
        owned: Box<dyn std::any::Any + Send>,
    ) -> ListenerHandle {
        let id = unsafe {
            ffi::my_timer_add_event_listener(self.ptr, event_name, callback, raw)
        };
        if id != 0 {
            self.listeners.lock().unwrap().insert(id, owned);
        }
        ListenerHandle { id }
    }

    /// Register a typed listener for `on_echo_fired`. The returned handle can be
    /// passed to `remove_event_listener` to unregister.
    pub fn add_on_echo_fired_listener<F>(&self, handler: F) -> ListenerHandle
    where F: Fn(&EchoEvent) + Send + Sync + 'static,
    {
        let owned: Box<OnEchoFiredHandler> = Box::new(OnEchoFiredHandler { f: Box::new(handler) });
        let raw = &*owned as *const OnEchoFiredHandler as *mut c_void;
        self.add_listener_inner(b"on_echo_fired\0".as_ptr() as *const c_char, on_echo_fired_trampoline, raw, owned)
    }

    /// Remove a previously-registered listener by handle. Returns true
    /// if the listener existed and was removed; false otherwise.
    pub fn remove_event_listener(&self, handle: ListenerHandle) -> bool {
        if handle.id == 0 { return false; }
        let rc = unsafe {
            ffi::my_timer_remove_event_listener(self.ptr, handle.id)
        };
        self.listeners.lock().unwrap().remove(&handle.id);
        rc == 0
    }

    pub fn echo(&self, req: EchoRequest) -> Result<EchoResponse, String> {
        let req = MyTimerEchoReq { req };
        let req_bytes = encode_cbor(&req)?;
        let raw_bytes = ffi_call_sync(self.timeout, |cb, ud| unsafe {
            ffi::my_timer_echo(self.ptr, cb, ud, req_bytes.as_ptr(), req_bytes.len())
        })?;
        decode_cbor::<EchoResponse>(&raw_bytes)
    }

    pub async fn echo_async(&self, req: EchoRequest) -> Result<EchoResponse, String> {
        let req = MyTimerEchoReq { req };
        let req_bytes = encode_cbor(&req)?;
        let ptr = self.ptr as usize;
        let raw_bytes = ffi_call_async(self.timeout, move |cb, ud| unsafe {
            ffi::my_timer_echo(ptr as *mut c_void, cb, ud, req_bytes.as_ptr(), req_bytes.len())
        }).await?;
        decode_cbor::<EchoResponse>(&raw_bytes)
    }

    pub fn version(&self) -> Result<String, String> {
        let req = MyTimerVersionReq {};
        let req_bytes = encode_cbor(&req)?;
        let raw_bytes = ffi_call_sync(self.timeout, |cb, ud| unsafe {
            ffi::my_timer_version(self.ptr, cb, ud, req_bytes.as_ptr(), req_bytes.len())
        })?;
        decode_cbor::<String>(&raw_bytes)
    }

    pub async fn version_async(&self) -> Result<String, String> {
        let req = MyTimerVersionReq {};
        let req_bytes = encode_cbor(&req)?;
        let ptr = self.ptr as usize;
        let raw_bytes = ffi_call_async(self.timeout, move |cb, ud| unsafe {
            ffi::my_timer_version(ptr as *mut c_void, cb, ud, req_bytes.as_ptr(), req_bytes.len())
        }).await?;
        decode_cbor::<String>(&raw_bytes)
    }

    pub fn complex(&self, req: ComplexRequest) -> Result<ComplexResponse, String> {
        let req = MyTimerComplexReq { req };
        let req_bytes = encode_cbor(&req)?;
        let raw_bytes = ffi_call_sync(self.timeout, |cb, ud| unsafe {
            ffi::my_timer_complex(self.ptr, cb, ud, req_bytes.as_ptr(), req_bytes.len())
        })?;
        decode_cbor::<ComplexResponse>(&raw_bytes)
    }

    pub async fn complex_async(&self, req: ComplexRequest) -> Result<ComplexResponse, String> {
        let req = MyTimerComplexReq { req };
        let req_bytes = encode_cbor(&req)?;
        let ptr = self.ptr as usize;
        let raw_bytes = ffi_call_async(self.timeout, move |cb, ud| unsafe {
            ffi::my_timer_complex(ptr as *mut c_void, cb, ud, req_bytes.as_ptr(), req_bytes.len())
        }).await?;
        decode_cbor::<ComplexResponse>(&raw_bytes)
    }

    pub fn schedule(&self, job: JobSpec, retry: RetryPolicy, schedule: ScheduleConfig) -> Result<ScheduleResult, String> {
        let req = MyTimerScheduleReq { job, retry, schedule };
        let req_bytes = encode_cbor(&req)?;
        let raw_bytes = ffi_call_sync(self.timeout, |cb, ud| unsafe {
            ffi::my_timer_schedule(self.ptr, cb, ud, req_bytes.as_ptr(), req_bytes.len())
        })?;
        decode_cbor::<ScheduleResult>(&raw_bytes)
    }

    pub async fn schedule_async(&self, job: JobSpec, retry: RetryPolicy, schedule: ScheduleConfig) -> Result<ScheduleResult, String> {
        let req = MyTimerScheduleReq { job, retry, schedule };
        let req_bytes = encode_cbor(&req)?;
        let ptr = self.ptr as usize;
        let raw_bytes = ffi_call_async(self.timeout, move |cb, ud| unsafe {
            ffi::my_timer_schedule(ptr as *mut c_void, cb, ud, req_bytes.as_ptr(), req_bytes.len())
        }).await?;
        decode_cbor::<ScheduleResult>(&raw_bytes)
    }

}
