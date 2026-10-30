#!/usr/bin/env bash
# lint.sh: style checks for the harness sources in src/.
#
# These rules are for people (and agents) building arx itself. They are not in
# the binary, and harness files an agent writes at run time (tools/, hooks/,
# examples/) are never linted.
#
#   1. Google formatting (clang-format, see .clang-format).
#   2. Google's linter (cpplint, see CPPLINT.cfg).
#   3. No file over 400 lines.
#   4. Doc comments (scripts/doc_check.awk).
set -uo pipefail
cd "$(dirname "$0")/.."

shopt -s nullglob
src=(src/*.c src/*/*.c src/*/*.h)
fail=0

if ! command -v clang-format >/dev/null; then
  echo "lint: clang-format is missing (brew install clang-format)" >&2
  exit 2
fi

echo "== clang-format (Google style)"
clang-format --dry-run --Werror "${src[@]}" || fail=1

echo "== cpplint"
uvx --quiet cpplint --quiet "${src[@]}" || fail=1

echo "== file length (max 400 lines)"
for f in "${src[@]}" scripts/* tests/*.sh tests/fake-curl Makefile; do
  [ -f "$f" ] || continue
  n=$(wc -l <"$f")
  if [ "$n" -gt 400 ]; then
    echo "$f: $n lines (max 400)"
    fail=1
  fi
done

echo "== doc comments"
awk -f scripts/doc_check.awk "${src[@]}" || fail=1

if [ "$fail" -eq 0 ]; then echo "lint: ok"; else echo "lint: failed"; fi
exit "$fail"
