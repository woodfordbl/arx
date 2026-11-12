#!/usr/bin/env bash
# mcp-servers.sh: the life of MCP servers: keys, timeouts, Ctrl-C, crashes,
# hot reload, list changes, stderr, hooks, plugins, credentials and events,
# against tests/fake-mcp. Run with `make test`.
set -u
. "$(dirname "$0")/mcp-lib.sh"

begin "keys"
gh_spec >agent.yaml
export FAKE_MCP_SLOW=1
sse_calls gh__echo '{\"kind\":\"slow\",\"text\":\"a\"}' gh__echo '{\"kind\":\"slow\",\"text\":\"b\"}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
t0=$(now)
run "go"
t1=$(now)
check "the default key * runs two calls one at a time" sh -c "! awk -v a=$t0 -v b=$t1 'BEGIN { exit !(b - a < 2) }'"
gh_spec 'keys: []' >agent.yaml
rm -f fake/count
t0=$(now)
run "go"
t1=$(now)
check "keys: [] runs them together" within "$t0" "$t1" 1.9
check "  with both results" [ "$(jq -r '[.messages[-2:][].content] | join(" ")' fake/req-02.json)" = "echo: a echo: b" ]
gh_spec 'keys: ["repo:{repo}"]' >agent.yaml
hook hooks/before_tool <<'EOF'
pass
EOF
calls gh__create_issue '{\"repo\":\"a/b\",\"title\":\"t\"}'
run "go"
check "{arg} in the server's keys is filled in" grep -q '"keys": \["repo:a/b"\]' hooks/before_tool.in
check "before_tool sees the server" grep -q '"server": "gh"' hooks/before_tool.in

begin "timeout and Ctrl-C"
gh_spec 'timeout: 1' >agent.yaml
export FAKE_MCP_SLOW=20
calls gh__echo '{\"kind\":\"slow\"}' gh__echo '{\"text\":\"after\"}'
run "go"
check "a slow call ends with the timeout text" [ "$(result 1)" = "[timed out after 1s; arx cancelled the call]" ]
id=$(grep tools/call fake/mcp-gh.jsonl | head -1 | jq .id)
check "notifications/cancelled reaches the server with the request id" \
  [ "$(grep notifications/cancelled fake/mcp-gh.jsonl | jq -c .params)" = "{\"requestId\":$id,\"reason\":\"timeout\"}" ]
check "the next call uses the same server" [ "$(result 2) $(starts gh)" = "echo: after 1" ]
{ gh_spec; echo 'tools: {gh__echo: {timeout: 1}}'; } >agent.yaml
calls gh__echo '{\"kind\":\"slow\"}'
run "go"
check "tools.<server>__<tool>.timeout wins for one tool" [ "$(result 1)" = "[timed out after 1s; arx cancelled the call]" ]
gh_spec >agent.yaml
calls gh__echo '{\"kind\":\"slow\"}'
rm -f fake/mcp-gh.jsonl
"$ARX" -p go --quiet >out.txt 2>err.txt &
pid=$!
for _ in $(seq 1 100); do grep -qs tools/call fake/mcp-gh.jsonl && break; sleep 0.05; done
server=$(cat fake/mcp-gh.pid)
kill -INT "$pid"
wait "$pid"
code=$?
check "Ctrl-C exits 130" exited 130
check "  the call is interrupted" has $TRANSCRIPT '[interrupted]'
check "  and no server is left" sh -c "! kill -0 $server 2>/dev/null"

begin "crash"
gh_spec >agent.yaml
export FAKE_MCP_MODE=crash=2
calls gh__echo '{\"text\":\"one\"}' gh__echo '{\"text\":\"two\"}' gh__echo '{\"text\":\"three\"}'
run "go"
check "an exit during a call is an error with the code" result_has 2 "the MCP server gh exited with code 3"
check "  the end of its log" result_has 2 "fake-mcp: out of memory"
check "  and the log's path" result_has 2 "[its log: $WS/.arx/sessions/"
check "the next call restarts the server" [ "$(result 3) $(starts gh)" = "echo: three 2" ]
check "mcp.server tells the exit" grep -q '"type":"mcp.server","server":"gh","state":"exit".*"code":3' $EVENTS
export FAKE_MCP_MODE=dies
rm -f fake/mcp-gh.starts
sse_tool gh__echo '{\"text\":\"x\"}' | reply 1 "200 OK"
sse_tool gh__echo '{\"text\":\"y\"}' | reply 2 "200 OK"
sse_tool bash "{\\\"command\\\":\\\"sed -i.bak 's/args: .gh./args: [gh], env: {FAKE_MCP_MODE: modern}/' agent.yaml\\\"}" | reply 3 "200 OK"
sse_tool gh__echo '{\"text\":\"z\"}' | reply 4 "200 OK"
sse_text "done" | reply 5 "200 OK"
rm -f fake/count
run "go"
check "three exits make the server failed" grep -q 'the MCP server gh failed: it exited 3 times in 5 minutes (last code 4)' fake/req-02.json
check "  after three starts" [ "$(grep -c '"state":"start"' $EVENTS)" -ge 3 ]
check "  with one [harness] note" [ "$(grep -o 'The MCP server gh failed' fake/req-05.json | wc -l | tr -d ' ')" = 1 ]
check "  its next call fails at once" grep -q '"content":"the MCP server gh failed: it exited 3 times' fake/req-03.json
check "an edit to its entry clears it" [ "$(result 4)" = "echo: z" ]
unset FAKE_MCP_MODE

