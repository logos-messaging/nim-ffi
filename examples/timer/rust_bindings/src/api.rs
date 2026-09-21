use std::os::raw::{c_char, c_int, c_void};
use std::slice;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
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
    if ret == NIMFFI_RET_OK { Ok(bytes) }
    else        { Err(String::from_utf8_lossy(&bytes).into_owned()) }
}

// nim-ffi result-callback status codes, emitted from ffi/ret_codes.nim.
#[allow(dead_code)]
const NIMFFI_RET_OK: c_int = 0;
#[allow(dead_code)]
const NIMFFI_RET_ERR: c_int = 1;
#[allow(dead_code)]
const NIMFFI_RET_MISSING_CALLBACK: c_int = 2;
#[allow(dead_code)]
const NIMFFI_RET_STALE_WARN: c_int = 3;
#[allow(dead_code)]
const NIMFFI_RET_TIMEOUT: c_int = 4;
#[allow(dead_code)]
const NIMFFI_RET_CLOSED: c_int = 5;
#[allow(dead_code)]
const NIMFFI_RET_INVALID_CTX: c_int = 6;
#[allow(dead_code)]
const NIMFFI_RET_BUSY: c_int = 7;

unsafe extern "C" fn on_result(
    ret: c_int,
    msg: *const c_char,
    len: usize,
    user_data: *mut c_void,
) {
    // NIMFFI_RET_STALE_WARN (3) is a non-terminal progress ping: the request
    // is still running. This wrapper only delivers the final result, so ignore
    // it WITHOUT reclaiming the box — a terminal callback still owns the Sender.
    if ret == NIMFFI_RET_STALE_WARN { return; }

    // Take ownership of the boxed Sender — dropping it at end of scope
    // releases the only outstanding handle.
    let tx = Box::from_raw(user_data as *mut FFISender);

    // `tx.send` returns Err only if the awaiting future was dropped (and with it
    // the Receiver): e.g. tokio::time::timeout elapsed, a tokio::select! branch
    // lost the race, or the future was dropped before being awaited. This cannot
    // happen with the crate's own examples but may occur in arbitrary
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
    if ret == NIMFFI_RET_MISSING_CALLBACK {
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
    if ret == NIMFFI_RET_MISSING_CALLBACK {
        drop(unsafe { Box::from_raw(raw as *mut FFISender) });
        return Err("RET_MISSING_CALLBACK (internal error)".into());
    }
    match tokio::time::timeout(timeout, rx.recv_async()).await {
        Ok(Ok(payload)) => payload,
        Ok(Err(_)) => Err("callback channel disconnected before delivery".into()),
        Err(_) => Err(format!("timed out after {:?}", timeout)),
    }
}

// `NimFfiMsg.name_id` of each event: FNV-1a 64 of its wire name.
pub const MY_TIMER_EVT_ON_ECHO_FIRED: u64 = 0xcdfdf536356b2a2b; // "on_echo_fired"
pub const MY_TIMER_EVT_ON_JOB_SCHEDULED: u64 = 0xd6ac432a40b9a85c; // "on_job_scheduled"
pub use super::ffi::{NIMFFI_NOT_RESPONDING_EVENT_QUEUE_FULL, NIMFFI_NOT_RESPONDING_HEARTBEAT};

/// Everything `my_timer` sends to the host: its events, the liveness reports
/// and the end of the context. The pump thread of a context decodes each
/// message into one of these before a listener runs.
#[derive(Debug, Clone)]
pub enum MyTimerMessage {
    /// Fired by `myTimerEcho` once the reply is ready.
    OnEchoFired(EchoEvent),
    /// Fired by `myTimerSchedule`. Its two params ride the wire as a synthesised
    /// `OnJobScheduledPayload` envelope, so the foreign side decodes one typed value.
    OnJobScheduled(OnJobScheduledPayload),
    /// The library stopped making progress. `reason` is a `NIMFFI_NOT_RESPONDING_*`:
    /// the FFI thread stalled, or the event queue overflowed and requests are
    /// refused from now on.
    NotResponding { reason: u64 },
    /// The FFI thread's heartbeat resumed.
    Responding,
    /// The context is gone; always the last message. `ok` is false when the
    /// library could not recycle the context, and `reason` then says why.
    Closed { ok: bool, reason: String },
    /// Not sent by the library: a message this binding could not decode, such
    /// as an event of a newer library.
    Undecodable { kind: u32, name_id: u64, error: String },
}

unsafe fn decode_message(msg: &ffi::NimFfiMsg) -> MyTimerMessage {
    let bytes: &[u8] = if msg.payload.is_null() || msg.len == 0 {
        &[]
    } else {
        slice::from_raw_parts(msg.payload, msg.len)
    };
    let decoded = match msg.kind {
        ffi::NIMFFI_MSG_EVENT => match msg.name_id {
            MY_TIMER_EVT_ON_ECHO_FIRED => decode_cbor(bytes).map(MyTimerMessage::OnEchoFired),
            MY_TIMER_EVT_ON_JOB_SCHEDULED => decode_cbor(bytes).map(MyTimerMessage::OnJobScheduled),
            _ => Err("unknown event".to_string()),
        },
        ffi::NIMFFI_MSG_NOT_RESPONDING => Ok(MyTimerMessage::NotResponding { reason: msg.aux }),
        ffi::NIMFFI_MSG_RESPONDING => Ok(MyTimerMessage::Responding),
        ffi::NIMFFI_MSG_CLOSED => Ok(MyTimerMessage::Closed {
            ok: msg.ret_code == NIMFFI_RET_OK,
            reason: String::from_utf8_lossy(bytes).into_owned(),
        }),
        _ => Err("unknown message kind".to_string()),
    };
    decoded.unwrap_or_else(|error| MyTimerMessage::Undecodable {
        kind: msg.kind,
        name_id: msg.name_id,
        error,
    })
}

type Handler = Arc<dyn Fn(&MyTimerMessage) + Send + Sync>;

/// Returned by every `add_*_listener`; pass it to `remove_event_listener`.
#[derive(Debug, Clone, Copy)]
pub struct ListenerHandle { pub id: u64 }

// What a context shares with its pump thread.
struct Inner {
    ptr: *mut c_void,
    listeners: Mutex<Vec<(u64, Handler)>>,
    next_id: AtomicU64,
    stop: AtomicBool,
}

// SAFETY: `ptr` is a token the library validates on every call, never
// dereferenced here. `my_timer_poll` admits one consumer per context and the pump
// thread is the only poller; everything else in `Inner` is already Sync.
unsafe impl Send for Inner {}
unsafe impl Sync for Inner {}

impl Inner {
    // Handlers run with the lock released, so a panic cannot poison it; recover anyway.
    fn lock(&self) -> MutexGuard<'_, Vec<(u64, Handler)>> {
        self.listeners.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn add(&self, handler: Handler) -> ListenerHandle {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        self.lock().push((id, handler));
        ListenerHandle { id }
    }

    fn remove(&self, id: u64) -> bool {
        let mut listeners = self.lock();
        let before = listeners.len();
        listeners.retain(|(lid, _)| *lid != id);
        listeners.len() != before
    }

    fn dispatch(&self, message: &MyTimerMessage) {
        // Cloned out so a handler may add or remove listeners.
        let handlers: Vec<Handler> = self.lock().iter().map(|(_, h)| h.clone()).collect();
        for handler in handlers {
            // A panicking handler must not end the pump; the panic hook already reported it.
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| handler(message)));
        }
    }
}

