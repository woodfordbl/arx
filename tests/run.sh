#!/usr/bin/env bash
# run.sh: end-to-end tests for arx against tests/fake-curl. No network and no
# API key: every model reply is scripted. Run with `make test`, which uses
# the sanitizer build (ARX=./arx-debug).
set -u
. "$(dirname "$0")/lib.sh"

# A plain reply: result JSON, events and transcript.
begin "text"
sse_text "Hello" | reply 1 "200 OK"
run "hi" --json
check "exits 0" exited 0
check "final_output in --json" has out.txt '"final_output":"Hello"'
check "events cover the session" has .arx/sessions/last/events.jsonl '"type":"session.end"'
check "transcript has 3 messages" test "$(wc -l <.arx/sessions/last/transcript.jsonl)" -eq 3

# Cost: usage.cost is 0 when Vercel AI Gateway uses your own provider key;
# the real price is in usage.market_cost.
begin "gateway cost"
{
  printf 'data: {"choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":"stop"}]}\n\n'
  printf 'data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2,"cost":0,"market_cost":0.0123}}\n\n'
  printf 'data: [DONE]\n\n'
} | reply 1 "200 OK"
run "hi" --json
check "cost from market_cost" has out.txt '"cost":0.0123'

# A tool call: the output reaches the next request.
begin "bash tool"
sse_tool bash '{\"command\":\"echo hi-there\"}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "go"
check "exits 0" exited 0
check "tool output in next request" has fake/req-02.json 'hi-there'
check "full output saved" has .arx/sessions/last/tool-0001.out 'hi-there'

# Transient errors are retried: 429 with Retry-After, 500, a curl timeout.
begin "retries"
reply 1 "429 Too Many Requests" "Retry-After: 0" <<<'{"error":{"message":"slow down"}}'
reply 2 "500 Internal Server Error" <<<'{"error":{"message":"oops"}}'
curl_exit 3 28
sse_text "made it" | reply 4 "200 OK"
run "go" --json
check "exits 0" exited 0
check "three retries" test "$(count .arx/sessions/last/events.jsonl model.retry)" -eq 3
check "answer after retries" has out.txt 'made it'

# A 401 stops with exit code 4.
begin "auth"
reply 1 "401 Unauthorized" <<<'{"error":{"message":"bad key"}}'
run "go"
check "exits 4" exited 4

# A reply that was not streamed is accepted too.
begin "non-streamed reply"
reply 1 "200 OK" <<<'{"choices":[{"message":{"role":"assistant","content":"plain"},"finish_reason":"stop"}]}'
run "go" --json
check "final_output from JSON body" has out.txt '"final_output":"plain"'

# Bad tool arguments go back to the model instead of crashing.
begin "bad tool json"
sse_tool bash '{not json' | reply 1 "200 OK"
sse_text "ok" | reply 2 "200 OK"
run "go"
check "exits 0" exited 0
check "model told the JSON is bad" has fake/req-02.json 'not a valid JSON object'

# edit: create, then an ambiguous replacement is refused.
begin "edit tool"
sse_tool edit '{\"path\":\"a.txt\",\"old\":\"\",\"new\":\"x x\"}' | reply 1 "200 OK"
sse_tool edit '{\"path\":\"a.txt\",\"old\":\"x\",\"new\":\"y\"}' | reply 2 "200 OK"
sse_text "done" | reply 3 "200 OK"
run "go"
check "file created" has a.txt 'x x'
check "ambiguous edit refused" has fake/req-03.json 'occurs 2 times'

# Hot reload: a tool the agent adds mid-session is offered next turn.
begin "hot reload: new tool"
script staged/hello <<'EOF'
#!/bin/sh
if [ "$1" = --schema ]; then echo '{"description":"Say hello","parameters":{"type":"object"}}'; exit; fi
echo hello-from-tool
EOF
sse_tool bash '{\"command\":\"mkdir -p tools && mv staged/hello tools/hello\"}' | reply 1 "200 OK"
sse_tool hello '{}' | reply 2 "200 OK"
sse_text "done" | reply 3 "200 OK"
run "go"
check "not offered before" lacks fake/req-01.json '"name":"hello"'
check "offered after the edit" has fake/req-02.json '"name":"hello"'
check "new tool ran" has fake/req-03.json 'hello-from-tool'
check "reload event" has .arx/sessions/last/events.jsonl '"type":"harness.reload"'

