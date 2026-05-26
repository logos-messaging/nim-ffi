//! Synchronous example: exercises a couple of round-trip methods and the
//! library-event listener API (typed + wildcard + remove).
//!
//! Run with: `cargo run --example main`

use my_timer::{decode_event_payload, EchoEvent, EchoRequest, ListenerHandle, MyTimerCtx, TimerConfig};
use std::os::raw::c_int;
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    mpsc, Arc,
};
use std::time::Duration;

fn main() -> Result<(), String> {
    let ctx = MyTimerCtx::create(
        TimerConfig {
            name: "rust-sync-demo".into(),
        },
        Duration::from_secs(5),
    )?;
    println!("[1] Context created");

    let version = ctx.version()?;
    println!("[2] Version: {}", version);

    // ── Typed listener for `onEchoFired` ──────────────────────────────
    // The handler runs on the lib's dispatch thread; route the payload
    // back to main via an mpsc channel so we can print synchronously.
    let (tx, rx) = mpsc::channel::<EchoEvent>();
    let typed_handle: ListenerHandle = ctx.add_on_echo_fired_listener(move |evt: &EchoEvent| {
        let _ = tx.send(evt.clone());
    });

    // ── Wildcard listener (catch-all) ─────────────────────────────────
    // Receives every event with the wire `event_id` pre-extracted and
    // the raw CBOR envelope bytes. Dispatch on `event_id` and lift the
    // payload via `decode_event_payload::<T>` to avoid hand-rolled CBOR.
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

    // Trigger an echo — fires `{.ffiEvent: "on_echo_fired".}` once.
    let echo = ctx.echo(EchoRequest {
        message: "sync-event-demo".into(),
        delay_ms: 1,
    })?;
    println!("[4] Echo response: echoed={}", echo.echoed);

    // Block for the typed event.
    match rx.recv_timeout(Duration::from_secs(2)) {
        Ok(evt) => println!(
            "[5] typed event onEchoFired: message={}, echo_count={}, wildcard_hits={}",
            evt.message,
            evt.echo_count,
            wildcard_hits.load(Ordering::SeqCst)
        ),
        Err(e) => return Err(format!("event never arrived: {}", e)),
    }

    // Drop the typed listener — a second echo only reaches the wildcard.
    let removed = ctx.remove_event_listener(typed_handle);
    assert!(removed, "remove_event_listener should report true");

    ctx.echo(EchoRequest {
        message: "after-remove".into(),
        delay_ms: 1,
    })?;
    // Give the lib thread a beat to deliver to the wildcard.
    std::thread::sleep(Duration::from_millis(50));
    println!(
        "[6] after remove: wildcard_hits={} (typed listener silent)",
        wildcard_hits.load(Ordering::SeqCst)
    );

    ctx.remove_event_listener(wildcard_handle);
    println!("Done.");
    Ok(())
}