// The context's only poller: takes each message out, decodes it and runs the listeners.
fn pump_loop(inner: Arc<Inner>) {
    loop {
        // The library owns the message; it is valid until the next poll.
        let mut msg: *const ffi::NimFfiMsg = std::ptr::null();
        // Once asked to stop, only take what already waits: a teardown's last messages.
        let stopping = inner.stop.load(Ordering::Acquire);
        let timeout_ms = if stopping { 0 } else { 250 };
        let ret = unsafe { ffi::my_timer_poll(inner.ptr, timeout_ms, &mut msg) };
        match ret {
            NIMFFI_RET_OK | NIMFFI_RET_CLOSED if !msg.is_null() => {
                let message = unsafe { decode_message(&*msg) };
                inner.dispatch(&message);
                if ret == NIMFFI_RET_CLOSED {
                    return;
                }
                continue;
            }
            NIMFFI_RET_TIMEOUT => {}
            NIMFFI_RET_INVALID_CTX => {
                // The context ended between two polls, so its CLOSED message was never seen.
                inner.dispatch(&MyTimerMessage::Closed { ok: true, reason: String::new() });
                return;
            }
            // NIMFFI_RET_BUSY, NIMFFI_RET_ERR: try again, without spinning.
            _ => std::thread::sleep(Duration::from_millis(10)),
        }
        if stopping {
            return;
        }
    }
}

/// High-level context for `MyTimer`.
pub struct MyTimerCtx {
    ptr: *mut c_void,
    timeout: Duration,
    inner: Arc<Inner>,
    pump: Option<std::thread::JoinHandle<()>>,
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
        // Before the pump stops: the teardown may still send events, and it wakes a blocked poll.
        if !self.ptr.is_null() {
            unsafe { ffi::my_timer_destroy(self.ptr); }
            self.ptr = std::ptr::null_mut();
        }
        self.inner.stop.store(true, Ordering::Release);
        if let Some(pump) = self.pump.take() {
            // A listener that drops the context runs on the pump: it cannot join itself.
            if pump.thread().id() != std::thread::current().id() {
                let _ = pump.join();
            }
        }
    }
}

