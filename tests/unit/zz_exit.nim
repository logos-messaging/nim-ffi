import results
import ffi
type TestLib = object
var sharedPool: FFIContextPool[TestLib]
when isMainModule:
  let s = sharedPool.staticFFIContext().valueOr:
    quit("static failed: " & error)
  echo "static ctx: ", cast[uint](s)
  # Simulate the rest of the suite doing light work, then exit with the
  # static thread still running.
  echo "exiting with static thread alive"
