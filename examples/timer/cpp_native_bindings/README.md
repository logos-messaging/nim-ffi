# C++ bindings — native (generated)

**Generated** native (zero-serialization) C++ bindings for the timer library —
the C++ counterpart of `c_bindings` / `go_bindings`. The CBOR C++ bindings live
in [`../cpp_bindings`](../cpp_bindings).

| File | Description |
|------|-------------|
| `my_timer.hpp` | Generated wrapper: a C++ struct + `toC`/`fromC` per `{.ffi.}` type, and a `My_timerNode` class whose methods marshal typed args into / read typed struct returns out of the native ABI — no CBOR. |
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

Requests are fully supported: scalar / string / bool / nested struct **and now
sequences (`std::vector`) and optionals (`std::optional`)** — create, version,
echo, complex, schedule all generate and round-trip typed values (ASAN-clean).
`toC` uses a holder that owns the C-array backing while string pointers borrow
the C++ argument (valid for the call's duration; the library deep-copies).

Native typed events are supported too: `node.On<Event>(handler)` registers a
native listener and the typed payload arrives via `fromC` (no CBOR).

The native header is the bare `my_timer.hpp` and the CBOR counterpart is
`my_timer_cbor.hpp` — matching the C headers (`my_timer.h` / `my_timer_cbor.h`)
and the `<name>` / `<name>_cbor` symbol naming.
