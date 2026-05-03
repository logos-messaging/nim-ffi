// Rust client for the nim_timer shared library built with nim-ffi + chronos.
//
// This file uses the generated `nimtimer` crate, which wraps all the raw FFI
// boilerplate (extern "C" declarations, callback machinery, JSON encode/decode).
//
// To regenerate the `nim_bindings` crate:
//   nim c --mm:orc -d:chronicles_log_level=WARN --nimMainPrefix:libnimtimer \
//         -d:ffiGenBindings examples/nim_timer/nim_timer.nim
use nimtimer::{EchoRequest, NimTimerCtx, TimerConfig};
use std::time::Duration;

fn main() {
    let timeout = Duration::from_secs(5);

    // ── 1. Create the timer service ────────────────────────────────────────
    let ctx = NimTimerCtx::create(TimerConfig { name: "demo".into() }, timeout)
        .expect("nimtimer_create failed");
    println!("[1] Context created");

    // ── 2. Sync call: version ──────────────────────────────────────────────
    let version = ctx.version().expect("nimtimer_version failed");
    println!("[2] Version (sync call, callback fired inline): {version}");

    // ── 3. Async call: echo (200 ms delay) ────────────────────────────────
    let echo = ctx
        .echo(EchoRequest {
            message: "hello from Rust".into(),
            delay_ms: 200,
        })
        .expect("nimtimer_echo failed");
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
        .expect("second nimtimer_echo failed");
    println!("[4] Echo: echoed={}, timerName={}", echo2.echoed, echo2.timer_name);

    println!("\nDone. The Nim FFI thread and watchdog are still running.");
    println!("(In a real app, call nimtimer_destroy to join them gracefully.)");
}
