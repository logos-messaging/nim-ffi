# skeleton — new-library template

A minimal, compilable nim-ffi library: a constructor, one async method, a library-initiated event, and a destructor, plus a nimble file and checked-in C++ bindings. Copy this directory instead of reverse-engineering `examples/timer/` (which is a feature tour, not a starting point).

## What's here

- `skeleton.nim` — the library. Every nim-ffi lib needs these four pieces, and nothing else:
  - `declareLibrary("skeleton", Skeleton)` — names the lib and its state object; must come before any FFI annotation.
  - `{.ffiCtor.}` constructor returning `Future[Result[T, string]]`.
  - one `{.ffi.}` async method, same return contract.
  - `{.ffiEvent.}` for a library-initiated callback.
  - `{.ffiDtor.}` destructor.
  - `genBindings()` as the **last** top-level call.
- `skeleton.nimble` — `build` and `genbindings_cpp` tasks.
- `cpp_bindings/` — generated C++ bindings, checked in and diff-verified by CI (`nimble check_bindings`).

## Copy-rename checklist

Pick your library name in two casings: a snake_case wire name (e.g. `my_lib`) and its PascalCase state type (e.g. `MyLib`).

1. Copy the directory: `cp -r examples/skeleton examples/my_lib`
2. Rename both files: `skeleton.nim` → `my_lib.nim`, `skeleton.nimble` → `my_lib.nimble`.
3. In `my_lib.nim`, replace every `skeleton` → `my_lib` and `Skeleton` → `MyLib`. That covers `declareLibrary("my_lib", MyLib)`, the state type, and the `myLibCreate` / `myLibHello` / `my_lib_destroy` proc names. Rename the request/response/event/config types to whatever your API needs.
4. In `my_lib.nimble`, update `packageName`, `description`, and every `libskeleton` → `libmy_lib` / `skeleton.nim` → `my_lib.nim`. The `--nimMainPrefix:libmy_lib` must match your `declareLibrary` name.
5. Regenerate bindings: `cd examples/my_lib && nimble genbindings_cpp` (add `-d:targetLang=rust` / `c` / `c_abi` variants as needed — see the root `ffi.nimble` for the full flag set).
6. If you keep the library long-term, wire it into the root `ffi.nimble` `check_bindings` task the same way `skeleton` is, so CI catches binding drift.

## Contracts worth remembering

- Every `{.ffi.}` / `{.ffiCtor.}` returns `Future[Result[T, string]]`: `return ok(value)` on success, `return err("reason")` on failure.
- A `{.ffi.}` method takes the state object as its **first** parameter.
- The dtor's exported symbol name (`skeleton_destroy`) avoids the camelCase→snake_case derivation and reads naturally in C; name yours the same way.
- `genBindings()` reads compile-time registries populated by the pragmas above it. Anything declared after it — or in a module imported after it — is silently missing from the output.

## Build & generate

```sh
cd examples/skeleton
nimble genbindings_cpp   # writes cpp_bindings/
```
