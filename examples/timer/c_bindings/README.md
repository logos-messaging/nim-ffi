# C Bindings for nim-timer

## Purpose

This folder contains **auto-generated C bindings** for the `my_timer` Nim
library. It is generated from `../timer.nim` and provides:

- `my_timer.h`: header-only C binding (`MyTimerCtx` + `my_timer_ctx_*` API)
- `main.c`: example executable demonstrating how to use the bindings
- `CMakeLists.txt`: build configuration that compiles the Nim library, the
  vendored TinyCBOR, and the C example

The bindings speak CBOR on the wire (the same format as the Rust and C++
backends) using the TinyCBOR copy vendored at
`ffi/codegen/templates/cpp/vendor/tinycbor`.

## How It's Generated

Regenerate these bindings by running from the repository root:

```sh
nimble genbindings_c
```

This invokes the Nim compiler with `-d:targetLang=c`, triggering
`genBindings(...)` in `timer.nim`, which reads the compile-time FFI registries
and emits the binding files.

## Building the Example

```sh
cd examples/timer/c_bindings
cmake -S . -B build
cmake --build build
./build/my_timer_example
```

## Asynchronous API

Every method and the constructor take a typed **result callback** and return
immediately. The callback fires exactly once — synchronously if the request
fails to even submit, otherwise from the Nim dispatch thread when the reply
arrives:

```c
static void on_echo(int err_code, const EchoResponse* reply,
                    const char* err_msg, void* user_data) {
    if (err_code != 0) { /* err_msg is set, reply is NULL */ return; }
    printf("echoed: %s\n", reply->echoed);
}
...
my_timer_ctx_echo(ctx, &req, on_echo, /*user_data=*/NULL);
```

See `main.c` for the full pattern, including a small `wait_done()` poll helper
that turns each async call back into a sequential step.

## Events

The library calls no event callback and the binding starts no thread. Events,
liveness reports and the end of the context are queued inside the library, and
the host takes them out on a thread of its choice:

```c
static void on_echo_fired(const EchoEvent* ev, void* user_data) {
    printf("fired: %s\n", ev->message);
}
...
MyTimerHandlers handlers = {0};          /* a NULL entry ignores that message */
handlers.on_echo_fired = on_echo_fired;
for (;;) {
    int rc = my_timer_ctx_pump_once(ctx, /*timeout_ms=*/100, &handlers);
    if (rc != NIMFFI_RET_OK && rc != NIMFFI_RET_TIMEOUT) break;
}
```

`MyTimerHandlers` in `my_timer.h` lists everything the library can send. A host
with an event loop of its own waits on `my_timer_ctx_poll_fd(ctx)` instead (an
epoll fd on Linux, a kqueue fd on macOS/BSD, an Event `HANDLE` on Windows), then
pumps with a timeout of 0 until `NIMFFI_RET_TIMEOUT`, and closes the handle when
done. Stop pumping a context before `my_timer_ctx_destroy()`.

## Memory Ownership

- Request-side strings/sequences are *borrowed* — pass a plain `const char*`
  (a literal is fine); the binding never frees them.
- Reply values and error strings passed into a result callback are **owned by
  the binding** and valid only for the duration of that callback. The caller
  never frees them — copy out anything you need to keep before returning.
- An event handed to a `MyTimerHandlers` entry follows the same rule. A value
  you decode yourself with `my_timer_decode_<event>()` is yours to release with
  the `my_timer_free_<Type>()` helper of its type.
- A `MyTimerCtx*` delivered to the constructor callback is the exception:
  ownership transfers to you, and you release it with `my_timer_ctx_destroy()`.

## Do Not Edit

The generated files in this folder are overwritten each time
`nimble genbindings_c` runs. Any manual changes will be lost.
