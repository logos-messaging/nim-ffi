## Third example library used by the cross-library stress tests.
##
## Unlike `timer` and `echoer`, the aggregator is **stateful**: each
## `record` call mutates the library object's internal sequence and
## counter. The `Aggregator` type is declared as a `ref object` so the
## mutation persists across calls — `ctx.myLib[]` holds the ref and
## subsequent calls dereference the same heap object.
##
## Exercises across the framework:
##   - stateful library type (ref object) under the FFI thread serialiser
##   - seq[string] in both input and output struct fields (wire-side
##     items+len pair)
##   - error paths from inside an .ffi. body (empty entry → err(...))

import ffi, chronos

type Aggregator = ref object
  prefix: string
  counter: int
  history: seq[string]

declareLibrary("aggregator", Aggregator)

type AggregatorConfig {.ffi.} = object
  prefix: string

type RecordRequest {.ffi.} = object
  entry: string

type RecordResponse {.ffi.} = object
  ## Index of the just-recorded entry (0-based) plus the running count
  ## and the prefix of the context that handled it. Lets host-side
  ## stress tests assert per-context isolation.
  index: int
  count: int
  prefix: string

type SummarizeResponse {.ffi.} = object
  count: int
  entries: seq[string]
  prefix: string

proc aggregator_create*(
    config: AggregatorConfig
): Future[Result[Aggregator, string]] {.ffiCtor.} =
  return ok(Aggregator(prefix: config.prefix, counter: 0, history: @[]))

proc aggregator_record*(
    agg: Aggregator, req: RecordRequest
): Future[Result[RecordResponse, string]] {.ffi.} =
  ## Append `req.entry` to the in-memory history. Empty entries are
  ## rejected so the error-isolation stress test can assert that an
  ## error here does not poison other contexts or other libraries.
  if req.entry.len == 0:
    return err("entry must not be empty")
  let idx = agg.history.len
  agg.history.add(req.entry)
  agg.counter += 1
  return ok(RecordResponse(index: idx, count: agg.counter, prefix: agg.prefix))

proc aggregator_summarize*(
    agg: Aggregator
): Future[Result[SummarizeResponse, string]] {.ffi.} =
  return ok(SummarizeResponse(
    count: agg.counter,
    entries: agg.history,
    prefix: agg.prefix,
  ))

proc aggregator_destroy*(agg: Aggregator) {.ffiDtor.} =
  discard

genBindings()