# The fingerprint also covers named programs and the scheduler file.
begin "hot reload: programs and the scheduler"
{ spec; echo "compactors: {mine: bin/compact}"; } >agent.yaml
script bin/compact <<<'#!/bin/sh'
sse_tool bash '{\"command\":\"echo cat >>bin/compact\"}' | reply 1 "200 OK"
sse_tool bash '{\"command\":\"true\"}' | reply 2 "200 OK"
sse_tool bash '{\"command\":\"echo x >scheduler\"}' | reply 3 "200 OK"
sse_text "done" | reply 4 "200 OK"
run "go"
check "a changed compactor and a new scheduler file each reload" \
  test "$(count .arx/sessions/last/events.jsonl '"type":"harness.reload"')" = 2

# A file in tools/ that is not executable is not a tool, and arx says why.
begin "tools: not executable"
mkdir tools
printf '#!/bin/sh\necho now\n' >tools/now
chmod 644 tools/now
sse_text "hi" | reply 1 "200 OK"
run "go"
check "it is not offered" lacks fake/req-01.json '"name":"now"'
"$ARX" check >check.txt 2>&1
check "arx check says why" has check.txt 'tools/now is not executable'

# A bad spec edit is rejected; the old spec keeps working.
begin "hot reload: bad spec"
{ spec; echo "modle: typo"; } >bad.yaml
sse_tool bash '{\"command\":\"cp bad.yaml agent.yaml\"}' | reply 1 "200 OK"
sse_text "fine" | reply 2 "200 OK"
run "go"
check "exits 0" exited 0
check "agent told why" has fake/req-02.json 'did you mean'

# --set overrides the spec; --cap turns stops the session.
begin "set and cap"
sse_tool bash '{\"command\":\"true\"}' | reply 1 "200 OK"
run "go" --set model=other-model --cap turns=1
check "model overridden" has fake/req-01.json '"model":"other-model"'
check "cap exits 3" exited 3

# Hooks: stop continues once; before_tool denies; a crashing after_tool hook
# (which runs only for calls that before_tool lets through) is ignored.
begin "hooks"
script hooks/stop <<'EOF'
#!/bin/sh
[ -f .stopped ] && exit 0
touch .stopped
echo '{"decision":"continue","message":"keep going"}'
EOF
script hooks/before_tool <<'EOF'
#!/bin/sh
grep -q 'rm -rf' && echo '{"decision":"deny","reason":"no deleting"}'
exit 0
EOF
script hooks/after_tool <<'EOF'
#!/bin/sh
exit 1
EOF
sse_text "first" | reply 1 "200 OK"
sse_tool bash '{\"command\":\"rm -rf x\"}' | reply 2 "200 OK"
sse_tool bash '{\"command\":\"true\"}' | reply 3 "200 OK"
sse_text "second" | reply 4 "200 OK"
run "go"
check "exits 0" exited 0
check "stop hook continued" has fake/req-02.json 'keep going'
check "before_tool denied" has fake/req-03.json 'denied: no deleting'
check "failed hook reported" has .arx/sessions/last/events.jsonl '"point":"after_tool","secs"'

# Restart via the stop hook drops the history.
begin "restart"
script hooks/stop <<'EOF'
#!/bin/sh
[ -f .done ] && exit 0
touch .done
echo '{"decision":"restart"}'
EOF
sse_text "first-answer" | reply 1 "200 OK"
sse_text "second-answer" | reply 2 "200 OK"
run "go"
check "history dropped" lacks fake/req-02.json 'first-answer'
check "compact event" has .arx/sessions/last/events.jsonl '"strategy":"restart"'

# Masking clears old tool outputs once the context passes the trigger.
begin "compaction: mask"
cat >>agent.yaml <<'EOF'
context_window: 1500
compaction: {strategy: mask, trigger: 0.5, keep: 1}
EOF
export PROMPT_TOKENS=0
for i in 1 2 3; do
  sse_tool bash '{\"command\":\"printf %0900d 0\"}' | reply "$i" "200 OK"
done
sse_text "done" | reply 4 "200 OK"
run "go"
unset PROMPT_TOKENS
check "exits 0" exited 0
check "outputs cleared" has fake/req-04.json '[output cleared'

