## Unit tests for the CBOR-free (`abi = c`) C binding shape: drives
## generateCAbiLibHeader against a synthetic registry, asserting on the text.

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
        procName: "timer_add",
        libName: "timer",
        kind: FFIKind.FFI,
        libTypeName: "Timer",
        extraParams: @[param("a", "int"), param("b", "int32")],
        returnTypeName: "int",
        scalarFastPath: true,
      ),
      FFIProcMeta(
        procName: "timer_name",
        libName: "timer",
        kind: FFIKind.FFI,
        libTypeName: "Timer",
        extraParams: @[],
        returnTypeName: "string",
        scalarFastPath: true,
      ),
      FFIProcMeta(
        procName: "timer_ratio",
        libName: "timer",
        kind: FFIKind.FFI,
        libTypeName: "Timer",
        extraParams: @[param("enabled", "bool")],
        returnTypeName: "float32",
        scalarFastPath: true,
      ),
      FFIProcMeta(
        procName: "timer_parse",
        libName: "timer",
        kind: FFIKind.STATIC,
        libTypeName: "Timer",
        extraParams: @[param("req", "EchoRequest")],
        returnTypeName: "EchoResponse",
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

  test "the context destructor propagates the destructor's status code":
    check(
      """
static inline int timer_ctx_destroy(TimerCtx* ctx) {
    if (!ctx) return NIMFFI_RET_OK;
    int rc = NIMFFI_RET_OK;
    if (ctx->ptr) { rc = timer_destroy(ctx->ptr); ctx->ptr = NULL; }
    free(ctx);
    return rc;
}""" in
        header
    )

  test "scalar-fast-path methods take inline args, not a Req struct":
    check "TimerAddReq" notin header
    check "TimerNameReq" notin header
    check "TimerRatioReq" notin header
    check "typedef void (*TimerScalarRawFn)(int caller_ret, char* msg, size_t len, void* user_data);" in
      header
    check "int timer_add(void* ctx, TimerScalarRawFn callback, void* user_data, int64_t a, int32_t b);" in
      header
    check "int timer_name(void* ctx, TimerScalarRawFn callback, void* user_data);" in
      header

  test "scalar-fast-path replies ride the same typed ReplyFn surface":
    check "typedef void (*TimerAddReplyFn)(int err_code, const int64_t* reply," in header
    check "typedef void (*TimerNameReplyFn)(int err_code, const char* reply," in header
    check "typedef void (*TimerRatioReplyFn)(int err_code, const float* reply," in header

  test "scalar-fast-path wrappers box the callback and adapt the raw reply":
    check "typedef struct { TimerAddReplyFn fn; void* user_data; } TimerAddScalarBox;" in
      header
    check "static void timer_add_scalar_reply(int caller_ret, char* msg, size_t len, void* ud)" in
      header
    check "timer_ctx_add(const TimerCtx* ctx, int64_t a, int32_t b, TimerAddReplyFn on_reply, void* user_data)" in
      header
    check "timer_ctx_name(const TimerCtx* ctx, TimerNameReplyFn on_reply, void* user_data)" in
      header
    check "return timer_add(ctx->ptr, timer_add_scalar_reply, box, a, b);" in header

  test "scalar returns unpack the 8-byte image; strings copy through the dup helper":
    check "memcpy(&reply, &slot, sizeof(reply));" in header
    check "float reply = (float)wide;" in header
    check "char* reply = nimffi_abi_dup_cstr_n(msg ? msg : \"\", msg ? len : 0);" in
      header
    check "if (n == SIZE_MAX) return NULL;" in header

  test "a static's raw symbol and wrapper both drop the ctx":
    check "int timer_parse(TimerParseReplyFn on_reply, void* user_data, " &
      "const TimerParseReq* req);" in header
    check "timer_static_parse(const EchoRequest* req, TimerParseReplyFn on_reply, void* user_data)" in
      header
    check "return timer_parse(on_reply, user_data, &ffi_req);" in header

  test "a static replies through the same typed ReplyFn surface as a method":
    check "typedef void (*TimerParseReplyFn)(int err_code, const EchoResponse* reply," in
      header

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
