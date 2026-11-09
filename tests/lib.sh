#!/usr/bin/env bash
# lib.sh: helpers for tests/run.sh: a fresh workspace per test, scripted
# model replies for fake-curl, and assertions.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ARX=${ARX:-./arx-debug}
ARX=$(cd "$(dirname "$ARX")" && pwd)/$(basename "$ARX")
export ARX_CURL="$ROOT/tests/fake-curl"
export NO_COLOR=1
# Never read the real user defaults or stored keys.
export ARX_CONFIG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/arx-config.XXXXXX")
export ARX_DISABLE_KEYCHAIN=1
# bash and edit come from the shell plugin, as after `arx setup`.
mkdir -p "$ARX_CONFIG_DIR/plugins"
ln -s "$ROOT/plugins/shell" "$ARX_CONFIG_DIR/plugins/shell"
export ASAN_OPTIONS=${ASAN_OPTIONS:-detect_leaks=0:abort_on_error=1}
export UBSAN_OPTIONS=${UBSAN_OPTIONS:-halt_on_error=1:print_stacktrace=1}
passed=0
failed=0

# Starts a test in a new temp workspace with a minimal agent.yaml.
begin() {
  name=$1
  WS=$(mktemp -d "${TMPDIR:-/tmp}/ar-test.XXXXXX")
  cd "$WS" || exit 1
  export FAKE_DIR="$WS/fake"
  mkdir -p "$FAKE_DIR"
  spec >agent.yaml
}

# Prints a minimal spec; extra YAML lines can follow on stdin.
spec() {
  cat <<'EOF'
name: test
model: test-model
endpoint: {base_url: "http://fake.invalid/v1", retry_base: 0.01, retry_max: 0.05}
EOF
}

# Runs arx headless with `-p TASK` and any extra arguments. Sets $code;
# stdout goes to out.txt and stderr to err.txt.
run() {
  local task=$1
  shift
  "$ARX" -p "$task" --quiet "$@" >out.txt 2>err.txt
  code=$?
}

# reply N STATUS [HEADER...] < BODY: the response for model call N.
reply() {
  local n=$1 status=$2
  shift 2
  {
    echo "HTTP/1.1 $status"
    for h in "$@"; do echo "$h"; done
    echo
    cat
  } >"$FAKE_DIR/$(printf %02d "$n").resp"
}

# curl_exit N CODE: model call N fails like curl exiting with CODE.
curl_exit() { echo "EXIT $2" >"$FAKE_DIR/$(printf %02d "$1").resp"; }

# The usage chunk and [DONE] that end every streamed reply.
sse_end() {
  printf 'data: {"choices":[],"usage":{"prompt_tokens":%d,' \
    "${PROMPT_TOKENS:-100}"
  printf '"completion_tokens":10,"cost":0.001}}\n\ndata: [DONE]\n\n'
}

# A streamed text reply.
sse_text() {
  printf 'data: {"choices":[{"index":0,"delta":{"role":"assistant",'
  printf '"content":"%s"}}]}\n\n' "$1"
  printf 'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}'
  printf '\n\n'
  sse_end
}

# A streamed tool call. ARGS is JSON escaped for a JSON string; it is sent
# in two pieces, as providers do.
sse_tool() {
  local half=$((${#2} / 2))
  # Never split inside an escape such as \" (it would not be valid JSON).
  while [ "$half" -gt 0 ] && [ "${2:$((half - 1)):1}" = '\' ]; do
    half=$((half + 1))
  done
  printf 'data: {"choices":[{"index":0,"delta":{"role":"assistant",'
  printf '"tool_calls":[{"index":0,"id":"call_%s","type":"function",' "$RANDOM"
  printf '"function":{"name":"%s","arguments":""}}]}}]}\n\n' "$1"
  printf 'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,'
  printf '"function":{"arguments":"%s"}}]}}]}\n\n' "${2:0:$half}"
  printf 'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,'
  printf '"function":{"arguments":"%s"}}]}}]}\n\n' "${2:$half}"
  printf 'data: {"choices":[{"index":0,"delta":{},'
  printf '"finish_reason":"tool_calls"}]}\n\n'
  sse_end
}

# Writes an executable script.
script() {
  mkdir -p "$(dirname "$1")"
  cat >"$1"
  chmod +x "$1"
}

# release_site DIR: a download site in DIR with this build as release
# v9.9.9, for install.sh and arx update (ARX_DOWNLOAD_URL=file://DIR).
release_site() {
  local name dl=$1/releases/download/v9.9.9
  name=arx-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m | sed 's/aarch64/arm64/')
  mkdir -p "$1/build/$name/bin" "$1/build/$name/libexec/arx" "$dl"
  cp "$ARX" "$1/build/$name/bin/arx"
  cp "$ROOT"/commands/arx-* "$1/build/$name/libexec/arx/"
  cp -R "$ROOT/commands/lib" "$1/build/$name/libexec/arx/"
  tar -C "$1/build" -czf "$dl/$name.tar.gz" "$name"
  (cd "$dl" && { sha256sum "$name.tar.gz" 2>/dev/null || shasum -a 256 "$name.tar.gz"; } >"$name.tar.gz.sha256")
  echo v9.9.9 >"$1/releases/latest"
}

# Records a passing check.
ok() {
  passed=$((passed + 1))
  echo "  ok    $name: $1"
}

# Records a failing check, with the workspace's stderr for context.
fail() {
  failed=$((failed + 1))
  echo "  FAIL  $name: $1  (workspace $WS)"
  sed 's/^/        /' err.txt 2>/dev/null | head -15
}

# check DESCRIPTION COMMAND...: passes when the command succeeds.
check() {
  local what=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$what"; else fail "$what"; fi
}

# True when FILE contains PATTERN (fixed string).
has() { grep -qF -- "$2" "$1"; }

# True when FILE does not contain PATTERN.
lacks() { ! grep -qF -- "$2" "$1"; }

# True when $code equals the argument.
exited() { [ "$code" -eq "$1" ]; }

# Number of lines in FILE that contain PATTERN.
count() { grep -cF -- "$2" "$1"; }

# Prints the totals and returns non-zero if anything failed.
summary() {
  echo
  echo "$passed passed, $failed failed"
  [ "$failed" -eq 0 ]
}
