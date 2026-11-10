#!/usr/bin/env bash
# gate.sh: tests the harness_edit gate against tests/fake-curl: what the
# hook gets, accept and reject, the revert of a rejected change, stop and
# exit code 5, and the check right before arx runs a file. tests/trust.sh
# tests policy folders. Run with `make test`.
set -u
. "$(dirname "$0")/lib.sh"
unset ARX_POLICY
EVENTS=.arx/sessions/last/events.jsonl
PROMPTS_ONLY='{reject: [.changes[]
  | select(.kind != "prompt" and .kind != "skill"
      and (.kind != "spec" or (.keys - ["instructions", "first_message"] != [])))
  | {key: .path, value: "only prompts and skills may change in this run"}]
  | from_entries}'

# Gives the test its own config folder, like tests/trust.sh, and a spec
# with a prompt file, a hook and a tool.
fresh() {
  begin "$1"
  export ARX_CONFIG_DIR=$WS/config
  mkdir -p "$ARX_CONFIG_DIR/plugins" "$ARX_CONFIG_DIR/kits" prompts
  ln -s "$ROOT/plugins/shell" "$ARX_CONFIG_DIR/plugins/shell"
  : >"$ARX_CONFIG_DIR/config.yaml"
  { spec; echo 'instructions: {file: prompts/system.md}'; } >agent.yaml
  echo "old prompt" >prompts/system.md
  script hooks/after_tool <<<'#!/bin/sh'
  script tools/look <<'EOF'
#!/bin/sh
if [ "${1:-}" = --schema ]; then
  echo '{"description": "look", "parameters": {"type": "object", "properties": {}}}'
  exit 0
fi
echo look ran
EOF
}

# policy DIR FILTER [YAML]: a policy folder whose harness_edit hook logs its
# input to gate-in.jsonl, copies the first `old` file to old-copy.txt, and
# prints what the jq FILTER makes of the input.
policy() {
  mkdir -p "$1"
  printf 'name: %s\nversion: 0.1.0\ndescription: a test policy\n%s\n' "$(basename "$1")" "${3:-}" >"$1/plugin.yaml"
  script "$1/hooks/harness_edit" <<EOF
#!/bin/sh
in=\$(cat)
echo "\$in" >>"\$ARX_CWD/gate-in.jsonl"
old=\$(echo "\$in" | jq -r '[.changes[].old // empty][0] // empty')
if [ -n "\$old" ]; then cp "\$old" "\$ARX_CWD/old-copy.txt"; echo "\$old" >"\$ARX_CWD/old-path.txt"; fi
echo "\$in" | jq -c '$2'
EOF
}

# bash_then_done COMMAND...: one bash call for each command, then "done".
bash_then_done() {
  local n=0 c
  for c in "$@"; do
    n=$((n + 1))
    sse_tool bash "{\\\"command\\\":\\\"$c\\\"}" | reply "$n" "200 OK"
  done
  sse_text "done" | reply $((n + 1)) "200 OK"
}

# A streamed reply with two tool calls, as in tests/runtime.sh: sse_two
# NAME ARGS NAME ARGS. ARGS is JSON escaped for a JSON string.
sse_two() {
  printf 'data: {"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":['
  printf '{"index":0,"id":"call_1","type":"function","function":{"name":"%s","arguments":"%s"}},' "$1" "$2"
  printf '{"index":1,"id":"call_2","type":"function","function":{"name":"%s","arguments":"%s"}}' "$3" "$4"
  printf ']}}]}\n\ndata: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}\n\n'
  sse_end
}

# True when an event of TYPE matches the jq condition.
event() { jq -es "any(.[]; .type == \"$1\" and ($2))" "$EVENTS" >/dev/null; }

# The first change in the hook's input, as compact JSON of the jq FIELD.
change() { head -n 1 gate-in.jsonl | jq -c ".changes[0]$1"; }

fresh "an accepted edit"
policy pol/p "$PROMPTS_ONLY"
bash_then_done "echo new prompt >prompts/system.md"
run "go" --policy pol/p
check "exits 0" exited 0
check "the hook got the change" test "$(change '| [.rel, .layer, .kind, .change]')" = '["prompts/system.md","spec","prompt","changed"]'
check "old is a copy of the accepted version" has old-copy.txt 'old prompt'
check "in a private folder outside the working directory, deleted after" \
  sh -c 'p=$(cat old-path.txt); case $p in "$PWD"/*) exit 1 ;; esac; test ! -e "$p" -a ! -e "$(dirname "$p")"'
check "a harness.edit event with accept" event harness.edit '.decision == "accept" and .kind == "prompt"'
check "the new prompt is in use" has fake/req-02.json 'new prompt'
check "the hook event says policy" event hook '.point == "harness_edit" and .policy == true and .plugin == "p"'
check "session.start names the policy" event session.start '.policy == ["p"]'

