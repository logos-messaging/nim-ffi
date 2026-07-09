//! End-to-end tests for the generated Rust `my_timer` bindings.
//!
//! Mirrors the C and C++ e2e suites: constructor, methods, nested seq/Option
//! payloads, multi-parameter requests, the error channel and the typed event
//! listener. Both generated call surfaces are covered — the blocking wrappers
//! (`ctx.echo(..)`) and the tokio-async wrappers (`ctx.echo_async(..).await`).

use std::sync::mpsc;
use std::time::Duration;

use my_timer::{
    ComplexRequest, EchoEvent, EchoRequest, JobSpec, MyTimerCtx, RetryPolicy, ScheduleConfig,
    TimerConfig,
};

const TIMEOUT: Duration = Duration::from_secs(5);

fn make_ctx(name: &str) -> MyTimerCtx {
    MyTimerCtx::create(TimerConfig { name: name.into() }, TIMEOUT).expect("create failed")
}

// ── Blocking path ───────────────────────────────────────────────────────────

#[test]
fn create_and_version_blocking() {
    let ctx = make_ctx("version-blocking");
    assert_eq!(ctx.version().expect("version failed"), "nim-timer v0.1.0");
}

#[test]
fn echo_round_trips_message_and_timer_name() {
    let ctx = make_ctx("echo-ctx");
    let resp = ctx
        .echo(EchoRequest {
            message: "hello".into(),
            delay_ms: 10,
        })
        .expect("echo failed");
    assert_eq!(resp.echoed, "hello");
    assert_eq!(resp.timer_name, "echo-ctx");
}

#[test]
fn echo_honours_delay() {
    let ctx = make_ctx("echo-delay");
    let start = std::time::Instant::now();
    let resp = ctx
        .echo(EchoRequest {
            message: "waited".into(),
            delay_ms: 150,
        })
        .expect("echo failed");
    let elapsed = start.elapsed();
    assert_eq!(resp.echoed, "waited");
    assert!(
        elapsed >= Duration::from_millis(130),
        "echo returned too early: {elapsed:?}"
    );
}

#[test]
fn complex_with_optional_note_present() {
    let ctx = make_ctx("complex-1");
    let resp = ctx
        .complex(ComplexRequest {
            messages: vec![
                EchoRequest {
                    message: "a".into(),
                    delay_ms: 1,
                },
                EchoRequest {
                    message: "b".into(),
                    delay_ms: 2,
                },
            ],
            tags: vec!["tag1".into(), "tag2".into()],
            note: Some("a note".into()),
            retries: Some(2),
        })
        .expect("complex failed");
    assert_eq!(resp.item_count, 2);
    assert!(resp.has_note);
    assert!(
        resp.summary.contains("note=a note"),
        "summary: {}",
        resp.summary
    );
    assert!(
        resp.summary.contains("retries=2"),
        "summary: {}",
        resp.summary
    );
}

#[test]
fn complex_with_optional_note_absent() {
    let ctx = make_ctx("complex-2");
    let resp = ctx
        .complex(ComplexRequest {
            messages: vec![],
            tags: vec![],
            note: None,
            retries: None,
        })
        .expect("complex failed");
    assert_eq!(resp.item_count, 0);
    assert!(!resp.has_note);
    assert!(
        resp.summary.contains("note=<none>"),
        "summary: {}",
        resp.summary
    );
}

#[test]
fn schedule_three_complex_params() {
    let ctx = make_ctx("schedule-ctx");
    let resp = ctx
        .schedule(
            JobSpec {
                name: "nightly-rollup".into(),
                payload: vec!["rollup".into(), "v2".into()],
                priority: 10,
            },
            RetryPolicy {
                max_attempts: 3,
                backoff_ms: 500,
                retry_on: vec!["timeout".into(), "5xx".into()],
            },
            ScheduleConfig {
                start_at_ms: 1_000,
                interval_ms: 15_000,
                jitter: Some(250),
            },
        )
        .expect("schedule failed");
    assert_eq!(resp.job_id, "schedule-ctx:nightly-rollup");
    assert!(resp.will_run_count >= 1);
}

// The error channel: an empty JobSpec.name makes the handler return
// err("job name must not be empty"), surfaced as an Err(String).
#[test]
fn schedule_empty_name_is_an_error() {
    let ctx = make_ctx("schedule-err");
    let res = ctx.schedule(
        JobSpec {
            name: "".into(),
            payload: vec![],
            priority: 0,
        },
        RetryPolicy {
            max_attempts: 1,
            backoff_ms: 10,
            retry_on: vec![],
        },
        ScheduleConfig {
            start_at_ms: 0,
            interval_ms: 0,
            jitter: None,
        },
    );
    let err = res.expect_err("expected schedule to fail on empty job name");
    assert_eq!(err, "job name must not be empty");
}

