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
/// Gets the elapsed time on each RET_STALE_WARN. Runs on a library thread, also after a timeout.
pub type Progress = std::sync::Arc<dyn Fn(Duration) + Send + Sync>;
struct CallSlot {
    tx: FFISender,
    progress: Option<Progress>,
}
const DISCONNECTED: &str = "callback channel disconnected before delivery";

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
// {{RET_CODES}}

unsafe extern "C" fn on_result(
    ret: c_int,
    msg: *const c_char,
    len: usize,
    user_data: *mut c_void,
) {
    // Non-terminal ping: do not reclaim the box, the terminal callback still owns it.
    if ret == NIMFFI_RET_STALE_WARN {
        let slot = &*(user_data as *const CallSlot);
        if let Some(progress) = &slot.progress {
            let text = if msg.is_null() { &[][..] } else { slice::from_raw_parts(msg as *const u8, len) };
            let ms = std::str::from_utf8(text).ok().and_then(|t| t.trim().parse::<u64>().ok());
            let ms = ms.unwrap_or(0);
            // A panic must not unwind into the library thread: it would abort.
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                progress(Duration::from_millis(ms))
            }));
        }
        return;
    }

    // Take ownership of the boxed slot — dropping it at end of scope
    // releases the only outstanding handle.
    let tx = Box::from_raw(user_data as *mut CallSlot).tx;

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

// `timeout: None` waits for the terminal RET_OK/RET_ERR with no Rust-side limit; a timeout only
// stops the wait, the Nim handler keeps running to completion.
fn ffi_call_sync<F>(timeout: Option<Duration>, progress: Option<Progress>, f: F) -> FFIResult
where
    F: FnOnce(ffi::FFICallback, *mut c_void) -> c_int,
{
    let (tx, rx) = flume::bounded::<FFIResult>(1);
    let raw = Box::into_raw(Box::new(CallSlot { tx, progress })) as *mut c_void;
    let ret = f(on_result, raw);
    if ret == NIMFFI_RET_MISSING_CALLBACK {
        // Callback will never fire; reclaim the box to avoid a leak.
        drop(unsafe { Box::from_raw(raw as *mut CallSlot) });
        return Err("RET_MISSING_CALLBACK (internal error)".into());
    }
    let payload = match timeout {
        Some(t) => rx.recv_timeout(t).map_err(|e| match e {
            flume::RecvTimeoutError::Timeout => format!("timed out after {:?}", t),
            flume::RecvTimeoutError::Disconnected => DISCONNECTED.to_string(),
        })?,
        None => rx.recv().map_err(|_| DISCONNECTED.to_string())?,
    };
    payload
}

async fn ffi_call_async<F>(timeout: Option<Duration>, progress: Option<Progress>, f: F) -> FFIResult
where
    F: FnOnce(ffi::FFICallback, *mut c_void) -> c_int,
{
    let (tx, rx) = flume::bounded::<FFIResult>(1);
    let raw = Box::into_raw(Box::new(CallSlot { tx, progress })) as *mut c_void;
    let ret = f(on_result, raw);
    if ret == NIMFFI_RET_MISSING_CALLBACK {
        drop(unsafe { Box::from_raw(raw as *mut CallSlot) });
        return Err("RET_MISSING_CALLBACK (internal error)".into());
    }
    let payload = match timeout {
        Some(t) => tokio::time::timeout(t, rx.recv_async())
            .await
            .map_err(|_| format!("timed out after {:?}", t))?
            .map_err(|_| DISCONNECTED.to_string())?,
        None => rx.recv_async().await.map_err(|_| DISCONNECTED.to_string())?,
    };
    payload
}
