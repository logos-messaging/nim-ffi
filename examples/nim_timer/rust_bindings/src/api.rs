use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;
use super::ffi;
use super::types::*;

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Default)]
struct FfiCallbackResult {
    payload: Option<Result<String, String>>,
}

type Pair = Arc<(Mutex<FfiCallbackResult>, Condvar)>;

unsafe extern "C" fn on_result(
    ret: c_int,
    msg: *const c_char,
    _len: usize,
    user_data: *mut c_void,
) {
    let pair = Arc::from_raw(user_data as *const (Mutex<FfiCallbackResult>, Condvar));
    {
        let (lock, cvar) = &*pair;
        let mut state = lock.lock().unwrap();
        state.payload = Some(if ret == 0 {
            Ok(CStr::from_ptr(msg).to_string_lossy().into_owned())
        } else {
            Err(CStr::from_ptr(msg).to_string_lossy().into_owned())
        });
        cvar.notify_one();
    }
    std::mem::forget(pair);
}

fn ffi_call<F>(timeout: Duration, f: F) -> Result<String, String>
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

/// High-level context for `NimTimer`.
pub struct NimTimerCtx {
    ptr: *mut c_void,
    timeout: Duration,
}

unsafe impl Send for NimTimerCtx {}
unsafe impl Sync for NimTimerCtx {}

impl NimTimerCtx {
    pub fn create(config: TimerConfig, timeout: Duration) -> Result<Self, String> {
        let config_json = serde_json::to_string(&config).map_err(|e| e.to_string())?;
        let config_c = CString::new(config_json).unwrap();
        let raw = ffi_call(timeout, |cb, ud| unsafe {
            ffi::nimtimer_create(config_c.as_ptr(), cb, ud)
        })?;
        // ctor returns the context address as a plain decimal string
        let addr: usize = raw.parse().map_err(|e: std::num::ParseIntError| e.to_string())?;
        Ok(Self { ptr: addr as *mut c_void, timeout })
    }

    pub fn new(config: TimerConfig) -> Result<Self, String> {
        Self::create(config, DEFAULT_TIMEOUT)
    }

    #[cfg(feature = "tokio")]
    pub async fn new_async(config: TimerConfig) -> Result<Self, String> {
        tokio::task::block_in_place(move || Self::new(config))
    }

    pub fn echo(&self, req: EchoRequest) -> Result<EchoResponse, String> {
        let req_json = serde_json::to_string(&req).map_err(|e| e.to_string())?;
        let req_c = CString::new(req_json).unwrap();
        let raw = ffi_call(self.timeout, |cb, ud| unsafe {
            ffi::nimtimer_echo(self.ptr, cb, ud, req_c.as_ptr())
        })?;
        serde_json::from_str::<EchoResponse>(&raw).map_err(|e| e.to_string())
    }

    pub fn version(&self) -> Result<String, String> {
        let raw = ffi_call(self.timeout, |cb, ud| unsafe {
            ffi::nimtimer_version(self.ptr, cb, ud)
        })?;
        serde_json::from_str::<String>(&raw).map_err(|e| e.to_string())
    }

    #[cfg(feature = "tokio")]
    pub async fn version_async(&self) -> Result<String, String> {
        let ptr = self.ptr;
        let timeout = self.timeout;
        tokio::task::block_in_place(move || {
            let ctx = Self { ptr, timeout };
            ctx.version()
        })
    }

    pub fn complex(&self, req: ComplexRequest) -> Result<ComplexResponse, String> {
        let req_json = serde_json::to_string(&req).map_err(|e| e.to_string())?;
        let req_c = CString::new(req_json).unwrap();
        let raw = ffi_call(self.timeout, |cb, ud| unsafe {
            ffi::nimtimer_complex(self.ptr, cb, ud, req_c.as_ptr())
        })?;
        serde_json::from_str::<ComplexResponse>(&raw).map_err(|e| e.to_string())
    }

    #[cfg(feature = "tokio")]
    pub async fn echo_async(&self, req: EchoRequest) -> Result<EchoResponse, String> {
        let ptr = self.ptr;
        let timeout = self.timeout;
        tokio::task::block_in_place(move || {
            let ctx = Self { ptr, timeout };
            ctx.echo(req)
        })
    }

    #[cfg(feature = "tokio")]
    pub async fn complex_async(&self, req: ComplexRequest) -> Result<ComplexResponse, String> {
        let ptr = self.ptr;
        let timeout = self.timeout;
        tokio::task::block_in_place(move || {
            let ctx = Self { ptr, timeout };
            ctx.complex(req)
        })
    }
}
