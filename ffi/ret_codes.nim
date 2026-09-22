## Status codes of the C ABI, and the foreign copies emitted from them. Every
## generator renders its block from `RetCodes`, so the C, C++ and Rust bindings
## cannot drift from the Nim runtime.

type RetCode* = object
  name*: string
  value*: cint

const RET_OK*: cint = 0
const RET_ERR*: cint = 1
const RET_MISSING_CALLBACK*: cint = 2
const RET_STALE_WARN*: cint = 3
  ## Non-terminal: fires every `StaleWarnInterval` with `msg` = elapsed ms as decimal ASCII, and a terminal code always follows.

const RET_TIMEOUT*: cint = 4 ## `<lib>_poll`: nothing arrived in time.
const RET_CLOSED*: cint = 5 ## `<lib>_poll`: the context was destroyed or recycled.
const RET_INVALID_CTX*: cint = 6 ## The token is nil, forged or names a past owner.
const RET_BUSY*: cint = 7 ## `<lib>_poll`: another thread is polling this context.
const RET_QUEUE_FULL*: cint = 8
  ## A request was refused: the request queue is full, or too many are unanswered.
const RET_TOO_LARGE*: cint = 9 ## A request was refused: its payload is over the cap.

const RetCodes* = [
  RetCode(name: "OK", value: RET_OK),
  RetCode(name: "ERR", value: RET_ERR),
  RetCode(name: "MISSING_CALLBACK", value: RET_MISSING_CALLBACK),
  RetCode(name: "STALE_WARN", value: RET_STALE_WARN),
  RetCode(name: "TIMEOUT", value: RET_TIMEOUT),
  RetCode(name: "CLOSED", value: RET_CLOSED),
  RetCode(name: "INVALID_CTX", value: RET_INVALID_CTX),
  RetCode(name: "BUSY", value: RET_BUSY),
  RetCode(name: "QUEUE_FULL", value: RET_QUEUE_FULL),
  RetCode(name: "TOO_LARGE", value: RET_TOO_LARGE),
]

func cRetCodeDefines*(): string =
  var lines = ""
  for code in RetCodes:
    if lines.len > 0:
      lines.add("\n")
    lines.add("#define NIMFFI_RET_" & code.name & " " & $code.value)

  return lines

func rustRetCodeConsts*(): string =
  var lines = ""
  for code in RetCodes:
    if lines.len > 0:
      lines.add("\n")
    lines.add("#[allow(dead_code)]\n")
    lines.add("const NIMFFI_RET_" & code.name & ": c_int = " & $code.value & ";")

  return lines
