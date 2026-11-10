#!/usr/bin/env bash
# background.sh: tests calls that do not block, against tests/fake-curl. A
# test scheduler plugin moves a call to the background with `detach`: the
# model gets a placeholder at once, and the result arrives in the session
# inbox when the call ends, and reaches the model as a note. Also: cancel,
# Ctrl-C, the end of the session and --resume. Run with `make test`.
set -u
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/runtime-lib.sh"

INBOX=.arx/sessions/last/inbox

# bg_sched [PYTHON]: a scheduler that starts call_1 and moves it to the
# background at once, and starts every other call. More Python can follow
# on stdin; it runs for each message `m`.
bg_sched() {
  sched <<EOF
    if "ready" in m:
        r = m["ready"]
        if r["id"] == "call_1":
            send(start=["call_1"], detach=["call_1"])
        else:
            send(start=[r["id"]])
$(cat)
EOF
}

begin "detach at start"
nap '[]'
bg_sched </dev/null
hook hooks/stop <<'EOF'
pass
EOF
sse_calls nap '{\"x\":\"a\",\"secs\":0.5}' | reply 1 "200 OK"
sse_text "waiting" | reply 2 "200 OK"
sse_text "all done" | reply 3 "200 OK"
run "go" --json
check "exits 0" exited 0
check "the placeholder is the result" has fake/req-02.json 'started as c1 in the background. Its result comes later in a [harness] note.'
check "it names the output file" has fake/req-02.json 'Output so far: '
check "the model was not kept waiting" lacks fake/req-02.json 'napped-a'
check "a result line in the inbox" has $INBOX '"cmd":"result","call":"c1","id":"call_1","name":"nap"'
check "with the status and the text" grep -q '"status":"ok","secs":[0-9.]*,"text":"napped-a' $INBOX
check "arx waits, then the note arrives" grep -q 'c1 (nap: .*) finished after [0-9]*s:\\nnapped-a' fake/req-03.json
check "as a harness note" has fake/req-03.json '[harness]'
check "the stop hook ran once" test "$(wc -l <hooks/stop.in)" -eq 1
check "after the note" has hooks/stop.in '"last_message": "all done"'
check "the last answer is the result" has out.txt '"final_output":"all done"'
check "nothing is left in flight" grep -q '"calls":[[:space:]]*\[\]' .arx/sessions/last/meta.json
check "tool.detach names the call" has "$EVENTS" '"type":"tool.detach","id":"call_1","name":"nap","call":"c1","queued":false'
check "tool.end names it too" grep -q '"type":"tool.end","id":"call_1","name":"nap","call":"c1","detached":true' "$EVENTS"

begin "keeps working"
nap '[]'
bg_sched </dev/null
sse_calls nap '{\"x\":\"a\",\"secs\":1}' | reply 1 "200 OK"
CALL_BASE=1 sse_calls bash '{\"command\":\"echo hi-there\"}' | reply 2 "200 OK"
sse_text "waiting" | reply 3 "200 OK"
sse_text "done" | reply 4 "200 OK"
"$ARX" -p go >out.txt 2>err.txt
code=$?
check "exits 0" exited 0
check "tool.run for every call" test "$(count "$EVENTS" '"type":"tool.run"')" -eq 2
check "the view draws the detach" has err.txt '↳ c1 nap runs in the background'
check "and names the call when it ends" has err.txt '↳ c1 nap: exit 0'
check "another tool ran while c1 ran" has fake/req-03.json 'hi-there'
check "c1 was still running then" lacks fake/req-03.json 'finished after'
check "its note came later" has fake/req-04.json 'finished after'
check "one tool message per call, in call order" test "$(result_ids 4)" = "call_1 call_2"

begin "queued"
nap '[]'
sched <<'EOF'
    if "ready" in m:
        send(detach=["call_1"], wake_at=time.time() + 0.3)
    if "tick" in m:
        send(start=["call_1"])
EOF
sse_calls nap '{\"x\":\"a\",\"secs\":0}' | reply 1 "200 OK"
sse_text "waiting" | reply 2 "200 OK"
sse_text "done" | reply 3 "200 OK"
run "go"
check "the placeholder says queued" has fake/req-02.json 'queued as c1 in the background.'
check "no output file yet" lacks fake/req-02.json 'Output so far'
check "tool.detach says queued" has "$EVENTS" '"call":"c1","queued":true'
check "it ran on the tick, turns later" has fake/req-03.json 'napped-a'
check "tool.run comes after tool.detach" test "$(grep -n -o '"type":"tool.[a-z]*"' "$EVENTS" | cut -d'"' -f4 | tr '\n' ' ')" = "tool.start tool.detach tool.run tool.end "

begin "cancel from the scheduler"
nap '["*"]'
hook hooks/after_tool <<'EOF'
pass
EOF
bg_sched <<'EOF'
        if r["id"] == "call_2":
            send(cancel=["call_1"])
