use my_timer_native::*;
fn main() {
    let node = MyTimerNode::new(TimerConfig { name: "rust-native-gen".into() }).unwrap();
    println!("version: {}", node.version().unwrap());
    let r = node.echo(EchoRequest { message: "hello from generated Rust".into(), delay_ms: 5 }).unwrap();
    println!("echo: echoed={} timer_name={}", r.echoed, r.timer_name);
}
