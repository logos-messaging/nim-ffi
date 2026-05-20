# Make the project root importable so test/example code can write
# `import ffi/alloc` instead of `import ../../ffi/alloc`.
switch("path", thisDir())

# begin Nimble config (version 2)
--noNimblePath
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config