## Result-callback status codes. One definition: the Nim constants below and
## every generated foreign copy (C, C++, Rust) are emitted from `ffiRetCodes`.

type FFIRetCode* = object
  name*: string
  value*: cint

const RET_OK*: cint = 0
const RET_ERR*: cint = 1
const RET_MISSING_CALLBACK*: cint = 2
const RET_STALE_WARN*: cint = 3
  ## Non-terminal: fires every `StaleWarnInterval` with `msg` = elapsed ms as decimal ASCII, always followed by a terminal code.

const ffiRetCodes* = [
  FFIRetCode(name: "OK", value: RET_OK),
  FFIRetCode(name: "ERR", value: RET_ERR),
  FFIRetCode(name: "MISSING_CALLBACK", value: RET_MISSING_CALLBACK),
  FFIRetCode(name: "STALE_WARN", value: RET_STALE_WARN),
]
