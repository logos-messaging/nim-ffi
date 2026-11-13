## Library half of reverse_split_module_fixture: declareLibrary only.

import ffi

type RevSplitLib* = object

{.emit: "void librevsplitNimMain(void) {}".}

declareLibrary("revsplit", RevSplitLib)
