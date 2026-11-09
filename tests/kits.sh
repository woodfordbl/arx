#!/usr/bin/env bash
# kits.sh: tests kits and the active list against tests/fake-curl: where
# the list comes from and in which order, --kit pinned across a reload,
# enable and disable, hook bands and the final policy result, the warnings
# of arx check, arx kit add, arx init <kit>, kit.lock, and the kits in
# kits/. Run with `make test`.
set -u
. "$(dirname "$0")/lib.sh"

# Gives the test its own config folder (with the shell plugin, as after
# `arx setup`) and saved defaults, so kits and plugins stay in the test.
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

# mktool DIR NAME: a tool in plugin DIR that says its name.
mktool() {
  script "$1/tools/$2" <<EOF
#!/bin/sh
if [ "\${1:-}" = --schema ]; then
  echo '{"description": "the $2 tool", "parameters": {"type": "object", "properties": {}}}'
  exit 0
fi
echo "$2 ran"
EOF
}

# mkkit NAME: a kit in the config folder; kit.yaml lines after name on
# stdin.
mkkit() {
  mkdir -p "$ARX_CONFIG_DIR/kits/$1"
  { printf 'name: %s\nversion: 0.1.0\ndescription: a test kit\n' "$1"; cat; } >"$ARX_CONFIG_DIR/kits/$1/kit.yaml"
}

# The plugins line of `arx check`, with any extra arguments.
plugins_line() { "$ARX" check "$@" 2>&1 | sed -n 's/^plugins: //p'; }

fresh "active list sources"
for p in a b c d e; do mkplugin "$ARX_CONFIG_DIR/plugins/$p" </dev/null; done
check "no kit and no list: every installed plugin" test "$(plugins_line)" = "a b c d e shell"
"$ARX" check --list >list.txt 2>&1
check "list says why" grep -qE '^1	a	on	installed' list.txt
echo "plugins: [c, a]" >>"$ARX_CONFIG_DIR/config.yaml"
check "config.yaml list: only its plugins, in its order" test "$(plugins_line)" = "c a"
mkkit k1 <<<'plugins: [e, b, shell]'
printf 'kit: k1\nenable: [a]\ndisable: [b]\n' >>agent.yaml
check "agent.yaml kit replaces it, then enable and disable" test "$(plugins_line)" = "e shell a"
"$ARX" check --list >list.txt 2>&1
check "list: kit, enable and disable reasons" grep -qE '^1	e	on	kit k1' list.txt
check "  enable in agent.yaml" grep -qE '^3	a	on	enable in agent.yaml' list.txt
check "  disable in agent.yaml" grep -qE '^-	b	off	disable in agent.yaml' list.txt
check "  not in the kit" grep -qE '^-	d	off	not in kit k1' list.txt
mkkit k2 <<<'plugins: [d]'
check "--kit wins over agent.yaml, and its edits" test "$(plugins_line --kit k2)" = "d"
mkkit k1-strict <<<$'extends: k1
enable: [c, {d: {x: 1}}]
disable: [e]'
check "a kit that extends another changes its list" test "$(plugins_line --kit k1-strict)" = "b shell c d"
check "--set plugins wins too" test "$(plugins_line --set 'plugins=["b","a"]')" = "b a"
"$ARX" check --kit nosuch >check.txt 2>&1
code=$?
check "a missing kit stops the run" exited 2
check "and names arx kit add" has check.txt 'run `arx kit add nosuch`'

fresh "settings merge order"
cat >>"$ARX_CONFIG_DIR/config.yaml" <<'EOF'
model_settings: {a: config, b: config, c: config, d: config}
enable: [{p: {x: config, y: config, z: config, w: config}}]
EOF
mkplugin "$ARX_CONFIG_DIR/plugins/p" </dev/null
script "$ARX_CONFIG_DIR/plugins/p/hooks/session_start" <<'EOF'
#!/bin/sh
echo "$ARX_PLUGIN_SETTINGS" >settings.json
EOF
mkkit k <<'EOF'
plugins: [{p: {y: kit, z: kit, w: kit}}]
model_settings: {b: kit, c: kit, d: kit}
EOF
printf 'kit: k\nmodel_settings: {c: agent, d: agent}\nenable: [{p: {z: agent, w: agent}}]\n' >>agent.yaml
sse_text "done" | reply 1 "200 OK"
run "go" --set model_settings.d=set --set 'enable=[{"p":{"w":"set"}}]'
check "exits 0" exited 0
# True when FILE has every one of the other arguments.
has_all() {
  local file=$1
  shift
  for want in "$@"; do grep -qF -- "$want" "$file" || return 1; done
}
check "model settings: config, kit, agent.yaml, --set" \
  has_all fake/req-01.json '"a":"config"' '"b":"kit"' '"c":"agent"' '"d":"set"' 
