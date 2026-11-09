#!/usr/bin/env bash
# state.sh: tests plugin state against tests/fake-curl: ARX_STATE_DIR and
# ARX_DATA_DIR for a plugin's tools, hooks, scheduler, observers,
# compactors and commands, none for spec-folder programs, --resume,
# subagents, a linked plugin, and the notes in `arx plugin remove` and
# `arx doctor`. Run with `make test`.
set -u
. "$(dirname "$0")/lib.sh"

PLUGINS=$ARX_CONFIG_DIR/plugins

# st DIR: the plugin `st` in DIR, with a tool `where` that prints and logs
# its folders, and a tool `count` that adds a line to $ARX_STATE_DIR/count.
st() {
  mkdir -p "$1"
  printf 'name: st\ndescription: keeps state\n' >"$1/plugin.yaml"
  script "$1/tools/where" <<'EOF'
#!/bin/sh
if [ "$1" = --schema ]; then echo '{"description":"Where","parameters":{"type":"object"}}'; exit; fi
echo "$ARX_SESSION $ARX_STATE_DIR $ARX_DATA_DIR" >>"$ARX_CWD/where.log"
echo "state=$ARX_STATE_DIR data=$ARX_DATA_DIR"
EOF
  script "$1/tools/count" <<'EOF'
#!/bin/sh
if [ "$1" = --schema ]; then echo '{"description":"Count","parameters":{"type":"object"}}'; exit; fi
mkdir -p "$ARX_STATE_DIR"
echo x >>"$ARX_STATE_DIR/count"
echo "count=$(wc -l <"$ARX_STATE_DIR/count" | tr -d ' ')"
EOF
}

# Removes every user plugin but the shell plugin.
clean() { find "$PLUGINS" -mindepth 1 -maxdepth 1 ! -name shell -exec rm -rf {} +; }

# The session folder of `last`, resolved.
session() { (cd .arx/sessions/last && pwd -P); }

begin "a tool gets both folders"
st "$PLUGINS/st"
sse_tool where '{}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "go"
check "exits 0" exited 0
check "ARX_STATE_DIR is in the session" has fake/req-02.json "state=$(session)/plugins/st"
check "ARX_DATA_DIR is in .arx/data" has fake/req-02.json "data=$(pwd -P)/.arx/data/st"
check "arx makes no state folder" [ ! -e "$(session)/plugins" ]
check "arx makes no data folder" [ ! -e .arx/data ]

begin "hooks, schedulers and observers get them"
st "$PLUGINS/st"
cat >>"$PLUGINS/st/plugin.yaml" <<'EOF'
observers: ['mkdir -p "$ARX_STATE_DIR" && echo "obs $ARX_STATE_DIR $ARX_DATA_DIR" >>"$ARX_STATE_DIR/seen"; cat >/dev/null']
EOF
script "$PLUGINS/st/hooks/before_tool" <<'EOF'
#!/bin/sh
cat >/dev/null
mkdir -p "$ARX_STATE_DIR"
echo "hook $ARX_STATE_DIR $ARX_DATA_DIR" >>"$ARX_STATE_DIR/seen"
EOF
script "$PLUGINS/st/scheduler" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
state = os.environ["ARX_STATE_DIR"]
os.makedirs(state, exist_ok=True)
with open(os.path.join(state, "seen"), "a") as f:
    f.write("sched %s %s\n" % (state, os.environ["ARX_DATA_DIR"]))
    f.write("settings %s\n" % os.environ.get("ARX_PLUGIN_SETTINGS", "unset"))
for line in sys.stdin:
    m = json.loads(line)
    if "ready" in m:
        print(json.dumps({"start": [m["ready"]["id"]]}), flush=True)
EOF
sse_tool where '{}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "go"
want="$(session)/plugins/st $(pwd -P)/.arx/data/st"
check "exits 0" exited 0
check "the tool ran" has fake/req-02.json "state=$(session)/plugins/st"
check "the hook got them" has "$(session)/plugins/st/seen" "hook $want"
check "the scheduler got them" has "$(session)/plugins/st/seen" "sched $want"
check "and its settings" has "$(session)/plugins/st/seen" "settings {}"
check "the observer got them" has "$(session)/plugins/st/seen" "obs $want"
clean

begin "spec-folder programs get none"
script tools/env <<'EOF'
#!/bin/sh
if [ "$1" = --schema ]; then echo '{"description":"Env","parameters":{"type":"object"}}'; exit; fi
echo "vars ${ARX_STATE_DIR-unset} ${ARX_DATA_DIR-unset} ${ARX_PLUGIN_DIR-unset}"
EOF
sse_tool env '{}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
(
  export ARX_STATE_DIR=/bad ARX_DATA_DIR=/bad ARX_PLUGIN_DIR=/bad
  run "go"
)
check "inherited values are removed" has fake/req-02.json 'vars unset unset unset'

