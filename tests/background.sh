#!/usr/bin/env bash
# background.sh: tests calls that do not block, against tests/fake-curl. A
# test scheduler plugin moves a call to the background with `detach`: the
# model gets a placeholder at once, and the result arrives in the session
# inbox when the call ends. Run with `make test`.
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
sse_calls nap '{\"x\":\"a\",\"secs\":0.3}' | reply 1 "200 OK"
CALL_BASE=1 sse_calls nap '{\"x\":\"b\",\"secs\":1}' | reply 2 "200 OK"
sse_text "done" | reply 3 "200 OK"
run "go"
check "exits 0" exited 0
check "the placeholder is the result" has fake/req-02.json 'started as c1 in the background. Its result comes later in a [harness] note.'
check "it names the output file" has fake/req-02.json 'Output so far: '
check "the model was not kept waiting" lacks fake/req-02.json 'napped-a'
check "a result line in the inbox" has $INBOX '"cmd":"result","call":"c1","id":"call_1","name":"nap"'
check "with the status and the text" grep -q '"status":"ok","secs":[0-9.]*,"text":"napped-a' $INBOX
check "one tool message per call, in call order" test "$(result_ids 3)" = "call_1 call_2"
check "tool.detach names the call" has "$EVENTS" '"type":"tool.detach","id":"call_1","name":"nap","call":"c1","queued":false'
check "tool.end names it too" grep -q '"type":"tool.end","id":"call_1","name":"nap","call":"c1","detached":true' "$EVENTS"

begin "queued"
nap '[]'
sched <<'EOF'
    if "ready" in m:
        r = m["ready"]
        if r["id"] == "call_1":
            send(detach=["call_1"], wake_at=time.time() + 0.3)
        else:
            send(start=[r["id"]])
    if "tick" in m:
        send(start=["call_1"])
EOF
sse_calls nap '{\"x\":\"a\",\"secs\":0}' | reply 1 "200 OK"
CALL_BASE=1 sse_calls nap '{\"x\":\"b\",\"secs\":1}' | reply 2 "200 OK"
sse_text "done" | reply 3 "200 OK"
run "go"
check "the placeholder says queued" has fake/req-02.json 'queued as c1 in the background.'
check "no output file yet" lacks fake/req-02.json 'Output so far'
check "tool.detach says queued" has "$EVENTS" '"call":"c1","queued":true'
check "it ran on the tick" has $INBOX 'napped-a'

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
check "the text says so" has $INBOX '[cancelled]'
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
check "the queued call ends at once" has $INBOX '[cancelled before it started]'
check "it never ran" lacks log.txt 'start-a'
check "the scheduler gets done with ran false" has sched.log '{"done": {"id": "call_1", "secs": 0, "is_error": true, "backoff": null, "ran": false}}'
check "a non-zero exit is an error" grep -q '"call":"c2".*"status":"error".*\[exit code 1\]' $INBOX

summary
