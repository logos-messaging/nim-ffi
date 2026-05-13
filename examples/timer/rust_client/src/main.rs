// Rust client for the timer shared library built with nim-ffi + chronos.
//
// This file uses the generated `timer` crate, which wraps all the raw FFI
// boilerplate (extern "C" declarations, callback machinery, JSON encode/decode).
//
// To regenerate the `rust_bindings` crate:
//   nim c --mm:orc -d:chronicles_log_level=WARN --nimMainPrefix:libtimer \
//         -d:ffiGenBindings examples/timer/timer.nim
use timer::{EchoRequest, TimerCtx, TimerConfig};
use std::time::Duration;

fn main() {
    let timeout = Duration::from_secs(5);

    // ── 1. Create the timer service ────────────────────────────────────────
    let ctx = TimerCtx::create(TimerConfig { name: "demo".into() }, timeout)
        .expect("timer_create failed");
    println!("[1] Context created");

    // ── 2. Sync call: version ──────────────────────────────────────────────
    let version = ctx.version().expect("timer_version failed");
    println!("[2] Version (sync call, callback fired inline): {version}");

    // ── 3. Async call: echo (200 ms delay) ────────────────────────────────
    let echo = ctx
        .echo(EchoRequest {
            message: "hello from Rust".into(),
            delay_ms: 200,
        })
        .expect("timer_echo failed");
    println!(
        "[3] Echo (async, 200 ms chronos delay): echoed={}, timerName={}",
        echo.echoed, echo.timer_name
    );

    // ── 4. A second echo ──────────────────────────────────────────────────
    let echo2 = ctx
        .echo(EchoRequest {
            message: "second request".into(),
            delay_ms: 50,
        })
        .expect("second timer_echo failed");
    println!("[4] Echo: echoed={}, timerName={}", echo2.echoed, echo2.timer_name);

    println!("\nDone. The Nim FFI thread and watchdog are still running.");
    println!("(In a real app, call timer_destroy to join them gracefully.)");
}
