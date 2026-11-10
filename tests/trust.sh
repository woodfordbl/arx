#!/usr/bin/env bash
# trust.sh: tests policy folders against tests/fake-curl: --policy and
# ARX_POLICY, what a policy puts first (hooks, tools, text, settings), and
# that no list or kit removes it. Run with `make test`.
set -u
. "$(dirname "$0")/lib.sh"
unset ARX_POLICY

# Gives the test its own config folder (with the shell plugin, as after
# `arx setup`) and saved defaults, like tests/kits.sh.
fresh() {
  begin "$1"
  export ARX_CONFIG_DIR=$WS/config
  mkdir -p "$ARX_CONFIG_DIR/plugins" "$ARX_CONFIG_DIR/kits"
  ln -s "$ROOT/plugins/shell" "$ARX_CONFIG_DIR/plugins/shell"
  spec >"$ARX_CONFIG_DIR/config.yaml"
  echo "name: test" >agent.yaml
}

# mkplugin DIR: a plugin folder named after DIR; more plugin.yaml lines on
# stdin.
mkplugin() {
  mkdir -p "$1"
  { printf 'name: %s\nversion: 0.1.0\ndescription: a test plugin\n' "$(basename "$1")"; cat; } >"$1/plugin.yaml"
}

# mkhook DIR POINT: a hook that adds DIR's name to order.txt.
mkhook() {
  script "$1/hooks/$2" <<EOF
#!/bin/sh
echo "$(basename "$1")" >>"\$ARX_CWD/order.txt"
EOF
}

# mktool DIR NAME: a tool in DIR that says which folder it is from.
mktool() {
  script "$1/tools/$2" <<EOF
#!/bin/sh
if [ "\${1:-}" = --schema ]; then
  echo '{"description": "$2 of $(basename "$1") {{timeout}}", "parameters": {"type": "object", "properties": {}}}'
  exit 0
fi
echo "$2 of $(basename "$1") ran"
EOF
}

# The description of tool NAME in model call 1.
tool_desc() {
  jq -r ".tools[] | select(.function.name == \"$1\") | .function.description" fake/req-01.json
}

fresh "a missing or broken policy folder"
sse_text "hi" | reply 1 "200 OK"
run "go" --policy nope
check "--policy with a missing folder exits 2" exited 2
check "it names the folder" has err.txt 'arx: policy nope: '
check "no session was started" test ! -e .arx/sessions
ARX_POLICY=$WS/gone run "go"
check "ARX_POLICY with a missing folder exits 2" exited 2
mkdir -p pol/bad pol/empty
echo "name: [" >pol/bad/plugin.yaml
run "go" --policy pol/bad
check "a bad plugin.yaml exits 2" exited 2
check "it says so as a policy problem" has err.txt "arx: policy $WS/pol/bad: "
run "go" --policy pol/empty
check "a folder without plugin.yaml is not skipped" has err.txt 'not a plugin'
check "no session and no model call" test ! -e .arx/sessions -a ! -e fake/req-01.json

fresh "policy hooks run first, and no list removes them"
mkplugin pol/p <<<'hooks: {before_tool: {band: policy}}'
mkplugin "$ARX_CONFIG_DIR/plugins/q" <<<'hooks: {before_tool: {band: policy}}'
mkplugin pol/n </dev/null
for d in pol/p pol/n "$ARX_CONFIG_DIR/plugins/q" "$WS"; do mkhook "$d" before_tool; done
sse_tool bash '{\"command\":\"true\"}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
ARX_POLICY=$WS/pol/p run "go" --policy pol/n --policy pol/p
check "policy band first, and policy folders first in each band" \
  test "$(tr '\n' ' ' <order.txt)" = "p q n $(basename "$WS") "
check "its hook events say policy" has .arx/sessions/last/events.jsonl '"plugin":"p","policy":true'
"$ARX" check --policy pol/p --list >list.txt 2>&1
check "check --list has a policy row first" grep -qE "^-	p	policy	--policy	$WS/pol/p$" list.txt
mkdir -p "$ARX_CONFIG_DIR/kits/k"
printf 'name: k\nversion: 0.1.0\ndescription: a kit\nplugins: [shell]\n' >"$ARX_CONFIG_DIR/kits/k/kit.yaml"
for extra in "plugins: [shell]" "disable: [p]" "kit: k"; do
  rm -f order.txt fake/count
  printf 'name: test\n%s\n' "$extra" >agent.yaml
  run "go" --policy pol/p
  check "'$extra' leaves the policy's hook running" has order.txt p
done

fresh "a plugin with the policy's name loads once"
mkplugin "$ARX_CONFIG_DIR/plugins/p" </dev/null
mkhook "$ARX_CONFIG_DIR/plugins/p" before_tool
echo "plugins: [shell, p]" >>agent.yaml
sse_tool bash '{\"command\":\"true\"}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
ARX_POLICY=$ARX_CONFIG_DIR/plugins/p run "go" --policy "$ARX_CONFIG_DIR/plugins/p"
check "the hook ran once" test "$(count order.txt p)" = 1
ARX_POLICY=$ARX_CONFIG_DIR/plugins/p "$ARX" check --list >list.txt 2>&1
check "one row, with the state policy" test "$(grep -c '	p	' list.txt)" = 1 -a "$(count list.txt '	p	policy')" = 1

