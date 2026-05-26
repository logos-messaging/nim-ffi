//! Tokio (async) example: same shape as `main.rs` but exercises the
//! async `_async` API and bridges library events into a tokio-aware
//! channel for async consumption.
//!
//! Run with: `cargo run --example tokio_main`

use my_timer::{decode_event_payload, EchoEvent, EchoRequest, ListenerHandle, MyTimerCtx, TimerConfig};
use std::os::raw::c_int;
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};
use std::time::Duration;
use tokio::sync::mpsc;

#[tokio::main]
async fn main() -> Result<(), String> {
    let ctx = MyTimerCtx::new_async(
        TimerConfig {
            name: "rust-tokio-demo".into(),
        },
        Duration::from_secs(5),
    )
    .await?;
    println!("[1] Context created");

    let version = ctx.version_async().await?;
    println!("[2] Version: {}", version);

    // ── Typed listener for `onEchoFired` ──────────────────────────────
    // The handler fires on the lib's dispatch thread, so we hop into an
    // `mpsc::UnboundedSender` (which is Send + Sync) to forward into the
    // tokio runtime.
    let (typed_tx, mut typed_rx) = mpsc::unbounded_channel::<EchoEvent>();
    let typed_handle: ListenerHandle = ctx.add_on_echo_fired_listener(move |evt: &EchoEvent| {
        let _ = typed_tx.send(evt.clone());
    });

    // ── Wildcard listener (catch-all) ─────────────────────────────────
    // The handler receives the FFI return code, the pre-extracted wire
    // `event_id`, and the raw CBOR envelope. Pair with
    // `decode_event_payload::<T>` to lift the payload into a typed
    // value when the event is one you care about.
    let wildcard_hits = Arc::new(AtomicUsize::new(0));
    let wildcard_hits_for_cb = Arc::clone(&wildcard_hits);
    let wildcard_handle: ListenerHandle =
        ctx.add_event_listener(move |ret: c_int, event_id: &str, envelope: &[u8]| {
            wildcard_hits_for_cb.fetch_add(1, Ordering::SeqCst);
            println!(
                "[3] wildcard event: ret={}, event_id={}, envelope_bytes={}",
                ret,
                event_id,
                envelope.len()
            );
            if ret == 0 && event_id == "on_echo_fired" {
                match decode_event_payload::<EchoEvent>(envelope) {
                    Ok(evt) => println!(
                        "    decoded EchoEvent: message={}, echo_count={}",
                        evt.message, evt.echo_count
                    ),
                    Err(e) => println!("    decode failed: {}", e),
                }
            }
        });

    // Trigger an echo via the async API — fires `on_echo_fired` once.
    let echo = ctx
        .echo_async(EchoRequest {
            message: "async-event-demo".into(),
            delay_ms: 1,
        })
        .await?;
    println!("[4] Echo response: echoed={}", echo.echoed);

    // Await the typed event with a bounded timeout.
    let evt = tokio::time::timeout(Duration::from_secs(2), typed_rx.recv())
        .await
        .map_err(|_| "event never arrived".to_string())?
        .ok_or_else(|| "typed channel closed".to_string())?;
    println!(
        "[5] typed event onEchoFired: message={}, echo_count={}, wildcard_hits={}",
        evt.message,
        evt.echo_count,
        wildcard_hits.load(Ordering::SeqCst)
    );

    // Drop the typed listener; a second echo only reaches the wildcard.
    assert!(ctx.remove_event_listener(typed_handle));

    ctx.echo_async(EchoRequest {
        message: "after-remove".into(),
        delay_ms: 1,
    })
    .await?;
    tokio::time::sleep(Duration::from_millis(50)).await;
    println!(
        "[6] after remove: wildcard_hits={} (typed listener silent)",
        wildcard_hits.load(Ordering::SeqCst)
    );

    ctx.remove_event_listener(wildcard_handle);
    println!("Done.");
    Ok(())
}
