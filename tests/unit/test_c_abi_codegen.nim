## Unit tests for the CBOR-free (`abi = c`) C binding shape. Drives
## generateCAbiLibHeader against a synthetic registry (no macro pipeline, no
## files written), asserting on the emitted text.

import std/strutils
import unittest2
import ffi/codegen/[meta, c]

proc field(n, t: string): FFIFieldMeta =
  FFIFieldMeta(name: n, typeName: t)

proc param(n, t: string, isPtr = false): FFIParamMeta =
  FFIParamMeta(name: n, typeName: t, isPtr: isPtr)

suite "generateCAbiLibHeader":
  setup:
    let types = @[
      FFITypeMeta(
        name: "EchoRequest",
        fields: @[field("message", "string"), field("delayMs", "int")],
      ),
      FFITypeMeta(name: "EchoResponse", fields: @[field("echoed", "string")]),
      FFITypeMeta(
        name: "ComplexRequest",
        fields:
          @[field("messages", "seq[EchoRequest]"), field("note", "Option[string]")],
      ),
    ]
    let procs = @[
      FFIProcMeta(
        procName: "timer_create",
        libName: "timer",
        kind: FFIKind.CTOR,
        libTypeName: "Timer",
        extraParams: @[param("config", "EchoRequest")],
        returnTypeName: "Timer",
      ),
      FFIProcMeta(
        procName: "timer_echo",
        libName: "timer",
        kind: FFIKind.FFI,
        libTypeName: "Timer",
        extraParams: @[param("req", "ComplexRequest")],
        returnTypeName: "EchoResponse",
      ),
      FFIProcMeta(
        procName: "timer_version",
        libName: "timer",
        kind: FFIKind.FFI,
        libTypeName: "Timer",
        extraParams: @[],
        returnTypeName: "string",
      ),
      FFIProcMeta(
        procName: "timer_destroy",
        libName: "timer",
        kind: FFIKind.DTOR,
        libTypeName: "Timer",
        extraParams: @[],
        returnTypeName: "",
      ),
    ]
    let header = generateCAbiLibHeader(procs, types, "timer")

  test "the header is self-contained and links no CBOR":
    check "#include <stdint.h>" in header
    check "nim_ffi_cbor.h" notin header
    check "CborError" notin header
    check "tinycbor" notin header.toLowerAscii()

  test "abi = c wire structs mirror the _CWire layout":
    # string -> const char*; POD unchanged.
    check "const char* message;" in header
    check "int64_t delayMs;" in header
    # seq[T] -> <wireElem>* <f>_items + ptrdiff_t <f>_len (two fields).
    check "EchoRequest* messages_items;" in header
    check "ptrdiff_t messages_len;" in header
    # Option[string] -> pointer to the element wire type (NULL = none).
    check "const char** note;" in header
    # nested {.ffi.} type rides as its _CWire struct.
    check "EchoRequest config;" in header

  test "per-proc Req envelopes are emitted as structs":
    check "} TimerEchoReq;" in header
    check "} TimerCreateCtorReq;" in header

  test "exported symbols use the _CWire structs, not CBOR buffers":
    check "req_cbor" notin header
    check "const TimerEchoReq* req" in header
    check "void* timer_create(const TimerCreateCtorReq* req," in header
    check "int timer_destroy(void* ctx);" in header

  test "object returns hand back a const struct pointer; string returns a cstring":
    check "typedef void (*TimerEchoReplyFn)(int err_code, const EchoResponse* reply," in
      header
    check "typedef void (*TimerVersionReplyFn)(int err_code, const char* reply," in
      header

  test "constructor delivers its context address through a raw string callback":
    check "TimerCreateRawFn)(int err_code, const char* ctx_addr," in header
    check "strtoull(ctx_addr" in header

  test "high-level context wrapper is emitted":
    check "} TimerCtx;" in header
    check "timer_ctx_create(" in header
    check "timer_ctx_echo(" in header
    check "timer_ctx_version(" in header
    check "timer_ctx_destroy(" in header

  test "events are rejected (CBOR-only for now)":
    expect ValueError:
      discard generateCAbiLibHeader(
        procs,
        types,
        "timer",
        @[
          FFIEventMeta(
            wireName: "on_tick",
            nimProcName: "onTick",
            libName: "timer",
            payloadTypeName: "EchoResponse",
          )
        ],
      )
