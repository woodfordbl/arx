#!/usr/bin/env bash
# plugins.sh: checks every plugin in the arx marketplace (plugins/), then
# runs them together in the demo harness in examples/plugins/ against
# fake-curl, so the plugin guide (docs/plugins.md) stays true. The
# background plugin gets its own harness at the end: subagents in the
# background, `max`, `after` and cancel_call. Run with `make test`.
set -u
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/runtime-lib.sh"

# Starts a test in a temp workspace holding a copy of the demo harness, with
# the marketplace copied in as its plugins/.
begin_examples() {
  begin "$1"
  cp -RL "$ROOT/examples/plugins/." .
}

# Each plugin is valid on its own, the way `arx plugin add` checks it.
begin "marketplace"
for dir in "$ROOT"/plugins/*/; do
  check "$(basename "$dir") passes check --plugin" "$ARX" check --plugin "$dir"
done

# The spec, tools, subagent and hooks load.
begin_examples "check"
"$ARX" check >check.txt 2>&1
check "spec is valid" has check.txt 'ok:'
check "python tool found" has check.txt 'word_count'
check "shell tool found" has check.txt ' now'
check "subagent found" has check.txt 'reviewer'
check "all four hooks found" has check.txt 'session_start(git-context) before_tool(guard) after_tool(fail-hint) stop'
check "every plugin loads" has check.txt 'plugins: background chatgpt clock fail-hint git-context guard keep-last mcp-oauth never-stop notify op-key plugin-authoring reviewer shell word-count'

# Tools, every hook, and the observer in one session.
begin_examples "tools, hooks, observer"
git init -q . && touch untracked.txt
sse_tool word_count '{\"path\":\"agent.yaml\"}' | reply 1 "200 OK"
sse_tool now '{}' | reply 2 "200 OK"
sse_tool bash '{\"command\":\"git push --force\"}' | reply 3 "200 OK"
sse_tool bash '{\"command\":\"false\"}' | reply 4 "200 OK"
sse_text "all done" | reply 5 "200 OK"
sse_tool bash '{\"command\":\"touch DONE\"}' | reply 6 "200 OK"
sse_text "done now" | reply 7 "200 OK"
run "count the words"
check "exits 0" exited 0
check "session_start added git status" has fake/req-01.json 'untracked.txt'
check "python tool answered" has fake/req-02.json ' words, '
check "shell tool answered" grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}T' fake/req-03.json
check "before_tool denied a force push" has fake/req-04.json 'denied: destructive command'
check "after_tool added a note" has fake/req-05.json 'Read the full output file'
check "stop hook sent it back" has fake/req-06.json 'create the file DONE'
check "observer reported the end" has err.txt 'ended: done'

# The compactor drops old messages once the prompt passes the trigger.
begin_examples "compactor"
export PROMPT_TOKENS=0
for i in $(seq 1 16); do sse_tool now '{}' | reply "$i" "200 OK"; done
sse_tool bash '{\"command\":\"touch DONE\"}' | reply 17 "200 OK"
sse_text "done" | reply 18 "200 OK"
run "go" --set context_window=1500
unset PROMPT_TOKENS
check "exits 0" exited 0
check "compactor ran" has .arx/sessions/last/events.jsonl '"strategy":"keep_last"'
check "old messages dropped" has fake/req-18.json 'earlier messages were dropped'

# The subagent runs with its own spec and answers the parent.
begin_examples "subagent"
sse_tool reviewer '{\"task\":\"review agent.yaml\"}' | reply 1 "200 OK"
sse_text "1. nothing serious" | reply 2 "200 OK"
sse_tool bash '{\"command\":\"touch DONE\"}' | reply 3 "200 OK"
sse_text "done" | reply 4 "200 OK"
run "get a review"
check "exits 0" exited 0
check "review came back" has fake/req-03.json 'nothing serious'
check "reviewer has no edit tool" lacks fake/req-02.json '"name":"edit"'

# The coding kit's prompt, then the line that plugin-authoring adds.
begin_examples "coding kit prompt"
mkdir -p kits && cp -R "$ROOT/kits/coding" kits/ && touch DONE
sse_text "done" | reply 1 "200 OK"
run "go" --kit coding
check "exits 0" exited 0
msg0 1 >msg0.txt
check "message 0 starts with the kit's prompt" grep -q '^You are a coding agent' msg0.txt
check "and ends with plugin-authoring's line" [ "$(tail -1 msg0.txt)" = "Before you add a tool, hook or observer to your harness, read the plugin-authoring skill." ]
"$ARX" check --kit coding >check.txt 2>&1
check "arx check names it" has check.txt 'prompt: kit coding; plugins add plugin-authoring (89 bytes)'

# The driver resumes a session each time the turn cap stops it.
begin_examples "driver"
sse_tool now '{}' | reply 1 "200 OK"
sse_tool bash '{\"command\":\"touch DONE\"}' | reply 2 "200 OK"
sse_text "done" | reply 3 "200 OK"
ARX="$ARX" sh drivers/resume_on_cap.sh "go" 3 1 >driver.txt 2>&1
check "driver resumed until done" has driver.txt 'finished with exit 0 after 3 round(s)'

# bg_plugin SETTINGS: a harness whose active list is shell and the
# background plugin with SETTINGS (a YAML mapping).
bg_plugin() {
  mkdir -p plugins
  ln -s "$ROOT/plugins/background" plugins/background
  echo "plugins: [shell, {background: $1}]" >>agent.yaml
}

# Two subagents with max 1: the first starts, the second waits. The parent
# and the subagents race for the scripted replies, so replies 2 to 6 are the
# same text: three parent turns and one answer for each subagent.
begin "background: subagents run in the background"
bg_plugin '{max: 1}'
spec >sub.yaml
echo 'tools: {helper: {agent: sub.yaml}}' >>agent.yaml
sse_calls helper '{\"task\":\"one\"}' helper '{\"task\":\"two\"}' |
  reply 1 "200 OK"
for i in 2 3 4 5 6; do sse_text "fine" | reply "$i" "200 OK"; done
"$ARX" -p go >out.txt 2>err.txt
code=$?
cat fake/req-*.json >all.txt
check "exits 0" exited 0
check "the prompt explains background calls" has fake/req-01.json 'Some tool calls run in the background.'
check "the first subagent starts" has all.txt 'started as c1 in the background'
check "max 1 queues the second" has all.txt 'queued as c2 in the background'
check "the first answer arrives as a note" grep -q 'c1 (helper: one) finished after [0-9]*s:\\nfine' all.txt
check "then the second" grep -q 'c2 (helper: two) finished after' all.txt
check "the second started when the first ended" test "$(grep -o '"type":"tool.[a-z]*","id":"call_[12]"' "$EVENTS" | cut -d'"' -f4,8 | tr '\n"' ' :' | sed 's/.*tool.end:call_1 //')" = "tool.run:call_2 tool.end:call_2 "
check "their events are forwarded" has "$EVENTS" '"depth":1'
check "but the view does not draw them" lacks err.txt '│'

begin "background: after, and cancel_call"
bg_plugin '{after: 0.3s}'
nap '[]'
sse_calls nap '{\"x\":\"a\",\"secs\":5}' | reply 1 "200 OK"
CALL_BASE=1 sse_calls cancel_call '{\"id\":\"c9\"}' cancel_call '{\"id\":\"c1\"}' |
  reply 2 "200 OK"
sse_text "waiting" | reply 3 "200 OK"
sse_text "done" | reply 4 "200 OK"
t0=$(now)
run "go"
t1=$(now)
check "exits 0" exited 0
check "a long call moves to the background" has fake/req-02.json 'started as c1 in the background'
check "an unknown id fails" has fake/req-03.json 'No call c9 is in flight.'
check "and lists the calls in flight" has fake/req-03.json 'In flight: c1 (nap, started '
check "cancel_call cancels" has fake/req-03.json 'Cancel sent to c1.'
check "the note confirms it" grep -q 'c1 (nap: .*) was cancelled after' fake/req-04.json
check "the call did not run to its end" within "$t0" "$t1" 4

begin "background: a named tool"
bg_plugin '{tools: [nap]}'
nap '[]'
sse_calls nap '{\"x\":\"a\",\"secs\":2}' bash '{\"command\":\"echo hi-there\"}' |
  reply 1 "200 OK"
sse_text "waiting" | reply 2 "200 OK"
sse_text "done" | reply 3 "200 OK"
run "go"
check "exits 0" exited 0
check "the named tool goes to the background at once" has fake/req-02.json 'started as c1 in the background'
check "other tools stay in the foreground" has fake/req-02.json 'hi-there'
check "its result arrives" has fake/req-03.json 'napped-a'

summary
