## Cross-platform IPC round-trip integration test (Linux / macOS / Windows).
##
## Builds the timer library with the in-process CBOR serve loop (-d:ffiIpcServe),
## the Nim host that starts it, and the lib-free Nim client; then starts the
## server, runs the client over a loopback TCP socket, and asserts the client's
## exit code. Everything uses chronos / Nim tooling, so there is no POSIX-only
## C or shell in the path. Driven by `nimble test_ipc`.
import std/[os, osproc, strutils]

const
  Port = 47097
  Address = "tcp:127.0.0.1:" & $Port

let
  root = getCurrentDir() # nimble runs tasks from the repo root
  ipc = root / "examples" / "timer" / "ipc_chronos"
  libExt =
    when defined(windows): "dll" elif defined(macosx): "dylib" else: "so"
  exeExt = (when defined(windows): ".exe" else: "")
  lib = ipc / ("libmy_timer." & libExt)
  serveHost = ipc / ("serve_host" & exeExt)
  client = ipc / ("client" & exeExt)
  nimBase = "nim c --mm:orc -d:chronicles_log_level=WARN"

proc sh(cmd: string) =
  echo "+ ", cmd
  let code = execCmd(cmd)
  doAssert code == 0, "command failed (" & $code & "): " & cmd

# 1) Library with the serve loop compiled in.
sh nimBase & " --app:lib --noMain --nimMainPrefix:libmy_timer -d:ffiIpcServe" & " -o:" &
  lib.quoteShell & " " & (root / "examples" / "timer" / "timer.nim").quoteShell

# 2) Host links the lib (rpath so it is found next to the binary on POSIX; on
#    Windows the dll sits in the same directory and is found automatically).
var hostCmd =
  nimBase & " --passL:-L" & ipc.quoteShell & " --passL:-lmy_timer"
when not defined(windows):
  hostCmd &= " --passL:-Wl,-rpath," & ipc.quoteShell
sh hostCmd & " -o:" & serveHost.quoteShell & " " & (ipc / "serve_host.nim").quoteShell

# 3) Client (no lib).
sh nimBase & " -o:" & client.quoteShell & " " & (ipc / "client.nim").quoteShell

# 4) Start the server, run the client (it retries the connect), assert, stop.
echo "+ start ", serveHost, " ", Address
let srv = startProcess(serveHost, args = [Address], options = {poParentStreams})
var clientCode = 1
try:
  clientCode = execCmd(client.quoteShell & " " & Address)
finally:
  srv.terminate()
  discard srv.waitForExit(2000)
  srv.close()

doAssert clientCode == 0, "client round-trip failed (exit " & $clientCode & ")"
echo "IPC cross-platform round-trip OK"
