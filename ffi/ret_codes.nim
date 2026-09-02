## Result-callback status codes, and the foreign copies emitted from them. Every
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

const RetCodes* = [
  RetCode(name: "OK", value: RET_OK),
  RetCode(name: "ERR", value: RET_ERR),
  RetCode(name: "MISSING_CALLBACK", value: RET_MISSING_CALLBACK),
  RetCode(name: "STALE_WARN", value: RET_STALE_WARN),
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
