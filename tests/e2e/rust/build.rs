use std::path::PathBuf;

// The `my_timer` bindings' build.rs compiles the Nim shared library into the
// repo root and adds it to the link search path — but a dependency's
// `rustc-link-arg` does not propagate to this crate's test binaries, so they
// would fail to find `libmy_timer.so` at runtime. Embed an rpath to the repo
// root here so `cargo test` works without setting LD_LIBRARY_PATH. (Windows has
// no rpath; there the loader finds the DLL via PATH / the working directory.)
fn main() {
    if cfg!(target_os = "windows") {
        return;
    }
    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let mut repo_root = manifest;
    while !repo_root.join("ffi.nimble").exists() {
        assert!(
            repo_root.pop(),
            "could not locate repo root (no ffi.nimble ancestor)"
        );
    }
    println!("cargo:rustc-link-arg=-Wl,-rpath,{}", repo_root.display());
}
