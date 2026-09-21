use std::collections::HashMap;
use std::ffi::CStr;
use std::os::raw::{c_int, c_void};
use std::slice;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::thread::{JoinHandle, ThreadId};
use std::time::{Duration, Instant};
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

// nim-ffi status codes, emitted from ffi/ret_codes.nim.
#[allow(dead_code)]
const NIMFFI_RET_OK: c_int = 0;
#[allow(dead_code)]
const NIMFFI_RET_ERR: c_int = 1;
#[allow(dead_code)]
const NIMFFI_RET_TIMEOUT: c_int = 4;
#[allow(dead_code)]
const NIMFFI_RET_CLOSED: c_int = 5;
#[allow(dead_code)]
const NIMFFI_RET_INVALID_CTX: c_int = 6;
#[allow(dead_code)]
const NIMFFI_RET_BUSY: c_int = 7;
#[allow(dead_code)]
const NIMFFI_RET_QUEUE_FULL: c_int = 8;
#[allow(dead_code)]
const NIMFFI_RET_TOO_LARGE: c_int = 9;

// `NimFfiMsg.name_id` of each event: FNV-1a 64 of its wire name.
pub const MY_TIMER_EVT_ON_ECHO_FIRED: u64 = 0xcdfdf536356b2a2b; // "on_echo_fired"
pub const MY_TIMER_EVT_ON_JOB_SCHEDULED: u64 = 0xd6ac432a40b9a85c; // "on_job_scheduled"
pub use super::ffi::{NIMFFI_NOT_RESPONDING_EVENT_QUEUE_FULL, NIMFFI_NOT_RESPONDING_HEARTBEAT};

/// Everything `my_timer` sends to the host besides replies: its events, the
/// progress and liveness reports and the end of the context. The pump thread
/// of a context decodes each message into one of these before a listener runs.
/// A reply is not listed: it goes to the call that waits for it, which decodes
/// it into that call's return type.
#[derive(Debug, Clone)]
pub enum MyTimerMessage {
    /// Fired by `myTimerEcho` once the reply is ready.
    OnEchoFired(EchoEvent),
    /// Fired by `myTimerSchedule`. Its two params ride the wire as a synthesised
    /// `OnJobScheduledPayload` envelope, so the foreign side decodes one typed value.
    OnJobScheduled(OnJobScheduledPayload),
    /// Request `req_id` has been running for `elapsed_ms`. Not a reply: the
    /// request still runs and its call still returns.
    StaleWarn { req_id: u64, elapsed_ms: u64 },
    /// The library stopped making progress. `reason` is a `NIMFFI_NOT_RESPONDING_*`:
    /// the FFI thread stalled, or the event queue overflowed and requests are
    /// refused from now on.
    NotResponding { reason: u64 },
    /// The FFI thread's heartbeat resumed.
    Responding,
    /// The context is gone; always the last message. `ok` is false when the
    /// library could not recycle the context, and `reason` then says why. Every
    /// call still waiting for its reply has failed by the time a listener sees it.
    Closed { ok: bool, reason: String },
    /// Not sent by the library: a message this binding could not decode, such
    /// as an event of a newer library.
    Undecodable { kind: u32, name_id: u64, error: String },
}

unsafe fn payload_bytes(msg: &ffi::NimFfiMsg) -> &[u8] {
    if msg.payload.is_null() || msg.len == 0 {
        &[]
    } else {
        slice::from_raw_parts(msg.payload, msg.len)
    }
}

