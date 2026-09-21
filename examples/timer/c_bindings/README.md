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

## Requests

The library never calls into your program and the binding starts no thread. A
request returns as soon as it is queued; its reply waits inside the library
until you take it out. Every request comes in two shapes.

**Sequential program** — the `_sync` form submits, then dispatches the context until
its own reply arrives. You own what it hands out:

```c
EchoRequest req = {"hello", 50};
EchoResponse res;
char* err = NULL;
int rc = my_timer_ctx_echo_sync(ctx, &req, &res, &err, /*timeout_ms=*/5000, &handlers);
if (rc == NIMFFI_RET_OK) {
    printf("echoed: %s\n", res.echoed);
    my_timer_free_EchoResponse(&res);
} else {
    /* NIMFFI_RET_ERR: the library's error. NIMFFI_RET_TIMEOUT, NIMFFI_RET_CLOSED,
     * or the code of a refused submit. */
    fprintf(stderr, "echo failed (%d): %s\n", rc, err ? err : "");
    free(err);
}
```

Every other message that arrives meanwhile (an event, a liveness report) goes
to `handlers`, which may be `NULL`. After a timeout the late reply is dropped.

**Program with a loop** — the asynchronous form takes a typed reply callback,
which runs later, inside `my_timer_ctx_dispatch_next()`, on the thread that dispatches:

```c
static void on_echo(int ret, const EchoResponse* reply,
                    const char* err, void* user_data) {
    if (ret != NIMFFI_RET_OK) { /* err is set, reply is NULL */ return; }
    printf("echoed: %s\n", reply->echoed);
}
...
int rc = my_timer_ctx_echo(ctx, &req, on_echo, /*user_data=*/NULL);
if (rc != NIMFFI_RET_OK) {
    /* Refused: on_echo will never run. */
    fprintf(stderr, "refused (%d): %s\n", rc, my_timer_last_error());
}
```

The constructor follows the same split: `my_timer_ctx_create_sync()`, or
`my_timer_ctx_create()`, which hands the context out at once so that you can
dispatch it for the constructor's reply. Static requests (`my_timer_static_*`) need
no context; their replies arrive on the library's static context, dispatched with
`my_timer_static_dispatch_next()` (the `_sync` forms do it for you).

See `main.c` for the full pattern.

## Events and the dispatch thread

Events, liveness reports and the end of the context are queued inside the
library like replies, and come out of the same loop:

```c
static void on_echo_fired(const EchoEvent* ev, void* user_data) {
    printf("fired: %s\n", ev->message);
}
...
MyTimerHandlers handlers = {0};          /* a NULL entry ignores that message */
handlers.on_echo_fired = on_echo_fired;
for (;;) {
    int rc = my_timer_ctx_dispatch_next(ctx, /*timeout_ms=*/100, &handlers);
    if (rc != NIMFFI_RET_OK && rc != NIMFFI_RET_TIMEOUT) break;
}
```

`MyTimerHandlers` in `my_timer.h` lists everything the library can send besides
replies. A host with an event loop of its own waits on
`my_timer_ctx_poll_fd(ctx)` instead (an epoll fd on Linux, a kqueue fd on
macOS/BSD, an Event `HANDLE` on Windows), then dispatches with a timeout of 0 until
`NIMFFI_RET_TIMEOUT`, and closes the handle when done.

## Threads

A context of this binding is single-threaded by design: submit and dispatch it from
one thread, or hold one lock around both. `my_timer_ctx_destroy()` settles the
requests still waiting with `NIMFFI_RET_CLOSED`; never call it from inside a
handler or a reply callback. A host that wants another threading model uses the
raw exports (`my_timer_<proc>()`, `my_timer_poll()`) with the typed decoders
`my_timer_decode_<proc>_reply()` and `my_timer_decode_<event>()`.

## Memory Ownership

- Request-side strings/sequences are *borrowed* — pass a plain `const char*`
  (a literal is fine); the binding never frees them.
- Reply values and error strings passed into a reply callback are **owned by
  the binding** and valid only for the duration of that callback. The caller
  never frees them — copy out anything you need to keep before returning.
- An event handed to a `MyTimerHandlers` entry follows the same rule.
- What a `_sync` call hands out, and what you decode yourself with
  `my_timer_decode_<event>()` or `my_timer_decode_<proc>_reply()`, is yours:
  release it with the `my_timer_free_<Type>()` helper of its type (a bare
  string with `free()`). An error text handed out through a `char**` is yours
  too; release it with `free()`.
- A `MyTimerCtx*` is yours from the moment the constructor hands it out,
  whatever the constructor's reply says; release it with
  `my_timer_ctx_destroy()`.

## Do Not Edit

The generated files in this folder are overwritten each time
`nimble genbindings_c` runs. Any manual changes will be lost.
