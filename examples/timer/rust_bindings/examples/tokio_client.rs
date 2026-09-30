//! Tokio (async) example: the `_async` API over the same consts, `version` and three-parameter `schedule` calls as `sync_client.rs`.
//!
//! Run with: `cargo run --example tokio_client`

use std::time::Duration;
use my_timer::{
    EchoRequest, JobPriority, JobSpec, MyTimerCtx, RetryPolicy, ScheduleConfig,
    TimerConfig, TIMER_VERSION,
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
    assert_eq!(version, TIMER_VERSION);

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
    assert_eq!(echo1.echoed, "hello from tokio");
    assert_eq!(echo1.timer_name, "tokio-demo");
    assert_eq!(echo2.echoed, "second tokio request");
    assert_eq!(echo2.timer_name, "tokio-demo");

    // ── A call with three complex parameters ────────────────────────────
    // The generated `*_async` method returns a Future, so a tokio-driven
    // caller just `.await`s it like any other async fn. The macro packs
    // `job`, `retry`, and `schedule` into a single CBOR envelope on the wire.
    let schedule = ctx
        .schedule_async(
            JobSpec {
                name: "hourly-sync".into(),
                payload: vec!["sync".into(), "users".into()],
                priority: JobPriority::JpNormal,
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
        "[5] Schedule (3 complex params, awaited): jobId={}, willRunCount={}, firstRunAtMs={}, priority={:?}",
        schedule.job_id, schedule.will_run_count, schedule.first_run_at_ms, schedule.priority,
    );
    assert_eq!(schedule.job_id, "tokio-demo:hourly-sync");
    assert_eq!(schedule.will_run_count, 1);
    assert_eq!(schedule.first_run_at_ms, 500);
    assert_eq!(schedule.effective_backoff_ms, 250);
    assert_eq!(schedule.priority, JobPriority::JpNormal);

    println!("\nDone. Tokio runtime shut down.");
    Ok(())
}
