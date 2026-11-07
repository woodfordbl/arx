#!/usr/bin/env bash
# runtime.sh: tests the tool runtime against tests/fake-curl: keys on each
# call ([] runs in parallel, one key runs one at a time, "*" runs alone),
# results in call order, keys from a before_tool hook, a timeout and Ctrl-C
# while calls run in parallel, parallel subagents, and a scheduler plugin
# (start, result, wake_at and tick, backoff) with its fallback to the
# built-in scheduler. Run with `make test`.
set -u
. "$(dirname "$0")/lib.sh"

EVENTS=.arx/sessions/last/events.jsonl
TRANSCRIPT=.arx/sessions/last/transcript.jsonl

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

# nap KEYS: a tool tools/nap with the keys KEYS (JSON, or "" for none). A
# call {"x", "secs"} writes start-x and end-x around a sleep to log.txt.
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

begin "keys []: calls run in parallel"
nap '[]'
sse_calls nap '{\"x\":\"a\",\"secs\":1}' nap '{\"x\":\"b\",\"secs\":1}' |
  reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
t0=$(now)
run "go"
t1=$(now)
check "exits 0" exited 0
check "both start before either ends" sh -c "head -2 log.txt | grep -c start | grep -qx 2"
check "two sleep 1 calls take about one second" within "$t0" "$t1" 1.8
check "both results" has fake/req-02.json 'napped-b'
check "tool.start has the id" has "$EVENTS" '"type":"tool.start","id":"call_2"'
check "tool.end has the id" grep -q '"type":"tool.end","id":"call_1"' "$EVENTS"

begin "keys: results in call order"
nap '[]'
sse_calls nap '{\"x\":\"slow\",\"secs\":1}' nap '{\"x\":\"fast\",\"secs\":0}' |
  reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "go"
check "exits 0" exited 0
check "the fast call ends first" test "$(tail -2 log.txt | tr '\n' ' ')" = "end-fast end-slow "
check "results in call order" test "$(result_ids 2)" = "call_1 call_2"
check "transcript in call order" sh -c "grep -o 'tool_call_id\":\"call_[12]' $TRANSCRIPT | tr '\n' ' ' | grep -q 'call_1.*call_2'"

begin "keys: one key runs one at a time"
nap '["lock:{x}"]'
sse_calls nap '{\"x\":\"a\",\"secs\":0.3}' nap '{\"x\":\"a\",\"secs\":0.3}' \
  nap '{\"x\":\"b\",\"secs\":0.1}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "go"
check "exits 0" exited 0
check "same key waits" sh -c "grep -n . log.txt | grep -E 'end-a|start-a' | cut -d: -f2 | tr '\n' ' ' | grep -qx 'start-a end-a start-a end-a '"
check "other key runs at once" sh -c "head -2 log.txt | grep -q start-b"

begin "keys: no keys means * and runs alone"
nap ''
sse_calls nap '{\"x\":\"a\",\"secs\":0.2}' nap '{\"x\":\"b\",\"secs\":0.2}' |
  reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "go"
check "one at a time" in_order start-a end-a start-b end-b

begin "keys: * waits for the calls before it, and later calls wait for it"
nap '[]'
sse_calls nap '{\"x\":\"a\",\"secs\":0.3}' \
  bash '{\"command\":\"echo start-sh >>log.txt; sleep 0.3; echo end-sh >>log.txt\"}' \
  nap '{\"x\":\"c\",\"secs\":0}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "go"
check "exits 0" exited 0
check "bash alone, in call order" in_order start-a end-a start-sh end-sh start-c end-c

begin "keys: edit uses file:{path}"
hook hooks/before_tool <<'EOF'
pass
EOF
sse_calls edit '{\"path\":\"a.txt\",\"old\":\"\",\"new\":\"one\"}' \
  edit '{\"path\":\"b.txt\",\"old\":\"\",\"new\":\"two\"}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "go"
check "exits 0" exited 0
check "both files" test "$(cat a.txt b.txt)" = "onetwo"
check "the hook sees the keys" has hooks/before_tool.in '"keys": ["file:a.txt"]'

begin "keys: a template fills in arguments and hosts"
nap '["host:{url}", "n:{n}", "none:{missing}"]'
hook hooks/before_tool <<'EOF'
pass
EOF
sse_calls nap '{\"x\":\"a\",\"secs\":0,\"url\":\"https://User@API.example.com:8443/v1?q\",\"n\":3}' |
  reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "go"
check "keys filled in" has hooks/before_tool.in '"keys": ["host:api.example.com", "n:3", "none:"]'

begin "keys: a before_tool hook sets them"
hook hooks/before_tool <<'EOF'
if obj["name"] == "bash":
    out(keys=[])
EOF
sse_calls \
  bash '{\"command\":\"echo start-a >>log.txt; sleep 0.5; echo end-a >>log.txt\"}' \
  bash '{\"command\":\"echo start-b >>log.txt; sleep 0.5; echo end-b >>log.txt\"}' |
  reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "go"
check "exits 0" exited 0
check "the hook sees *" has hooks/before_tool.in '"keys": ["*"]'
check "bash calls ran in parallel" sh -c "head -2 log.txt | grep -c start | grep -qx 2"

begin "keys: a renamed call takes the new tool's keys"
nap '[]'
hook hooks/before_tool <<'EOF'
if obj["name"] == "bash":
    out(name="nap", args={"x": obj["args"]["command"], "secs": 0.5})
EOF
sse_calls bash '{\"command\":\"a\"}' bash '{\"command\":\"b\"}' |
  reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "go"
check "ran in parallel" sh -c "head -2 log.txt | grep -c start | grep -qx 2"

