//! Regressions for the PR #154 review findings at the Rust wrapper layer. Each test
//! failed before its fix; the comments say how.
//!
//! "Dropped" is observed without touching freed memory: every closure captures an
//! `Arc` token, the test keeps only a `Weak` to it, and the closure clones its probe
//! onto its own stack before doing anything that could drop its box.

use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::Duration;

use my_timer::{FetchHostClockCall, HostClock, MyTimerCtx, TimerConfig};

const CHILD_ENV: &str = "REVREG_CHILD";

fn make_ctx(name: &str) -> MyTimerCtx {
    MyTimerCtx::create(TimerConfig { name: name.into() }, Duration::from_secs(20))
        .expect("create failed")
}

#[derive(Default)]
struct Latch {
    state: Mutex<(bool, u32)>, // (open, entered)
    cv: Condvar,
}

impl Latch {
    fn enter_and_wait(&self) {
        let mut g = self.state.lock().unwrap();
        g.1 += 1;
        self.cv.notify_all();
        while !g.0 {
            g = self.cv.wait(g).unwrap();
        }
    }
    fn wait_entered(&self, n: u32) {
        let mut g = self.state.lock().unwrap();
        while g.1 < n {
            g = self.cv.wait(g).unwrap();
        }
    }
    fn release(&self) {
        self.state.lock().unwrap().0 = true;
        self.cv.notify_all();
    }
}

struct Probe {
    ctx: AtomicUsize, // *const MyTimerCtx; the ctx outlives every call that reads it
    capture: Mutex<Weak<()>>,
    latch: Latch,
    freed_while_running: AtomicI32, // -1 unset, 0 alive, 1 dropped
    done: AtomicBool,
}

impl Probe {
    fn new(ctx: &MyTimerCtx, token: &Arc<()>) -> Arc<Self> {
        Arc::new(Probe {
            ctx: AtomicUsize::new(ctx as *const MyTimerCtx as usize),
            capture: Mutex::new(Arc::downgrade(token)),
            latch: Latch::default(),
            freed_while_running: AtomicI32::new(-1),
            done: AtomicBool::new(false),
        })
    }
    fn ctx(&self) -> &MyTimerCtx {
        unsafe { &*(self.ctx.load(Ordering::SeqCst) as *const MyTimerCtx) }
    }
    fn record_capture(&self) {
        let dropped = self.capture.lock().unwrap().upgrade().is_none();
        self.freed_while_running.store(dropped as i32, Ordering::SeqCst);
    }
}

fn noop_impl(call: FetchHostClockCall, _: String) {
    call.reply(&HostClock { unix_ms: 0, zone: "UTC".into() });
}

/// Re-runs one test of this binary in a child with `CHILD_ENV=mode`.
fn run_child(test_name: &str, mode: &str) -> std::process::Output {
    Command::new(std::env::current_exe().unwrap())
        .args([test_name, "--exact", "--nocapture", "--test-threads=1"])
        .env(CHILD_ENV, mode)
        .output()
        .expect("spawn child")
}

// Review comment 4087687777, "the same happens when an impl replaces itself".
#[test]
fn self_replacement_keeps_the_running_closure_alive() {
    let ctx = make_ctx("find-self-replace");
    let token = Arc::new(());
    let probe = Probe::new(&ctx, &token);
    let (cap_token, cap_probe) = (token.clone(), probe.clone());
    assert!(ctx.set_fetch_host_clock_impl(move |call, _| {
        let _keep = &cap_token;
        let p = cap_probe.clone(); // the capture itself may be dropped below
        p.ctx().set_fetch_host_clock_impl(noop_impl);
        p.record_capture();
        call.reply(&HostClock { unix_ms: 1, zone: "UTC".into() });
        p.done.store(true, Ordering::SeqCst);
    }));
    drop(token); // only the box holds it now

    ctx.host_clock().expect("host_clock");
    assert!(probe.done.load(Ordering::SeqCst));
    // Before the fix, 1: `*slot = Some(owned)` dropped the box this closure runs from.
    assert_eq!(probe.freed_while_running.load(Ordering::SeqCst), 0);
}