EOF
sse_calls nap '{\"x\":\"a\",\"secs\":5}' | reply 1 "200 OK"
CALL_BASE=1 sse_calls nap '{\"x\":\"b\",\"secs\":1}' | reply 2 "200 OK"
sse_text "done" | reply 3 "200 OK"
t0=$(now)
run "go"
t1=$(now)
check "a background call drops the key *" has log.txt 'start-b'
check "the call was stopped" lacks log.txt 'end-a'
check "without a wait" within "$t0" "$t1" 4
check "the status is cancelled" has $INBOX '"status":"cancelled"'
check "the note says so" grep -q 'c1 (nap: .*) was cancelled after' fake/req-03.json
check "with the [cancelled] line" has fake/req-03.json '[cancelled]'
check "after_tool saw the real result" has hooks/after_tool.in '[cancelled]'

begin "cancel queued, and a failed call"
nap '[]'
sched <<'EOF'
    if "ready" in m:
        r = m["ready"]
        if r["id"] == "call_1":
            send(detach=["call_1"])
        elif r["id"] == "call_2":
            send(start=["call_2"], detach=["call_2"])
        else:
            send(cancel=["c1"], start=[r["id"]])
EOF
sse_calls nap '{\"x\":\"a\",\"secs\":0}' nap '{\"x\":\"b\",\"secs\":0,\"exit\":1}' |
  reply 1 "200 OK"
CALL_BASE=2 sse_calls nap '{\"x\":\"c\",\"secs\":1}' | reply 2 "200 OK"
sse_text "done" | reply 3 "200 OK"
run "go"
check "two short ids" has fake/req-02.json 'started as c2'
check "the queued call ends at once" has fake/req-03.json '[cancelled before it started]'
check "it never ran" lacks log.txt 'start-a'
check "the scheduler gets done with ran false" has sched.log '{"done": {"id": "call_1", "secs": 0, "is_error": true, "backoff": null, "ran": false}}'
check "a non-zero exit is an error" grep -q '"call":"c2".*"status":"error".*\[exit code 1\]' $INBOX
check "the note says failed" grep -q 'c2 (nap: .*) failed after' fake/req-03.json
check "results that end together share one note" test "$(jq '[.messages[] | select(.role == "user" and (.content | startswith("[harness]")))] | length' fake/req-03.json)" -eq 1

begin "timeout"
nap '[]'
echo 'tools: {nap: {timeout: 1s}}' >>agent.yaml
bg_sched </dev/null
sse_calls nap '{\"x\":\"a\",\"secs\":5}' | reply 1 "200 OK"
sse_text "waiting" | reply 2 "200 OK"
sse_text "done" | reply 3 "200 OK"
run "go"
check "a timeout is an error" grep -q 'c1 (nap: .*) failed after' fake/req-03.json
check "with the timeout line" has fake/req-03.json '[timed out after 1s'

begin "scheduler failure"
nap '[]'
sched <<'EOF'
    send(start=["call_1"], detach=["call_1"])
    sys.exit(0)
EOF
sse_calls nap '{\"x\":\"a\",\"secs\":0.5}' | reply 1 "200 OK"
sse_text "waiting" | reply 2 "200 OK"
sse_text "done" | reply 3 "200 OK"
run "go"
check "exits 0" exited 0
check "an error event" has "$EVENTS" 'it exited; using the built-in scheduler'
check "the result still arrives" has fake/req-03.json 'finished after'

# After a fallback the built-in scheduler holds a background call's named
# keys, but not "*". a had "*" and b has file:x; c is free and d waits for b.
begin "keys"
nap '["{k}"]'
sched <<'EOF'
    if "ready" in m:
        send(start=[m["ready"]["id"]], detach=[m["ready"]["id"]])
        if m["ready"]["id"] == "call_2":
            sys.exit(0)
EOF
sse_calls nap '{\"x\":\"a\",\"secs\":1.5,\"k\":\"*\"}' \
  nap '{\"x\":\"b\",\"secs\":1.5,\"k\":\"file:x\"}' | reply 1 "200 OK"
CALL_BASE=2 sse_calls nap '{\"x\":\"c\",\"secs\":0,\"k\":\"file:y\"}' \
  nap '{\"x\":\"d\",\"secs\":0,\"k\":\"file:x\"}' | reply 2 "200 OK"
sse_text "done" | reply 3 "200 OK"
run "go"
line() { grep -n -x -- "$1" log.txt | cut -d: -f1; }
check "a background * call does not block" test "$(line start-c)" -lt "$(line end-a)"
check "a background file:x call blocks file:x" test "$(line start-d)" -gt "$(line end-b)"

# The model call takes a second. A background tool that prints 1 MB fills
# its pipe at once, so it ends in time only if every poll round drains it.
begin "no pipe stall"
script tools/big <<'EOF'
#!/usr/bin/env python3
import sys, time
if "--schema" in sys.argv:
    print('{"description": "Prints 1 MB.", "parameters": {"type": "object"}, "keys": []}')
    sys.exit(0)
