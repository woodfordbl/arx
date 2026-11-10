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

fresh "a missing policy folder"
sse_text "hi" | reply 1 "200 OK"
run "go" --policy nope
check "--policy with a missing folder exits 2" exited 2
check "it names the folder" has err.txt 'arx: policy nope: '
check "no session was started" test ! -e .arx/sessions
ARX_POLICY=$WS/gone run "go"
check "ARX_POLICY with a missing folder exits 2" exited 2
check "no model call was made" test ! -e fake/req-01.json

summary