begin "reload"
mcp_spec >agent.yaml <<EOF
a: {command: $FAKE_MCP, args: [a], keys: []}
b: {command: $FAKE_MCP, args: [b], keys: []}
c: {command: $FAKE_MCP, args: [c], keys: []}
EOF
script edit.sh <<'EOF'
#!/bin/sh
for s in a b c; do cp fake/mcp-$s.pid pid-$s; done
sed -i.bak -e 's/args: .a./args: [a, ], timeout: 9/' -e '/^  c:/d' agent.yaml
EOF
sse_calls a__echo '{}' b__echo '{}' c__echo '{}' | reply 1 "200 OK"
sse_tool bash '{\"command\":\"./edit.sh\"}' | reply 2 "200 OK"
sse_calls a__echo '{}' b__echo '{}' | reply 3 "200 OK"
sse_tool bash '{\"command\":\"kill -0 $(cat pid-c) 2>/dev/null || echo gone >c.gone; cp fake/mcp-a.pid pid-a2; cp fake/mcp-b.pid pid-b2\"}' | reply 4 "200 OK"
sse_text "done" | reply 5 "200 OK"
run "go"
check "a changed entry gets a new process" sh -c '[ "$(cat pid-a)" != "$(cat pid-a2)" ]'
check "an unchanged one keeps its process" sh -c '[ "$(cat pid-b)" = "$(cat pid-b2)" ]'
check "a removed one stops" [ -f c.gone ]
check "  and its tools leave the request" [ "$(tool_names 5)" = "bash edit mcp_search mcp_select a__echo b__echo" ]

begin "list_changed"
for era in changes changes,legacy; do
  gh_spec 'preload: true' >agent.yaml
  rm -rf .arx/mcp fake/mcp-gh.jsonl
  calls gh__rename '{}'
  FAKE_MCP_MODE=$era run "go"
  check "$era: the first request has the old name" sh -c "tool_names() { jq -r '[.tools[].function.name] | join(\" \")' fake/req-01.json; }; tool_names | grep -q gh__create_issue"
  check "$era: the next request has the new list" sh -c "grep -q gh__open_issue fake/req-02.json && ! grep -q '\"gh__create_issue\"' fake/req-02.json"
done
check "a legacy server sends the change unasked" sh -c "! grep -q subscriptions/listen fake/mcp-gh.jsonl"
rm -rf .arx/mcp fake/mcp-gh.jsonl
calls gh__echo '{}'
FAKE_MCP_MODE=changes run "go"
check "a modern server gets subscriptions/listen" \
  [ "$(grep subscriptions/listen fake/mcp-gh.jsonl | jq -c .params.notifications)" = '{"toolsListChanged":true}' ]

begin "stderr"
gh_spec >agent.yaml
script slow-curl <<EOF
#!/bin/sh
sleep 1
exec "$ROOT/tests/fake-curl" "\$@"
EOF
calls gh__echo '{\"text\":\"1\"}' gh__echo '{\"text\":\"2\"}'
FAKE_MCP_MODE=chatty ARX_CURL=$WS/slow-curl run "go"
check "a server that fills stderr does not block" [ "$(result 2)" = "echo: 2" ]
check "  and its log holds all of it" [ "$(wc -c <"$(ls -d .arx/sessions/2*/mcp/gh.log)")" -ge 4194304 ]

begin "hooks"
gh_spec >agent.yaml
hook hooks/before_tool <<'EOF'
if obj.get("server") == "gh" and obj["name"].endswith("delete_repo"):
    out(result="denied: gh may not delete", is_error=True)
elif obj["name"] == "bash":
    out(name="gh__echo", args={"text": "renamed"})
EOF
hook hooks/after_tool <<'EOF'
if obj["call"]["name"] == "gh__create_issue":
    out(result=obj["result"] + " [checked]")
EOF
calls mcp_search '{\"query\":\"issue\"}' gh__delete_repo '{\"repo\":\"a\"}' \
  gh__create_issue '{\"repo\":\"a\",\"title\":\"t\"}' bash '{\"command\":\"true\"}'
run "go"
check "before_tool can deny by server" [ "$(result 2)" = "denied: gh may not delete" ]
check "  and the server never gets the call" sh -c "! grep -q delete.repo fake/mcp-gh.jsonl"
check "after_tool changes the result" [ "$(result 3)" = "create_issue:  [checked]" ]
check "a hook can rename a call to an MCP tool" [ "$(result 4 | head -1)" = "echo: renamed" ]
check "  and the result says what ran" result_has 4 '[ran as: gh__echo {"text":"renamed"}]'

