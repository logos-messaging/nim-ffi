# IPC example — CBOR over a socket (cross-process / cross-machine)

The native ABI in [`../c_bindings`](../c_bindings) is for callers that link the
library **in the same process**. When the caller lives in a *different process*
— possibly on a *different machine* — there is no shared address space, so the
request has to be serialized. That is exactly what the **CBOR ABI**
(`<name>_cbor`, declared in `my_timer_cbor.h`) is for.

> **The CBOR ABI exists solely for inter-process communication.** If you are in
> the same process as the library, use the native ABI instead — serializing to
> CBOR and decoding it on a sibling thread is pure overhead when you already
> share memory. Both ABIs ship in the same library; pick per call site.

This example wires that ABI across a socket:

- **`server`** links `libmy_timer`, creates one timer context at startup, and
  serves method calls. It owns the `ctx` pointer — which is meaningful only
  inside its own address space and never travels over the wire.
- **`client`** does **not** link the library. It only builds CBOR request
  payloads (with the `FfiCbor` encoder bundled in `my_timer_cbor.h`) and parses
  CBOR responses. It could be written in any language with a CBOR codec.

```
 client process                         server process
 ┌─────────────┐   method + CBOR req    ┌──────────────────────────┐
 │  build CBOR │ ─────────────────────▶ │ my_timer_<m>_cbor(ctx,…)  │
 │  parse CBOR │ ◀───────────────────── │ libmy_timer  (FFI thread) │
 └─────────────┘   ret + CBOR response  └──────────────────────────┘
```

Wire framing (network byte order, so endianness never matters):

```
request:  [u32 method_len][method][u32 payload_len][cbor payload]
response: [i32 ret       ][u32 resp_len][cbor/raw response]
```

## Build

```sh
cd examples/timer/ipc
make           # builds libmy_timer + server + client
```

## Scenario A — same machine (two processes, AF_UNIX)

A Unix-domain socket is the right transport when both ends are on one host.

```sh
make demo                       # starts the server, runs the client, cleans up
```

or manually, in two terminals:

```sh
# terminal 1
./server --unix /tmp/my_timer.sock

# terminal 2
./client --unix /tmp/my_timer.sock
```

Expected client output:

```
[client] version    = nim-timer v0.1.0
[client] echo.echoed= hello over the wire
[client] echo.timer = ipc-server        # proves the server's context state round-tripped
```

## Scenario B — separate machines (AF_INET / TCP)

The exact same binaries, over TCP. Run the server on host A and the client on
host B; only the address changes.

```sh
# host A (the server, e.g. 192.168.1.20)
./server --tcp 0.0.0.0 9099

# host B (the client)
./client --tcp 192.168.1.20 9099
```

Because the wire is self-describing CBOR with network-byte-order framing, the
two machines may differ in OS, architecture, or endianness. The client needs
only `my_timer_cbor.h` (or a CBOR library in its own language) — not the
compiled timer library.

## Notes

- Every `{.ffi.}` call is dispatched on the library's FFI thread, so the server
  blocks on a condvar-backed callback for each result before replying.
- The client demonstrates `version` (empty request → text response) and `echo`
  (nested request → `EchoResponse` map). `proto.h` includes a small CBOR reader
  to pull text fields out of the response map; a real client would use its
  language's CBOR library.
