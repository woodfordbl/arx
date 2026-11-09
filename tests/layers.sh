#!/usr/bin/env bash
# layers.sh: tests plugin loading against tests/fake-curl: plugin folders,
# plugin.yaml, the order of layers, hook chains, the `plugins:` list, the
# user's config folder, plugin commands and `arx check --plugin`. Run with
# `make test`.
set -u
. "$(dirname "$0")/lib.sh"

# plugin DIR [-]: a plugin folder with a plugin.yaml (from stdin with -,
# else a default) and a tool `hello` that says where it runs from.
plugin() {
  mkdir -p "$1"
  if [ "${2:-}" = - ]; then cat >"$1/plugin.yaml"; else
    echo "description: test plugin" >"$1/plugin.yaml"
  fi
  script "$1/tools/hello" <<'EOF'
#!/bin/sh
if [ "$1" = --schema ]; then echo '{"description":"Say hello","parameters":{"type":"object"}}'; exit; fi
echo "plugin hello from $ARX_PLUGIN_DIR"
EOF
}

# Removes everything the tests put in the shared config folder.
clean_config() { rm -rf "$ARX_CONFIG_DIR/plugins" "$ARX_CONFIG_DIR/tools" "$ARX_CONFIG_DIR/commands"; }

# text_plugin NAME: a project plugin with only a plugin.yaml: its name, then
# the lines on stdin.
text_plugin() { mkdir -p "plugins/$1"; { echo "name: $1"; cat; } >"plugins/$1/plugin.yaml"; }

begin "project plugin"
plugin plugins/greet - <<'EOF'
name: greet
version: 0.1.0
tools: {hello: {timeout: 5s}}
EOF
script plugins/greet/hooks/after_tool <<'EOF'
#!/bin/sh
echo '{"note": "greet-note"}'
EOF
mkdir -p plugins/greet/skills/greeting plugins/not-a-plugin
printf -- '---\nname: greeting\ndescription: How to greet.\n---\n' >plugins/greet/skills/greeting/SKILL.md
echo 'instructions: "Skills: {{skills}} {{harness}}"' >>agent.yaml
"$ARX" check >check.txt 2>&1
check "check lists the plugin" has check.txt 'plugins: greet'
check "check lists its tool" has check.txt ' hello'
check "check names the hook's plugin" has check.txt 'after_tool(greet)'
check "a folder without plugin.yaml is not a plugin" lacks check.txt 'not-a-plugin'
sse_tool hello '{}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "greet"
check "exits 0" exited 0
check "skills from the plugin are listed" has fake/req-01.json 'greeting: How to greet.'
check "the harness text names the plugin" has fake/req-01.json 'Plugins add tools'
check "the tool gets an absolute ARX_PLUGIN_DIR" has fake/req-02.json "plugin hello from $(pwd -P)/plugins/greet"
check "the plugin's after_tool hook ran" has fake/req-02.json 'greet-note'
check "the hook event names the plugin" has .arx/sessions/last/events.jsonl '"plugin":"greet"'

begin "the spec folder wins"
plugin plugins/greet
script tools/hello <<'EOF'
#!/bin/sh
if [ "$1" = --schema ]; then echo '{"description":"Mine","parameters":{"type":"object"}}'; exit; fi
echo "spec hello"
EOF
"$ARX" check >check.txt 2>&1
check "the plugin tool is reported as hidden" has check.txt 'plugin greet: tools/hello is hidden'
sse_tool hello '{}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "greet"
check "the spec's tool ran" has fake/req-02.json 'spec hello'

begin "hook chain"
plugin plugins/guard
script hooks/after_tool <<'EOF'
#!/bin/sh
echo '{"note": "spec-note"}'
EOF
script plugins/guard/hooks/after_tool <<'EOF'
#!/bin/sh
echo '{"note": "guard-note"}'
EOF
script hooks/before_tool <<'EOF'
#!/bin/sh
exit 0
EOF
script plugins/guard/hooks/before_tool <<'EOF'
#!/bin/sh
case "$(cat)" in *rm*) echo '{"decision":"deny","reason":"guard says no"}' ;; esac
EOF
sse_tool bash '{\"command\":\"echo hi\"}' | reply 1 "200 OK"
sse_tool bash '{\"command\":\"rm x\"}' | reply 2 "200 OK"
sse_text "done" | reply 3 "200 OK"
run "chain"
check "both after_tool notes arrive" grep -q 'spec-note.*guard-note' fake/req-02.json
check "a plugin's before_tool can deny" has fake/req-03.json 'guard says no'

