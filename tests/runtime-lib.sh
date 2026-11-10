#!/usr/bin/env bash
# runtime-lib.sh: helpers for the tests of the tool runtime (runtime.sh and
# background.sh): replies with several tool calls, a `nap` tool that sleeps
# and leaves marker files, hooks and scheduler plugins written in Python,
# and checks on time and order. Source it after lib.sh.

EVENTS=.arx/sessions/last/events.jsonl
TRANSCRIPT=.arx/sessions/last/transcript.jsonl

# A streamed reply with several tool calls: sse_calls NAME ARGS [NAME ARGS
# ...]. ARGS is JSON escaped for a JSON string. The ids are call_1, call_2...
# With CALL_BASE=N they start at call_N+1, so that the ids of two replies
# differ, as a provider's do.
sse_calls() {
  local i=0 sep="" base=${CALL_BASE:-0}
  printf 'data: {"choices":[{"index":0,"delta":{"role":"assistant",'
  printf '"tool_calls":['
  while [ $# -gt 0 ]; do
    printf '%s{"index":%d,"id":"call_%d","type":"function",' "$sep" "$i" \
      $((base + i + 1))
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

# nap KEYS: a tool tools/nap with the keys KEYS (JSON, or "" for none). A
# call {"x", "secs"} writes start-x and end-x around a sleep to log.txt,
# and exits with "exit" (0 when missing).
nap() {
  script tools/nap <<'EOF'
#!/usr/bin/env python3
import json, sys, time
args = json.load(sys.stdin)
x = args.get("x", "?")
open("log.txt", "a").write("start-%s\n" % x)
open("started-%s" % x, "w").close()
time.sleep(float(args.get("secs", 1)))
open("log.txt", "a").write("end-%s\n" % x)
print("napped-%s" % x)
sys.exit(int(args.get("exit", 0)))
EOF
  local keys=""
  [ -n "$1" ] && keys=", \"keys\": $1"
  cat >tools/nap.json <<EOF
{"description": "Sleeps.", "parameters": {"type": "object",
 "properties": {"x": {"type": "string"}, "secs": {"type": "number"}}}$keys}
EOF
}

# The wall clock in seconds, with a fraction.
now() { python3 -c 'import time; print(time.time())'; }

# True when $2 - $1 is below $3 seconds.
within() { awk -v a="$1" -v b="$2" -v l="$3" 'BEGIN { exit !(b - a < l) }'; }

# True when log.txt has the lines in this order, one after another.
in_order() { [ "$(tr '\n' ' ' <log.txt)" = "$* " ]; }

# The tool_call_ids of the tool messages in request N, in order.
result_ids() {
  python3 -c '
import json, sys
req = json.load(open(sys.argv[1]))
print(" ".join(m["tool_call_id"] for m in req["messages"] if m["role"] == "tool"))
' "fake/req-$(printf %02d "$1").json"
}

# hook PATH < PYTHON: a hook written in Python; `obj` is the input and
# out(...) prints fields. Each input is appended to PATH.in.
hook() {
  local path=$1
  script "$path" <<EOF
#!/usr/bin/env python3
import json, sys
obj = json.load(sys.stdin)
with open("$WS/$path.in", "a") as f:
    f.write(json.dumps(obj) + "\n")
def out(**fields):
    print(json.dumps(fields))
$(cat)
EOF
}

# sched PYTHON: a scheduler plugin at the top of the spec folder. `send`
# prints a message; every message from arx is appended to sched.log.
sched() {
  script scheduler <<EOF
#!/usr/bin/env python3
import json, sys, time
def send(**m):
    print(json.dumps(m), flush=True)
while True:
    line = sys.stdin.readline()
    if not line:
        break
    m = json.loads(line)
    open("sched.log", "a").write(json.dumps(m) + "\n")
$(cat)
EOF
}
