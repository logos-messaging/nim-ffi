# Go (cgo) bindings — native (same-process) example

Generated cgo bindings for the timer library. The Go wrapper links the library
directly and calls the **native** C ABI, marshalling each `{.ffi.}` type from an
idiomatic Go struct into its flat C-POD form per call.

## Files

| File | Description |
|------|-------------|
| `my_timer.go` | Generated cgo package. One Go struct per `{.ffi.}` type plus a `toC()` marshaller; one method per `{.ffi.}` proc. |
| `my_timer.h` | Native C header (emitted alongside the `.go` so cgo's `#include` resolves locally). |
| `go.mod` | Makes the package an importable module. |
| `example/` | A runnable `main.go` that exercises the struct-param methods. |

Regenerate with `nimble genbindings_go` (from the repo root); the files here are
overwritten each time and `gofmt`-finalized.

## Mapping

| Nim (`{.ffi.}`) | Go |
|-----------------|-----|
| `string` | `string` |
| `int` / `int64` … | `int64` … |
| `bool` | `bool` |
| `seq[T]` | `[]T` |
| `Option[T]` / `Maybe[T]` | `*T` (nil = none) |
| nested `{.ffi.}` struct | nested Go struct |

Each call deep-copies its arguments across the FFI thread, so the Go-side C
allocations are freed (via `defer`) as soon as the call returns. String-returning
methods give back a Go `string`; **struct-returning methods give back a typed Go
struct** — the C-POD return is read into Go inside the result callback (delivered
via a `runtime/cgo.Handle`), so the caller never touches C memory.

## Build & run

```sh
cd examples/timer/go_bindings
make run
```

Expected output:

```
created timer
version: nim-timer v0.1.0
echo: echoed="hello from Go" timerName="go-native-demo"
complex: itemCount=2 hasNote=true summary="received 2 messages, note=a note, retries=3"
schedule: jobId="go-native-demo:nightly" willRunCount=12
done
```

`Echo`, `Complex` and `Schedule` take `{.ffi.}` structs, slices and optionals
directly and return typed Go structs — previously these procs were skipped by
the Go generator.

For the cross-process / cross-machine path (CBOR over a socket), see
[`../ipc`](../ipc); a Go client could speak the same wire protocol using any Go
CBOR library.