begin "parallel: a timeout"
nap '[]'
echo 'tools: {nap: {timeout: 1s}}' >>agent.yaml
sse_calls nap '{\"x\":\"a\",\"secs\":5}' nap '{\"x\":\"b\",\"secs\":5}' |
  reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
t0=$(now)
run "go"
t1=$(now)
check "exits 0" exited 0
check "both timed out" test "$(grep -o 'timed out after 1s' fake/req-02.json | wc -l)" -eq 2
check "at the same time" within "$t0" "$t1" 3

begin "parallel: Ctrl-C"
nap '[]'
hook hooks/after_tool <<'EOF'
pass
EOF
sse_calls nap '{\"x\":\"a\",\"secs\":5}' nap '{\"x\":\"b\",\"secs\":5}' \
  bash '{\"command\":\"touch never\"}' | reply 1 "200 OK"
t0=$(now)
"$ARX" -p go --quiet >out.txt 2>err.txt &
pid=$!
for _ in $(seq 1 100); do [ -e started-a ] && [ -e started-b ] && break; sleep 0.05; done
kill -INT "$pid"
wait "$pid"
code=$?
t1=$(now)
check "exits 130" exited 130
check "stops quickly" within "$t0" "$t1" 4
check "both interrupted" test "$(grep -c '\[interrupted\]' $TRANSCRIPT)" -eq 2
check "the queued call did not run" test ! -e never
check "the queued call has a result" has "$TRANSCRIPT" 'interrupted before this tool ran'
check "after_tool ran for both" test "$(wc -l <hooks/after_tool.in)" -eq 2

begin "parallel subagents"
spec >sub.yaml
cat >>agent.yaml <<'EOF'
tools: {helper: {agent: sub.yaml}}
EOF
# Each subagent's model call takes a second, so two in a row take two.
script slow-curl <<EOF
#!/bin/sh
[ "\${ARX_DEPTH:-0}" = 1 ] && sleep 1
exec "$ROOT/tests/fake-curl" "\$@"
EOF
sse_calls helper '{\"task\":\"one\"}' helper '{\"task\":\"two\"}' |
  reply 1 "200 OK"
sse_text "sub-done" | reply 2 "200 OK"
sse_text "sub-done" | reply 3 "200 OK"
sse_text "done" | reply 4 "200 OK"
t0=$(now)
ARX_CURL="$WS/slow-curl" run "go"
t1=$(now)
check "exits 0" exited 0
check "both answers" test "$(grep -o 'sub-done' fake/req-04.json | wc -l)" -eq 2
check "in parallel" within "$t0" "$t1" 1.9
check "both forward their events" test "$(grep -c '"depth":1,"turn":[0-9]*,"type":"session.start"' $EVENTS)" -eq 2
check "event lines stay whole" python3 -c "
import json
for line in open('$EVENTS'): json.loads(line)"

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

begin "scheduler plugin: start, result, wake_at and backoff"
nap '["host:{url}"]'
sched <<'EOF'
    if "ready" in m:
        r = m["ready"]
        if r["id"] == "call_2":
            send(result={"id": "call_2", "text": "budget used up"})
        elif r["id"] == "call_3":
            send(wake_at=time.time() + 0.3)
        else:
            send(start=[r["id"]])
    if "tick" in m:
        send(start=["call_3"])
EOF
hook hooks/after_tool <<'EOF'
out(backoff={"key": "host:api.example.com", "secs": 30})
EOF
sse_calls nap '{\"x\":\"a\",\"secs\":0,\"url\":\"http://api.example.com/\"}' \
  nap '{\"x\":\"b\",\"secs\":0}' nap '{\"x\":\"c\",\"secs\":0}' |
  reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "go"
check "exits 0" exited 0
check "ready has name and keys" has sched.log '{"ready": {"id": "call_1", "name": "nap", "keys": ["host:api.example.com"]}}'
check "the started call ran" has fake/req-02.json 'napped-a'
check "a result ends a call without a run" has fake/req-02.json 'budget used up'
check "it did not run" lacks log.txt 'start-b'
check "a tick at wake_at" has sched.log '"tick"'
check "started on the tick" has fake/req-02.json 'napped-c'
check "done has the backoff" has sched.log '"backoff": {"key": "host:api.example.com", "secs": 30}'
check "done has secs and is_error" grep -q '"done": {"id": "call_1", "secs": [0-9.e-]*, "is_error": false' sched.log
check "results in call order" test "$(result_ids 2)" = "call_1 call_2 call_3"
check "no error" lacks "$EVENTS" '"type":"error"'

begin "scheduler plugin: bad output falls back"
nap '[]'
sched <<'EOF'
    print("not json", flush=True)
EOF
sse_calls nap '{\"x\":\"a\",\"secs\":0}' nap '{\"x\":\"b\",\"secs\":0}' |
  reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "go"
check "exits 0" exited 0
check "an error event" has "$EVENTS" 'printed a bad line: not json; using the built-in scheduler'
check "the calls still ran" has fake/req-02.json 'napped-b'

begin "scheduler plugin: exit falls back"
nap '[]'
script scheduler <<'EOF'
#!/bin/sh
exit 0
EOF
sse_calls nap '{\"x\":\"a\",\"secs\":0}' | reply 1 "200 OK"
sse_calls nap '{\"x\":\"b\",\"secs\":0}' | reply 2 "200 OK"
sse_text "done" | reply 3 "200 OK"
run "go"
check "exits 0" exited 0
check "an error event" has "$EVENTS" 'it exited; using the built-in scheduler'
check "reported once" test "$(grep -c 'using the built-in scheduler' $EVENTS)" -eq 1
check "the calls still ran" has fake/req-03.json 'napped-b'

summary
