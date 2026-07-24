//! Synchronous example: exercises the typed per-event listener API.
//!
//! Run with: `cargo run --example main`

use my_timer::{EchoEvent, EchoRequest, MyTimerCtx, TimerConfig};
use std::sync::mpsc;
use std::time::Duration;

fn main() -> Result<(), String> {
    // `myTimerLibVersion` is {.ffiStatic.}: an associated fn, no ctx needed.
    println!("lib version: {}", MyTimerCtx::lib_version(Duration::from_secs(5))?);

    let ctx = MyTimerCtx::create(
        TimerConfig { name: "rust-sync-demo".into() },
        Duration::from_secs(5),
    )?;

    // Closure runs on the lib's dispatch thread; forward to `main` via mpsc and recv_timeout below.
    let (tx, rx) = mpsc::channel::<EchoEvent>();
    let typed_handle = ctx.add_on_echo_fired_listener(move |evt: &EchoEvent| {
        let _ = tx.send(evt.clone());
    });

    ctx.echo(EchoRequest { message: "sync-event-demo".into(), delay_ms: 1 })?;

    match rx.recv_timeout(Duration::from_secs(2)) {
        Ok(evt) => println!("typed onEchoFired: message={}, echo_count={}", evt.message, evt.echo_count),
        Err(e) => return Err(format!("event never arrived: {}", e)),
    }

    ctx.remove_event_listener(typed_handle);
    Ok(())
}
