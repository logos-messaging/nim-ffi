//! Tokio (async) example: same shape as `main.rs` but exercises the
//! async `_async` API and bridges library events into a tokio-aware
//! channel for async consumption.
//!
//! Run with: `cargo run --example tokio_main`

use my_timer::{decode_event_payload, EchoEvent, EchoRequest, MyTimerCtx, TimerConfig};
use std::os::raw::c_int;
use std::time::Duration;
use tokio::sync::mpsc;

#[tokio::main]
async fn main() -> Result<(), String> {
    let ctx = MyTimerCtx::new_async(
        TimerConfig { name: "rust-tokio-demo".into() },
        Duration::from_secs(5),
    )
    .await?;

    // Typed listener: the handler fires on the lib's dispatch thread,
    // which is *outside* the tokio runtime. Forwarding through a tokio
    // `unbounded_channel` (Sender is Send + Sync, non-blocking) hands
    // the event over to the runtime so we can `.await` it below.
    let (typed_tx, mut typed_rx) = mpsc::unbounded_channel::<EchoEvent>();
    let typed_handle = ctx.add_on_echo_fired_listener(move |evt: &EchoEvent| {
        let _ = typed_tx.send(evt.clone());
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

    // Trigger an echo via the async API — fires `on_echo_fired` once,
    // which the dispatch thread delivers to both listeners above.
    ctx.echo_async(EchoRequest { message: "async-event-demo".into(), delay_ms: 1 })
        .await?;

    // Await the typed event with a bounded timeout so a missing event
    // surfaces as an error instead of hanging the example forever.
    let evt = tokio::time::timeout(Duration::from_secs(2), typed_rx.recv())
        .await
        .map_err(|_| "event never arrived".to_string())?
        .ok_or_else(|| "typed channel closed".to_string())?;
    println!("typed onEchoFired: message={}, echo_count={}", evt.message, evt.echo_count);

    ctx.remove_event_listener(typed_handle);
    ctx.remove_event_listener(wildcard_handle);
    Ok(())
}
