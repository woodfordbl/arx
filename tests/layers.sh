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
check "a project plugin hides a user plugin of the same name" test "$(grep -o greet check.txt | wc -l)" -eq 1
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