check "plugin settings: config, kit, agent.yaml, --set" grep -qF '"x":"config","y":"kit","z":"agent","w":"set"' settings.json

fresh "--kit is pinned across a reload"
for p in alpha beta; do
  mkplugin "$ARX_CONFIG_DIR/plugins/$p" </dev/null
  mktool "$ARX_CONFIG_DIR/plugins/$p" "${p}_tool"
done
mkkit k1 <<<'plugins: [shell, alpha]'
mkkit k2 <<<'plugins: [shell, beta]'
echo "kit: k1" >>agent.yaml
sse_tool bash '{\"command\":\"echo kit: k2 >agent.yaml\"}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "switch" --kit k1
check "exits 0" exited 0
check "the harness reloaded" has .arx/sessions/last/events.jsonl '"type":"harness.reload"'
check "the kit from --kit stays" has fake/req-02.json 'alpha_tool'
check "the edit did not change it" lacks fake/req-02.json 'beta_tool'
echo "kit: k1" >agent.yaml
sse_tool bash '{\"command\":\"echo kit: k2 >agent.yaml\"}' | reply 3 "200 OK"
sse_text "done" | reply 4 "200 OK"
run "switch"
check "without --kit, the agent can change it" has fake/req-04.json 'beta_tool'

fresh "enable and disable"
mkplugin "$ARX_CONFIG_DIR/plugins/extra" </dev/null
mkkit k <<<'plugins: [shell]'
echo "kit: k" >>agent.yaml
"$ARX" plugin enable extra >out.txt 2>&1
check "enable writes agent.yaml" grep -qE '^enable: \[extra\]' agent.yaml
check "and turns it on" test "$(plugins_line)" = "shell extra"
"$ARX" plugin disable shell >out.txt 2>&1
check "disable writes agent.yaml" grep -qE '^disable: \[shell\]' agent.yaml
check "and turns it off" test "$(plugins_line)" = "extra"
"$ARX" plugin enable shell >out.txt 2>&1
check "enable takes it out of disable" lacks agent.yaml 'disable:'
"$ARX" plugin disable extra --global >out.txt 2>&1
check "--global writes config.yaml" grep -qE '^disable: \[extra\]' "$ARX_CONFIG_DIR/config.yaml"
"$ARX" plugin list >list.txt 2>&1
check "plugin list shows order, state and why" grep -qE '^shell +[0-9.]+ +user +1 +on +kit k' list.txt
check "plugin list names the kit" has list.txt 'Using kit k (from agent.yaml).'
"$ARX" config set kit k --global
mkdir -p "$WS/new" && (cd "$WS/new" && "$ARX" plugin new late >/dev/null && "$ARX" plugin add ./late --yes) >add.txt 2>&1
check "a new plugin joins a default kit's list" grep -qE '^enable: \[.*late' "$ARX_CONFIG_DIR/config.yaml"

fresh "hook bands"
for p in pa pb pc; do mkplugin "$ARX_CONFIG_DIR/plugins/$p" <<<"hooks: {after_tool: {band: $([ $p = pa ] && echo normal || ([ $p = pb ] && echo policy) || echo final), changes: [result]}}"; done
script "$ARX_CONFIG_DIR/plugins/pa/hooks/after_tool" <<'EOF'
#!/bin/sh
echo pa >>order.log
echo '{"result": "NORMAL"}'
EOF
script "$ARX_CONFIG_DIR/plugins/pb/hooks/after_tool" <<'EOF'
#!/bin/sh
echo pb >>order.log
echo '{"result": "POLICY"}'
EOF
script "$ARX_CONFIG_DIR/plugins/pc/hooks/after_tool" <<'EOF'
#!/bin/sh
echo pc >>order.log
EOF
mkkit k <<<'plugins: [pc, pa, pb, shell]'
echo "kit: k" >>agent.yaml
sse_tool bash '{\"command\":\"echo tool output\"}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "go"
check "exits 0" exited 0
check "policy, then normal, then final" test "$(tr '\n' ' ' <order.log)" = "pb pa pc "
check "the policy result is final" has fake/req-02.json 'POLICY'
check "a later hook could not change it" lacks fake/req-02.json 'NORMAL'
check "its event says so" has .arx/sessions/last/events.jsonl '"ignored":"result: a policy hook set it'
"$ARX" check >check.txt 2>&1
check "check warns about the overlap, in run order" has check.txt 'after_tool: 3 hooks change result; they run in this order: plugin pb (policy), plugin pa (normal), plugin pc (final)'