begin "fail closed is per layer"
plugin plugins/strict - <<'EOF'
hooks: {before_tool: {fail: closed}}
EOF
script plugins/strict/hooks/before_tool <<'EOF'
#!/bin/sh
exit 1
EOF
sse_tool bash '{\"command\":\"echo hi\"}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "strict"
check "the failed plugin hook denies the call" has fake/req-02.json 'before_tool hook failed'

begin "plugins: list"
plugin plugins/greet
plugin plugins/other
echo "plugins: [other]" >>agent.yaml
"$ARX" check >check.txt 2>&1
check "only the listed plugin loads" has check.txt 'plugins: other'
check "the other plugin does not" lacks check.txt 'greet'
"$ARX" check --set 'plugins=[]' >check.txt 2>&1
check "--set plugins=[] turns them all off" lacks check.txt 'plugins:'

begin "broken plugins are skipped"
plugin plugins/typo - <<'EOF'
nmae: typo
EOF
plugin plugins/future - <<'EOF'
arx: ">=999.0"
EOF
plugin plugins/renamed - <<'EOF'
name: something-else
EOF
plugin plugins/vague - <<'EOF'
arx: latest
EOF
"$ARX" check >check.txt 2>&1
code=$?
check "the harness still loads" exited 0
check "a typo is explained" has check.txt 'did you mean "name"'
check "the name must match the folder" has check.txt 'must match the folder name'
check "arx: must be a version" has check.txt 'must look like ">=0.2.0"'
check "the broken ones do not load" test -z "$(grep -E '^plugins:.*(typo|renamed|vague)' check.txt)"
# Only a release compares versions; a build between releases takes any plugin,
# so plugins can use what is new on main.
if "$ARX" version | grep -qE ' [0-9]+\.[0-9]+\.[0-9]+$'; then
  check "a release asks for a newer arx" has check.txt 'needs arx >=999.0'
else
  check "a build between releases accepts any version" has check.txt 'plugins: future'
fi

begin "plugin.yaml merges under the spec"
plugin plugins/kit - <<'EOF'
tools: {helper: {agent: subagents/helper.yaml}}
observers: ['echo "$ARX_PLUGIN_DIR" >plugin-dir.txt; cat >/dev/null']
compactors: {keep: compactors/keep.sh}
EOF
mkdir -p plugins/kit/subagents && echo "name: helper" >plugins/kit/subagents/helper.yaml
script plugins/kit/compactors/keep.sh <<'EOF'
#!/bin/sh
touch compacted.txt
cat
EOF
cat >>agent.yaml <<'EOF'
observers: ["cat >mine.jsonl"]
context_window: 1000
compaction: {strategy: keep, trigger: 0.5}
EOF
"$ARX" check >check.txt 2>&1
check "the subagent path resolves in the plugin" has check.txt 'helper'
check "a compactor name is a valid strategy" has check.txt 'ok:'
export PROMPT_TOKENS=900
sse_text "one" | reply 1 "200 OK"
run "go"
unset PROMPT_TOKENS
check "the spec's observer still runs" test -s mine.jsonl
check "the plugin's observer gets ARX_PLUGIN_DIR" has plugin-dir.txt "$(pwd -P)/plugins/kit"

begin "a new plugin loads on the next turn"
plugin staging/late
sse_tool bash '{\"command\":\"mkdir -p plugins && mv staging/late plugins/late\"}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "install"
check "the plugin's tool is offered on the next call" has fake/req-02.json '"name":"hello"'

