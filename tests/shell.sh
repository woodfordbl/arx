#!/usr/bin/env bash
# shell.sh: checks that bash and edit come from the shell plugin
# (plugins/shell), which runs `arx tool bash|edit`: the tools in a session,
# schema files next to tools, replacing a tool from a project plugin, the
# doctor warning for an agent with no tools, and `arx setup`, which turns the
# plugin on. lib.sh links the plugin in, as `arx setup` does. Run with
# `make test`.
set -u
. "$(dirname "$0")/lib.sh"
SHELL_DIR=$ROOT/plugins/shell

# `arx tool` on its own: JSON in, the result out, as a process tool.
begin "arx tool"
echo '{"command":"echo out; echo err >&2; exit 3"}' | "$ARX" tool bash >bash.txt 2>&1
code=$?
check "bash runs the command" has bash.txt 'out'
check "bash keeps stderr" has bash.txt 'err'
check "bash exits with the command's code" exited 3
echo '{"command":"cat; echo read"}' | "$ARX" tool bash >stdin.txt 2>&1
check "the command gets no stdin" test "$(cat stdin.txt)" = read
echo '{"command":"yes | head -1"}' | "$ARX" tool bash >pipe.txt 2>&1
check "SIGPIPE is back to the default" test "$(cat pipe.txt)" = y
echo '{}' | "$ARX" tool bash >bad.txt 2>&1
code=$?
check "bash without a command is an error" exited 1
check "bash says what it needs" has bad.txt 'needs a string argument `command`'
echo '{"path":"a.txt","old":"","new":"x x"}' | "$ARX" tool edit >edit.txt 2>&1
code=$?
check "edit creates a file" exited 0
check "edit says so" has edit.txt 'created a.txt'
echo '{"path":"a.txt","old":"x","new":"y"}' | "$ARX" tool edit >edit2.txt 2>&1
code=$?
check "an ambiguous edit is an error" exited 1
check "edit says why" has edit2.txt 'occurs 2 times'
echo 'not json' | "$ARX" tool edit >json.txt 2>&1
check "bad JSON is reported" has json.txt 'not a valid JSON object'
"$ARX" tool nope >nope.txt 2>&1
code=$?
check "an unknown tool is a usage error" exited 2
for t in bash edit; do
  "$ARX" tool $t --schema | jq -S . >"$t.schema"
  jq -S . "$SHELL_DIR/tools/$t.json" >"$t.file"
  check "$t.json matches arx tool $t --schema" cmp -s "$t.schema" "$t.file"
done

# The plugin's tools in a session, with today's descriptions.
begin "plugin tools"
"$ARX" tools >tools.json 2>err.txt
check "bash and edit are listed" test "$(jq -r '[.[].function.name] | join(" ")' tools.json)" = "bash edit"
check "bash's description has the output sizes" has tools.json 'first 2048 and last 6144 bytes'
check "bash's description has its timeout" has tools.json 'Timeout 120s.'
check "edit keeps its parameters" test "$(jq -c '.[1].function.parameters.required' tools.json)" = '["path","old","new"]'
"$ARX" tools --set tools.bash.timeout=5s --set tool_output.head=100 >tools2.json 2>err.txt
check "tools.bash.timeout is the general setting" has tools2.json 'Timeout 5s.'
check "the description follows tool_output" has tools2.json 'first 100 and last'
"$ARX" check --set tools.edit.enabled=false >check.txt 2>&1
check "tools.edit.enabled=false hides edit" grep -q '^tools: bash$' check.txt
sse_tool bash '{\"command\":\"echo hello from bash\"}' | reply 1 "200 OK"
sse_tool edit '{\"path\":\"b.txt\",\"old\":\"\",\"new\":\"hi\"}' | reply 2 "200 OK"
sse_tool bash '{}' | reply 3 "200 OK"
sse_text "done" | reply 4 "200 OK"
run "go"
check "exits 0" exited 0
check "bash output reached the model" has fake/req-02.json 'hello from bash'
check "edit wrote the file" test "$(cat b.txt)" = hi
check "edit's result reached the model" has fake/req-03.json 'created b.txt'
check "a bad call is an error for the model" has fake/req-04.json '[exit code 1]'
check "edit is a process tool now" test "$(grep -c '"type":"tool.end".*"exit"' .arx/sessions/last/events.jsonl)" = 3
check "edit's output is saved" grep -q 'created b.txt' .arx/sessions/last/tool-0002.out
check "no tool problems" lacks fake/req-01.json 'Tool problems'

# A file that only runs `exec "$ARX_BIN" tool NAME` starts as arx itself:
# here the #! line names no real shell, so running the file would fail.
begin "direct start"
script tools/run <<'EOF'
#!/no/such/shell
# hands over to arx
exec "$ARX_BIN" tool bash "$@"
EOF
echo '{"description":"x","parameters":{"type":"object"}}' >tools/run.json
script tools/other <<'EOF'
#!/no/such/shell
echo first
exec "$ARX_BIN" tool bash "$@"
EOF
echo '{"description":"y","parameters":{"type":"object"}}' >tools/other.json
sse_tool run '{\"command\":\"echo direct\"}' | reply 1 "200 OK"
sse_tool other '{\"command\":\"echo direct\"}' | reply 2 "200 OK"
sse_text "done" | reply 3 "200 OK"
run "go"
check "the hand-over runs without the file's shell" has fake/req-02.json 'direct'
check "any other file runs as it is" has fake/req-03.json 'could not start the tool'

