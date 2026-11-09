#!/usr/bin/env bash
# plugins.sh: checks every plugin in the arx marketplace (plugins/), then
# runs them together in the demo harness in examples/plugins/ against
# fake-curl, so the plugin guide (docs/plugins.md) stays true. Run with
# `make test`.
set -u
. "$(dirname "$0")/lib.sh"

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
check "every plugin loads" has check.txt 'plugins: chatgpt clock fail-hint git-context guard keep-last never-stop notify op-key plugin-authoring reviewer shell word-count'

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

# The driver resumes a session each time the turn cap stops it.
begin_examples "driver"
sse_tool now '{}' | reply 1 "200 OK"
sse_tool bash '{\"command\":\"touch DONE\"}' | reply 2 "200 OK"
sse_text "done" | reply 3 "200 OK"
ARX="$ARX" sh drivers/resume_on_cap.sh "go" 3 1 >driver.txt 2>&1
check "driver resumed until done" has driver.txt 'finished with exit 0 after 3 round(s)'

summary