fresh "replaces"
mkplugin "$ARX_CONFIG_DIR/plugins/mybash" </dev/null
mktool "$ARX_CONFIG_DIR/plugins/mybash" bash
mkkit k <<<'plugins: [mybash, shell]'
echo "kit: k" >>agent.yaml
"$ARX" check >check.txt 2>&1
check "a hidden tool is a warning" has check.txt 'plugin mybash hides the tool bash of plugin shell'
echo "replaces: [bash]" >>"$ARX_CONFIG_DIR/plugins/mybash/plugin.yaml"
"$ARX" check >check.txt 2>&1
check "replaces: says it is on purpose" lacks check.txt 'hides the tool bash'
check "its bash wins" has <("$ARX" tools 2>&1) 'the bash tool'

fresh "arx kit add from a local marketplace"
mkdir -p market/kits/k3
mkplugin market/plugins/gamma </dev/null
mktool market/plugins/gamma gamma_tool
printf 'name: k3\nversion: 1.0.0\ndescription: market kit\nplugins: [gamma, shell]\n' >market/kits/k3/kit.yaml
"$ARX" kit add ./market/kits/k3 </dev/null >add.txt 2>&1
check "without a terminal it asks for --yes" has add.txt 'add --yes'
check "and changes nothing" test ! -e "$ARX_CONFIG_DIR/kits/k3"
"$ARX" kit add ./market/kits/k3 --yes --default </dev/null >add.txt 2>&1
check "the kit is installed" test -f "$ARX_CONFIG_DIR/kits/k3/kit.yaml"
check "its plugin comes from the marketplace" test -x "$ARX_CONFIG_DIR/plugins/gamma/tools/gamma_tool"
check "with its source" has "$ARX_CONFIG_DIR/plugins/gamma/.arx-source" "source=$(pwd -P)/market/plugins/gamma"
check "an installed plugin is kept" test -L "$ARX_CONFIG_DIR/plugins/shell"
check "--default sets kit: in config.yaml" grep -qE '^kit: k3' "$ARX_CONFIG_DIR/config.yaml"
check "the default kit is used" test "$(plugins_line)" = "gamma shell"
"$ARX" kit list >list.txt 2>&1
check "kit list shows it" grep -qE '^k3 +1\.0\.0 +yes' list.txt
"$ARX" kit add ./market/kits/k3 --yes </dev/null >add.txt 2>&1
code=$?
check "a second add needs --force" exited 1
"$ARX" kit remove k3 --yes </dev/null >rm.txt 2>&1
check "remove deletes it" test ! -e "$ARX_CONFIG_DIR/kits/k3"
check "and the default" lacks "$ARX_CONFIG_DIR/config.yaml" 'kit:'

fresh "a kit with an executable"
mkdir -p bad/init
printf 'name: bad\nplugins: [shell]\n' >bad/kit.yaml
script bad/init/run.sh <<<'#!/bin/sh'
"$ARX" check --kit-dir bad >check.txt 2>&1
code=$?
check "check --kit-dir rejects it" exited 2
check "and names the file" has check.txt 'bad/init/run.sh: is executable, and a kit holds no code'
"$ARX" kit add ./bad --yes </dev/null >add.txt 2>&1
code=$?
check "kit add refuses it" exited 1
cp -R bad "$ARX_CONFIG_DIR/kits/bad"
"$ARX" check --kit bad >check.txt 2>&1
code=$?
check "a run refuses it" exited 2

fresh "kit.lock"
mkplugin "$ARX_CONFIG_DIR/plugins/gamma" </dev/null
printf 'source=acme/tools/gamma@v1\ncommit=acme-tools-abc1234\n' >"$ARX_CONFIG_DIR/plugins/gamma/.arx-source"
mkkit k <<<'plugins: [shell, gamma@v1]'
echo "kit: k" >>agent.yaml
sse_text "done" | reply 1 "200 OK"
run "go"
check "a kit with @ref writes kit.lock" has kit.lock '"name":"gamma","source":"acme/tools/gamma@v1","commit":"acme-tools-abc1234"'
check "with the kit itself" grep -qE '^kit: \{"name":"k"' kit.lock

