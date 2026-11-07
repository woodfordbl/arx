#!/usr/bin/env bash
# hooks.sh: tests the hook lifecycle on raw objects against tests/fake-curl:
# before_model and after_model, before_tool and after_tool on the raw call
# and result, chains across layers, the outputs hooks printed before (deny
# and note), "[ran as: ...]", after_tool after an error, a timeout and
# Ctrl-C, and the retry after a context overflow. Run with `make test`.
set -u
. "$(dirname "$0")/lib.sh"

# hook PATH < PYTHON: a hook written in Python. `obj` is the input; print
# the fields to change with out(...). Each input is appended to PATH.in.
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

# A plugin folder with an empty plugin.yaml.
plugin() {
  mkdir -p "$1"
  echo "description: test plugin" >"$1/plugin.yaml"
}

EVENTS=.arx/sessions/last/events.jsonl

begin "before_model: input"
hook hooks/before_model <<'EOF'
pass
EOF
echo 'model_settings: {temperature: 0.2}' >>agent.yaml
sse_text "done" | reply 1 "200 OK"
run "hello-task"
check "exits 0" exited 0
check "gets the messages" has hooks/before_model.in 'hello-task'
check "gets the tools" has hooks/before_model.in '"name": "bash"'
check "gets the model" has hooks/before_model.in '"model": "test-model"'
check "gets the settings" has hooks/before_model.in '"temperature": 0.2'
check "reason is turn" has hooks/before_model.in '"reason": "turn"'
check "gets point and turn" has hooks/before_model.in '"point": "before_model"'
check "no change, no reset" lacks .arx/sessions/last/transcript.jsonl '_reset'
check "no change listed" lacks "$EVENTS" '"changed"'

begin "before_model: changes"
hook hooks/before_model <<'EOF'
msgs = obj["messages"] + [{"role": "user", "content": "injected-by-hook"}]
out(messages=msgs, model="other-model", settings={"temperature": 0.9},
    tools=[t for t in obj["tools"] if t["function"]["name"] != "edit"])
EOF
sse_text "done" | reply 1 "200 OK"
run "go"
check "exits 0" exited 0
check "messages sent" has fake/req-01.json 'injected-by-hook'
check "model sent" has fake/req-01.json '"model":"other-model"'
check "settings sent" has fake/req-01.json '"temperature":0.9'
check "tools replaced" lacks fake/req-01.json '"name":"edit"'
check "bash kept" has fake/req-01.json '"name":"bash"'
check "transcript reset" has .arx/sessions/last/transcript.jsonl '{"_reset":true}'
check "history after the reset" sh -c "awk '/_reset/{f=1} f' .arx/sessions/last/transcript.jsonl | grep -q injected-by-hook"
check "event lists the changes" has "$EVENTS" '"changed":["messages","tools","model","settings"]'

begin "before_model: a bad field is ignored"
hook hooks/before_model <<'EOF'
out(messages="not a list")
EOF
sse_text "done" | reply 1 "200 OK"
run "go"
check "exits 0" exited 0
check "reported" has "$EVENTS" 'printed a bad \"messages\"'
check "history kept" has fake/req-01.json '"role":"user"'

begin "after_model"
hook hooks/after_model <<'EOF'
reply = obj["reply"]
reply["content"] = "rewritten-reply"
out(reply=reply)
EOF
sse_text "original-reply" | reply 1 "200 OK"
run "go" --json
check "exits 0" exited 0
check "gets the reply" has hooks/after_model.in 'original-reply'
check "gets the usage" has hooks/after_model.in '"prompt_tokens": 100'
check "gets the finish" has hooks/after_model.in '"finish": "stop"'
check "reply replaced" has out.txt 'rewritten-reply'
check "transcript has the new reply" has .arx/sessions/last/transcript.jsonl 'rewritten-reply'

