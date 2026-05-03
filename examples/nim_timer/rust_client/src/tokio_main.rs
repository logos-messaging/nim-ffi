use nimtimer::{EchoRequest, NimTimerCtx, TimerConfig};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::task;

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() {
    let timeout = Duration::from_secs(5);

    let ctx = task::spawn_blocking(move || {
        NimTimerCtx::create(TimerConfig { name: "tokio-demo".into() }, timeout)
    })
    .await
    .expect("failed to join create task")
    .expect("nimtimer_create failed");

    let ctx = Arc::new(Mutex::new(ctx));

    let version = task::spawn_blocking({
        let ctx = Arc::clone(&ctx);
        move || {
            let ctx = ctx.lock().unwrap();
            ctx.version()
        }
    })
    .await
    .expect("failed to join version task")
    .expect("nimtimer_version failed");

    println!("[1] Tokio runtime started");
    println!("[2] Version: {version}");

    let req1 = EchoRequest {
        message: "hello from tokio".into(),
        delay_ms: 200,
    };
    let req2 = EchoRequest {
        message: "second tokio request".into(),
        delay_ms: 50,
    };

    let fut1 = task::spawn_blocking({
        let ctx = Arc::clone(&ctx);
        move || {
            let ctx = ctx.lock().unwrap();
            ctx.echo(req1)
        }
    });

    let fut2 = task::spawn_blocking({
        let ctx = Arc::clone(&ctx);
        move || {
            let ctx = ctx.lock().unwrap();
            ctx.echo(req2)
        }
    });

    let echo1 = fut1
        .await
        .expect("failed to join tokio blocking task")
        .expect("nimtimer_echo failed");
    let echo2 = fut2
        .await
        .expect("failed to join tokio blocking task")
        .expect("nimtimer_echo failed");

    println!("[3] Echo 1: echoed={}, timerName={}", echo1.echoed, echo1.timer_name);
    println!("[4] Echo 2: echoed={}, timerName={}", echo2.echoed, echo2.timer_name);

    println!("\nDone. Tokio runtime shut down.");
}
