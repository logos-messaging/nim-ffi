# IPC example — the library serves *itself* over CBOR (chronos)

When a caller lives in the **same process** as the library it uses the native
ABI (zero serialization). When it lives in a **different process** — possibly on
a different machine — there is no shared address space, so requests must be
serialized. That is what **CBOR** is for: *native locally, CBOR for IPC.*

This example puts the socket server **inside the library**. With
`-d:ffiIpcServe`, `libmy_timer` gains `serve.nim`, which:

- runs a chronos socket server, and
- for each request, **decodes CBOR at the socket edge and calls the library's
  own async procs directly** — a plain in-process call, native, with no
  serialization between the socket layer and the logic, and no FFI boundary or
  callback bridge inside the server. The server *is* the library.

```
remote client ──CBOR over socket──▶ serve loop ──direct Nim call──▶ timer procs
              (inter-process)                   (in-process, zero-serialization)
```

It speaks CBOR (not the native struct ABI) at the wire because over a socket the
data is serialized regardless — a native ABI would only move the decode and add
marshalling for no gain. CBOR-on-the-wire / direct-call-in-process is the right
shape for a relay.

## Files

| File | Role |
|------|------|
| `serve.nim` | Compiled into `libmy_timer` under `-d:ffiIpcServe`; the chronos server + `my_timer_serve(address)`. |
| `serve_host.nim` | Tiny host that links the library and starts the server. |
| `client.nim` | Lib-free chronos client (builds CBOR requests, reads replies). |

The wire framing (network byte order, so endianness never matters):

```
request:  [u32 method_len][method][u32 payload_len][cbor payload]
response: [i32 ret       ][u32 resp_len][cbor response]
```

## Run

It builds and runs on **Linux, macOS and Windows** (TCP is the portable
transport; `unix:<path>` also works on POSIX).

```sh
# one-command, asserted round-trip over loopback TCP (this is what CI runs):
nimble test_ipc
```

Or by hand, from the repo root:

```sh
ext=$(case "$(uname -s)" in Darwin) echo dylib;; *) echo so;; esac)
nim c --app:lib --noMain --nimMainPrefix:libmy_timer -d:ffiIpcServe \
  -o:examples/timer/ipc_chronos/libmy_timer.$ext examples/timer/timer.nim
nim c --passL:-Lexamples/timer/ipc_chronos --passL:-lmy_timer \
  --passL:-Wl,-rpath,"$PWD/examples/timer/ipc_chronos" \
  -o:examples/timer/ipc_chronos/serve_host examples/timer/ipc_chronos/serve_host.nim
nim c -o:examples/timer/ipc_chronos/client examples/timer/ipc_chronos/client.nim

examples/timer/ipc_chronos/serve_host tcp:127.0.0.1:9099 &
examples/timer/ipc_chronos/client     tcp:127.0.0.1:9099
```

Expected client output:

```
[client] version    = nim-timer v0.1.0
[client] echo.echoed= hello over the wire
[client] echo.timer = ipc-server     # the server's own context state round-tripped
```

## Notes

- The serve loop fires the library's events (e.g. `echo` → `onEchoFired`); it
  installs an empty event registry on its thread so dispatch finds zero
  listeners. Delivering events to remote clients is separate, future work.
- A remote client needs only a CBOR codec, not the compiled library — it can be
  written in any language. `client.nim` is the Nim reference.
