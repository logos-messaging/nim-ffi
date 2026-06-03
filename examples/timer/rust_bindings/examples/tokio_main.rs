//! Tokio (async) example: same shape as `main.rs` but exercises the async `_async` API
//! and bridges library events into a tokio mpsc for async consumption.
//!
//! Run with: `cargo run --example tokio_main`

use my_timer::{EchoEvent, EchoRequest, MyTimerCtx, TimerConfig};
use std::time::Duration;
use tokio::sync::mpsc;

#[tokio::main]
async fn main() -> Result<(), String> {
    let ctx = MyTimerCtx::new_async(
        TimerConfig { name: "rust-tokio-demo".into() },
        Duration::from_secs(5),
    )
    .await?;

    // Handler fires on the lib's dispatch thread (outside the tokio runtime); forward via tokio mpsc to await it below.
    let (typed_tx, mut typed_rx) = mpsc::unbounded_channel::<EchoEvent>();
    let typed_handle = ctx.add_on_echo_fired_listener(move |evt: &EchoEvent| {
        let _ = typed_tx.send(evt.clone());
    });

    ctx.echo_async(EchoRequest { message: "async-event-demo".into(), delay_ms: 1 })
        .await?;

    let evt = tokio::time::timeout(Duration::from_secs(2), typed_rx.recv())
        .await
        .map_err(|_| "event never arrived".to_string())?
        .ok_or_else(|| "typed channel closed".to_string())?;
    println!("typed onEchoFired: message={}, echo_count={}", evt.message, evt.echo_count);

    ctx.remove_event_listener(typed_handle);
    Ok(())
}
