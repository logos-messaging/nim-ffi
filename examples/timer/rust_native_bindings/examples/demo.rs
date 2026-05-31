use my_timer_native::*;
fn main() {
    let node = MyTimerNode::new(TimerConfig { name: "rust-native-gen".into() }).unwrap();
    println!("version: {}", node.version().unwrap());

    // Native typed event: echo fires on_echo_fired inline with a raw C-POD
    // EchoEvent payload, delivered straight to the closure (no CBOR decode).
    let h = node.add_on_echo_fired_listener(|e: &EchoEvent| {
        println!("event on_echo_fired: message={:?} echo_count={}", e.message, e.echo_count);
    });

    let r = node.echo(EchoRequest { message: "hello from generated Rust".into(), delay_ms: 5 }).unwrap();
    println!("echo: echoed={} timer_name={}", r.echoed, r.timer_name);
    println!("removed listener: {}", node.remove_event_listener(h));

    let c = node.complex(ComplexRequest {
        messages: vec![EchoRequest { message: "one".into(), delay_ms: 0 },
                       EchoRequest { message: "two".into(), delay_ms: 0 }],
        tags: vec!["a".into(), "b".into()],
        note: Some("a note".into()),
        retries: Some(3),
    }).unwrap();
    println!("complex: item_count={} has_note={} summary={:?}", c.item_count, c.has_note, c.summary);

    let s = node.schedule(
        JobSpec { name: "nightly".into(), payload: vec!["x".into()], priority: 5 },
        RetryPolicy { max_attempts: 3, backoff_ms: 100, retry_on: vec!["timeout".into()] },
        ScheduleConfig { start_at_ms: 1000, interval_ms: 5000, jitter: Some(50) },
    ).unwrap();
    println!("schedule: job_id={:?} will_run_count={}", s.job_id, s.will_run_count);
}