# A subagent is arx again; its answer and events come back.
begin "subagent"
spec >sub.yaml
cat >>agent.yaml <<'EOF'
tools: {researcher: {agent: sub.yaml}}
EOF
sse_tool researcher '{\"task\":\"look it up\"}' | reply 1 "200 OK"
sse_text "sub-result" | reply 2 "200 OK"
sse_text "done" | reply 3 "200 OK"
run "go"
check "exits 0" exited 0
check "subagent got the task" has fake/req-02.json 'look it up'
check "answer returned" has fake/req-03.json 'sub-result'
check "child events forwarded" has .arx/sessions/last/events.jsonl '"depth":1'

# --resume continues a session with its history.
begin "resume"
sse_tool bash '{\"command\":\"echo from-run-one\"}' | reply 1 "200 OK"
run "go" --cap turns=1
sse_text "resumed" | reply 2 "200 OK"
run "continue" --resume last --json
check "exits 0" exited 0
check "history kept" has fake/req-02.json 'from-run-one'

# `arx ctl note` reaches the agent on its next turn.
begin "ctl note"
sse_tool bash '{\"command\":\"$ARX_BIN ctl $ARX_SESSION note hello-note\"}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "go"
check "note delivered" has fake/req-02.json 'hello-note'

# Observers receive the event stream.
begin "observer"
echo 'observers: ["cat > obs.jsonl"]' >>agent.yaml
sse_text "hi" | reply 1 "200 OK"
run "go"
check "observer saw session.end" has obs.jsonl '"type":"session.end"'

# Events hold the visible session: the prompt, a call's arguments, when its
# process started, and its output.
begin "events"
sse_tool bash '{\"command\":\"echo out-text\"}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "the task"
ev=.arx/sessions/last/events.jsonl
event() { jq -c "select(.type == \"$1\")" "$ev"; }
check "prompt.start has the task" test "$(event prompt.start | jq -r .text)" = "the task"
check "session.start has the window" test "$(event session.start | jq .context_window)" = 128000
check "session.start has the cwd" test "$(event session.start | jq -r .cwd)" = "$(pwd -P)"
check "tool.start has the arguments" test "$(event tool.start | jq -r .args.command)" = "echo out-text"
check "tool.end has the output" test "$(event tool.end | jq -r .output)" = "out-text"
check "tool.run is between start and end" test \
  "$(jq -r 'select(.type | startswith("tool.")) | .type' "$ev" | tr '\n' ' ')" = "tool.start tool.run tool.end "
check "tool.run names the call" test "$(event tool.run | jq -r .id)" = "$(event tool.start | jq -r .id)"
check "headless has no prompt.end" lacks "$ev" '"type":"prompt.end"'

# Arguments over 16 KB stay out of tool.start; ones that are not JSON go in
# as the raw string.
begin "event args"
big=$(printf 'x%.0s' $(seq 1 17000))
sse_tool bash "{\\\"command\\\":\\\"true $big\\\"}" | reply 1 "200 OK"
sse_tool bash 'not json' | reply 2 "200 OK"
sse_text "done" | reply 3 "200 OK"
run "go"
ev=.arx/sessions/last/events.jsonl
check "big arguments are cut" test \
  "$(jq -c 'select(.type == "tool.start" and .turn == 1) | [.args, .args_cut]' "$ev")" = "[null,true]"
check "raw arguments are a string" test \
  "$(jq -r 'select(.type == "tool.start" and .turn == 2) | .args' "$ev")" = "not json"

# Interactive mode: each line is a prompt with its own start and end.
begin "interactive events"
sse_text "first-answer" | reply 1 "200 OK"
sse_text "second-answer" | reply 2 "200 OK"
python3 "$ROOT/tests/pty.py" --screen screen.txt \
  --keys 'one<enter><wait:first-answer>two<enter><wait:second-answer><c-d>' -- "$ARX" >/dev/null 2>err.txt
ev=.arx/sessions/last/events.jsonl
check "two prompts start" test "$(jq -r 'select(.type == "prompt.start") | .text' "$ev" | tr '\n' ' ')" = "one two "
check "each prompt ends with its answer" test \
  "$(jq -r 'select(.type == "prompt.end") | "\(.status) \(.turns) \(.final_output)"' "$ev" | tr '\n' ',')" = \
  "done 1 first-answer,done 2 second-answer,"

# --input jsonl: prompts arrive as JSON lines, in one process and session.
begin "input jsonl"
sse_text "first-answer" | reply 1 "200 OK"
sse_text "second-answer" | reply 2 "200 OK"
printf '%s\n' '{"prompt":"one","extra":1}' '' 'not json' '{"prompt":7}' '{"prompt":"/exit"}' |
  "$ARX" --input jsonl --quiet >out.txt 2>err.txt