// Independent contexts keep their own state; an error on one must not poison it.
#[test]
fn independent_contexts_keep_their_own_state() {
    let a = make_ctx("alpha");
    let b = make_ctx("beta");
    assert_eq!(
        a.echo(EchoRequest {
            message: "x".into(),
            delay_ms: 5
        })
        .unwrap()
        .timer_name,
        "alpha"
    );
    assert_eq!(
        b.echo(EchoRequest {
            message: "x".into(),
            delay_ms: 5
        })
        .unwrap()
        .timer_name,
        "beta"
    );

    // Trigger an error on `a`, then prove both contexts still work.
    let _ = a.schedule(
        JobSpec {
            name: "".into(),
            payload: vec![],
            priority: 0,
        },
        RetryPolicy {
            max_attempts: 1,
            backoff_ms: 10,
            retry_on: vec![],
        },
        ScheduleConfig {
            start_at_ms: 0,
            interval_ms: 0,
            jitter: None,
        },
    );
    assert_eq!(
        a.echo(EchoRequest {
            message: "again".into(),
            delay_ms: 0
        })
        .unwrap()
        .echoed,
        "again"
    );
    assert_eq!(
        b.echo(EchoRequest {
            message: "still".into(),
            delay_ms: 0
        })
        .unwrap()
        .timer_name,
        "beta"
    );
}

// ── Async path ──────────────────────────────────────────────────────────────

#[tokio::test]
async fn create_and_version_async() {
    let ctx = MyTimerCtx::new_async(
        TimerConfig {
            name: "version-async".into(),
        },
        TIMEOUT,
    )
    .await
    .expect("new_async failed");
    assert_eq!(
        ctx.version_async().await.expect("version_async failed"),
        "nim-timer v0.1.0"
    );
}

#[tokio::test]
async fn concurrent_async_calls_are_independent() {
    let ctx = make_ctx("concurrent");
    let (r1, r2, r3) = tokio::join!(
        ctx.echo_async(EchoRequest {
            message: "one".into(),
            delay_ms: 80
        }),
        ctx.echo_async(EchoRequest {
            message: "two".into(),
            delay_ms: 40
        }),
        ctx.echo_async(EchoRequest {
            message: "three".into(),
            delay_ms: 20
        }),
    );
    assert_eq!(r1.unwrap().echoed, "one");
    assert_eq!(r2.unwrap().echoed, "two");
    assert_eq!(r3.unwrap().echoed, "three");
}

// Chained async calls A->B->C preserve ordering and payload across hops.
#[tokio::test]
async fn triple_pipeline_async() {
    let ctx = make_ctx("pipeline");
    let a = ctx
        .echo_async(EchoRequest {
            message: "A".into(),
            delay_ms: 20,
        })
        .await
        .unwrap();
    let b = ctx
        .echo_async(EchoRequest {
            message: format!("{}->B", a.echoed),
            delay_ms: 10,
        })
        .await
        .unwrap();
    let c = ctx
        .echo_async(EchoRequest {
            message: format!("{}->C", b.echoed),
            delay_ms: 5,
        })
        .await
        .unwrap();
    assert_eq!(c.echoed, "A->B->C");
    assert_eq!(c.timer_name, "pipeline");
}

// ── Typed events ────────────────────────────────────────────────────────────

#[test]
fn typed_event_fires_after_echo() {
    let ctx = make_ctx("events");
    let (tx, rx) = mpsc::channel::<EchoEvent>();
    let handle = ctx.add_on_echo_fired_listener(move |evt: &EchoEvent| {
        let _ = tx.send(evt.clone());
    });
    assert_ne!(handle.id, 0, "listener registration returned zero id");

    ctx.echo(EchoRequest {
        message: "event-msg".into(),
        delay_ms: 1,
    })
    .expect("echo failed");

    let evt = rx
        .recv_timeout(Duration::from_secs(2))
        .expect("event never arrived");
    assert_eq!(evt.message, "event-msg");
    assert_eq!(evt.echo_count, 1);

    assert!(ctx.remove_event_listener(handle));
    assert!(
        !ctx.remove_event_listener(handle),
        "double remove must report false"
    );
}
