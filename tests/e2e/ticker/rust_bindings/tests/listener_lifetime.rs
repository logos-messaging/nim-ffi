//! Listener box lifetime against tests/e2e/ticker: under ASan a box freed too early is a use-after-free.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, OnceLock, Weak};
use std::thread;
use std::time::{Duration, Instant};
use ticker::{ListenerHandle, Tick, TickerConfig, TickerCtx};

const CALL_TIMEOUT: Duration = Duration::from_secs(5);
const WAIT_LIMIT: Duration = Duration::from_secs(5);
const TICK_INTERVAL_MS: i64 = 1;
const TAG_LEN: usize = 64;
const TICKS_BEFORE_DESTROY: usize = 5;
const TICKS_TO_OBSERVE: usize = 20;
const NEVER_ISSUED_ID: u64 = 1_000_000;
const HOST_THREADS: usize = 4;
const CYCLES_PER_THREAD: usize = 200;
const RACE_WINDOW: Duration = Duration::from_millis(50);

fn make_ctx(stall_teardown: bool) -> Arc<TickerCtx> {
    Arc::new(TickerCtx::create(TickerConfig { stall_teardown }, CALL_TIMEOUT).unwrap())
}

fn wait_for_ticks(ticks: &AtomicUsize, at_least: usize) -> bool {
    let deadline = Instant::now() + WAIT_LIMIT;
    while ticks.load(Ordering::SeqCst) < at_least {
        if Instant::now() > deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(1));
    }
    true
}

#[test]
fn listener_removes_itself() {
    let ctx = make_ctx(false);
    let weak: Weak<TickerCtx> = Arc::downgrade(&ctx);
    let handle: Arc<OnceLock<ListenerHandle>> = Arc::new(OnceLock::new());
    let fired = AtomicBool::new(false);
    let (tx, rx) = mpsc::channel::<usize>();
    // `tag` lives in the box: reading it after the remove reads freed memory unless the drop waits for the callback.
    let tag = "x".repeat(TAG_LEN);
    let self_handle = handle.clone();
    let id = ctx.add_on_tick_listener(move |_: &Tick| {
        if fired.swap(true, Ordering::SeqCst) {
            return;
        }
        let ctx = weak.upgrade().unwrap();
        assert!(ctx.remove_event_listener(*self_handle.get().unwrap()));
        let _ = tx.send(tag.len());
    });
    handle.set(id).unwrap();
    ctx.start(TICK_INTERVAL_MS).unwrap();

    assert_eq!(rx.recv_timeout(WAIT_LIMIT).unwrap(), TAG_LEN);
}

#[test]
fn listener_removes_sibling() {
    let ctx = make_ctx(false);
    let weak: Weak<TickerCtx> = Arc::downgrade(&ctx);
    let sibling: Arc<OnceLock<ListenerHandle>> = Arc::new(OnceLock::new());
    let removed = Arc::new(AtomicBool::new(false));
    let calls_after_remove = Arc::new(AtomicUsize::new(0));
    let ticks = Arc::new(AtomicUsize::new(0));

    let (s, r, t) = (sibling.clone(), removed.clone(), ticks.clone());
    ctx.add_on_tick_listener(move |_: &Tick| {
        if !r.swap(true, Ordering::SeqCst) {
            let ctx = weak.upgrade().unwrap();
            assert!(ctx.remove_event_listener(*s.get().unwrap()));
        }
        t.fetch_add(1, Ordering::SeqCst);
    });
    let (r, c, tag) = (
        removed.clone(),
        calls_after_remove.clone(),
        "y".repeat(TAG_LEN),
    );
    let id = ctx.add_on_tick_listener(move |_: &Tick| {
        if r.load(Ordering::SeqCst) && tag.len() == TAG_LEN {
            c.fetch_add(1, Ordering::SeqCst);
        }
    });
    sibling.set(id).unwrap();
    ctx.start(TICK_INTERVAL_MS).unwrap();

    assert!(wait_for_ticks(&ticks, TICKS_TO_OBSERVE));
    assert_eq!(calls_after_remove.load(Ordering::SeqCst), 0);
}