// Found in the walkthrough: `Drop` destroys the ctx, then drops the box even when
// destroy had to leak a worker that is still inside the closure.
#[test]
fn drop_with_a_stuck_impl_keeps_its_closure_alive() {
    let ctx = make_ctx("find-teardown");
    let token = Arc::new(());
    let probe = Probe::new(&ctx, &token);
    let (cap_token, cap_probe) = (token.clone(), probe.clone());
    assert!(ctx.set_fetch_host_clock_impl(move |call, _| {
        let _keep = &cap_token;
        let p = cap_probe.clone();
        call.reply(&HostClock { unix_ms: 1, zone: "UTC".into() }); // answer, then stay stuck
        p.latch.enter_and_wait();
        p.record_capture();
        p.done.store(true, Ordering::SeqCst);
    }));
    drop(token);

    ctx.host_clock().expect("host_clock");
    probe.latch.wait_entered(1);
    drop(ctx); // the recycle quarantines the slot, then the box is dropped
    probe.latch.release();
    for _ in 0..1000 {
        if probe.done.load(Ordering::SeqCst) {
            break;
        }
        std::thread::sleep(Duration::from_millis(1));
    }
    assert!(probe.done.load(Ordering::SeqCst));
    // Before the fix, 1: the leaked worker resumed inside a dropped closure.
    assert_eq!(probe.freed_while_running.load(Ordering::SeqCst), 0);
}

// Review comment 4087688037: a panic must not unwind across `extern "C"`.
#[test]
fn panicking_impl_fails_the_call_instead_of_aborting() {
    if std::env::var(CHILD_ENV).as_deref() == Ok("panic") {
        let ctx = make_ctx("find-panic");
        ctx.set_fetch_host_clock_impl(|_, _| panic!("boom"));
        let r = ctx.host_clock();
        std::process::exit(if r.is_err() { 0 } else { 1 });
    }
    let out = run_child("panicking_impl_fails_the_call_instead_of_aborting", "panic");
    // Before the fix, it aborted (SIGABRT): "panic in a function that cannot unwind".
    assert!(
        out.status.success(),
        "child: {:?}\n{}",
        out.status,
        String::from_utf8_lossy(&out.stderr)
    );
}

// Review comment 4087687900: the FFI call happens before the slot lock, so two
// racing setters can leave Nim holding a box Rust already dropped.
#[test]
fn concurrent_sets_leave_nim_and_the_wrapper_agreeing() {
    if std::env::var(CHILD_ENV).as_deref() == Ok("set_race") {
        let ctx = make_ctx("find-set-race");
        let mismatches = AtomicUsize::new(0);
        for _round in 0..200 {
            // id -> the closure's token; the closure answers with its own id.
            let live: Arc<Mutex<Vec<(i64, Weak<()>)>>> = Arc::default();
            std::thread::scope(|s| {
                for t in 0..4 {
                    let (ctx, live) = (&ctx, live.clone());
                    s.spawn(move || {
                        for i in 0..50 {
                            let token = Arc::new(());
                            let id = (t * 50 + i) as i64;
                            live.lock().unwrap().push((id, Arc::downgrade(&token)));
                            ctx.set_fetch_host_clock_impl(move |call, _| {
                                let _keep = &token;
                                call.reply(&HostClock { unix_ms: id, zone: "UTC".into() });
                            });
                        }
                    });
                }
            });
            // The closure Nim runs must be one that is still alive. Before the fix Nim
            // could run a box Rust had dropped (SIGSEGV, or a stale id).
            let answer = ctx.host_clock().expect("host_clock after the race");
            let id: i64 = answer.rsplit('@').next().unwrap().parse().unwrap();
            let owned = live
                .lock()
                .unwrap()
                .iter()
                .any(|(i, w)| *i == id && w.upgrade().is_some());
            if !owned {
                mismatches.fetch_add(1, Ordering::SeqCst);
            }
        }
        let m = mismatches.load(Ordering::SeqCst);
        eprintln!("rounds with a wrapper/Nim mismatch: {m}/200");
        std::process::exit(if m == 0 { 0 } else { 1 });
    }
    let out = run_child("concurrent_sets_leave_nim_and_the_wrapper_agreeing", "set_race");
    assert!(
        out.status.success(),
        "child: {:?}\n{}",
        out.status,
        String::from_utf8_lossy(&out.stderr)
    );
}
