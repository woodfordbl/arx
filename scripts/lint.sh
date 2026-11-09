#!/usr/bin/env bash
# lint.sh: style checks for the C sources in src/ (arx) and pick/ (the menu
# program that the commands call).
#
# These rules are for people (and agents) building arx itself. They are not in
# the binary, and harness files an agent writes at run time (tools/, hooks/,
# examples/) are never linted.
#
#   1. Google formatting (clang-format, see .clang-format).
#   2. Google's linter (cpplint, see CPPLINT.cfg).
#   3. No file over 400 lines.
#   4. Doc comments (scripts/doc_check.awk).
#   5. Process and signal calls only in the native platform files, so the
#      browser build (proc_host.c) can replace them.
set -uo pipefail
cd "$(dirname "$0")/.."

shopt -s nullglob
src=(src/*.c src/*/*.c src/*/*.h pick/*.c pick/*.h)
fail=0

# Formatting can differ between clang-format major versions, so everyone
# (and CI) uses the same one. CI installs it with pip; see ci.yml.
clang_format_major=23
if ! command -v clang-format >/dev/null; then
  echo "lint: clang-format $clang_format_major is missing" \
    "(brew install clang-format, or pip install clang-format==23.1.3)" >&2
  exit 2
fi
major=$(clang-format --version | sed -n 's/.*version \([0-9]*\)\..*/\1/p')
if [ "$major" != "$clang_format_major" ]; then
  echo "lint: clang-format $clang_format_major is needed, found $major" \
    "(pip install clang-format==23.1.3)" >&2
  exit 2
fi

echo "== clang-format (Google style)"
clang-format --dry-run --Werror "${src[@]}" || fail=1

echo "== cpplint"
if command -v cpplint >/dev/null; then
  cpplint --quiet "${src[@]}" || fail=1
else
  uvx --quiet cpplint --quiet "${src[@]}" || fail=1
fi

echo "== file length (max 400 lines)"
for f in "${src[@]}" scripts/* tests/*.sh tests/*.py tests/fake-curl commands/* commands/lib/*.sh \
  install.sh Makefile; do
  [ -f "$f" ] || continue
  n=$(wc -l <"$f")
  if [ "$n" -gt 400 ]; then
    echo "$f: $n lines (max 400)"
    fail=1
  fi
done

echo "== doc comments"
awk -f scripts/doc_check.awk "${src[@]}" || fail=1

echo "== platform calls (in src/: only in base/proc.c and proc_posix.c)"
calls='(^|[^A-Za-z0-9_])(posix_spawnp?|exec[lv]p?e?|fork|pipe|dup2?|kill|waitpid|sigaction|signal)[[:space:]]*\('
# pick/ is a separate native program, never part of the browser build.
if grep -nE "$calls" "${src[@]}" |
  grep -vE '^(src/base/proc(_posix)?\.c|pick/[a-z]+\.c):'; then
  echo "use the platform section of src/base/base.h instead"
  fail=1
fi

if [ "$fail" -eq 0 ]; then echo "lint: ok"; else echo "lint: failed"; fi
exit "$fail"
