# Rust bindings — native (generated)

**Generated** native (zero-serialization) Rust crate for the timer library — the
Rust counterpart of `c_bindings` / `go_bindings` / `cpp_native_bindings`, and the
native sibling of the CBOR crate in [`../rust_bindings`](../rust_bindings).

| File | Description |
|------|-------------|
| `src/ffi.rs` | `#[repr(C)]` POD mirrors + `extern "C"` native entry points. |
| `src/types.rs` | Idiomatic structs + `to_c`/`from_c` (a holder owns the `CString`s for the call). |
| `src/api.rs` | `<Lib>Node` — methods marshal typed args in / read typed struct returns out; blocking via `std::sync::mpsc`. No CBOR. |
| `examples/demo.rs` | A small consumer. |

```rust
let node = MyTimerNode::new(TimerConfig { name: "my-app".into() })?;
println!("{}", node.version()?);
let r = node.echo(EchoRequest { message: "hello".into(), delay_ms: 5 })?;   // -> EchoResponse
```

Regenerate with `nimble genbindings_rust_native`.

## Status

Requests are fully supported: scalar / string / bool / float / nested struct
**and now sequences (`Vec`) and optionals (`Option`)** — create, version, echo,
complex, schedule all generate and round-trip typed values. `to_c` returns a
holder that owns the `CString`s and C-array backing (heap, so the C struct's raw
pointers stay valid across the move and for the call).

Still to come: native typed events and the native-bare / `_cbor` reconciliation.
Linking is left to the consumer (`-L <dir> -l my_timer` + rpath, as in
`examples/demo.rs`); a build.rs that compiles the dylib can be added later.