fresh "which tool wins"
mkplugin pol/a </dev/null
mkplugin pol/b </dev/null
mkplugin "$ARX_CONFIG_DIR/plugins/r" <<<'replaces: [bash, edit]'
mkplugin "$ARX_CONFIG_DIR/plugins/z" </dev/null
for d in pol/a pol/b "$ARX_CONFIG_DIR/plugins/r" "$WS"; do mktool "$d" bash; done
for d in "$ARX_CONFIG_DIR/plugins/r" "$WS" "$ARX_CONFIG_DIR/plugins/z"; do mktool "$d" edit; done
for d in "$WS" "$ARX_CONFIG_DIR/plugins/z"; do mktool "$d" look; done
sse_text "hi" | reply 1 "200 OK"
ARX_POLICY=$WS/pol/a run "go" --policy pol/b
check "the first policy folder's tool wins" test "$(tool_desc bash)" = "bash of a 120"
check "else a tool that replaces: the name beats the spec folder's" test "$(tool_desc edit)" = "edit of r 120"
check "else the first tool in layer order" test "$(tool_desc look)" = "look of $(basename "$WS") 120"
ARX_POLICY=$WS/pol/a "$ARX" check --policy pol/b >check.txt 2>&1
check "a hidden tool gets the note" has check.txt 'tools/bash is hidden by a tool above it'
check "no warning for a hide the rule explains" lacks check.txt 'hides the tool bash'
check "no warning for a replaced tool" lacks check.txt 'plugin r hides'
check "a hide by place in the order still warns" has check.txt 'plugin shell hides the tool edit of plugin z'

fresh "a policy's values win"
mkplugin pol/p <<'EOF'
instructions: "POLICY TEXT"
model_settings: {temperature: 0, top_p: null}
tools: {bash: {timeout: 7s}}
EOF
mkplugin pol/second <<'EOF'
instructions: "SECOND TEXT"
model_settings: {temperature: 0.5, seed: 4}
EOF
mktool pol/p bash
cat >>agent.yaml <<'EOF'
instructions: "SPEC TEXT {{plugin_instructions}} END"
tools: {bash: {timeout: 99s}}
model_settings: {top_p: 0.5}
plugins: [shell, {p: {instructions: null}}]
EOF
sse_text "hi" | reply 1 "200 OK"
run "go" --policy pol/p --policy pol/second --set model_settings.temperature=1 --set model_settings.seed=9
check "policy text first, in folder order, outside {{plugin_instructions}}" \
  test "$(msg0 1)" = "POLICY TEXT

SECOND TEXT

SPEC TEXT  END"
check "the first policy's model setting wins over --set" test "$(field 1 temperature)" = 0
check "the next policy's wins over --set too" test "$(field 1 seed)" = 4
check "a policy's null removes the field" test "$(field 1 top_p)" = null
check "a policy's tool option wins over the spec's" test "$(tool_desc bash)" = "bash of p 7"
"$ARX" check --policy pol/p >check.txt 2>&1
check "check warns about the agent.yaml settings" has check.txt 'settings for policy p in agent.yaml are ignored'

fresh "a policy's settings"
mkplugin pol/p </dev/null
script pol/p/hooks/session_start <<'EOF'
#!/bin/sh
echo "$ARX_PLUGIN_SETTINGS" >"$ARX_CWD/settings.txt"
EOF
echo 'enable: [{p: {from_config: 1, both: config}}]' >>"$ARX_CONFIG_DIR/config.yaml"
echo 'enable: [{p: {from_agent: 1, both: agent}}]' >>agent.yaml
sse_text "hi" | reply 1 "200 OK"
run "go" --policy pol/p --set 'enable=[{"p": {"from_set": 1}}]'
check "config.yaml and --set settings reach the hook, agent.yaml's do not" \
  test "$(jq -c . settings.txt)" = '{"from_config":1,"both":"config","from_set":1}'
check "the policy still loads once" test "$("$ARX" check --policy pol/p --list | grep -c '	p	')" = 1

fresh "a subagent gets the policy"
mkplugin pol/p </dev/null
mkhook pol/p session_start
spec >sub.yaml
echo 'tools: {researcher: {agent: sub.yaml}}' >>agent.yaml
sse_tool researcher '{\"task\":\"look it up\"}' | reply 1 "200 OK"
sse_text "sub-result" | reply 2 "200 OK"
sse_text "done" | reply 3 "200 OK"
run "go" --policy pol/p
check "the policy's hook ran in both" test "$(count order.txt p)" = 2
check "the subagent's events show the policy hook at depth 1" \
  jq -es 'any(.[]; .type == "hook" and .depth == 1 and .policy == true)' .arx/sessions/last/events.jsonl

summary