begin "after_model: removes tool calls"
hook hooks/after_model <<'EOF'
reply = obj["reply"]
reply.pop("tool_calls", None)
reply["content"] = "no tools today"
out(reply=reply)
EOF
sse_tool bash '{\"command\":\"touch ran\"}' | reply 1 "200 OK"
run "go"
check "exits 0" exited 0
check "tool did not run" test ! -e ran
check "finish was tool_calls" has hooks/after_model.in '"finish": "tool_calls"'

begin "before_tool: rewrite"
hook hooks/before_tool <<'EOF'
if obj["args"].get("command") == "echo one":
    out(args={"command": "echo two"})
EOF
sse_tool bash '{\"command\":\"echo one\"}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "go"
check "exits 0" exited 0
check "gets the raw call" grep -q '"id": "call_.*"name": "bash", "args": {"command": "echo one"}' hooks/before_tool.in
check "rewritten call ran" grep -q 'two\\n\[ran as: echo two\]' fake/req-02.json
check "event lists args" has "$EVENTS" '"changed":["args"]'

begin "before_tool: rename"
script tools/shout <<'EOF'
#!/bin/sh
if [ "$1" = --schema ]; then echo '{"description":"Shout","parameters":{"type":"object"}}'; exit; fi
echo "SHOUTED $(cat)"
EOF
hook hooks/before_tool <<'EOF'
if obj["name"] == "bash":
    out(name="shout")
EOF
sse_tool bash '{\"command\":\"hi\"}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "go"
check "the other tool ran" has fake/req-02.json 'SHOUTED'
check "ran as names it" has fake/req-02.json '[ran as: shout hi]'

begin "before_tool: result skips the tool"
hook hooks/before_tool <<'EOF'
out(result="cached-answer")
EOF
hook hooks/after_tool <<'EOF'
pass
EOF
sse_tool bash '{\"command\":\"touch ran\"}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "go"
check "tool did not run" test ! -e ran
check "result sent" has fake/req-02.json 'cached-answer'
check "no ran-as line" lacks fake/req-02.json 'ran as'
check "after_tool skipped" test ! -e hooks/after_tool.in

begin "after_tool"
hook hooks/after_tool <<'EOF'
out(result=obj["result"].upper())
EOF
sse_tool bash '{\"command\":\"echo quiet\"}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "go"
check "gets the call" has hooks/after_tool.in '"call": {"id": "call_'
check "gets the result" has hooks/after_tool.in '"result": "quiet\n"'
check "gets is_error" has hooks/after_tool.in '"is_error": false'
check "result replaced" has fake/req-02.json 'QUIET'
check "event lists result" has "$EVENTS" '"changed":["result"]'

begin "old outputs"
script hooks/before_tool <<'EOF'
#!/bin/sh
grep -q 'rm -rf' && echo '{"decision":"deny","reason":"no deleting"}'
exit 0
EOF
script hooks/after_tool <<'EOF'
#!/bin/sh
echo '{"note":"a-note"}'
EOF
sse_tool bash '{\"command\":\"rm -rf x\"}' | reply 1 "200 OK"
sse_tool bash '{\"command\":\"echo kept\"}' | reply 2 "200 OK"
sse_text "done" | reply 3 "200 OK"
run "go"
check "deny becomes the result" has fake/req-02.json '"content":"denied: no deleting"'
check "deny event" has "$EVENTS" '"decision":"deny"'
check "note appended" grep -qF 'kept\n\n[after_tool] a-note' fake/req-03.json

begin "chain across layers"
plugin plugins/second
hook hooks/before_tool <<'EOF'
out(args={"command": "echo from-spec"})
EOF
hook plugins/second/hooks/before_tool <<'EOF'
out(args={"command": obj["args"]["command"] + "-and-plugin"})
EOF
hook hooks/after_tool <<'EOF'
out(result="spec-result")
EOF
hook plugins/second/hooks/after_tool <<'EOF'
out(result=obj["result"] + "+plugin")
EOF
sse_tool bash '{\"command\":\"echo model\"}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "go"
check "plugin hook sees the spec hook's call" has plugins/second/hooks/before_tool.in 'echo from-spec'
check "both rewrites ran" has fake/req-02.json '[ran as: echo from-spec-and-plugin]'
check "plugin hook sees the spec hook's result" has plugins/second/hooks/after_tool.in '"result": "spec-result"'
check "results chained" has fake/req-02.json 'spec-result+plugin'

