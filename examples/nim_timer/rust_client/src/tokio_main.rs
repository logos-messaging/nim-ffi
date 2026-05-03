use nimtimer::{EchoRequest, NimTimerCtx, TimerConfig};

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let ctx = NimTimerCtx::new_async(TimerConfig { name: "tokio-demo".into() }).await?;

    let version = ctx.version_async().await?;
    println!("[1] Tokio runtime started");
    println!("[2] Version: {version}");

    let echo1 = ctx
        .echo_async(EchoRequest {
            message: "hello from tokio".into(),
            delay_ms: 200,
        })
        .await?;

    let echo2 = ctx
        .echo_async(EchoRequest {
            message: "second tokio request".into(),
            delay_ms: 50,
        })
        .await?;

    println!("[3] Echo 1: echoed={}, timerName={}", echo1.echoed, echo1.timer_name);
    println!("[4] Echo 2: echoed={}, timerName={}", echo2.echoed, echo2.timer_name);

    println!("\nDone. Tokio runtime shut down.");
    Ok(())
}
