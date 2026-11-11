//! The reverse call token and argument ownership, as the README and api.rs document them.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use my_timer::{FetchHostClockCall, HostClock, MyTimerCtx, TimerConfig};

fn make_ctx(name: &str) -> MyTimerCtx {
    MyTimerCtx::create(TimerConfig { name: name.into() }, Duration::from_secs(20))
        .expect("create failed")
}

// The token is plain data: copy it, send it, share it.
const _: () = {
    const fn assert_token<T: Copy + Send + Sync + 'static>() {}
    assert_token::<FetchHostClockCall>();
};

#[test]
fn deferred_reply_moves_owned_args_to_a_thread() {
    let ctx = make_ctx("rev-deferred-args");
    ctx.set_fetch_host_clock_impl(|call, precision: String| {
        // `precision` is owned: it moves into the thread with the token.
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(20));
            call.reply(&HostClock { unix_ms: 7, zone: precision }).expect("reply");
        });
    }).expect("set_fetch_host_clock_impl");
    assert_eq!(ctx.host_clock().expect("host_clock"), "ms@7");
}

#[test]
fn a_call_token_outliving_its_context_replies_an_error() {
    let ctx = make_ctx("rev-stale-token");
    let kept: Arc<Mutex<Option<FetchHostClockCall>>> = Arc::default();
    let slot = kept.clone();
    ctx.set_fetch_host_clock_impl(move |call, _| {
        *slot.lock().unwrap() = Some(call); // a plain copy: {context token, call id}
        call.reply(&HostClock { unix_ms: 1, zone: "UTC".into() }).expect("reply");
    }).expect("set_fetch_host_clock_impl");
    ctx.host_clock().expect("host_clock");
    let call = kept.lock().unwrap().take().expect("the impl ran");
    drop(ctx); // the token now names a slot with no owner, or a new one
    assert_eq!(
        call.reply(&HostClock { unix_ms: 2, zone: "UTC".into() }),
        Err("reply fetch_host_clock: NIMFFI_RET_INVALID_CTX".to_string())
    );
    assert_eq!(
        call.fail("too late"),
        Err("fail fetch_host_clock: NIMFFI_RET_INVALID_CTX".to_string())
    );
}
