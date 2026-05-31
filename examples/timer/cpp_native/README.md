# C++ example — native (same-process)

A C++ program that links the timer library directly and calls its **native**
(zero-serialization) C ABI, with an idiomatic RAII wrapper. Struct returns come
back as typed C structs read in the callback.

```cpp
mytimer::TimerNode node("my-app");
std::cout << node.version();            // "nim-timer v0.1.0"
auto r = node.echo("hello", /*delayMs=*/5);
std::cout << r.echoed << " / " << r.timerName;
```

## Native vs CBOR C++

This repository ships **two** C++ examples, matching the two ABIs:

| Example | ABI | Use it for |
|---------|-----|------------|
| **`cpp_native/`** (this one) | native `<name>` | **Same-process / local**. Passes flat C structs by value, zero serialization. |
| [`../cpp_bindings/`](../cpp_bindings) | CBOR `<name>_cbor` (tinycbor) | **Inter-process communication**, where the request must be serialized to cross the boundary anyway. |

In one address space the CBOR round-trip is pure overhead, so prefer this native
path locally; reach for the CBOR bindings only when you actually cross a
process/machine boundary (see also [`../ipc`](../ipc)).

## Build & run

```sh
cd examples/timer/cpp_native
make run
```

This compiles `libmy_timer.{dylib,so}` and runs `./example`. Each call is
dispatched on the library's background FFI thread; the wrapper blocks on a
`std::future` until the result callback fires. A struct return (`EchoResponse`)
is delivered as a `const EchoResponse*` in the callback — valid only for the
callback's lifetime, so the wrapper copies its fields out before returning.

The native header comes from [`../c_bindings/my_timer.h`](../c_bindings) (the C
and C++ native examples share it); regenerate it with `nimble genbindings_c`.
