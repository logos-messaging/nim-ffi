# C++ bindings — native (generated)

**Generated** native (zero-serialization) C++ bindings for the timer library —
the C++ counterpart of `c_bindings` / `go_bindings`. The CBOR C++ bindings live
in [`../cpp_bindings`](../cpp_bindings).

| File | Description |
|------|-------------|
| `my_timer_native.hpp` | Generated wrapper: a C++ struct + `toC`/`fromC` per `{.ffi.}` type, and a `My_timerNode` class whose methods marshal typed args into / read typed struct returns out of the native ABI — no CBOR. |
| `my_timer.h` | Native C header (structs + entry points) the `.hpp` includes. |
| `main.cpp`, `Makefile` | A driver + build. |

```cpp
my_timer::My_timerNode node(my_timer::TimerConfig{"my-app"});
std::cout << node.Version();
auto r = node.Echo(my_timer::EchoRequest{"hello", 5});  // -> EchoResponse
std::cout << r.echoed << " / " << r.timerName;
```

Regenerate with `nimble genbindings_cpp_native` (from the repo root).

## Build & run

```sh
cd examples/timer/cpp_native_bindings
make run
```

## Status

First cut. Methods whose params/returns use only scalar / string / bool /
nested-struct fields are generated (create, version, echo). Methods using
**sequences or optionals** are emitted as `// SKIPPED` for now (complex,
schedule) — those plus **native typed events** are the next increments. The
native-bare / `_cbor` filename reconciliation (matching the C headers) is also a
follow-up; today this emits `my_timer_native.hpp` so it coexists with the CBOR
`my_timer.hpp`.
