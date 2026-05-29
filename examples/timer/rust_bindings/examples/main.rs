//! Synchronous example: exercises the library-event listener API
//! (typed + wildcard + remove).
//!
//! Run with: `cargo run --example main`

use my_timer::{decode_event_payload, EchoEvent, EchoRequest, MyTimerCtx, TimerConfig};
use std::os::raw::c_int;
use std::sync::mpsc;
use std::time::Duration;

fn main() -> Result<(), String> {
    let ctx = MyTimerCtx::create(
        TimerConfig { name: "rust-sync-demo".into() },
        Duration::from_secs(5),
    )?;

    // Typed listener: the closure is invoked on the lib's dispatch
    // thread, so forward the payload to `main` via std mpsc and block
    // on `recv_timeout` below. `add_on_echo_fired_listener` is generated
    // per `{.ffiEvent.}`-declared proc and takes a typed `&EchoEvent`.
    let (tx, rx) = mpsc::channel::<EchoEvent>();
    let typed_handle = ctx.add_on_echo_fired_listener(move |evt: &EchoEvent| {
        let _ = tx.send(evt.clone());
    });

    // Wildcard listener: receives every event with the FFI return code,
    // the wire `event_id` pre-extracted from the CBOR envelope, and the
    // raw envelope bytes. Lift to a typed payload via
    // `decode_event_payload::<T>` when the event_id matches one you
    // care about — this avoids hand-rolling ciborium calls per branch.
    let wildcard_handle = ctx.add_event_listener(|ret: c_int, event_id: &str, envelope: &[u8]| {
        println!("wildcard: ret={}, event_id={}, bytes={}", ret, event_id, envelope.len());
        if ret == 0 && event_id == "on_echo_fired" {
            match decode_event_payload::<EchoEvent>(envelope) {
                Ok(evt) => println!("  decoded: message={}, echo_count={}", evt.message, evt.echo_count),
                Err(e) => println!("  decode failed: {}", e),
            }
        }
    });

    // Trigger the event — fires `on_echo_fired` once, which the
    // dispatch thread delivers to both listeners above.
    ctx.echo(EchoRequest { message: "sync-event-demo".into(), delay_ms: 1 })?;

    match rx.recv_timeout(Duration::from_secs(2)) {
        Ok(evt) => println!("typed onEchoFired: message={}, echo_count={}", evt.message, evt.echo_count),
        Err(e) => return Err(format!("event never arrived: {}", e)),
    }

    ctx.remove_event_listener(typed_handle);
    ctx.remove_event_listener(wildcard_handle);
    Ok(())
}