fresh "the kits in kits/"
export ARX_LIBEXEC=$ROOT/commands
"$ARX" kit add research --yes </dev/null >add.txt 2>&1
check "a shipped kit needs no download" test -L "$ARX_CONFIG_DIR/kits/research"
check "its plugins are links too" test -L "$ARX_CONFIG_DIR/plugins/never-stop"
rm agent.yaml
"$ARX" init research >init.txt 2>&1
check "init copies the kit's init/" test -f program.md -a -f prompts/first.md
check "its agent.yaml uses the kit" grep -qE '^kit: research' agent.yaml
"$ARX" check >check.txt 2>&1
check "the project checks out" has check.txt 'kit: research (from agent.yaml)'
check "never-stop is on" has check.txt 'stop(never-stop)'
sse_text "first idea done" | reply 1 "200 OK"
sse_text "second" | reply 2 "200 OK"
run "go" --cap turns=2
check "never-stop sends it on with the kit's message" has fake/req-02.json 'Next experiment. Log it in results.tsv.'
"$ARX" kit add explorer --yes </dev/null >add.txt 2>&1
check "explorer has bash and no edit" grep -q '^tools: bash' <("$ARX" check --kit explorer 2>&1)
check "  (no edit)" lacks <("$ARX" check --kit explorer 2>&1) ' edit'
"$ARX" kit add coding --yes </dev/null >add.txt 2>&1
"$ARX" check --kit coding >check.txt 2>&1
check "coding loads every plugin it names" has check.txt 'plugins: guard shell git-context fail-hint reviewer plugin-authoring keep-last word-count clock notify'
check "guard comes first" has <("$ARX" check --kit coding --list) $'1\tguard\ton'
mkdir -p "$WS/missing" && (cd "$WS/missing" && "$ARX" init nosuch) >init.txt 2>&1
check "init with a kit that is not installed says so" has init.txt 'run `arx kit add nosuch`'
unset ARX_LIBEXEC

fresh "plugin text and settings under a kit"
mkplugin "$ARX_CONFIG_DIR/plugins/p" <<'EOF'
instructions: "Plugin text."
model_settings: {temperature: 0.1, top_p: 0.2, seed: 1}
EOF
mkdir -p "$ARX_CONFIG_DIR/plugins/p/prompts"
echo "Short text." >"$ARX_CONFIG_DIR/plugins/p/prompts/short.md"
mkkit k <<'EOF'
plugins: [p]
prompt: prompt.md
model_settings: {temperature: 0.5}
EOF
echo "Kit prompt." >"$ARX_CONFIG_DIR/kits/k/prompt.md"
echo 'model_settings: {top_p: 0.6}' >>"$ARX_CONFIG_DIR/config.yaml"
# with_p SETTINGS: agent.yaml uses kit k, with SETTINGS for plugin p.
with_p() { printf 'name: test\nkit: k\nenable:\n  - p: %s\n' "$1" >agent.yaml; }
with_p '{}'
for n in 1 2 3 4 5; do sse_text "done" | reply $n "200 OK"; done
run "go"
check "the kit's prompt comes first, then the plugin's text" [ "$(msg0 1)" = "$(printf 'Kit prompt.\n\nPlugin text.')" ]
check "the kit's model_settings win over the plugin's" [ "$(field 1 temperature)" = 0.5 ]
check "and so do config.yaml's" [ "$(field 1 top_p)" = 0.6 ]
check "the plugin's other fields stay" [ "$(field 1 seed)" = 1 ]
with_p '{instructions: null}'
run "go"
check "{instructions: null} drops the text" [ "$(msg0 2)" = "Kit prompt." ]
with_p '{instructions: "Replaced."}'
run "go"
check "a string replaces it" [ "$(msg0 3)" = "$(printf 'Kit prompt.\n\nReplaced.')" ]
with_p '{instructions: {file: prompts/short.md}}'
run "go"
check "{file:} uses another file of the plugin" [ "$(msg0 4)" = "$(printf 'Kit prompt.\n\nShort text.')" ]
with_p '{model_settings: {seed: 3}}'
run "go"
check "settings change the plugin's value" [ "$(field 5 seed)" = 3 ]
with_p '{instructions: {file: missing.md}}'
"$ARX" check >check.txt 2>&1
code=$?
check "a missing file in the settings is a spec error" exited 2
check "  that names the plugin" has check.txt 'plugins.p.instructions: cannot read'

fresh "arx setup keeps the kit"
echo "kit: k" >>"$ARX_CONFIG_DIR/config.yaml"
for i in 1 2 3 4; do echo '{"data":[{"id":"test-model"}]}' | reply "$i" "200 OK"; done
printf 'sk-test' | "$ARX" setup --provider custom --base-url http://fake.invalid/v1 \
  --key-env TEST_KEY --model test-model --key-stdin --no-test >setup.txt 2>&1
check "kit: is still in config.yaml" grep -qE '^kit: k' "$ARX_CONFIG_DIR/config.yaml"

summary
