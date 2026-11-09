#!/usr/bin/env bash
# climb-lib.sh: helpers for tests/climb.sh and tests/climb-run.sh, on top
# of lib.sh: a git project to climb, scripted rounds for tests/climb-agent,
# a scorer that reads a list, and a reader for results.jsonl.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
CLIMB=$ROOT/commands/arx-climb
export ARX GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

# project NAME: starts a test in a git project on main: work/value is 10,
# eval/score prints it (or crashes on exit, none and slow, and prints 4242
# with --holdout), and climb.yaml has change: [work/] plus the lines on
# stdin (eval: {command: eval/score, files: [eval/]} unless they set eval).
project() {
  begin "$1"
  printf '.arx/\nfake/\n*.txt\n' >.gitignore
  mkdir -p work
  echo 10 >work/value
  echo old >work/old.py
  script eval/score <<'SCORE'
#!/bin/sh
[ "${1:-}" != --holdout ] || { echo "score: 4242"; exit 0; }
v=$(cat work/value)
case "$v" in
  exit) echo boom; exit 1 ;;
  none) echo "no score here" ;;
  slow) sleep 10; echo "score: 1" ;;
  *) echo "score: $v" ;;
esac
SCORE
  { echo "change: [work/]"; cat; } >climb.yaml
  grep -q '^eval:' climb.yaml || echo "eval: {command: eval/score, files: [eval/]}" >>climb.yaml
  git init -q && git symbolic-ref HEAD refs/heads/main && git add -A && git commit -qm base
}

# round N SCRIPT: what the agent does in round N (run with bash).
round() { printf '%s\n' "$2" >"$FAKE_DIR/round-$(printf %02d "$1").sh"; }

# climb ARGS...: runs arx climb with the stub agent (as run t, unless ARGS
# name one). Sets $code; stdout goes to out.txt and stderr to err.txt.
climb() {
  local a named=0
  for a in "$@"; do case "$a" in --name | --resume) named=1 ;; esac; done
  [ "$named" -eq 1 ] || set -- --name t "$@"
  ARX_BIN=$ROOT/tests/climb-agent "$CLIMB" "$@" >out.txt 2>err.txt </dev/null
  code=$?
}

# jl [JQ OPTIONS] FILTER: jq over the last run's results.jsonl, as an array.
jl() { jq -rs "$@" .arx/climb/last/results.jsonl; }

# noisy SCORE...: eval/score prints the next score of the list on each run,
# whatever the work; commits it.
noisy() {
  printf '%s\n' "$@" >"$FAKE_DIR/scores"
  rm -f "$FAKE_DIR/n"
  script eval/score <<'SCORE'
#!/bin/sh
n=$(($(cat "$FAKE_DIR/n" 2>/dev/null || echo 0) + 1))
echo "$n" >"$FAKE_DIR/n"
echo "score: $(sed -n "${n}p" "$FAKE_DIR/scores")"
SCORE
  git add eval/score && git commit -qm noisy
}