unsafe fn decode_message(msg: &ffi::NimFfiMsg) -> MyTimerMessage {
    let bytes = payload_bytes(msg);
    let decoded = match msg.kind {
        ffi::NIMFFI_MSG_EVENT => match msg.name_id {
            MY_TIMER_EVT_ON_ECHO_FIRED => decode_cbor(bytes).map(MyTimerMessage::OnEchoFired),
            MY_TIMER_EVT_ON_JOB_SCHEDULED => decode_cbor(bytes).map(MyTimerMessage::OnJobScheduled),
            _ => Err("unknown event".to_string()),
        },
        ffi::NIMFFI_MSG_STALE_WARN => Ok(MyTimerMessage::StaleWarn {
            req_id: msg.id,
            elapsed_ms: msg.aux,
        }),
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

// A reply: the CBOR of the return value, or the library's error text.
type FFIResult = Result<Vec<u8>, String>;
type Handler = Arc<dyn Fn(&MyTimerMessage) + Send + Sync>;

const CONTEXT_CLOSED: &str = "context closed before the reply arrived";

/// Returned by every `add_*_listener`; pass it to `remove_event_listener`.
#[derive(Debug, Clone, Copy)]
pub struct ListenerHandle { pub id: u64 }

// What a context shares with its pump thread.
struct Inner {
    ptr: *mut c_void,
    listeners: Mutex<Vec<(u64, Handler)>>,
    // The calls that wait for a reply, by request id.
    waiters: Mutex<HashMap<u64, flume::Sender<FFIResult>>>,
    next_id: AtomicU64,
    stop: AtomicBool,
    // Written under the `waiters` lock: no reply can be delivered any more.
    ended: AtomicBool,
    pump_thread: OnceLock<ThreadId>,
}

// SAFETY: `ptr` is a token the library validates on every call, never
// dereferenced here. `my_timer_poll` admits one consumer per context and only the
// pump thread polls; everything else in `Inner` is already Sync.
unsafe impl Send for Inner {}
unsafe impl Sync for Inner {}

// No lock here is held while foreign code of the host runs, so a panic cannot poison one; recover anyway.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|e| e.into_inner())
}

// Why the library refused a request. `my_timer_last_error` is per thread: call this
// on the refused thread, before its next request.
fn last_error(ret: c_int) -> String {
    let text = unsafe { CStr::from_ptr(ffi::my_timer_last_error()) }.to_string_lossy().into_owned();
    if text.is_empty() { format!("request refused (NIMFFI_RET {ret})") } else { text }
}

fn spawn_pump(name: &str, inner: Arc<Inner>) -> Result<JoinHandle<()>, String> {
    std::thread::Builder::new()
        .name(name.into())
        .spawn(move || pump_loop(inner))
        .map_err(|e| e.to_string())
}

impl Inner {
    fn new(ptr: *mut c_void) -> Self {
        Inner {
            ptr,
            listeners: Mutex::new(Vec::new()),
            waiters: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(1),
            stop: AtomicBool::new(false),
            ended: AtomicBool::new(false),
            pump_thread: OnceLock::new(),
        }
    }

    fn add(&self, handler: Handler) -> ListenerHandle {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        lock(&self.listeners).push((id, handler));
        ListenerHandle { id }
    }

    fn remove(&self, id: u64) -> bool {
        let mut listeners = lock(&self.listeners);
        let before = listeners.len();
        listeners.retain(|(lid, _)| *lid != id);
        listeners.len() != before
    }

    fn dispatch(&self, message: &MyTimerMessage) {
        // Cloned out so a handler may add or remove listeners.
        let handlers: Vec<Handler> = lock(&self.listeners).iter().map(|(_, h)| h.clone()).collect();
        for handler in handlers {
            // A panicking handler must not end the pump; the panic hook already reported it.
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| handler(message)));
        }
    }

    // Sends a request with `send(ctx, req_id_out)` and registers the waiter of its reply.
    fn submit<F>(&self, send: F) -> Result<(u64, flume::Receiver<FFIResult>), String>
    where
        F: FnOnce(*mut c_void, *mut u64) -> c_int,
    {
        let (tx, rx) = flume::bounded::<FFIResult>(1);
        let mut req_id: u64 = 0;
        // Held across the call: the pump can poll the reply before the call
        // returns, and takes this lock before it looks the waiter up.
        let mut waiters = lock(&self.waiters);
        let ret = send(self.ptr, &mut req_id);
        if ret != NIMFFI_RET_OK {
            // Refused: no reply will come, so nothing is registered.
            return Err(last_error(ret));
        }
        if self.ended.load(Ordering::Acquire) {
            return Err(CONTEXT_CLOSED.into());
        }
        waiters.insert(req_id, tx);
        Ok((req_id, rx))
    }

    // Hands a reply to its waiter. One without a waiter is dropped: its call timed out.
    unsafe fn complete(&self, msg: &ffi::NimFfiMsg) {
        let waiter = lock(&self.waiters).remove(&msg.id);
        if let Some(tx) = waiter {
            let bytes = payload_bytes(msg);
            let reply = if msg.ret_code == NIMFFI_RET_OK {
                Ok(bytes.to_vec())
            } else {
                // Lossy: the text comes from a Nim `string`, so invalid UTF-8 is a library bug.
                Err(String::from_utf8_lossy(bytes).into_owned())
            };
            // The call may have gone away meanwhile (a dropped future).
            let _ = tx.send(reply);
        }
    }

    // No reply can arrive any more: dropping a sender fails its call with CONTEXT_CLOSED.
    fn fail_waiters(&self) {
        let mut waiters = lock(&self.waiters);
        self.ended.store(true, Ordering::Release);
        waiters.clear();
    }

    // Forgets the waiter so a late reply is dropped; a reply that raced the timeout still counts.
    fn timed_out(&self, req_id: u64, rx: &flume::Receiver<FFIResult>, timeout: Duration) -> FFIResult {
        lock(&self.waiters).remove(&req_id);
        rx.try_recv().unwrap_or_else(|_| Err(format!("timed out after {:?}", timeout)))
    }

    fn wait(&self, req_id: u64, rx: &flume::Receiver<FFIResult>, timeout: Duration) -> FFIResult {
        if self.pump_thread.get() == Some(&std::thread::current().id()) {
            return self.wait_on_pump(req_id, rx, timeout);
        }
        match rx.recv_timeout(timeout) {
            Ok(reply) => reply,
            Err(flume::RecvTimeoutError::Timeout) => self.timed_out(req_id, rx, timeout),
            Err(flume::RecvTimeoutError::Disconnected) => Err(CONTEXT_CLOSED.into()),
        }
    }

    // A blocking call made by a listener runs on the pump thread, the only one
    // that can deliver its reply: keep pumping here until that reply arrives.
    fn wait_on_pump(&self, req_id: u64, rx: &flume::Receiver<FFIResult>, timeout: Duration) -> FFIResult {
        let deadline = Instant::now() + timeout;
        loop {
            match rx.try_recv() {
                Ok(reply) => return reply,
                Err(flume::TryRecvError::Disconnected) => return Err(CONTEXT_CLOSED.into()),
                Err(flume::TryRecvError::Empty) => {}
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return self.timed_out(req_id, rx, timeout);
            }
            let slice_ms = left.as_millis().clamp(1, 250) as i32;
            pump_step(self, slice_ms);
        }
    }

    // The `.await` of an `_async` call. It must not run on the pump thread (inside
    // a listener): nothing would pump the reply, and the call would time out.
    async fn wait_async(&self, req_id: u64, rx: flume::Receiver<FFIResult>, timeout: Duration) -> FFIResult {
        match tokio::time::timeout(timeout, rx.recv_async()).await {
            Ok(Ok(reply)) => reply,
            Ok(Err(_)) => Err(CONTEXT_CLOSED.into()),
            Err(_) => self.timed_out(req_id, &rx, timeout),
        }
    }
}

