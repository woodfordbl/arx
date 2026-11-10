# Makefile for arx.
#   make            release binary ./arx (-Os, LTO, dead-code stripped), and
#                   commands/lib/pick, the menu program the commands call
#   make debug      ./arx-debug with AddressSanitizer and UBSan
#   make test       run the src/base unit tests (tests/base_test.c), then
#                   tests/run.sh, plugins.sh, layers.sh, cli.sh, shell.sh,
#                   hooks.sh, runtime.sh, kits.sh, credentials.sh, state.sh,
#                   climb.sh, climb-run.sh, ui.sh and mcp.sh against
#                   ./arx-debug
#   make bench      check the performance budgets against ./arx
#   make lint       style checks (scripts/lint.sh)
#   make format     rewrite src/ and pick/ in Google style
#   make install    install arx, its commands, and the plugins and kits of
#                   this repo into $(PREFIX) (~/.local); `arx setup` turns
#                   the shell plugin on, and `arx kit add NAME` adds a kit
#   make uninstall  remove them again
#   make dist       dist/arx-<os>-<arch>.tar.gz (+ .sha256), as releases ship;
#                   fails if the tarball lacks libexec/arx/lib/pick
#   make static     static Linux (musl) binaries, built in Docker
#   make wasm       arx.wasm, the core for browsers (wasm32-wasi), built with
#                   $(WASI_CC) and, when installed, binaryen's wasm-opt; then
#                   scripts/wasm-imports.sh checks its imports
CC ?= cc
UNAME := $(shell uname)
PREFIX ?= $(HOME)/.local
TARGET ?= $(shell uname -s | tr '[:upper:]' '[:lower:]')-$(shell uname -m | sed 's/aarch64/arm64/')
SHA256 := $(shell command -v sha256sum >/dev/null 2>&1 && echo sha256sum || echo shasum -a 256)

YAML_DEFS := -DYAML_VERSION_MAJOR=0 -DYAML_VERSION_MINOR=2 \
  -DYAML_VERSION_PATCH=5 '-DYAML_VERSION_STRING="0.2.5"' -DYAML_DECLARE_STATIC
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null | sed 's/^v//')
CPPFLAGS := -I. -Ivendor/libyaml/include -D_GNU_SOURCE -D_DARWIN_C_SOURCE \
  $(YAML_DEFS) '-DARX_VERSION="$(VERSION)"'
WARN := -std=c11 -Wall -Wextra -Wshadow -Wstrict-prototypes
REL := -Os -flto -ffunction-sections -fdata-sections
DBG := -O0 -g -fsanitize=address,undefined -fno-omit-frame-pointer
ifeq ($(UNAME),Darwin)
  GC := -Wl,-dead_strip
else
  GC := -Wl,--gc-sections
endif

