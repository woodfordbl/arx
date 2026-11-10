#!/usr/bin/env bash
# mcp-lib.sh: helpers for the MCP suites (mcp.sh, mcp-servers.sh,
# mcp-http.sh), on top of lib.sh.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EVENTS=.arx/sessions/last/events.jsonl
TRANSCRIPT=.arx/sessions/last/transcript.jsonl
FAKE_MCP="$ROOT/tests/fake-mcp"

# Prints the spec with the YAML on stdin under mcp_servers.
mcp_spec() {
  spec
  echo "mcp_servers:"
  sed 's/^/  /'
}

# gh_spec [KEYS]: a spec with the fake server "gh" and extra entry keys.
gh_spec() {
  local extra=""
  [ $# -gt 0 ] && extra=", $*"
  echo "gh: {command: $FAKE_MCP, args: [gh]$extra}" | mcp_spec
}

# A streamed reply with several tool calls: sse_calls NAME ARGS [NAME ARGS
# ...]. ARGS is JSON escaped for a JSON string. The ids are call_1, call_2...
sse_calls() {
  local i=0 sep=""
  printf 'data: {"choices":[{"index":0,"delta":{"role":"assistant",'
  printf '"tool_calls":['
  while [ $# -gt 0 ]; do
    printf '%s{"index":%d,"id":"call_%d","type":"function",' "$sep" "$i" \
      $((i + 1))
    printf '"function":{"name":"%s","arguments":"%s"}}' "$1" "$2"
    sep=","
    i=$((i + 1))
    shift 2
  done
  printf ']}}]}\n\n'
  printf 'data: {"choices":[{"index":0,"delta":{},'
  printf '"finish_reason":"tool_calls"}]}\n\n'
  sse_end
}

# calls NAME ARGS...: one model reply per pair, in order, then a final
# answer. Call N's result is the last message of request N+1. It starts
# fake-curl's count again, so a workspace can run more than once.
calls() {
  local n=1
  rm -f "$FAKE_DIR"/count "$FAKE_DIR"/*.resp "$FAKE_DIR"/req-*.json
  while [ $# -gt 0 ]; do
    sse_tool "$1" "$2" | reply "$n" "200 OK"
    n=$((n + 1))
    shift 2
  done
  sse_text "done" | reply "$n" "200 OK"
}

# The result of tool call N of a run made with `calls`.
result() {
  jq -r '.messages[-1].content' "fake/req-$(printf %02d $(($1 + 1))).json"
}

# result_has N TEXT: true when the result of call N contains TEXT.
result_has() { result "$1" | grep -qF -- "$2"; }

# The tool names of model request N.
tool_names() {
  jq -r '[.tools[].function.name] | join(" ")' "fake/req-$(printf %02d "$1").json"
}

# The number of times the fake server NAME started.
starts() {
  if [ -f "fake/mcp-$1.starts" ]; then
    wc -l <"fake/mcp-$1.starts" | tr -d ' '
  else
    echo 0
  fi
}

# hook PATH < PYTHON: a hook written in Python; `obj` is the input and
# out(...) prints fields. Each input is appended to PATH.in.
hook() {
  local path=$1
  {
    echo '#!/usr/bin/env python3'
    echo 'import json, sys'
    echo 'obj = json.load(sys.stdin)'
    echo "with open(\"$WS/$path.in\", \"a\") as f:"
    echo '    f.write(json.dumps(obj) + "\n")'
    echo 'def out(**fields):'
    echo '    print(json.dumps(fields))'
    cat
  } | script "$path"
}

# Seconds since the epoch, with fractions.
now() { python3 -c 'import time; print(time.time())'; }

# within T0 T1 LIMIT: true when T1 - T0 is under LIMIT seconds.
within() { awk -v a="$1" -v b="$2" -v l="$3" 'BEGIN { exit !(b - a < l) }'; }