impl MyTimerCtx {
    /// Creates the FFIContext + MyTimer; async via chronos.
    pub fn create(config: TimerConfig, timeout: Duration) -> Result<Self, String> {
        let req = MyTimerCreateCtorReq { config };
        let req_bytes = encode_cbor(&req)?;
        let raw_bytes = ffi_call_sync(timeout, |cb, ud| unsafe {
            let _ = ffi::my_timer_create(req_bytes.as_ptr(), req_bytes.len(), cb, ud);
            0
        })?;
        let addr_str: String = decode_cbor(&raw_bytes)?;
        let addr: usize = addr_str.parse().map_err(|e: std::num::ParseIntError| e.to_string())?;
        Self::start(addr as *mut c_void, timeout)
    }

    /// Creates the FFIContext + MyTimer; async via chronos.
    pub async fn new_async(config: TimerConfig, timeout: Duration) -> Result<Self, String> {
        let req = MyTimerCreateCtorReq { config };
        let req_bytes = encode_cbor(&req)?;
        let raw_bytes = ffi_call_async(timeout, move |cb, ud| unsafe {
            let _ = ffi::my_timer_create(req_bytes.as_ptr(), req_bytes.len(), cb, ud);
            0
        }).await?;
        let addr_str: String = decode_cbor(&raw_bytes)?;
        let addr: usize = addr_str.parse().map_err(|e: std::num::ParseIntError| e.to_string())?;
        Self::start(addr as *mut c_void, timeout)
    }

    fn start(ptr: *mut c_void, timeout: Duration) -> Result<Self, String> {
        let inner = Arc::new(Inner {
            ptr,
            listeners: Mutex::new(Vec::new()),
            next_id: AtomicU64::new(1),
            stop: AtomicBool::new(false),
        });
        // Built first: if the thread cannot start, dropping it destroys the context.
        let mut ctx = Self { ptr, timeout, inner: inner.clone(), pump: None };
        let pump = std::thread::Builder::new()
            .name("my_timer-pump".into())
            .spawn(move || pump_loop(inner))
            .map_err(|e| e.to_string())?;
        ctx.pump = Some(pump);
        Ok(ctx)
    }

    /// Fired by `myTimerEcho` once the reply is ready.
    /// Register a typed listener for `on_echo_fired`. The returned handle can be
    /// passed to `remove_event_listener` to unregister.
    pub fn add_on_echo_fired_listener<F>(&self, handler: F) -> ListenerHandle
    where F: Fn(&EchoEvent) + Send + Sync + 'static,
    {
        self.inner.add(Arc::new(move |m: &MyTimerMessage| {
            if let MyTimerMessage::OnEchoFired(payload) = m { handler(payload) }
        }))
    }

    /// Fired by `myTimerSchedule`. Its two params ride the wire as a synthesised
    /// `OnJobScheduledPayload` envelope, so the foreign side decodes one typed value.
    /// Register a typed listener for `on_job_scheduled`. The returned handle can be
    /// passed to `remove_event_listener` to unregister.
    pub fn add_on_job_scheduled_listener<F>(&self, handler: F) -> ListenerHandle
    where F: Fn(&OnJobScheduledPayload) + Send + Sync + 'static,
    {
        self.inner.add(Arc::new(move |m: &MyTimerMessage| {
            if let MyTimerMessage::OnJobScheduled(payload) = m { handler(payload) }
        }))
    }

    /// Register a listener for `NotResponding`; it receives the reason.
    pub fn add_not_responding_listener<F>(&self, handler: F) -> ListenerHandle
    where F: Fn(u64) + Send + Sync + 'static,
    {
        self.inner.add(Arc::new(move |m: &MyTimerMessage| {
            if let MyTimerMessage::NotResponding { reason } = m { handler(*reason) }
        }))
    }

    /// Register a listener for `Responding`.
    pub fn add_responding_listener<F>(&self, handler: F) -> ListenerHandle
    where F: Fn() + Send + Sync + 'static,
    {
        self.inner.add(Arc::new(move |m: &MyTimerMessage| {
            if let MyTimerMessage::Responding = m { handler() }
        }))
    }

    /// Register a listener for `Closed`; it receives `ok` and `reason`.
    pub fn add_closed_listener<F>(&self, handler: F) -> ListenerHandle
    where F: Fn(bool, &str) + Send + Sync + 'static,
    {
        self.inner.add(Arc::new(move |m: &MyTimerMessage| {
            if let MyTimerMessage::Closed { ok, reason } = m { handler(*ok, reason) }
        }))
    }

    /// Register a listener that sees every message the library sends.
    pub fn add_message_listener<F>(&self, handler: F) -> ListenerHandle
    where F: Fn(&MyTimerMessage) + Send + Sync + 'static,
    {
        self.inner.add(Arc::new(handler))
    }