fresh "a rejected new hook"
policy pol/p "$PROMPTS_ONLY"
bash_then_done "mkdir -p hooks && printf '#!/bin/sh\\\\ntouch marker\\\\n' >hooks/before_tool && chmod +x hooks/before_tool" "true"
run "go" --policy pol/p
check "exits 0" exited 0
check "the file is gone" test ! -e hooks/before_tool
check "the hook saw it as an added, executable hook" test "$(change '| [.kind, .change, .exec, has("old")]')" = '["hook","added",true,false]'
check "the agent's version is kept" has .arx/sessions/last/harness/rejected/1-hooks__before_tool 'touch marker'
check "the agent got the note" has fake/req-02.json 'The policy rejected your change to hooks/before_tool (only prompts and skills may change in this run). arx restored the previous version. Your version is in '
check "the hook never ran" test ! -e marker
check "a harness.edit event with reject" event harness.edit '.decision == "reject" and .policy == "p" and (.reason | startswith("only prompts"))'
check "harness.reload counts it" event harness.reload '.rejected == 1'

fresh "a rejected change to a tool and a removed hook"
policy pol/p "$PROMPTS_ONLY"
cp -p tools/look look.orig
bash_then_done "echo broken >tools/look; chmod 700 tools/look; rm hooks/after_tool"
run "go" --policy pol/p
check "the tool's bytes are back" cmp -s tools/look look.orig
check "and its mode" test -x tools/look -a "$(ls -l tools/look | cut -c1-10)" = "$(ls -l look.orig | cut -c1-10)"
check "the removed hook is back" test -x hooks/after_tool
check "two rejects" event harness.reload '.rejected == 2'

fresh "an edit that keeps the size and the mtime"
policy pol/p "$PROMPTS_ONLY"
cp -p tools/look look.orig
bash_then_done "sed 's/look ran/LOOK RAN/' look.orig >tools/look; touch -r look.orig tools/look"
run "go" --policy pol/p
check "it still counts as a change" event harness.edit '.kind == "tool" and .decision == "reject"'
check "and is reverted" cmp -s tools/look look.orig

fresh "spec edits: keys and pinned"
policy pol/p 'empty'
{ spec; echo 'limits: {max_turns: 9}'; } >agent.yaml
sed 's|http://fake.invalid/v1|http://fake.invalid/v2|; s|max_turns: 9|max_turns: 7|' agent.yaml >next.yaml
bash_then_done "cp next.yaml agent.yaml"
run "go" --policy pol/p --set limits.max_turns=5
check "keys name each changed value" test "$(change .keys)" = '["endpoint.base_url","limits.max_turns"]'
check "pinned names the keys that --set overrides" test "$(change .pinned)" = '["limits.max_turns"]'
check "path is absolute" test "$(change .path)" = "\"$WS/agent.yaml\""
check "the kind is spec" test "$(change .kind)" = '"spec"'

fresh "a kit edit under --kit"
policy pol/p 'empty'
mkdir -p "$ARX_CONFIG_DIR/kits/k"
printf 'name: k\nversion: 0.1.0\ndescription: a kit\nplugins: [shell]\n' >"$ARX_CONFIG_DIR/kits/k/kit.yaml"
bash_then_done "echo 'plugins: []' >>$ARX_CONFIG_DIR/kits/k/kit.yaml"
run "go" --policy pol/p --kit k
check "it reaches the hook as kind kit" test "$(change '| [.kind, .layer, .rel]')" = '["kit","kit:k","kit.yaml"]'

fresh "stop"
policy pol/p '{decision: "stop", reason: "no edits in this run"}'
bash_then_done "echo new >prompts/system.md" "true"
"$ARX" -p go --quiet --json --policy pol/p >out.txt 2>err.txt
code=$?
check "exits 5" exited 5
check "--json says policy" test "$(jq -r '[.status, .exit] | @csv' out.txt)" = '"policy",5'
check "session.end says policy" event session.end '.status == "policy"'
check "the edit event says stop, with the reason" event harness.edit '.decision == "stop" and .reason == "no edits in this run"'
check "no model call after it" test ! -e fake/req-02.json
check "the file is left as the agent wrote it" has prompts/system.md new

fresh "a failed hook"
policy pol/p 'empty'
script pol/p/hooks/harness_edit <<<'#!/bin/sh
exit 1'
bash_then_done "echo new >prompts/system.md"
run "go" --policy pol/p
check "fail is closed: the batch is rejected" has prompts/system.md 'old prompt'
check "with the reason" event harness.edit '.reason == "the harness_edit hook of p failed"'
rm -f fake/count
echo "new" >prompts/other.md
printf 'hooks: {harness_edit: {fail: open}}\n' >>pol/p/plugin.yaml
run "go" --policy pol/p
check "with fail: open the batch is accepted" has prompts/system.md new

