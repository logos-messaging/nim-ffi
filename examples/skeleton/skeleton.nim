## Minimal nim-ffi library template. Copy this directory, rename every
## `skeleton` / `Skeleton` to your library's name (see README.md), and build
## from here instead of reverse-engineering the feature-tour examples/timer/.
## It wires up the four pieces every nim-ffi library needs — a constructor, one
## async method, a library-initiated event, and a destructor — and nothing else.

import ffi, chronos

# The FFI context owns exactly one of these, built by the {.ffiCtor.} and torn
# down by the {.ffiDtor.} below.
type Skeleton = object
  greeting: string # set at creation, read back in each response

# Names the library and its state object, and picks the wire format every
# {.ffi.} / {.ffiEvent.} inherits ("cbor" default; pass defaultABIFormat = "c"
# for the CBOR-free flat-struct ABI). Must precede every FFI annotation below.
declareLibrary("skeleton", Skeleton)

# Types crossing the boundary are plain objects annotated {.ffi.}; the generator
# emits a matching struct/class on the foreign side for each.
type SkeletonConfig {.ffi.} = object
  greeting: string

type HelloRequest {.ffi.} = object
  name: string

type HelloResponse {.ffi.} = object
  message: string

type HelloEvent {.ffi.} = object
  name: string

# A library-initiated event: call `onHello(...)` from any {.ffi.} handler to
# dispatch it to the foreign side's callback. The wire name (`on_hello`) is
# derived from the proc name; pass a string literal to override it.
proc onHello*(evt: HelloEvent) {.ffiEvent.}

# The constructor, called once from the foreign side. `err(msg)` here surfaces a
# construction failure; the async body may `await`.
proc skeletonCreate*(
    config: SkeletonConfig
): Future[Result[Skeleton, string]] {.ffiCtor.} =
  ok(Skeleton(greeting: config.greeting))

# A {.ffi.} method takes the state object first, may `await`, and returns
# Future[Result[T, string]].
proc skeletonHello*(
    skeleton: Skeleton, req: HelloRequest
): Future[Result[HelloResponse, string]] {.ffi.} =
  await sleepAsync(1.milliseconds)
  onHello(HelloEvent(name: req.name))
  ok(HelloResponse(message: skeleton.greeting & ", " & req.name & "!"))

proc skeleton_destroy*(skeleton: Skeleton) {.ffiDtor.} =
  discard

# genBindings() must be the LAST top-level call: each pragma above registers its
# proc/type into a compile-time registry that genBindings() reads to emit the
# bindings, so anything declared after it is silently missing. No-op unless
# -d:ffiGenBindings is set.
genBindings()
