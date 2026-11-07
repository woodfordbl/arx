# Makefile for arx: thin wrappers around `zig build` (see build.zig), kept so
# the commands in the docs and CI stay short.
#   make            release binary ./arx (optimized for size, stripped)
#   make debug      ./arx-debug with safety checks and leak reports
#   make test       the Zig unit tests, then tests/run.sh, plugins.sh,
#                   layers.sh and cli.sh against ./arx-debug
#   make bench      check the performance budgets against ./arx
#   make lint       style checks (scripts/lint.sh)
#   make format     rewrite src/ with zig fmt
#   make install    install arx and its commands into $(PREFIX) (~/.local)
#   make uninstall  remove them again
#   make dist       dist/arx-<os>-<arch>.tar.gz (+ .sha256), as releases ship
#   make static     static Linux (musl) binaries for x86_64 and arm64
#
# arx builds with exactly one Zig release, ZIG_VERSION below; build.zig and
# build.zig.zon name the same one. Set ZIG to use a zig that is not on PATH.
ZIG ?= zig
ZIG_VERSION := 0.17.0
PREFIX ?= $(HOME)/.local
OS := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m | sed 's/aarch64/arm64/')
TARGET ?= $(OS)-$(ARCH)
SHA256 := $(shell command -v sha256sum >/dev/null 2>&1 && echo sha256sum || echo shasum -a 256)
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null | sed 's/^v//')
VERSION_FLAG := $(if $(VERSION),-Dversion=$(VERSION))

# The Zig target for each release target. The Linux ones link musl
# statically, so the binary runs on any distribution.
ZIG_TARGET_darwin-arm64 := aarch64-macos
ZIG_TARGET_darwin-x86_64 := x86_64-macos
ZIG_TARGET_linux-x86_64 := x86_64-linux-musl
ZIG_TARGET_linux-arm64 := aarch64-linux-musl
ZIG_TARGET := $(ZIG_TARGET_$(TARGET))

SRC := $(shell find src -name '*.zig') build.zig build.zig.zon

arx: check-zig $(SRC)
	$(ZIG) build -Doptimize=small -Dtarget=$(ZIG_TARGET) $(VERSION_FLAG) --prefix build/$(TARGET)
	rm -f $@ && cp build/$(TARGET)/bin/arx $@ # replace, not overwrite: macOS kills an overwritten signed binary
	strip $@ 2>/dev/null || true

debug: arx-debug
arx-debug: check-zig $(SRC)
	$(ZIG) build -Doptimize=debug $(VERSION_FLAG) --prefix build/debug
	rm -f $@ && cp build/debug/bin/arx $@

# Stops early, with the fix, when the zig on PATH is not the pinned one.
check-zig:
	@have=$$($(ZIG) version 2>/dev/null); if [ "$$have" != "$(ZIG_VERSION)" ]; then \
	  echo "arx builds with Zig $(ZIG_VERSION); found '$${have:-no zig}'." >&2; \
	  echo "Install it from https://ziglang.org/download/ or set ZIG=/path/to/zig." >&2; \
	  exit 1; fi

test: arx-debug
	$(ZIG) build test -Doptimize=debug
	ARX=./arx-debug tests/run.sh
	ARX=./arx-debug tests/plugins.sh
	ARX=./arx-debug tests/layers.sh
	ARX=./arx-debug tests/cli.sh

install: arx
	mkdir -p $(PREFIX)/bin $(PREFIX)/libexec/arx
	rm -f $(PREFIX)/bin/arx
	cp arx $(PREFIX)/bin/arx
	cp commands/arx-* $(PREFIX)/libexec/arx/
	chmod 755 $(PREFIX)/bin/arx $(PREFIX)/libexec/arx/arx-*
	@echo "installed arx $(VERSION) in $(PREFIX)/bin; run \`arx setup\` next"

uninstall:
	rm -rf $(PREFIX)/bin/arx $(PREFIX)/libexec/arx

dist: arx
	rm -rf dist/arx-$(TARGET)
	mkdir -p dist/arx-$(TARGET)/bin dist/arx-$(TARGET)/libexec/arx
	cp arx dist/arx-$(TARGET)/bin/
	cp commands/arx-* dist/arx-$(TARGET)/libexec/arx/
	tar -C dist -czf dist/arx-$(TARGET).tar.gz arx-$(TARGET)
	cd dist && $(SHA256) arx-$(TARGET).tar.gz >arx-$(TARGET).tar.gz.sha256

# Zig cross-compiles, so this needs no Docker and works from macOS too.
static: check-zig
	for t in linux-x86_64 linux-arm64; do \
	  $(MAKE) --no-print-directory clean-bin arx TARGET=$$t && mv arx arx-$$t || exit 1; \
	done

bench: arx
	tests/bench.sh

lint:
	scripts/lint.sh

format: check-zig
	$(ZIG) fmt src build.zig build.zig.zon

clean-bin:
	rm -f arx

clean:
	rm -rf build dist zig-out arx arx-debug arx-linux-*

.PHONY: debug check-zig test bench lint format install uninstall dist static clean clean-bin
