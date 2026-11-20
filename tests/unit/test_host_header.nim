## `host/nim_ffi.h` is a hand copy of the codes and message kinds a host reads;
## it must say what ffi/ret_codes.nim and ffi/ffi_msg.nim say.

import std/[strutils, strformat]
import unittest2
import ffi/[ret_codes, ffi_msg]

const header = staticRead("../../host/nim_ffi.h")

suite "host/nim_ffi.h matches the Nim sources":
  test "every return code is defined with its value":
    for code in RetCodes:
      check header.contains(&"#define NIMFFI_RET_{code.name} {code.value}\n")

  test "every message kind is defined with its value":
    for kind in MsgKinds:
      check header.contains(&"#define NIMFFI_MSG_{kind.name} {kind.value} ")