begin "plugins and \${NAME}"
mkdir -p plugins/gh/bin
cp "$FAKE_MCP" plugins/gh/bin/server
cat >plugins/gh/plugin.yaml <<'EOF'
name: gh
mcp_servers:
  gh: {command: ./bin/server, args: [gh], env: {TOKEN_A: "${MY_TOKEN}", TOKEN_B: "${NOPE:-fallback}"}}
EOF
spec >agent.yaml
calls gh__echo '{\"text\":\"p\"}'
MY_TOKEN=secret run "go"
check "a plugin's server with a relative command runs" [ "$(result 1)" = "echo: p" ]
check "  with ARX_PLUGIN_DIR" [ "$(jq -r .ARX_PLUGIN_DIR fake/mcp-gh.starts)" = "$(cd plugins/gh && pwd -P)" ]
check "\${NAME} expands from the environment" [ "$(jq -r .TOKEN_A fake/mcp-gh.starts)" = secret ]
check "\${NAME:-default} falls back" [ "$(jq -r .TOKEN_B fake/mcp-gh.starts)" = fallback ]
check "arx check prints the value unexpanded" sh -c "MY_TOKEN=secret '$ARX' check | grep -vq secret"
calls gh__echo '{\"text\":\"p\"}'
run "go"
check "a missing variable stops the start, by name" grep -q 'the MCP server gh failed: the environment variable MY_TOKEN is not set' fake/req-02.json
{ spec; echo 'enable: [{gh: {mcp_servers: {gh: {args: [gh, extra]}}}}]'; } >agent.yaml
echo '[{"name": "echo", "description": "Echo."}]' >extra
rm -f fake/mcp-gh.starts
calls gh__echo '{\"text\":\"p\"}'
MY_TOKEN=secret run "go"
check "the plugin's settings override args" [ "$(jq -c .argv fake/mcp-gh.starts)" = '["gh","extra"]' ]

begin "credentials"
script cred <<'EOF'
#!/bin/sh
read -r input
echo "$input" >>cred.log
echo '{"api_key": "key-from-program"}'
EOF
{ gh_spec 'credential: k, api_key_env: TOKEN_GH'; echo 'credentials: {k: ./cred}'; } >agent.yaml
sse_text "done" | reply 1 "200 OK"
run "go"
check "the program does not run before the start" [ ! -e cred.log ]
calls gh__echo '{\"text\":\"c\"}'
run "go"
check "the program's api_key lands in api_key_env" [ "$(jq -r .TOKEN_GH fake/mcp-gh.starts)" = key-from-program ]
check "  it gets reason start and the server" [ "$(jq -c . cred.log)" = '{"reason":"start","server":"gh"}' ]
script cred <<'EOF'
#!/bin/sh
echo "sign in first" >&2
exit 1
EOF
calls gh__echo '{\"text\":\"c\"}'
run "go"
check "a failing program fails the server with its stderr" grep -q 'the MCP server gh failed: the credential program failed (exit 1): sign in first' fake/req-02.json

begin "events"
gh_spec >agent.yaml
calls gh__echo '{\"kind\":\"progress\",\"text\":\"e\"}'
run "go"
check "mcp.server goes start, ready, stop" [ "$(grep '"mcp.server"' $EVENTS | jq -r .state | tr '\n' ' ')" = "start ready stop " ]
check "tool.start has the server" [ "$(grep '"tool.start"' $EVENTS | jq -r .server)" = gh ]
check "tool.progress carries the server's progress" \
  [ "$(grep '"tool.progress"' $EVENTS | jq -c '[.name, .server, .progress, .total, .message]')" = '["gh__echo","gh",1,2,"half"]' ]

begin "a call in the background"
ln -s "$ROOT/plugins/background" "$ARX_CONFIG_DIR/plugins/background"
{ gh_spec; echo 'enable: [{background: {tools: [gh__echo]}}]'; } >agent.yaml
export FAKE_MCP_SLOW=0.5
calls gh__echo '{\"kind\":\"slow\",\"text\":\"bg\"}'
sse_text "waiting" | reply 2 "200 OK"
sse_text "done" | reply 3 "200 OK"
run "go"
check "an MCP call can move to the background" has fake/req-02.json 'started as c1 in the background'
check "  and its result arrives in a note" grep -q 'c1 (gh__echo: .*) finished after [0-9]*s:\\necho: bg' fake/req-03.json
export FAKE_MCP_SLOW=30
calls gh__echo '{\"kind\":\"slow\",\"text\":\"never\"}' bash '{\"command\":\"sleep 1\"}'
rm -f fake/mcp-gh.jsonl
t0=$(now)
run "go" --cap turns=2
t1=$(now)
check "the end of the session stops a background MCP call" within "$t0" "$t1" 10
check "  with notifications/cancelled to the server" grep -q notifications/cancelled fake/mcp-gh.jsonl
rm -f "$ARX_CONFIG_DIR/plugins/background"

summary
