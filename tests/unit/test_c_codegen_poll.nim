## The `<lib>.h` header of a `-d:ffiPollMode` build declares the poll shape.

import std/strutils
import unittest2
import ffi/codegen/[meta, c]

proc field(n, t: string): FFIFieldMeta =
  FFIFieldMeta(name: n, typeName: t)

proc param(n, t: string, isPtr = false): FFIParamMeta =
  FFIParamMeta(name: n, typeName: t, isPtr: isPtr)

suite "generateCLibHeader: the poll model":
  setup:
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
        extraParams: @[param("req", "EchoRequest")],
        returnTypeName: "string",
      ),
      FFIProcMeta(
        procName: "timer_ping",
        libName: "timer",
        kind: FFIKind.STATIC,
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
    let types = @[FFITypeMeta(name: "EchoRequest", fields: @[field("m", "string")])]
    let header = generateCLibHeader(procs, types, "timer")

  test "every export has the poll shape and answers with a message":
    check "int timer_create(const uint8_t* req_cbor, size_t req_cbor_len, void** ctx_out, uint64_t* req_id_out);" in
      header
    check "int timer_echo(void* ctx, const uint8_t* req_cbor, size_t req_cbor_len, uint64_t* req_id_out);" in
      header
    check "int timer_ping(const uint8_t* req_cbor, size_t req_cbor_len, uint64_t* req_id_out);" in
      header
    check "int timer_destroy(void* ctx);" in header
    check "int timer_poll(void* ctx, int32_t timeout_ms, const PollResult** msg);" in
      header
    check "int timer_poll_fd(void* ctx);" in header
    check "int timer_reverse_reply(void* ctx, uint64_t call_id, int ret, const uint8_t* payload, size_t len);" in
      header

  test "the message and its kinds are declared in the header":
    check "typedef struct {" in header
    check "} PollResult;" in header
    check "#define NIMFFI_MSG_REPLY 1" in header
    check "#define NIMFFI_MSG_REVERSE_CALL 4" in header

  test "no callback-model machinery leaks in":
    check "FFICallback" notin header
    check "timer_add_event_listener" notin header
    check "timer_ctx_create(" notin header

  test "the codecs are still there for the requests and replies":
    check "timer_enc_" in header
    check "timer_dec_" in header