begin "--resume keeps state"
st "$PLUGINS/st"
sse_tool count '{}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "go"
first=$(session)
sse_tool count '{}' | reply 3 "200 OK"
sse_text "done" | reply 4 "200 OK"
run "again" --resume last
check "the resumed session counts on" has fake/req-04.json 'count=2'
sse_tool count '{}' | reply 5 "200 OK"
sse_text "done" | reply 6 "200 OK"
run "new"
check "a new session starts at one" has fake/req-06.json 'count=1'
check "the first session kept its file" [ "$(wc -l <"$first/plugins/st/count" | tr -d ' ')" = 2 ]

begin "subagents get their own state folder"
st "$PLUGINS/st"
spec >sub.yaml
echo 'tools: {helper: {agent: sub.yaml}}' >>agent.yaml
sse_tool where '{}' | reply 1 "200 OK"
sse_tool helper '{\"task\":\"look\"}' | reply 2 "200 OK"
sse_tool where '{}' | reply 3 "200 OK"
sse_text "sub done" | reply 4 "200 OK"
sse_text "done" | reply 5 "200 OK"
run "go"
check "exits 0" exited 0
check "both called the tool" [ "$(wc -l <where.log | tr -d ' ')" = 2 ]
read -r id1 state1 data1 <<<"$(sed -n 1p where.log)"
read -r id2 state2 data2 <<<"$(sed -n 2p where.log)"
check "the state folders differ" [ "$state1" != "$state2" ]
check "each is in its own session" [ "$state1" = "$(dirname "$(dirname "$state1")")/plugins/st" ]
check "the parent's names its session" has <(echo "$state1") "/$id1/plugins/st"
check "the subagent's names its session" has <(echo "$state2") "/$id2/plugins/st"
check "the data folders match" [ "$data1" = "$data2" ]
clean

begin "a linked plugin uses its name"
st dev-copy
ln -s "$(pwd)/dev-copy" "$PLUGINS/st"
sse_tool where '{}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "go"
check "ARX_STATE_DIR ends in its name" has fake/req-02.json "state=$(session)/plugins/st "
check "ARX_DATA_DIR too" has fake/req-02.json "data=$(pwd -P)/.arx/data/st"
check "not the folder's name" lacks fake/req-02.json 'plugins/dev-copy'
check "in either variable" lacks fake/req-02.json 'data/dev-copy'
clean

begin "a plugin's compactor gets them"
st "$PLUGINS/st"
echo 'compactors: {keep: compactors/keep.sh}' >>"$PLUGINS/st/plugin.yaml"
script "$PLUGINS/st/compactors/keep.sh" <<'EOF'
#!/bin/sh
echo "$ARX_PLUGIN_DIR $ARX_STATE_DIR $ARX_DATA_DIR" >"$ARX_CWD/compactor.txt"
cat
EOF
cat >>agent.yaml <<'EOF'
context_window: 1000
compaction: {strategy: keep, trigger: 0.5}
EOF
export PROMPT_TOKENS=900
sse_tool where '{}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "go"
unset PROMPT_TOKENS
check "it ran" test -s compactor.txt
check "with all three" has compactor.txt "$(cd "$PLUGINS/st" && pwd -P) $(session)/plugins/st $(pwd -P)/.arx/data/st"
clean

begin "a command gets ARX_DATA_DIR only"
st "$PLUGINS/st"
script "$PLUGINS/st/commands/arx-st" <<'EOF'
#!/bin/sh
if [ "${1:-}" = run ]; then exec "$ARX_BIN" -p go --quiet; fi
echo "${ARX_DATA_DIR-unset} ${ARX_STATE_DIR-unset}"
EOF
"$ARX" st >cmd.txt 2>&1
check "data, and no state" [ "$(cat cmd.txt)" = "$(pwd -P)/.arx/data/st unset" ]
script tools/env <<'EOF'
#!/bin/sh
if [ "$1" = --schema ]; then echo '{"description":"Env","parameters":{"type":"object"}}'; exit; fi
echo "data ${ARX_DATA_DIR-unset} plugin ${ARX_PLUGIN_DIR-unset}"
EOF
sse_tool env '{}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
"$ARX" st run >run.txt 2>&1
check "its arx -p leaks nothing" has fake/req-02.json 'data unset plugin unset'

begin "arx plugin remove keeps the data"
st "$PLUGINS/st"
mkdir -p .arx/data/st
"$ARX" plugin remove st --yes >remove.txt 2>&1
check "the plugin is gone" [ ! -e "$PLUGINS/st" ]
check "the data stays" [ -d .arx/data/st ]
check "and it says so" has remove.txt 'Kept its data in .arx/data/st/'

begin "arx doctor names data without a plugin"
st "$PLUGINS/st"
mkdir -p .arx/data/gone .arx/data/st
"$ARX" doctor >doctor.txt 2>&1
check "it lists the orphan" has doctor.txt '.arx/data/gone/ holds data for gone, which is not installed'
check "not an installed plugin" lacks doctor.txt '.arx/data/st/'
clean

summary