# A schema file next to a tool: arx reads it and does not run the tool.
begin "schema file"
script tools/fast <<'EOF'
#!/bin/sh
[ "$1" = --schema ] && touch schema-ran && exit 1
echo fast ran
EOF
echo '{"description":"From the file, timeout {{timeout}}s.","parameters":{"type":"object","properties":{}}}' >tools/fast.json
script tools/slow <<'EOF'
#!/bin/sh
[ "$1" = --schema ] && echo '{"description":"From --schema.","parameters":{"type":"object"}}' && exit 0
echo slow ran
EOF
script tools/broken <<'EOF'
#!/bin/sh
echo broken ran
EOF
echo '[1, 2]' >tools/broken.json
"$ARX" tools >tools.json 2>err.txt
"$ARX" check >check.txt 2>&1
check "the description comes from the file" has tools.json 'From the file, timeout 120s.'
check "the tool did not run for its schema" test ! -e schema-ran
check "--schema stays the fallback" has tools.json 'From --schema.'
check "a bad schema file skips the tool" has check.txt 'tools/broken skipped: broken.json must be a JSON object'
check "schema files are not tools" lacks check.txt 'fast.json'
"$ARX" check --plugin "$SHELL_DIR" >plugin.txt 2>&1
check "check --plugin lists tools, not schema files" has plugin.txt 'tools=bash edit'
# A change to the schema file is seen on the next turn.
sse_tool bash '{\"command\":\"sed -i.bak s/From.the.file/Changed/ tools/fast.json\"}' |
  reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "go"
check "an edited schema file reloads" has fake/req-02.json 'Changed, timeout'

# A project plugin's bash wins over the shell plugin's, and so does the
# agent's own tools/edit.
begin "override"
script plugins/bash/tools/bash <<'EOF'
#!/bin/sh
[ "$1" = --schema ] && echo '{"description":"Run it in the sandbox.","parameters":{"type":"object"}}' && exit 0
echo "sandboxed: $(cat)"
EOF
echo 'name: bash' >plugins/bash/plugin.yaml
script tools/edit <<'EOF'
#!/bin/sh
[ "$1" = --schema ] && echo '{"description":"My own edit.","parameters":{"type":"object"}}' && exit 0
echo "my edit"
EOF
"$ARX" check >check.txt 2>&1
check "both still load" grep -q '^tools: edit bash$' check.txt
check "the shell plugin's bash is hidden" has check.txt 'plugin shell: tools/bash is hidden by a tool above it'
"$ARX" tools >tools.json 2>&1
check "the model sees the project's bash" has tools.json 'Run it in the sandbox.'
sse_tool bash '{\"command\":\"ls\"}' | reply 1 "200 OK"
sse_tool edit '{}' | reply 2 "200 OK"
sse_text "done" | reply 3 "200 OK"
run "go"
check "bash calls go to the project plugin" has fake/req-02.json 'sandboxed: {'
check "edit calls go to the agent's own tool" has fake/req-03.json 'my edit'

# Without the plugin, an agent has no tools, and doctor says so. (doctor
# calls the endpoint too, so the session runs first.)
begin "doctor"
echo 'plugins: []' >>agent.yaml
sse_tool bash '{\"command\":\"ls\"}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "go"
check "a call to bash says there is none" has fake/req-02.json 'unknown tool \"bash\" (available: none)'
"$ARX" check >check.txt 2>&1
check "plugins: [] leaves no tools" grep -q '^tools:$' check.txt
"$ARX" doctor >doctor.txt 2>&1
check "doctor warns about no tools" has doctor.txt 'the agent has no tools'
spec >agent.yaml
"$ARX" doctor >doctor.txt 2>&1
check "doctor lists the tools" has doctor.txt 'tools: bash edit'

# `arx setup` turns the plugin on: from a source checkout (commands/ next to
# the binary) and from an installed copy (libexec/arx/plugins/shell).
models() { echo '{"data":[{"id":"test-model"}]}'; }
for layout in checkout installed; do
  begin "arx setup ($layout)"
  rm agent.yaml
  export ARX_CONFIG_DIR=$WS/config
  if [ "$layout" = installed ]; then
    mkdir -p lib/arx/plugins && cp -R "$SHELL_DIR" lib/arx/plugins/shell
    export ARX_LIBEXEC=$WS/lib/arx
    want=$WS/lib/arx/plugins/shell
  else
    export ARX_LIBEXEC=$ROOT/commands
    want=$SHELL_DIR
  fi
  for i in 1 2 3 4; do models | reply "$i" "200 OK"; done
  printf 'sk-test' | ARX_BIN=$ARX bash "$ROOT/commands/arx-setup" --provider custom \
    --base-url http://fake.invalid/v1 --key-env TEST_KEY --model test-model \
    --key-stdin --no-test >setup.txt 2>&1
  check "setup says it turned the plugin on" has setup.txt 'Turned on the shell plugin'
  check "the plugin is a link to the copy next to arx" \
    test "$(cd "$ARX_CONFIG_DIR/plugins/shell" && pwd -P)" = "$(cd "$want" && pwd -P)"
  "$ARX" check >check.txt 2>&1
  check "the agent has bash and edit" grep -q '^tools: bash edit$' check.txt
  printf 'sk-test' | ARX_BIN=$ARX bash "$ROOT/commands/arx-setup" --provider custom \
    --base-url http://fake.invalid/v1 --key-env TEST_KEY --model test-model \
    --key-stdin --no-test >setup2.txt 2>&1
  check "a second setup leaves it as it is" lacks setup2.txt 'shell plugin'
  unset ARX_LIBEXEC
done

summary