fresh "two policies"
policy pol/a '{reject: {(.changes[] | select(.kind == "tool") | .path): "a says no tools", "/nope": "x"}}'
policy pol/b '{reject: {(.changes[] | select(.kind == "hook") | .path): "b says no hooks"}}'
cp -p tools/look look.orig
bash_then_done "echo x >>tools/look; echo x >>hooks/after_tool; echo new >prompts/system.md"
run "go" --policy pol/a --policy pol/b
check "both got the same input" test "$(jq -c '[.changes[].kind] | sort' gate-in.jsonl | sort -u | wc -l)" -eq 1
check "their rejects join" event harness.reload '.rejected == 2'
check "each reject names its policy" event harness.edit '.kind == "hook" and .policy == "b" and .reason == "b says no hooks"'
check "the prompt edit is accepted" has prompts/system.md new
check "an unknown path is ignored, and the event says so" event hook '.plugin == "a" and (.ignored | contains("/nope"))'
rm -f fake/count gate-in.jsonl
policy pol/a '{decision: "stop", reason: "a stops"}'
bash_then_done "echo newer >prompts/system.md"
run "go" --policy pol/a --policy pol/b
check "the first stop ends the run" exited 5
check "and the later hook does not run" test "$(wc -l <gate-in.jsonl)" -eq 1

fresh "a change in the policy folder"
policy pol/p 'empty'
bash_then_done "echo '# edited' >>pol/p/hooks/harness_edit" "true"
run "go" --policy pol/p
check "stops the run with exit 5" exited 5
check "before the changed hook runs" test ! -e gate-in.jsonl
check "the event says why" event harness.edit '.decision == "stop" and .layer == "policy:p"'

fresh "a file over the copy limit"
policy pol/p "$PROMPTS_ONLY"
head -c 5000000 /dev/zero >tools/big.json
bash_then_done "echo x >>tools/big.json" "true"
run "go" --policy pol/p
check "a rejected change to it stops the run with exit 5" exited 5
check "the hook got no old copy" test "$(change '| has("old")')" = false

fresh "a hook the agent changes runs only after the policy saw it"
policy pol/p "$PROMPTS_ONLY"
bash_then_done "echo 'touch marker' >>hooks/after_tool" "true"
run "go" --policy pol/p
check "exits 0" exited 0
check "the changed hook did not run in the same turn" test ! -e marker
check "its hook event says why" event hook '.point == "after_tool" and (.error | startswith("changed since the policy accepted it"))'
check "the reload then reverted it" lacks hooks/after_tool marker

fresh "a tool changed and called in the same reply"
policy pol/p 'empty'
sse_two bash '{\"command\":\"echo echo changed >>tools/look\"}' look '{}' | reply 1 "200 OK"
sse_tool look '{}' | reply 2 "200 OK"
sse_text "done" | reply 3 "200 OK"
run "go" --policy pol/p
check "the call ends with an error result" has fake/req-02.json 'changed since the policy accepted it; the policy sees it before the next model call'
check "once the policy accepted it, it runs" has fake/req-03.json 'look ran\nchanged'

fresh "a policy file changed and about to run"
policy pol/p 'empty'
script pol/p/hooks/after_tool <<<'#!/bin/sh'
bash_then_done "echo 'touch \$ARX_CWD/marker' >>pol/p/hooks/after_tool" "true"
run "go" --policy pol/p
check "the run stops with exit 5" exited 5
check "and the changed file never ran" test ! -e marker
check "before the next model call" test ! -e fake/req-02.json

fresh "a scheduler and a compactor the agent changes"
policy pol/p 'empty'
script bin/compact <<<'#!/bin/sh
cat'
{ spec; printf 'compactors: {mine: bin/compact}\ncompaction: {strategy: mine, trigger: 0.0001}\n'; } >agent.yaml
script staged <<<'#!/bin/sh
touch "$ARX_CWD/sched-ran"
cat >/dev/null'
sse_two bash '{\"command\":\"cp staged scheduler; echo touch compact-ran >>bin/compact\"}' look '{}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "go" --policy pol/p
check "exits 0" exited 0
check "the new scheduler reaches the gate as kind scheduler" event harness.edit '.kind == "scheduler" and .change == "added"'
check "the changed compactor counts as a change of kind program" event harness.edit '.kind == "program" and .decision == "accept"'

fresh "harness_edit outside a policy folder"
policy pol/p 'empty'
script hooks/harness_edit <<<'#!/bin/sh
touch "$ARX_CWD/spec-gate-ran"'
bash_then_done "echo new >prompts/system.md"
run "go" --policy pol/p
check "it never runs" test ! -e spec-gate-ran -a -e gate-in.jsonl

summary