begin "after_tool after an error and a timeout"
echo 'tools: {bash: {timeout: 1s}}' >>agent.yaml
hook hooks/after_tool <<'EOF'
out(note="error=%s" % obj["is_error"])
EOF
sse_tool bash '{\"command\":\"false\"}' | reply 1 "200 OK"
sse_tool bash '{\"command\":\"sleep 5\"}' | reply 2 "200 OK"
sse_text "done" | reply 3 "200 OK"
run "go"
check "ran after the error" has fake/req-02.json '[after_tool] error=True'
check "ran after the timeout" has fake/req-03.json '[after_tool] error=True'
check "both ran" test "$(wc -l <hooks/after_tool.in)" -eq 2

begin "after_tool after Ctrl-C"
hook hooks/after_tool <<'EOF'
open("after-ran", "w").write(obj["result"])
EOF
sse_tool bash '{\"command\":\"touch started; sleep 5\"}' | reply 1 "200 OK"
"$ARX" -p go --quiet >out.txt 2>err.txt &
pid=$!
for _ in $(seq 1 100); do [ -e started ] && break; sleep 0.05; done
kill -INT "$pid"
wait "$pid"
code=$?
check "exits 130" exited 130
check "after_tool ran" test -e after-ran

begin "context overflow: a before_model hook compacts"
hook hooks/before_model <<'EOF'
if obj["reason"] == "context_overflow":
    out(messages=obj["messages"][:1] + [{"role": "user", "content": "compacted-by-hook"}])
EOF
echo '{"error":{"message":"maximum context length exceeded"}}' | reply 1 "400 Bad Request"
sse_text "done" | reply 2 "200 OK"
run "go"
check "exits 0" exited 0
check "ran with the reason" has hooks/before_model.in '"reason": "context_overflow"'
check "retried with its messages" has fake/req-02.json 'compacted-by-hook'
check "transcript reset" sh -c "awk '/_reset/{f=1} f' .arx/sessions/last/transcript.jsonl | grep -q compacted-by-hook"
check "no built-in compaction" lacks "$EVENTS" '"type":"compact"'

begin "context overflow: built-in compaction without a hook"
hook hooks/before_model <<'EOF'
pass
EOF
cat >>agent.yaml <<'EOF'
compaction: {strategy: mask, keep: 0}
EOF
sse_tool bash '{\"command\":\"echo big-output\"}' | reply 1 "200 OK"
echo '{"error":{"message":"maximum context length exceeded"}}' | reply 2 "400 Bad Request"
sse_text "done" | reply 3 "200 OK"
run "go"
check "exits 0" exited 0
check "hook ran for the overflow" has hooks/before_model.in '"reason": "context_overflow"'
check "built-in compaction ran" has "$EVENTS" '"type":"compact"'
check "retried masked" has fake/req-03.json '[output cleared'

begin "context overflow: one retry only"
echo '{"error":{"message":"maximum context length exceeded"}}' | reply 1 "400 Bad Request"
echo '{"error":{"message":"maximum context length exceeded"}}' | reply 2 "400 Bad Request"
hook hooks/before_model <<'EOF'
if obj["reason"] == "context_overflow":
    out(messages=obj["messages"][:1] + [{"role": "user", "content": "short"}])
EOF
run "go"
check "exits 1" exited 1
check "two calls" test "$(cat fake/count)" -eq 2

begin "check lists the new points"
script hooks/before_model <<'EOF'
#!/bin/sh
EOF
script hooks/after_model <<'EOF'
#!/bin/sh
EOF
echo 'hooks: {before_model: {timeout: 5s}, after_model: {fail: open}}' >>agent.yaml
"$ARX" check >check.txt 2>&1
check "spec is valid" has check.txt 'ok:'
check "hooks listed" has check.txt 'before_model after_model'

summary
