use std::time::Duration;
use my_timer::{
    EchoRequest, JobSpec, MyTimerCtx, RetryPolicy, ScheduleConfig, TimerConfig,
};

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let ctx = MyTimerCtx::new_async(
        TimerConfig { name: "tokio-demo".into() },
        Duration::from_secs(30),
    ).await?;

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

    // ── A call with three complex parameters ────────────────────────────
    // The generated `*_async` method returns a Future, so a tokio-driven
    // caller just `.await`s it like any other async fn. The macro packs
    // `job`, `retry`, and `schedule` into a single CBOR envelope on the wire.
    let schedule = ctx
        .schedule_async(
            JobSpec {
                name: "hourly-sync".into(),
                payload: vec!["sync".into(), "users".into()],
                priority: 5,
            },
            RetryPolicy {
                max_attempts: 5,
                backoff_ms: 250,
                retry_on: vec!["timeout".into()],
            },
            ScheduleConfig {
                start_at_ms: 500,
                interval_ms: 3_600_000,
                jitter: None,
            },
        )
        .await?;
    println!(
        "[5] Schedule (3 complex params, awaited): jobId={}, willRunCount={}, firstRunAtMs={}",
        schedule.job_id, schedule.will_run_count, schedule.first_run_at_ms,
    );

    println!("\nDone. Tokio runtime shut down.");
    Ok(())
}