# The platform has two sides (see src/base/base.h): proc.c and proc_posix.c
# natively, proc_host.c in the browser build.
NATIVE_SRC := src/base/proc.c src/base/proc_posix.c
HOST_SRC := src/base/proc_host.c
SRC := $(filter-out $(HOST_SRC),$(wildcard src/*.c src/*/*.c))
HDR := $(wildcard src/*/*.h)
VENDOR := vendor/cjson/cJSON.c $(wildcard vendor/libyaml/src/*.c)
REL_OBJ := $(patsubst %.c,build/rel/%.o,$(SRC) $(VENDOR))
DBG_OBJ := $(patsubst %.c,build/dbg/%.o,$(SRC) $(VENDOR))
# pick is a separate program: nothing of it links into arx.
PICK := commands/lib/pick
PICK_SRC := $(wildcard pick/*.c)
PICK_HDR := $(wildcard pick/*.h)

all: arx $(PICK)

arx: $(REL_OBJ)
	$(CC) $(REL) $(GC) $^ -lm -o $@
	strip $@

debug: arx-debug
arx-debug: $(DBG_OBJ)
	$(CC) -fsanitize=address,undefined $^ -lm -o $@

build/rel/src/%.o: src/%.c $(HDR)
	@mkdir -p $(dir $@)
	$(CC) $(CPPFLAGS) $(WARN) $(REL) -c $< -o $@
build/rel/vendor/%.o: vendor/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CPPFLAGS) -w $(REL) -c $< -o $@
build/dbg/src/%.o: src/%.c $(HDR)
	@mkdir -p $(dir $@)
	$(CC) $(CPPFLAGS) $(WARN) $(DBG) -c $< -o $@
build/dbg/vendor/%.o: vendor/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CPPFLAGS) -w $(DBG) -c $< -o $@

$(PICK): $(PICK_SRC) $(PICK_HDR)
	@mkdir -p $(dir $@)
	$(CC) -I. -D_GNU_SOURCE -D_DARWIN_C_SOURCE '-DARX_VERSION="$(VERSION)"' \
	  $(WARN) $(REL) $(GC) $(PICK_SRC) -o $@
	strip $@

# Unit tests for src/base: the JSON-RPC peer and the process helpers.
BASE_TEST_OBJ := $(patsubst %.c,build/dbg/%.o,$(filter src/base/%,$(SRC)) \
  vendor/cjson/cJSON.c)
build/dbg/base_test: tests/base_test.c $(BASE_TEST_OBJ)
	$(CC) $(CPPFLAGS) $(WARN) $(DBG) $^ -o $@

test: arx-debug build/dbg/base_test $(PICK)
	build/dbg/base_test
	ARX=./arx-debug tests/run.sh
	ARX=./arx-debug tests/plugins.sh
	ARX=./arx-debug tests/layers.sh
	ARX=./arx-debug tests/cli.sh
	ARX=./arx-debug tests/shell.sh
	ARX=./arx-debug tests/hooks.sh
	ARX=./arx-debug tests/runtime.sh
	ARX=./arx-debug tests/kits.sh
	ARX=./arx-debug tests/credentials.sh
	ARX=./arx-debug tests/state.sh
	ARX=./arx-debug tests/climb.sh
	ARX=./arx-debug tests/climb-run.sh
	ARX=./arx-debug tests/ui.sh
	ARX=./arx-debug tests/mcp.sh

# The browser build: the same sources with proc_host.c in place of the
# native platform files. zig bundles wasi-libc; WASI_CC can name wasi-sdk's
# clang instead (--target=wasm32-wasip1). CI pins both tools (ci.yml).
WASI_CC ?= zig cc -target wasm32-wasi
WASM_OPT ?= wasm-opt
WASM_SRC := $(filter-out $(NATIVE_SRC),$(SRC)) $(HOST_SRC)
WASM_OBJ := $(patsubst %.c,build/wasm/%.o,$(WASM_SRC) $(VENDOR))
WASM_DEFS := -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_GETPID \
  -D_WASI_EMULATED_SIGNAL
# The lime1 CPU (LLVM's, and zig's default) is what JSPI browsers run.
# The module carries no target_features section, so wasm-opt is told.
WASM := -Os -flto -ffunction-sections -fdata-sections -mcpu=lime1
WASM_FEATURES := --enable-bulk-memory-opt --enable-call-indirect-overlong \
  --enable-extended-const --enable-multivalue --enable-mutable-globals \
  --enable-nontrapping-float-to-int --enable-sign-ext

wasm: arx.wasm
arx.wasm: $(WASM_OBJ)
	$(WASI_CC) $(WASM) -mexec-model=reactor -Wl,--gc-sections -s $^ \
	  -lwasi-emulated-getpid -lwasi-emulated-process-clocks -o $@
	if command -v $(WASM_OPT) >/dev/null; then $(WASM_OPT) $(WASM_FEATURES) \
	  -Oz --strip-debug --strip-producers $@ -o $@; fi
	scripts/wasm-imports.sh $@

build/wasm/src/%.o: src/%.c $(HDR)
	@mkdir -p $(dir $@)
	$(WASI_CC) $(CPPFLAGS) $(WASM_DEFS) $(WARN) -Werror $(WASM) -c $< -o $@
build/wasm/vendor/%.o: vendor/%.c
	@mkdir -p $(dir $@)
	$(WASI_CC) $(CPPFLAGS) $(WASM_DEFS) -w $(WASM) -c $< -o $@

install: all
	mkdir -p $(PREFIX)/bin $(PREFIX)/libexec/arx
	rm -f $(PREFIX)/bin/arx
	cp arx $(PREFIX)/bin/arx
	cp commands/arx-* $(PREFIX)/libexec/arx/
	rm -rf $(PREFIX)/libexec/arx/plugins $(PREFIX)/libexec/arx/kits \
	  $(PREFIX)/libexec/arx/climb $(PREFIX)/libexec/arx/lib
	cp -R plugins kits commands/climb commands/lib $(PREFIX)/libexec/arx/
	chmod 755 $(PREFIX)/bin/arx $(PREFIX)/libexec/arx/arx-*
	@echo "installed arx $(VERSION) in $(PREFIX)/bin; run \`arx setup\` next"

uninstall:
	rm -rf $(PREFIX)/bin/arx $(PREFIX)/libexec/arx

dist: all
	rm -rf dist/arx-$(TARGET)
	mkdir -p dist/arx-$(TARGET)/bin dist/arx-$(TARGET)/libexec/arx
	cp arx dist/arx-$(TARGET)/bin/
	cp commands/arx-* dist/arx-$(TARGET)/libexec/arx/
	cp -R plugins kits commands/climb commands/lib dist/arx-$(TARGET)/libexec/arx/
	tar -C dist -czf dist/arx-$(TARGET).tar.gz arx-$(TARGET)
	@tar -tzf dist/arx-$(TARGET).tar.gz | grep -qx 'arx-$(TARGET)/libexec/arx/lib/pick' || \
	  { echo "dist: the tarball has no libexec/arx/lib/pick" >&2; exit 1; }
	cd dist && $(SHA256) arx-$(TARGET).tar.gz >arx-$(TARGET).tar.gz.sha256

bench: arx
	tests/bench.sh

lint:
	scripts/lint.sh

format:
	clang-format -i $(SRC) $(HOST_SRC) $(HDR) $(PICK_SRC) $(PICK_HDR)

# Leaves the static pick in commands/lib/pick, for `make dist`.
static:
	docker run --rm -v "$(CURDIR)":/w -w /w alpine:3.20 sh -c \
	  'apk add -q build-base && make clean all CC="gcc -static" && \
	   mv arx arx-linux-$$(uname -m) && rm -rf build'

clean:
	rm -rf build dist arx arx-debug arx.wasm $(PICK)

.PHONY: all debug test bench lint format install uninstall dist static wasm \
  clean