enum Step { Message, Idle, Ended }

// One poll: a reply goes to its waiter, anything else to the listeners.
fn pump_step(inner: &Inner, timeout_ms: i32) -> Step {
    if inner.ended.load(Ordering::Acquire) {
        return Step::Ended;
    }
    // The library owns the message; it is valid until the next poll.
    let mut msg: *const ffi::NimFfiMsg = std::ptr::null();
    let ret = unsafe { ffi::my_timer_poll(inner.ptr, timeout_ms, &mut msg) };
    match ret {
        NIMFFI_RET_OK | NIMFFI_RET_CLOSED if !msg.is_null() => {
            let msg = unsafe { &*msg };
            if msg.kind == ffi::NIMFFI_MSG_REPLY {
                unsafe { inner.complete(msg) };
                return Step::Message;
            }
            // Decoded before a listener runs: a listener's blocking call polls again.
            let message = unsafe { decode_message(msg) };
            if ret == NIMFFI_RET_CLOSED {
                inner.fail_waiters();
            }
            inner.dispatch(&message);
            if ret == NIMFFI_RET_CLOSED { Step::Ended } else { Step::Message }
        }
        NIMFFI_RET_TIMEOUT => Step::Idle,
        NIMFFI_RET_INVALID_CTX => {
            // The context ended between two polls, so its CLOSED message was never seen.
            inner.fail_waiters();
            inner.dispatch(&MyTimerMessage::Closed { ok: true, reason: String::new() });
            Step::Ended
        }
        // NIMFFI_RET_BUSY, NIMFFI_RET_ERR: try again, without spinning.
        _ => {
            std::thread::sleep(Duration::from_millis(10));
            Step::Idle
        }
    }
}

