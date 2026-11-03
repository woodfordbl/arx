# Makefile for arx.
#   make            release binary ./arx (-Os, LTO, dead-code stripped)
#   make debug      ./arx-debug with AddressSanitizer and UBSan
#   make test       run tests/run.sh, plugins.sh, layers.sh and cli.sh against
#                   ./arx-debug
#   make bench      check the performance budgets against ./arx
#   make lint       style checks (scripts/lint.sh)
#   make format     rewrite src/ in Google style
#   make install    install arx and its commands into $(PREFIX) (~/.local)
#   make uninstall  remove them again
#   make dist       dist/arx-<os>-<arch>.tar.gz (+ .sha256), as releases ship
#   make static     static Linux (musl) binary, built in Docker
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

SRC := $(wildcard src/*.c src/*/*.c)
HDR := $(wildcard src/*/*.h)
VENDOR := vendor/cjson/cJSON.c $(wildcard vendor/libyaml/src/*.c)
REL_OBJ := $(patsubst %.c,build/rel/%.o,$(SRC) $(VENDOR))
DBG_OBJ := $(patsubst %.c,build/dbg/%.o,$(SRC) $(VENDOR))

arx: $(REL_OBJ)
	$(CC) $(REL) $(GC) $^ -o $@
	strip $@

debug: arx-debug
arx-debug: $(DBG_OBJ)
	$(CC) -fsanitize=address,undefined $^ -o $@

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

test: arx-debug
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

bench: arx
	tests/bench.sh

lint:
	scripts/lint.sh

format:
	clang-format -i $(SRC) $(HDR)

static:
	docker run --rm -v "$(CURDIR)":/w -w /w alpine:3.20 sh -c \
	  'apk add -q build-base && make clean arx CC="gcc -static" && \
	   mv arx arx-linux-$$(uname -m) && rm -rf build'

clean:
	rm -rf build dist arx arx-debug

.PHONY: debug test bench lint format install uninstall dist static clean