begin "plugin instructions"
text_plugin fr <<<'instructions: "Answer in French."'
text_plugin de <<<'instructions: ["Antworte auf Deutsch.", "Heute ist {{date}}."]'
echo 'instructions: "Be brief."' >>agent.yaml
for n in 1 2 3 4; do sse_text "done" | reply $n "200 OK"; done
run "go" --set 'plugins=["fr"]'
check "the text follows the spec's prompt after a blank line" [ "$(msg0 1)" = "$(printf 'Be brief.\n\nAnswer in French.')" ]
de="Antworte auf Deutsch.\n\nHeute ist $(date +%Y-%m-%d)."
run "go" --set 'plugins=["fr", "de"]'
check "two plugins add text in list order, and {{date}} renders" [ "$(msg0 2)" = "$(printf "Be brief.\n\nAnswer in French.\n\n$de")" ]
run "go" --set 'plugins=["de", "fr"]'
check "the reversed list reverses the text" [ "$(msg0 3)" = "$(printf "Be brief.\n\n$de\n\nAnswer in French.")" ]
run "go" --set 'plugins=["fr"]' --set 'instructions=Start. {{ plugin_instructions }} End.'
check "{{plugin_instructions}} places the text, once" [ "$(msg0 4)" = "Start. Answer in French. End." ]
sse_text "done" | reply 5 "200 OK"
run "go" --set 'plugins=["fr", "de"]' --set 'instructions={{harness}}'
check "{{harness}} names the plugins with text" has fake/req-05.json 'The plugins fr and de add text after your instructions'

begin "plugin instructions from a file"
text_plugin p <<<'instructions: {file: prompts/p.md}'
mkdir -p plugins/p/prompts && echo "From the file." >plugins/p/prompts/p.md
sse_text "done" | reply 1 "200 OK"
run "go"
check "{file:} resolves in the plugin folder" has fake/req-01.json 'From the file.'
echo "Outside." >x.md
text_plugin bad <<'EOF'
instructions: [{file: ../../x.md}, "{{harness}}"]
model_settings: {model: x, stream: false}
EOF
"$ARX" check --plugin plugins/bad >out.txt 2>err.txt
code=$?
check "a bad plugin text fails check --plugin" exited 2
check "a file outside the plugin folder" has err.txt 'instructions: ../../x.md is outside the plugin folder'
check "{{harness}} in plugin text" has err.txt "instructions: {{harness}} belongs in the spec's prompt, not a plugin's"
check "model in model_settings" has err.txt 'model_settings.model: arx sets this field; a plugin cannot'
check "stream in model_settings" has err.txt 'model_settings.stream: arx sets this field; a plugin cannot'

begin "plugin model_settings"
text_plugin cool <<<'model_settings: {temperature: 0.1, parallel_tool_calls: true}'
script hooks/before_model <<'EOF'
#!/bin/sh
cat >before_model.json
EOF
for n in 1 2 3 4; do sse_text "done" | reply $n "200 OK"; done
run "go"
check "a plugin's setting is in the request" [ "$(field 1 temperature)" = 0.1 ]
check "before_model gets it in settings" [ "$(jq -c .settings.parallel_tool_calls before_model.json)" = true ]
echo 'model_settings: {temperature: 0.5}' >>agent.yaml
run "go"
check "agent.yaml wins over a plugin" [ "$(field 2 temperature)" = 0.5 ]
check "field by field" [ "$(field 2 parallel_tool_calls)" = true ]
run "go" --set model_settings.temperature=0.9
check "--set wins over both" [ "$(field 3 temperature)" = 0.9 ]
text_plugin a <<<'model_settings: {top_p: null}'
text_plugin b <<<'model_settings: {top_p: 0.7}'
run "go"
check "the first plugin's null removes the field" [ "$(jq 'has("top_p")' fake/req-04.json)" = false ]

begin "no plugin text: the prompt is the same as before"
sse_text "done" | reply 1 "200 OK"
run "go"
id=$(jq -r .session .arx/sessions/last/events.jsonl | head -1)
msg0 1 | sed -e "s#$(pwd -P)#@WS@#g" -e "s#$ARX#@ARX@#g" -e "s#$ROOT#@ROOT@#g" -e "s#$id#@ID@#g" >msg0.txt
cat >want.txt <<'EOF'
You are an autonomous agent working in @WS@. Use the tools to act, check the results, and keep going until the task is done. A reply without a tool call ends the task, so never say you will do something later: do it now. When everything is done, reply with a short summary and no tool calls.