    /// Remove a previously-registered listener by handle. Returns true
    /// if the listener existed and was removed; false otherwise.
    /// Listeners run on the context's pump thread, one message at a time, and may
    /// call this for any listener: a dispatch in flight still runs the handlers it
    /// took, so a removed handler can run once more.
    pub fn remove_event_listener(&self, handle: ListenerHandle) -> bool {
        self.inner.remove(handle.id)
    }

    /// Sleeps `delayMs` then echoes the message back, firing `on_echo_fired`.
    pub fn echo(&self, req: EchoRequest) -> Result<EchoResponse, String> {
        let req = MyTimerEchoReq { req };
        let req_bytes = encode_cbor(&req)?;
        let raw_bytes = ffi_call_sync(self.timeout, |cb, ud| unsafe {
            ffi::my_timer_echo(self.ptr, cb, ud, req_bytes.as_ptr(), req_bytes.len())
        })?;
        decode_cbor::<EchoResponse>(&raw_bytes)
    }

    /// Sleeps `delayMs` then echoes the message back, firing `on_echo_fired`.
    pub async fn echo_async(&self, req: EchoRequest) -> Result<EchoResponse, String> {
        let req = MyTimerEchoReq { req };
        let req_bytes = encode_cbor(&req)?;
        let ptr = self.ptr as usize;
        let raw_bytes = ffi_call_async(self.timeout, move |cb, ud| unsafe {
            ffi::my_timer_echo(ptr as *mut c_void, cb, ud, req_bytes.as_ptr(), req_bytes.len())
        }).await?;
        decode_cbor::<EchoResponse>(&raw_bytes)
    }

    /// Returns the library's version string.
    pub fn version(&self) -> Result<String, String> {
        let req = MyTimerVersionReq {};
        let req_bytes = encode_cbor(&req)?;
        let raw_bytes = ffi_call_sync(self.timeout, |cb, ud| unsafe {
            ffi::my_timer_version(self.ptr, cb, ud, req_bytes.as_ptr(), req_bytes.len())
        })?;
        decode_cbor::<String>(&raw_bytes)
    }

    /// Returns the library's version string.
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

    /// Three object-typed params (`job`, `retry`, `schedule`) packed into one CBOR envelope.
    pub fn schedule(&self, job: JobSpec, retry: RetryPolicy, schedule: ScheduleConfig) -> Result<ScheduleResult, String> {
        let req = MyTimerScheduleReq { job, retry, schedule };
        let req_bytes = encode_cbor(&req)?;
        let raw_bytes = ffi_call_sync(self.timeout, |cb, ud| unsafe {
            ffi::my_timer_schedule(self.ptr, cb, ud, req_bytes.as_ptr(), req_bytes.len())
        })?;
        decode_cbor::<ScheduleResult>(&raw_bytes)
    }

    /// Three object-typed params (`job`, `retry`, `schedule`) packed into one CBOR envelope.
    pub async fn schedule_async(&self, job: JobSpec, retry: RetryPolicy, schedule: ScheduleConfig) -> Result<ScheduleResult, String> {
        let req = MyTimerScheduleReq { job, retry, schedule };
        let req_bytes = encode_cbor(&req)?;
        let ptr = self.ptr as usize;
        let raw_bytes = ffi_call_async(self.timeout, move |cb, ud| unsafe {
            ffi::my_timer_schedule(ptr as *mut c_void, cb, ud, req_bytes.as_ptr(), req_bytes.len())
        }).await?;
        decode_cbor::<ScheduleResult>(&raw_bytes)
    }

    pub fn lib_version(timeout: Duration) -> Result<String, String> {
        let req = MyTimerLibVersionReq {};
        let req_bytes = encode_cbor(&req)?;
        let raw_bytes = ffi_call_sync(timeout, |cb, ud| unsafe {
            ffi::my_timer_lib_version(cb, ud, req_bytes.as_ptr(), req_bytes.len())
        })?;
        decode_cbor::<String>(&raw_bytes)
    }

    pub async fn lib_version_async(timeout: Duration) -> Result<String, String> {
        let req = MyTimerLibVersionReq {};
        let req_bytes = encode_cbor(&req)?;
        let raw_bytes = ffi_call_async(timeout, move |cb, ud| unsafe {
            ffi::my_timer_lib_version(cb, ud, req_bytes.as_ptr(), req_bytes.len())
        }).await?;
        decode_cbor::<String>(&raw_bytes)
    }

    /// Stop every context the library still holds and join their threads.
    /// Call it before the process exits when a context is still alive, or when a
    /// static proc built the shared context.
    /// Returns 0 when every context stopped, 1 when one was left running.
    /// This wrapper reports that as true.
    pub fn shutdown() -> bool {
        unsafe { ffi::my_timer_shutdown() == 0 }
    }

}