start = time.time()
sys.stdout.write("x" * (1 << 20))
sys.stdout.flush()
open("big-secs", "w").write("%f" % (time.time() - start))
EOF
script slow-curl <<EOF
#!/bin/sh
sleep 1
exec "$ROOT/tests/fake-curl" "\$@"
EOF
bg_sched </dev/null
sse_calls big '{}' | reply 1 "200 OK"
sse_text "waiting" | reply 2 "200 OK"
sse_text "done" | reply 3 "200 OK"
ARX_CURL="$WS/slow-curl" run "go"
check "exits 0" exited 0
check "the tool ended during the model call" awk '{ exit !($1 < 0.8) }' big-secs
check "all of its output is saved" test "$(wc -c <.arx/sessions/last/tool-0001.out)" -eq 1048576

begin "ids"
nap '[]'
sched <<'EOF'
    if "ready" in m:
        r = m["ready"]
        if r["name"] == "nap":
            send(start=[r["id"]], detach=[r["id"]])
        else:
            send(start=[r["id"]])
EOF
sse_calls nap '{\"x\":\"a\",\"secs\":0}' nap '{\"x\":\"b\",\"secs\":0}' |
  reply 1 "200 OK"
CALL_BASE=2 sse_calls bash '{\"command\":\"sleep 0.5\"}' | reply 2 "200 OK"
run "go" --cap turns=2
check "two calls get c1 and c2" has fake/req-02.json 'started as c2'
check "meta.json keeps the counter" grep -q '"call_seq":[[:space:]]*2' .arx/sessions/last/meta.json
check "and the calls in flight" grep -q '"call":[[:space:]]*"c1"' .arx/sessions/last/meta.json
check "with the output file" grep -q '"out":[[:space:]]*".*/tool-0001.out"' .arx/sessions/last/meta.json
CALL_BASE=3 sse_calls nap '{\"x\":\"c\",\"secs\":0}' | reply 3 "200 OK"
sse_text "waiting" | reply 4 "200 OK"
sse_text "done" | reply 5 "200 OK"
run "more" --resume last
check "after --resume the next one is c3" has fake/req-04.json 'started as c3'

begin "Ctrl-C"
nap '[]'
hook hooks/after_tool <<'EOF'
pass
EOF
bg_sched </dev/null
sse_calls nap '{\"x\":\"a\",\"secs\":5}' | reply 1 "200 OK"
sse_text "waiting" | reply 2 "200 OK"
"$ARX" -p go --quiet >out.txt 2>err.txt &
pid=$!
for _ in $(seq 1 100); do [ -e fake/req-02.json ] && break; sleep 0.05; done
sleep 0.3
kill -INT "$pid"
wait "$pid"
code=$?
check "exits 130" exited 130
check "the call was stopped" lacks log.txt 'end-a'
check "its result line says stopped" has $INBOX '"status":"stopped"'
check "after_tool ran" has hooks/after_tool.in '[interrupted]'
check "meta.json still lists c1" grep -q '"call":[[:space:]]*"c1"' .arx/sessions/last/meta.json

begin "session end by a cap, then resume"
nap '[]'
bg_sched </dev/null
sse_calls nap '{\"x\":\"a\",\"secs\":5}' | reply 1 "200 OK"
CALL_BASE=1 sse_calls bash '{\"command\":\"true\"}' | reply 2 "200 OK"
t0=$(now)
run "go" --cap turns=2
t1=$(now)
check "the cap exits 3" exited 3
check "the call was stopped" lacks log.txt 'end-a'
check "without waiting for it" within "$t0" "$t1" 4
check "the inbox has a stopped line" grep -q '"status":"stopped".*\[stopped: the session ended\]' $INBOX
sse_text "done" | reply 3 "200 OK"
run "more" --resume last
check "resume exits 0" exited 0
check "the note says it was stopped" grep -q 'c1 (nap: .*) was stopped after' fake/req-03.json
check "nothing is left in flight" grep -q '"calls":[[:space:]]*\[\]' .arx/sessions/last/meta.json

begin "resume after a crash"
nap '[]'
bg_sched </dev/null
sse_calls nap '{\"x\":\"a\",\"secs\":2}' | reply 1 "200 OK"
sse_text "waiting" | reply 2 "200 OK"
"$ARX" -p go --quiet >out.txt 2>err.txt &
pid=$!
for _ in $(seq 1 100); do [ -e fake/req-02.json ] && break; sleep 0.05; done
sleep 0.3
kill -9 "$pid"
wait "$pid" 2>/dev/null
sse_text "done" | reply 3 "200 OK"
run "more" --resume last
check "resume exits 0" exited 0
check "the note says it did not finish" grep -q 'c1 (nap: .*) did not finish: the session stopped while it ran. Output so far: .*tool-0001.out' fake/req-03.json
check "nothing is left in flight" grep -q '"calls":[[:space:]]*\[\]' .arx/sessions/last/meta.json

begin "wall cap"
nap '[]'
bg_sched </dev/null
sse_calls nap '{\"x\":\"a\",\"secs\":5}' | reply 1 "200 OK"
sse_text "waiting" | reply 2 "200 OK"
t0=$(now)
run "go" --cap wall=1s
t1=$(now)
check "exits 3" exited 3
check "while it waited" within "$t0" "$t1" 3
check "the call was stopped" lacks log.txt 'end-a'

summary