// The context's only poller.
fn pump_loop(inner: Arc<Inner>) {
    let _ = inner.pump_thread.set(std::thread::current().id());
    loop {
        // Once asked to stop, only take what already waits: a teardown's last messages.
        let stopping = inner.stop.load(Ordering::Acquire);
        let timeout_ms = if stopping { 0 } else { 250 };
        match pump_step(&inner, timeout_ms) {
            Step::Message => {}
            Step::Idle => {
                if stopping {
                    break;
                }
            }
            Step::Ended => break,
        }
    }
    // Nobody delivers a reply from here on.
    inner.fail_waiters();
}

struct StaticPump {
    inner: Arc<Inner>,
    thread: JoinHandle<()>,
}

// The reply of a static request arrives on the library's static context: one
// pump per process, started by the first static call and stopped by `shutdown`.
// Its thread does not keep the process alive.
static STATIC_PUMP: Mutex<Option<StaticPump>> = Mutex::new(None);

fn static_inner() -> Result<Arc<Inner>, String> {
    let mut slot = lock(&STATIC_PUMP);
    if let Some(pump) = slot.as_ref() {
        if !pump.inner.ended.load(Ordering::Acquire) {
            return Ok(pump.inner.clone());
        }
    }
    let ptr = unsafe { ffi::my_timer_static_ctx() };
    if ptr.is_null() {
        return Err(last_error(NIMFFI_RET_ERR));
    }
    let inner = Arc::new(Inner::new(ptr));
    let thread = spawn_pump("my_timer-static-pump", inner.clone())?;
    *slot = Some(StaticPump { inner: inner.clone(), thread });
    Ok(inner)
}

fn stop_static_pump(slot: &mut Option<StaticPump>) {
    if let Some(pump) = slot.take() {
        pump.inner.stop.store(true, Ordering::Release);
        if pump.thread.thread().id() != std::thread::current().id() {
            let _ = pump.thread.join();
        }
    }
}

/// High-level context for `MyTimer`.
///
/// Every request has a blocking method and an `_async` one. Both send the request,
/// then wait for its reply, which the context's pump thread takes out of
/// `my_timer_poll`; `Err` carries the library's error text, the reason a request was
/// refused, a timeout, or the end of the context.
///
/// Listeners run on the pump thread. One may make a blocking call on its own
/// context: the call pumps the context itself until its reply arrives, so other
/// listeners can run meanwhile. It must not block on an `_async` call: nothing
/// pumps the reply while the pump thread is parked, so the call times out.
pub struct MyTimerCtx {
    ptr: *mut c_void,
    timeout: Duration,
    inner: Arc<Inner>,
    pump: Option<JoinHandle<()>>,
}