#[test]
fn stalled_destroy_keeps_boxes_alive() {
    let ctx = make_ctx(true);
    let ticks = Arc::new(AtomicUsize::new(0));
    let (t, tag) = (ticks.clone(), "z".repeat(TAG_LEN));
    ctx.add_on_tick_listener(move |_: &Tick| {
        if tag.len() == TAG_LEN {
            t.fetch_add(1, Ordering::SeqCst);
        }
    });
    ctx.start(TICK_INTERVAL_MS).unwrap();
    assert!(wait_for_ticks(&ticks, TICKS_BEFORE_DESTROY));

    drop(ctx);

    let after_destroy = ticks.load(Ordering::SeqCst);
    assert!(
        wait_for_ticks(&ticks, after_destroy + TICKS_TO_OBSERVE),
        "the loop stopped firing"
    );
}

#[test]
fn remove_returns_false_for_unknown_and_removed_handles() {
    let ctx = make_ctx(false);
    let handle = ctx.add_on_tick_listener(|_: &Tick| {});

    assert!(!ctx.remove_event_listener(ListenerHandle { id: 0 }));
    assert!(!ctx.remove_event_listener(ListenerHandle {
        id: NEVER_ISSUED_ID
    }));
    assert!(ctx.remove_event_listener(handle));
    assert!(!ctx.remove_event_listener(handle));
}

#[test]
fn host_threads_add_and_remove_while_callbacks_fire() {
    let ctx = make_ctx(false);
    let ticks = Arc::new(AtomicUsize::new(0));
    let failed_removes = Arc::new(AtomicUsize::new(0));
    let zero_ids = Arc::new(AtomicUsize::new(0));
    let t = ticks.clone();
    ctx.add_on_tick_listener(move |_: &Tick| {
        t.fetch_add(1, Ordering::SeqCst);
    });
    ctx.start(TICK_INTERVAL_MS).unwrap();
    assert!(wait_for_ticks(&ticks, 1));

    let workers: Vec<_> = (0..HOST_THREADS)
        .map(|_| {
            let (ctx, failed, zeros) = (ctx.clone(), failed_removes.clone(), zero_ids.clone());
            thread::spawn(move || {
                for _ in 0..CYCLES_PER_THREAD {
                    let tag = "h".repeat(TAG_LEN);
                    let h =
                        ctx.add_on_tick_listener(move |_: &Tick| assert_eq!(tag.len(), TAG_LEN));
                    if h.id == 0 {
                        zeros.fetch_add(1, Ordering::SeqCst);
                    } else if !ctx.remove_event_listener(h) {
                        failed.fetch_add(1, Ordering::SeqCst);
                    }
                }
            })
        })
        .collect();
    for w in workers {
        w.join().unwrap();
    }

    assert_eq!(zero_ids.load(Ordering::SeqCst), 0);
    assert_eq!(failed_removes.load(Ordering::SeqCst), 0);
    let seen = ticks.load(Ordering::SeqCst);
    assert!(
        wait_for_ticks(&ticks, seen + TICKS_TO_OBSERVE),
        "the loop stopped firing"
    );
}

#[test]
fn remove_from_other_context_waits_for_running_callback() {
    let ctx_a = make_ctx(false);
    let ctx_b = make_ctx(false);
    let a_inside = Arc::new(AtomicBool::new(false));
    let a_fired = AtomicBool::new(false);
    let b_removing = Arc::new(AtomicBool::new(false));
    let (tx, rx) = mpsc::channel::<usize>();

    let (inside, removing, tag) = (a_inside.clone(), b_removing.clone(), "v".repeat(TAG_LEN));
    let victim = ctx_a.add_on_tick_listener(move |_: &Tick| {
        if a_fired.swap(true, Ordering::SeqCst) {
            return;
        }
        inside.store(true, Ordering::SeqCst);
        let deadline = Instant::now() + WAIT_LIMIT;
        while !removing.load(Ordering::SeqCst) && Instant::now() < deadline {
            thread::yield_now();
        }
        // A remove that does not wait for this callback drops `tag` inside this window.
        thread::sleep(RACE_WINDOW);
        let _ = tx.send(tag.len());
    });
    let weak_a: Weak<TickerCtx> = Arc::downgrade(&ctx_a);
    let (inside, removing) = (a_inside.clone(), b_removing.clone());
    ctx_b.add_on_tick_listener(move |_: &Tick| {
        if !inside.load(Ordering::SeqCst) || removing.swap(true, Ordering::SeqCst) {
            return;
        }
        assert!(weak_a.upgrade().unwrap().remove_event_listener(victim));
    });
    ctx_a.start(TICK_INTERVAL_MS).unwrap();
    ctx_b.start(TICK_INTERVAL_MS).unwrap();

    assert_eq!(rx.recv_timeout(WAIT_LIMIT * 2).unwrap(), TAG_LEN);
}
