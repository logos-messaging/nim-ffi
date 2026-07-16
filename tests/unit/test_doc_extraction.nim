## `##` comments on annotated procs → the registry. Codegen: test_doc_propagation.nim.

import unittest2
import results
import ffi
import ffi/codegen/meta

type DocLib = object

# Stub the importc NimMain declareLibrary emits (plain-exe link).
{.emit: "void libdoctestNimMain(void) {}".}

declareLibrary("doctest", DocLib)

type DocConfig {.ffi.} = object
  v: int

type Tocked {.ffi.} = object
  n: int

proc doctest_create*(c: DocConfig): Future[Result[DocLib, string]] {.ffiCtor.} =
  ## Builds the lib.
  return ok(DocLib())

proc doctest_documented*(lib: DocLib): Future[Result[string, string]] {.ffi.} =
  ## First line.
  ## Second line.
  return ok("ok")

proc doctest_undocumented*(lib: DocLib): Future[Result[string, string]] {.ffi.} =
  return ok("ok")

proc doctest_hash_commented*(lib: DocLib): Future[Result[string, string]] {.ffi.} =
  # not a doc comment
  return ok("ok")

proc doctest_spec_documented*(
    lib: DocLib, n: int
): Future[Result[int, string]] {.ffi: "abi = cbor".} =
  ## Doc survives alongside a pragma spec.
  return ok(n)

proc doctest_destroy*(lib: DocLib) {.ffiDtor.} =
  ## Tears it down.
  discard

proc doctest_tocked*(p: Tocked) {.ffiEvent: "on_tocked".} =
  ## Fires on every tock.

proc doctest_plain*(p: Tocked) {.ffiEvent: "on_plain".}

# The registries are compile-time only, so snapshot them into consts.
proc docOf(procName: string): string {.compileTime.} =
  for p in ffiProcRegistry:
    if p.procName == procName:
      return p.doc
  doAssert false, "no proc " & procName & " in ffiProcRegistry"

proc eventDocOf(wireName: string): string {.compileTime.} =
  for e in ffiEventRegistry:
    if e.wireName == wireName:
      return e.doc
  doAssert false, "no event " & wireName & " in ffiEventRegistry"

const
  CreateDoc = docOf("doctest_create")
  DocumentedDoc = docOf("doctest_documented")
  UndocumentedDoc = docOf("doctest_undocumented")
  HashCommentedDoc = docOf("doctest_hash_commented")
  SpecDocumentedDoc = docOf("doctest_spec_documented")
  DestroyDoc = docOf("doctest_destroy")
  TockedDoc = eventDocOf("on_tocked")
  PlainEventDoc = eventDocOf("on_plain")

suite "extractDocComment: what lands on the registry":
  test "a single-line doc comment is captured":
    check CreateDoc == "Builds the lib."

  test "a multi-line doc comment keeps its line breaks":
    check DocumentedDoc == "First line.\nSecond line."

  test "an undocumented proc gets an empty doc":
    check UndocumentedDoc == ""

  test "a plain `#` comment is not captured":
    check HashCommentedDoc == ""

  test "a doc comment survives a pragma spec argument":
    check SpecDocumentedDoc == "Doc survives alongside a pragma spec."

  test "the destructor's doc is captured":
    check DestroyDoc == "Tears it down."

  test "an event proc's doc comment is captured":
    check TockedDoc == "Fires on every tock."

  test "an undocumented event proc gets an empty doc":
    check PlainEventDoc == ""
