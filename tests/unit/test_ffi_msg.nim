## The message `<lib>_poll` hands out: the parts a foreign binding pins down at
## compile time.

import std/[sets, strutils]
import unittest2
import ../../ffi/ffi_msg

suite "the wire name is carried as a number":
  test "nameId is the FNV-1a 64 the generators bake into the bindings":
    # Pinned: a binding compares these constants against what the library sends,
    # so a change here silently stops every event of an older host from matching.
    check nameId("") == 0xcbf29ce484222325'u64
    check nameId("on_echo_fired") == 0xcdfdf536356b2a2b'u64
    check nameIdLiteral("on_echo_fired") == "0xcdfdf536356b2a2b"

  test "the names a library uses do not collide":
    var seen = initHashSet[uint64]()
    for name in ["on_echo_fired", "on_job_scheduled", "onEchoFired", "echo", "e"]:
      check not seen.containsOrIncl(nameId(name))

suite "the struct is declared once per translation unit":
  test "the C declaration is guarded and lists every kind":
    let decl = cMsgDecl()
    check decl.startsWith("#ifndef NIMFFI_MSG_DECLARED")
    check decl.endsWith("#endif /* NIMFFI_MSG_DECLARED */")
    for k in MsgKinds:
      check decl.contains("#define NIMFFI_MSG_" & k.name & " " & $k.value)

  test "the Rust declaration matches it kind for kind":
    let decl = rustMsgDecl()
    check decl.contains("#[repr(C)]")
    for k in MsgKinds:
      let want = "pub const NIMFFI_MSG_" & k.name & ": u32 = " & $k.value & ";"
      check decl.contains(want)
