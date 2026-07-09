# C Bindings for nim-timer

## Purpose

This folder contains **auto-generated C bindings** for the `my_timer` Nim
library. It is generated from `../timer.nim` and provides:

- `my_timer.h`: header-only C binding (`MyTimerCtx` + `my_timer_ctx_*` API)
- `nim_ffi_prelude.h` / `nim_ffi_cbor.h` / `nim_ffi_sync.h`: shared, library-
  agnostic headers (owned string/byte types, leaf CBOR codecs, and the blocking
  `_sync` call helper)
- `main.c`: example executable demonstrating how to use the bindings
- `CMakeLists.txt`: build configuration that compiles the Nim library, the
  vendored TinyCBOR, and the C example

The bindings speak CBOR on the wire (the same format as the Rust and C++
backends) using the TinyCBOR copy vendored at
`ffi/codegen/templates/cpp/vendor/tinycbor`.

## How It's Generated

Regenerate these bindings by running from the parent directory:

```sh
cd examples/timer
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

## Blocking API (`_sync`)

Every method and the constructor also get a blocking `_sync` variant. It
submits the request, waits up to `timeout_ms` for the reply, deep-copies the
result into a caller-owned out-param and returns 0 — or fills `err_buf` and
returns non-zero. This is what `main.c` uses:

```c
EchoResponse resp = {0};
char err[256];
if (my_timer_ctx_echo_sync(ctx, &req, &resp, err, sizeof(err), 5000) != 0) {
    fprintf(stderr, "echo failed: %s\n", err);
    return 1;
}
printf("echoed: %s\n", resp.echoed.data);
my_timer_free_EchoResponse(&resp); /* release the owned reply */
```

The out-param is yours: release any owned reply fields (strings, sequences)
with the generated `my_timer_free_<Type>()` helper — or `nimffi_free_str` for a
bare string reply.

## Asynchronous API

Every method and the constructor also take a typed **result callback** and
return immediately. The callback fires exactly once — synchronously if the
request fails to even submit, otherwise from the Nim dispatch thread when the
reply arrives:

```c
static void on_echo(int err_code, const EchoResponse* reply,
                    const char* err_msg, void* user_data) {
    if (err_code != 0) { /* err_msg is set, reply is NULL */ return; }
    printf("echoed: %s\n", reply->echoed.data);
}
...
my_timer_ctx_echo(ctx, &req, on_echo, /*user_data=*/NULL);
```

Library-initiated **events** are always asynchronous — they arrive on the Nim
dispatch thread via `my_timer_ctx_add_on_<event>_listener`.

## Memory Ownership

- Request-side strings/sequences are *borrowed* — wrap C strings with
  `nimffi_str(...)`; the binding never frees them.
- A `_sync` out-param is **owned by the caller** on success — release owned
  fields with the generated `my_timer_free_<Type>()` helper.
- Reply values and error strings passed into an *async* result callback are
  **owned by the binding** and valid only for the duration of that callback.
  The caller never frees them — copy out anything you need before returning.
- A `MyTimerCtx*` (from `_sync`'s out-param or the constructor callback) is
  yours either way: release it with `my_timer_ctx_destroy()`.

## Do Not Edit

The generated files in this folder are overwritten each time
`nimble genbindings_c` runs. Any manual changes will be lost.