// SAFETY: `ptr` is a token the library validates on every call; it is never
// dereferenced here. A request export only checks the token and puts the
// request on a lock-guarded queue, which is sound from any number of threads;
// the library's single FFI thread runs every handler. Replies and events come
// back through the pump thread alone, and the waiter table and the listeners
// it shares with the callers are behind mutexes.
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
        let (ctx, req_id, rx) = Self::start(&req_bytes, timeout, ffi::my_timer_create)?;
        // An error reply or a timeout drops `ctx`, which destroys the context.
        ctx.inner.wait(req_id, &rx, timeout)?;
        Ok(ctx)
    }

    /// Creates the FFIContext + MyTimer; async via chronos.
    pub async fn new_async(config: TimerConfig, timeout: Duration) -> Result<Self, String> {
        let req = MyTimerCreateCtorReq { config };
        let req_bytes = encode_cbor(&req)?;
        let (ctx, req_id, rx) = Self::start(&req_bytes, timeout, ffi::my_timer_create)?;
        // An error reply or a timeout drops `ctx`, which destroys the context.
        ctx.inner.wait_async(req_id, rx, timeout).await?;
        Ok(ctx)
    }

    // `submit` is the ctor export. The waiter of its reply is registered before
    // the pump starts, so the pump cannot see the reply first.
    fn start(
        req_bytes: &[u8],
        timeout: Duration,
        submit: unsafe extern "C" fn(*const u8, usize, *mut *mut c_void, *mut u64) -> c_int,
    ) -> Result<(Self, u64, flume::Receiver<FFIResult>), String> {
        let mut ptr: *mut c_void = std::ptr::null_mut();
        let mut req_id: u64 = 0;
        let ret = unsafe { submit(req_bytes.as_ptr(), req_bytes.len(), &mut ptr, &mut req_id) };
        if ret != NIMFFI_RET_OK || ptr.is_null() {
            // Nothing was claimed, so there is nothing to destroy.
            return Err(last_error(ret));
        }
        let inner = Arc::new(Inner::new(ptr));
        let (tx, rx) = flume::bounded::<FFIResult>(1);
        lock(&inner.waiters).insert(req_id, tx);
        // Built before the thread: from here on, an early return drops it, which destroys the context.
        let mut ctx = Self { ptr, timeout, inner: inner.clone(), pump: None };
        ctx.pump = Some(spawn_pump("my_timer-pump", inner)?);
        Ok((ctx, req_id, rx))
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

    /// Register a listener for `StaleWarn`; it receives the request id and the
    /// milliseconds the request has been running.
    pub fn add_stale_warn_listener<F>(&self, handler: F) -> ListenerHandle
    where F: Fn(u64, u64) + Send + Sync + 'static,
    {
        self.inner.add(Arc::new(move |m: &MyTimerMessage| {
            if let MyTimerMessage::StaleWarn { req_id, elapsed_ms } = m { handler(*req_id, *elapsed_ms) }
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
        let (req_id, rx) = self.inner.submit(
            |ctx, req_id| unsafe { ffi::my_timer_echo(ctx, req_bytes.as_ptr(), req_bytes.len(), req_id) },
        )?;
        let raw_bytes = self.inner.wait(req_id, &rx, self.timeout)?;
        decode_cbor::<EchoResponse>(&raw_bytes)
    }

    /// Sleeps `delayMs` then echoes the message back, firing `on_echo_fired`.
    pub async fn echo_async(&self, req: EchoRequest) -> Result<EchoResponse, String> {
        let req = MyTimerEchoReq { req };
        let req_bytes = encode_cbor(&req)?;
        let (req_id, rx) = self.inner.submit(
            |ctx, req_id| unsafe { ffi::my_timer_echo(ctx, req_bytes.as_ptr(), req_bytes.len(), req_id) },
        )?;
        let raw_bytes = self.inner.wait_async(req_id, rx, self.timeout).await?;
        decode_cbor::<EchoResponse>(&raw_bytes)
    }

    /// Returns the library's version string.
    pub fn version(&self) -> Result<String, String> {
        let req = MyTimerVersionReq {};
        let req_bytes = encode_cbor(&req)?;
        let (req_id, rx) = self.inner.submit(
            |ctx, req_id| unsafe { ffi::my_timer_version(ctx, req_bytes.as_ptr(), req_bytes.len(), req_id) },
        )?;
        let raw_bytes = self.inner.wait(req_id, &rx, self.timeout)?;
        decode_cbor::<String>(&raw_bytes)
    }

    /// Returns the library's version string.
    pub async fn version_async(&self) -> Result<String, String> {
        let req = MyTimerVersionReq {};
        let req_bytes = encode_cbor(&req)?;
        let (req_id, rx) = self.inner.submit(
            |ctx, req_id| unsafe { ffi::my_timer_version(ctx, req_bytes.as_ptr(), req_bytes.len(), req_id) },
        )?;
        let raw_bytes = self.inner.wait_async(req_id, rx, self.timeout).await?;
        decode_cbor::<String>(&raw_bytes)
    }

    pub fn complex(&self, req: ComplexRequest) -> Result<ComplexResponse, String> {
        let req = MyTimerComplexReq { req };
        let req_bytes = encode_cbor(&req)?;
        let (req_id, rx) = self.inner.submit(
            |ctx, req_id| unsafe { ffi::my_timer_complex(ctx, req_bytes.as_ptr(), req_bytes.len(), req_id) },
        )?;
        let raw_bytes = self.inner.wait(req_id, &rx, self.timeout)?;
        decode_cbor::<ComplexResponse>(&raw_bytes)
    }

    pub async fn complex_async(&self, req: ComplexRequest) -> Result<ComplexResponse, String> {
        let req = MyTimerComplexReq { req };
        let req_bytes = encode_cbor(&req)?;
        let (req_id, rx) = self.inner.submit(
            |ctx, req_id| unsafe { ffi::my_timer_complex(ctx, req_bytes.as_ptr(), req_bytes.len(), req_id) },
        )?;
        let raw_bytes = self.inner.wait_async(req_id, rx, self.timeout).await?;
        decode_cbor::<ComplexResponse>(&raw_bytes)
    }

    /// Three object-typed params (`job`, `retry`, `schedule`) packed into one CBOR envelope.
    pub fn schedule(&self, job: JobSpec, retry: RetryPolicy, schedule: ScheduleConfig) -> Result<ScheduleResult, String> {
        let req = MyTimerScheduleReq { job, retry, schedule };
        let req_bytes = encode_cbor(&req)?;
        let (req_id, rx) = self.inner.submit(
            |ctx, req_id| unsafe { ffi::my_timer_schedule(ctx, req_bytes.as_ptr(), req_bytes.len(), req_id) },
        )?;
        let raw_bytes = self.inner.wait(req_id, &rx, self.timeout)?;
        decode_cbor::<ScheduleResult>(&raw_bytes)
    }

    /// Three object-typed params (`job`, `retry`, `schedule`) packed into one CBOR envelope.
    pub async fn schedule_async(&self, job: JobSpec, retry: RetryPolicy, schedule: ScheduleConfig) -> Result<ScheduleResult, String> {
        let req = MyTimerScheduleReq { job, retry, schedule };
        let req_bytes = encode_cbor(&req)?;
        let (req_id, rx) = self.inner.submit(
            |ctx, req_id| unsafe { ffi::my_timer_schedule(ctx, req_bytes.as_ptr(), req_bytes.len(), req_id) },
        )?;
        let raw_bytes = self.inner.wait_async(req_id, rx, self.timeout).await?;
        decode_cbor::<ScheduleResult>(&raw_bytes)
    }

    pub fn lib_version(timeout: Duration) -> Result<String, String> {
        let req = MyTimerLibVersionReq {};
        let req_bytes = encode_cbor(&req)?;
        let inner = static_inner()?;
        let (req_id, rx) = inner.submit(
            |_, req_id| unsafe { ffi::my_timer_lib_version(req_bytes.as_ptr(), req_bytes.len(), req_id) },
        )?;
        let raw_bytes = inner.wait(req_id, &rx, timeout)?;
        decode_cbor::<String>(&raw_bytes)
    }

    pub async fn lib_version_async(timeout: Duration) -> Result<String, String> {
        let req = MyTimerLibVersionReq {};
        let req_bytes = encode_cbor(&req)?;
        let inner = static_inner()?;
        let (req_id, rx) = inner.submit(
            |_, req_id| unsafe { ffi::my_timer_lib_version(req_bytes.as_ptr(), req_bytes.len(), req_id) },
        )?;
        let raw_bytes = inner.wait_async(req_id, rx, timeout).await?;
        decode_cbor::<String>(&raw_bytes)
    }

    /// Stop every context the library still holds and join their threads.
    /// Call it before the process exits when a context is still alive, or when a
    /// static proc built the shared context.
    /// Returns 0 when every context stopped, 1 when one was left running.
    /// This wrapper reports that as true.
    pub fn shutdown() -> bool {
        // Held across the shutdown, so no static call starts a pump on a context about to go.
        let mut static_pump = lock(&STATIC_PUMP);
        stop_static_pump(&mut static_pump);
        unsafe { ffi::my_timer_shutdown() == 0 }
    }

}
