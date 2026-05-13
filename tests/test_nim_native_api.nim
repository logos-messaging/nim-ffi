## Demonstrates the Nim-native side of the {.ffi.} / {.ffiCtor.} macros:
## every annotated proc remains callable from Nim with its declared signature
## (`Future[Result[T, string]]`), no callbacks or CBOR buffers involved. The
## C-exported wrapper exists in parallel as an overload distinguishable by
## arity — see `test_ffi_context.nim` for the C-shape callers.

import std/options
import unittest2
import results
import ../ffi

type Counter = object
  start: int

ffiType:
  type CounterConfig = object
    initial: int

ffiType:
  type IncRequest = object
    by: int

ffiType:
  type CounterState = object
    value: int

proc counter_create*(
    cfg: CounterConfig
): Future[Result[Counter, string]] {.ffiCtor.} =
  ## Async ctor body — exercises the chronos path on the FFI thread.
  await sleepAsync(1.milliseconds)
  return ok(Counter(start: cfg.initial))

proc counter_value*(
    c: Counter
): Future[Result[CounterState, string]] {.ffi.} =
  ## Sync body (no `await`); the Nim-facing wrapper still returns
  ## Future[Result[...]] so the source-level shape is preserved.
  return ok(CounterState(value: c.start))

proc counter_add*(
    c: Counter, req: IncRequest
): Future[Result[CounterState, string]] {.ffi.} =
  ## Async body with a real chronos yield.
  await sleepAsync(1.milliseconds)
  return ok(CounterState(value: c.start + req.by))

proc counter_compose*(
    c: Counter, a: int, b: int
): Future[Result[int, string]] {.ffi.} =
  ## Multiple primitive params plus a non-object return type.
  return ok(c.start + a + b)

proc counter_greet*(
    c: Counter, name: Option[string]
): Future[Result[string, string]] {.ffi.} =
  ## Exercises Option[T] param round-trip.
  let n = if name.isSome: name.get else: "anon"
  return ok("hello " & n & " (start=" & $c.start & ")")

proc counter_fail*(
    c: Counter, reason: string
): Future[Result[string, string]] {.ffi.} =
  ## Error path — the failure surfaces as Result.err on the caller side.
  return err("rejected: " & reason)

proc counter_chain*(
    c: Counter, steps: int
): Future[Result[CounterState, string]] {.ffi.} =
  ## Real async work: multiple awaits composing other {.ffi.} procs.
  ## Shows that the Nim-facing wrapper for an {.ffi.} proc is itself
  ## awaitable, so {.ffi.} procs can be composed naturally without ever
  ## touching the C-export shape.
  var current = c
  for i in 0 ..< steps:
    await sleepAsync(1.milliseconds)
    let stepRes = await counter_add(current, IncRequest(by: 1))
    if stepRes.isErr:
      return err(stepRes.error)
    current = Counter(start: stepRes.value.value)
  return ok(CounterState(value: current.start))

suite "Nim-native API for {.ffi.} / {.ffiCtor.}":
  test "ffiCtor returns the user-typed lib value":
    let res = waitFor counter_create(CounterConfig(initial: 7))
    check res.isOk
    check res.value.start == 7

  test "sync .ffi. body completes via Future[Result[T, string]]":
    let res = waitFor counter_value(Counter(start: 5))
    check res.isOk
    check res.value.value == 5

  test "async .ffi. body with await":
    let res = waitFor counter_add(Counter(start: 5), IncRequest(by: 3))
    check res.isOk
    check res.value.value == 8

  test "multiple primitive params":
    let res = waitFor counter_compose(Counter(start: 1), 2, 3)
    check res.isOk
    check res.value == 6

  test "Option[string] param round-trip — some":
    let res = waitFor counter_greet(Counter(start: 1), some("jamon"))
    check res.isOk
    check res.value == "hello jamon (start=1)"

  test "Option[string] param round-trip — none":
    let res = waitFor counter_greet(Counter(start: 2), none(string))
    check res.isOk
    check res.value == "hello anon (start=2)"

  test "error result propagates as Result.err":
    let res = waitFor counter_fail(Counter(start: 0), "out of cookies")
    check res.isErr
    check res.error == "rejected: out of cookies"

  test "async .ffi. body chains multiple awaits and composes other .ffi. procs":
    let res = waitFor counter_chain(Counter(start: 10), 4)
    check res.isOk
    check res.value.value == 14

  test "chain with 0 steps returns the input unchanged":
    let res = waitFor counter_chain(Counter(start: 42), 0)
    check res.isOk
    check res.value.value == 42
