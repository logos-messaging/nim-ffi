# Build the Nim dylib next to the generated Go package and run the example.
#
#   make run     # build libmy_timer + run the example
#   make clean
#
# The generated package's cgo directives use ${SRCDIR}, so the library only has
# to sit in this directory (-L/-rpath point here). It is compiled from the repo
# root so the vendored Nimble dependencies resolve.

REPO_ROOT := $(abspath ../../..)
NIM_SRC   := $(REPO_ROOT)/examples/timer/timer.nim

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  LIBNAME := libmy_timer.dylib
else
  LIBNAME := libmy_timer.so
endif

NIMFLAGS := --mm:orc -d:chronicles_log_level=WARN --app:lib --noMain \
            --nimMainPrefix:libmy_timer

.PHONY: all run clean

all: $(LIBNAME)

$(LIBNAME):
	cd $(REPO_ROOT) && nim c $(NIMFLAGS) -o:$(CURDIR)/$(LIBNAME) $(NIM_SRC)

run: $(LIBNAME)
	cd example && go run .

clean:
	rm -f $(LIBNAME) example/example
