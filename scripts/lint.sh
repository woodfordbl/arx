#!/usr/bin/env bash
# lint.sh: style checks for the arx sources in src/ and build.zig.
#
# These rules are for people (and agents) building arx itself. They are not in
# the binary, and harness files an agent writes at run time (tools/, hooks/,
# examples/) are never linted.
#
#   1. Formatting: zig fmt, from the pinned Zig release.
#   2. No file over 400 lines.
#   3. Doc comments (scripts/doc_check.awk).
set -uo pipefail
cd "$(dirname "$0")/.."

shopt -s nullglob
zig_files=(build.zig src/*.zig src/*/*.zig)
zig=${ZIG:-zig}
zig_version=$(sed -n 's/^ZIG_VERSION := //p' Makefile)
fail=0

# Formatting can change between Zig releases, so everyone (and CI) uses the
# pinned one.
if ! have=$("$zig" version 2>/dev/null); then
  echo "lint: Zig $zig_version is missing (https://ziglang.org/download/, or set ZIG)" >&2
  exit 2
fi
if [ "$have" != "$zig_version" ]; then
  echo "lint: Zig $zig_version is needed, found $have" >&2
  exit 2
fi

echo "== zig fmt"
"$zig" fmt --check "${zig_files[@]}" build.zig.zon || fail=1

echo "== file length (max 400 lines)"
for f in "${zig_files[@]}" scripts/* tests/*.sh tests/fake-curl commands/* install.sh Makefile; do
  [ -f "$f" ] || continue
  n=$(wc -l <"$f")
  if [ "$n" -gt 400 ]; then
    echo "$f: $n lines (max 400)"
    fail=1
  fi
done

echo "== doc comments"
awk -f scripts/doc_check.awk "${zig_files[@]}" || fail=1

if [ "$fail" -eq 0 ]; then echo "lint: ok"; else echo "lint: failed"; fi
exit "$fail"
