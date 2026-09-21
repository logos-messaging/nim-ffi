//! Synchronous example: exercises the typed per-event listener API, a blocking
//! call made from inside a listener, concurrent callers and a refused request.
//!
//! Run with: `cargo run --example sync_main`

use my_timer::{EchoEvent, EchoRequest, MyTimerCtx, TimerConfig};
use std::sync::{mpsc, Arc};
use std::time::Duration;

fn main() -> Result<(), String> {
    // `myTimerLibVersion` is {.ffiStatic.}: an associated fn, no ctx needed.
    println!("lib version: {}", MyTimerCtx::lib_version(Duration::from_secs(5))?);

    let ctx = Arc::new(MyTimerCtx::create(
        TimerConfig { name: "rust-sync-demo".into() },
        Duration::from_secs(5),
    )?);

    // Closure runs on the ctx's dispatch thread; forward to `main` via mpsc and recv_timeout below.
    let (tx, rx) = mpsc::channel::<EchoEvent>();
    let typed_handle = ctx.add_on_echo_fired_listener(move |evt: &EchoEvent| {
        let _ = tx.send(evt.clone());
    });

    // Liveness and the end of the context arrive through the same dispatch thread.
    ctx.add_not_responding_listener(|reason| eprintln!("my_timer is not responding (reason {reason})"));
    let (closed_tx, closed_rx) = mpsc::channel::<(bool, String)>();
    ctx.add_closed_listener(move |ok, reason| {
        let _ = closed_tx.send((ok, reason.to_string()));
    });

    ctx.echo(EchoRequest { message: "sync-event-demo".into(), delay_ms: 1 })?;

    match rx.recv_timeout(Duration::from_secs(2)) {
        Ok(evt) => println!("typed onEchoFired: message={}, echo_count={}", evt.message, evt.echo_count),
        Err(e) => return Err(format!("event never arrived: {}", e)),
    }

    ctx.remove_event_listener(typed_handle);

    // A listener runs on the dispatch thread, the one that delivers replies. A blocking
    // call from inside it still works: it dispatches the context until its reply arrives.
    // `Weak`, because the context owns its listeners: an `Arc` would keep it alive forever.
    let (version_tx, version_rx) = mpsc::channel::<Result<String, String>>();
    let weak = Arc::downgrade(&ctx);
    let in_listener = ctx.add_on_echo_fired_listener(move |_evt: &EchoEvent| {
        if let Some(ctx) = weak.upgrade() {
            let _ = version_tx.send(ctx.version());
        }
    });
    ctx.echo(EchoRequest { message: "call-from-listener".into(), delay_ms: 1 })?;
    match version_rx.recv_timeout(Duration::from_secs(2)) {
        Ok(version) => println!("version, asked from inside a listener: {}", version?),
        Err(e) => return Err(format!("the listener's call never returned: {}", e)),
    }
    ctx.remove_event_listener(in_listener);

    // Any number of threads may call at once; each gets the reply to its own request.
    let callers: Vec<_> = (0..8)
        .map(|i| {
            let ctx = ctx.clone();
            std::thread::spawn(move || {
                let message = format!("caller-{i}");
                let reply = ctx.echo(EchoRequest { message: message.clone(), delay_ms: 10 })?;
                if reply.echoed != message {
                    return Err(format!("caller {i} got the reply of {}", reply.echoed));
                }
                Ok(())
            })
        })
        .collect();
    for caller in callers {
        caller.join().map_err(|_| "a caller panicked".to_string())??;
    }
    println!("8 concurrent callers each got their own reply");

    // The library refuses a request over its payload cap: the call returns the
    // reason at once, and the context keeps working.
    match ctx.echo(EchoRequest { message: "x".repeat(9 * 1024 * 1024), delay_ms: 0 }) {
        Ok(_) => return Err("an oversized request was accepted".into()),
        Err(e) => println!("refused: {e}"),
    }
    // A handler's own error comes back the same way, as the reply.
    match ctx.echo(EchoRequest { message: "too slow".into(), delay_ms: 60_000 }) {
        Ok(_) => return Err("an over-long delay was accepted".into()),
        Err(e) => println!("rejected: {e}"),
    }
    println!("still working: version {}", ctx.version()?);

    // Dropping the ctx destroys it and joins the dispatch thread, so `Closed` has been delivered by then.
    drop(ctx);
    match closed_rx.try_recv() {
        Ok((ok, reason)) => println!("closed: ok={ok} reason={reason:?}"),
        Err(e) => return Err(format!("closed never arrived: {}", e)),
    }

    // The static call above started the static context; this stops it.
    if !MyTimerCtx::shutdown() {
        return Err("shutdown left a context running".into());
    }
    Ok(())
}
