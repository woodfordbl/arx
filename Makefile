# Makefile for arx.
#   make          release binary ./arx (-Os, LTO, dead-code stripped)
#   make debug    ./arx-debug with AddressSanitizer and UBSan
#   make test     run tests/run.sh and tests/plugins.sh against ./arx-debug
#   make bench    check the performance budgets against ./arx
#   make lint     style checks (scripts/lint.sh)
#   make format   rewrite src/ in Google style
#   make static   static Linux (musl) binary, built in Docker
CC ?= cc
UNAME := $(shell uname)

YAML_DEFS := -DYAML_VERSION_MAJOR=0 -DYAML_VERSION_MINOR=2 \
  -DYAML_VERSION_PATCH=5 '-DYAML_VERSION_STRING="0.2.5"' -DYAML_DECLARE_STATIC
CPPFLAGS := -I. -Ivendor/libyaml/include -D_GNU_SOURCE -D_DARWIN_C_SOURCE \
  $(YAML_DEFS)
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
	rm -rf build arx arx-debug

.PHONY: debug test bench lint format static clean