Your harness is yours to change; edits take effect on your next turn:
- Spec: agent.yaml (YAML: model settings, tools, hooks, compaction, limits). Check edits with `@ARX@ check --spec agent.yaml`.
- Tools: ./tools/<name>, any executable (chmod +x). `<name> --schema` prints {"description": ..., "parameters": <JSON Schema>}; a call gets its arguments as JSON on stdin; stdout and stderr are the result; a non-zero exit marks an error.
- Hooks: ./hooks/<point> for session_start, before_model, after_model, before_tool, after_tool and stop: JSON on stdin; print the fields to change, or a decision, as JSON on stdout.
- Skills: (set `skills:` in the spec) <name>/SKILL.md with name and description front matter.
- Session files (full tool outputs, transcript): @WS@/.arx/sessions/@ID@
- Plugins add tools, hooks and skills below yours: shell (@ROOT@/plugins/shell). A tool of yours with the same name wins; hooks all run by band (policy, normal, final) and then in this order, yours first.
EOF
check "message 0 is byte for byte the same" cmp -s msg0.txt want.txt

begin "user folder and user plugins"
clean_config
plugin "$ARX_CONFIG_DIR/plugins/mine"
plugin "$ARX_CONFIG_DIR/plugins/greet"
plugin plugins/greet
script "$ARX_CONFIG_DIR/tools/utool" <<'EOF'
#!/bin/sh
if [ "$1" = --schema ]; then echo '{"description":"User tool","parameters":{"type":"object"}}'; exit; fi
EOF
"$ARX" check >check.txt 2>&1
check "a project sees the user's tools" has check.txt ' utool'
check "and the user's plugins, after its own" has check.txt 'plugins: greet mine'
check "a project plugin hides a user plugin of the same name" test "$(grep '^plugins:' check.txt | grep -o greet | wc -l)" -eq 1
"$ARX" check --set 'plugins=["mine"]' >check.txt 2>&1
check "a plugins: list keeps the named user plugin" has check.txt 'plugins: mine'
check "but leaves out the config folder's own tools" lacks check.txt 'utool'
clean_config

begin "plugin commands"
clean_config
script "$ARX_CONFIG_DIR/plugins/cmds/commands/arx-plugtest" <<'EOF'
#!/bin/sh
# arx-plugtest: a plugin command
echo "plugtest from $ARX_PLUGIN_DIR"
EOF
script "$ARX_CONFIG_DIR/plugins/cmds/commands/arx-setup" <<'EOF'
#!/bin/sh
echo "FAKE SETUP"
EOF
script "$ARX_CONFIG_DIR/commands/arx-mine" <<'EOF'
#!/bin/sh
echo "my command"
EOF
"$ARX" plugtest >out.txt 2>&1
check "a plugin adds a command" has out.txt "plugtest from $ARX_CONFIG_DIR/plugins/cmds"
"$ARX" setup --help >out.txt 2>&1
check "a plugin cannot replace a core command" lacks out.txt 'FAKE SETUP'
"$ARX" mine >out.txt 2>&1
check "the user's commands folder works" has out.txt 'my command'
"$ARX" help >out.txt 2>&1
check "help lists plugin commands" has out.txt 'a plugin command'
clean_config

begin "check --plugin"
plugin kit - <<'EOF'
name: kit
version: 1.2.3
description: A kit.
requires: [sh, no-such-program-arx]
EOF
script kit/commands/arx-kit </dev/null
"$ARX" check --plugin kit >out.txt 2>err.txt
code=$?
check "a good plugin passes" exited 0
check "it prints the name" has out.txt 'name=kit'
check "and the version" has out.txt 'version=1.2.3'
check "and what is missing" has out.txt 'missing=no-such-program-arx'
check "and its tools and commands" grep -q '^tools=hello$' out.txt
check "commands are listed" has out.txt 'commands=arx-kit'
echo "tols: {}" >kit/plugin.yaml
"$ARX" check --plugin kit >out.txt 2>err.txt
code=$?
check "a bad plugin fails" exited 2
check "with a hint" has err.txt 'did you mean "tools"'

summary