code=$?
ev=.arx/sessions/last/events.jsonl
check "exits 0 at the end of stdin" exited 0
check "one session" test "$(ls .arx/sessions | grep -vc last)" -eq 1
check "each prompt ends done" test \
  "$(jq -r 'select(.type == "prompt.end") | "\(.status) \(.final_output)"' "$ev" | tr '\n' ',')" = \
  "done first-answer,done second-answer,"
check "the second request holds the first exchange" has fake/req-02.json 'first-answer'
check "/exit is text" test "$(jq -r '.messages[-1].content' fake/req-02.json)" = "/exit"
check "a bad line is an error event" test "$(jq -r 'select(.type == "error") | .error' "$ev" | tr '\n' ',')" = \
  'bad input line: not json,bad input line: {"prompt":7},'
check "the session ends" has "$ev" '"type":"session.end"'
"$ARX" --input jsonl -p x >/dev/null 2>err.txt </dev/null
code=$?
check "-p is a usage error" exited 2
check "it says why" has err.txt 'arx: --input jsonl does not take -p'

# waitfor FILE PATTERN: waits up to 5 s for PATTERN to show in FILE.
waitfor() {
  for _ in $(seq 1 100); do
    grep -qF -- "$2" "$1" 2>/dev/null && return 0
    sleep 0.05
  done
  return 1
}

# --input jsonl and signals: Ctrl-C ends a prompt, never the session.
begin "input jsonl signals"
sse_tool bash '{\"command\":\"sleep 30\"}' | reply 1 "200 OK"
sse_text "after-cancel" | reply 2 "200 OK"
mkfifo in
"$ARX" --input jsonl --quiet <in >out.txt 2>err.txt &
pid=$!
exec 9>in
ev=.arx/sessions/last/events.jsonl
waitfor "$ev" '"type":"session.start"'
kill -INT "$pid"
sleep 0.3
check "a SIGINT while idle does not end the session" kill -0 "$pid"
echo '{"prompt":"sleep"}' >&9
waitfor "$ev" '"type":"tool.run"'
kill -INT "$pid"
check "a SIGINT ends the prompt" waitfor "$ev" '"type":"prompt.end"'
check "its status is interrupted" test "$(jq -r 'select(.type == "prompt.end") | .status' "$ev")" = interrupted
echo '{"prompt":"again"}' >&9
check "the next prompt works" waitfor "$ev" '"final_output":"after-cancel"'
exec 9>&-
wait "$pid"
code=$?
check "the end of stdin ends the session" exited 0
rm -rf .arx
"$ARX" --input jsonl --quiet <in >out.txt 2>err.txt &
pid=$!
exec 9>in
waitfor "$ev" '"type":"session.start"'
kill -TERM "$pid"
wait "$pid"
code=$?
exec 9>&-
check "a SIGTERM while idle ends the session" exited 130

# `arx ctl stop` ends the prompt that runs, not the ones after it.
begin "input jsonl stop"
sse_tool bash '{\"command\":\"$ARX_BIN ctl $ARX_SESSION stop\"}' | reply 1 "200 OK"
sse_text "second-answer" | reply 2 "200 OK"
printf '%s\n' '{"prompt":"one"}' '{"prompt":"two"}' | "$ARX" --input jsonl --quiet >out.txt 2>err.txt
ev=.arx/sessions/last/events.jsonl
check "stop ends the first prompt" test \
  "$(jq -r 'select(.type == "prompt.end") | "\(.turns) \(.final_output)"' "$ev" | tr '\n' ',')" = "1 ,2 second-answer,"

# Subcommands.
begin "cli"
sse_text "hi" | reply 1 "200 OK"
run "go"
"$ARX" watch last >watch.txt 2>&1
check "watch replays the session" has watch.txt '● done'
"$ARX" check >check.txt 2>&1
check "check passes" has check.txt 'ok:'
echo "tols: {}" >>agent.yaml
"$ARX" check >check.txt 2>&1
code=$?
check "check rejects a typo" exited 2
check "check suggests the key" has check.txt 'did you mean "tools"'
"$ARX" schema >schema.json
check "schema is JSON" python3 -m json.tool schema.json
"$ARX" >/dev/null 2>err.txt </dev/null
code=$?
check "no task is a usage error" exited 2

summary
