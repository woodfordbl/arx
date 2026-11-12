#!/usr/bin/env bash
# mcp-http.sh: `arx mcp http`, the bridge for `url:` servers, against
# fake-curl, which answers the bridge by its Mcp-Method header. Run with
# `make test`.
set -u
. "$(dirname "$0")/mcp-lib.sh"

# mcp_reply METHOD[-NN] STATUS [HEADER...] < BODY: the reply to a method
# (a/b is written a-b), for every call or for call NN.
mcp_reply() {
  local name=$1 status=$2
  shift 2
  {
    echo "HTTP/1.1 $status"
    for h in "$@"; do echo "$h"; done
    echo
    cat
  } >"$FAKE_DIR/mcp-$name.resp"
}

# A JSON-RPC result line.
rpc() { printf '{"jsonrpc":"2.0","id":1,"result":%s}\n' "$1"; }

# The usual replies of a modern server with two tools.
modern() {
  rpc '{"supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"instructions":"Linear issues."}' |
    mcp_reply server-discover "200 OK" "Content-Type: application/json"
  rpc '{"tools":[{"name":"find","description":"Find issues.","inputSchema":{"type":"object","properties":{"region":{"type":"string","x-mcp-header":"Region"},"q":{"type":"string"}}}},{"name":"bad","description":"Bad header.","inputSchema":{"type":"object","properties":{"o":{"type":"object","x-mcp-header":"Thing"}}}}]}' |
    mcp_reply tools-list "200 OK" "Content-Type: application/json"
  rpc '{"content":[{"type":"text","text":"found 3"}]}' |
    mcp_reply tools-call "200 OK" "Content-Type: application/json"
}

# linear_spec [KEYS]: a spec with the HTTP server "linear".
linear_spec() {
  local extra=""
  [ $# -gt 0 ] && extra=", $*"
  echo "linear: {url: \"https://mcp.linear.example/mcp\"$extra}" | mcp_spec
}

begin "bridge: headers and replies"
linear_spec 'headers: {X-Team: "${TEAM:-blue}"}' >agent.yaml
modern
{
  printf 'event: message\ndata: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":%s,"progress":1,"total":4}}\n\n' 3
  printf 'data: {"jsonrpc":"2.0","id":9,"result":{"content":[{"type":"text","text":"streamed"}]}}\n\n'
} | mcp_reply tools-call-02 "200 OK" "Content-Type: text/event-stream"
calls mcp_search '{\"query\":\"find bad\"}' \
  linear__find '{\"region\":\"eu\",\"q\":\"x\"}' \
  linear__find '{\"region\":\"zürich\"}'
run "go"
check "search lists the server's tools through the bridge" result_has 1 "linear__find: Find issues."
check "a tool with a bad x-mcp-header is dropped" sh -c "! grep -q linear__bad fake/req-02.json"
check "  with a line in the server's log" grep -q "dropped the tool bad" "$(ls .arx/sessions/2*/mcp/linear.log)"
check "a JSON reply is one message" [ "$(result 2)" = "found 3" ]
hdr=fake/mcp-tools-call-01.hdr
check "requests carry MCP-Protocol-Version" has $hdr "MCP-Protocol-Version: 2026-07-28"
check "  Mcp-Method" has $hdr "Mcp-Method: tools/call"
check "  Mcp-Name" has $hdr "Mcp-Name: find"
check "  Mcp-Param-{Name} for a marked argument" has $hdr "Mcp-Param-Region: eu"
check "  not for an unmarked one" lacks $hdr "Mcp-Param-Q"
check "  the entry's headers, expanded" has $hdr "X-Team: blue"
check "  and Accept for both reply kinds" has $hdr "Accept: application/json, text/event-stream"
check "the body is the JSON-RPC request" [ "$(jq -c '[.method, .params.name, .params.arguments.q]' fake/mcp-tools-call-01.json)" = '["tools/call","find","x"]' ]
check "a value that is not ASCII goes as base64" has fake/mcp-tools-call-02.hdr "Mcp-Param-Region: =?base64?$(printf 'zürich' | base64)?="
check "an event stream reply gives the response" [ "$(result 3)" = "streamed" ]
check "  and its notifications reach arx" grep -q '"type":"tool.progress".*"server":"linear","progress":1,"total":4' $EVENTS
check "the entry is not on the command line" sh -c "! grep -q 'X-Team' $EVENTS"
check "arx check --hosts has the url's host" sh -c "'$ARX' check --hosts | grep -qx mcp.linear.example"

begin "bridge: errors, retries and cancel"
linear_spec 'timeout: 1' >agent.yaml
modern
echo "busy" | mcp_reply tools-list-01 "503 Service Unavailable" "Retry-After: 0"
echo "boom" | mcp_reply tools-call-01 "500 Internal Server Error"
printf 'SLEEP 20\n' >fake/mcp-tools-call-02.resp
echo "who are you" | mcp_reply tools-call-03 "401 Unauthorized"
calls linear__find '{\"q\":\"a\"}' linear__find '{\"q\":\"b\"}' linear__find '{\"q\":\"c\"}'
run "go"
check "tools/list is retried after a 503" [ "$(cat fake/count-tools-list)" = 2 ]
check "an HTTP error reaches the model as an MCP error" [ "$(result 1)" = "MCP error -32000: HTTP 500 from mcp.linear.example: boom" ]
check "tools/call is not retried" [ "$(cat fake/count-tools-call)" = 3 ]
check "a slow call times out" [ "$(result 2)" = "[timed out after 1s; arx cancelled the call]" ]
check "  and the cancel stops its HTTP request" [ -e fake/mcp-tools-call-02.killed ]
check "a 401 without a credential says what to set" result_has 3 "401 from mcp.linear.example: the server wants a credential. Set mcp_servers.linear.credential"

begin "bridge: credentials"
script cred <<'EOF'
#!/bin/sh
read -r input
echo "$input" >>cred.log
n=$(wc -l <cred.log | tr -d ' ')
echo "{\"headers\": {\"Authorization\": \"Bearer token-$n\"}}"
EOF
{ linear_spec 'credential: oauth'; echo 'credentials: {oauth: ./cred}'; } >agent.yaml
modern
echo "expired" | mcp_reply tools-call-01 "401 Unauthorized" 'WWW-Authenticate: Bearer resource_metadata="https://mcp.linear.example/.well-known/oauth-protected-resource", scope="read"'
calls linear__find '{\"q\":\"a\"}'
run "go"
check "the program runs before the first request" [ "$(head -1 cred.log | jq -c '[.reason, .server, .url, .base_url]')" = '["start","linear","https://mcp.linear.example/mcp","https://mcp.linear.example/mcp"]' ]
check "its header goes on the requests" has fake/mcp-tools-list-01.hdr "Authorization: Bearer token-1"
check "a 401 runs it again with reason rejected" [ "$(sed -n 2p cred.log | jq -c '[.reason, .status]')" = '["rejected",401]' ]
check "  with the WWW-Authenticate value as the challenge" \
  [ "$(sed -n 2p cred.log | jq -r .challenge)" = 'Bearer resource_metadata="https://mcp.linear.example/.well-known/oauth-protected-resource", scope="read"' ]
check "  and the request is repeated once, with the new value" has fake/mcp-tools-call-02.hdr "Authorization: Bearer token-2"
check "  which succeeds" [ "$(result 1)" = "found 3" ]
echo "no" | mcp_reply tools-call "401 Unauthorized"
calls linear__find '{\"q\":\"a\"}'
rm -f fake/count-* fake/mcp-tools-call-0*
run "go"
check "a second 401 ends the request with an error" result_has 1 "401 from mcp.linear.example: the server rejected the credential"
check "  after one repeat" [ "$(cat fake/count-tools-call)" = 2 ]
script cred <<'EOF'
#!/bin/sh
echo "sign in with: arx mcp-oauth login linear" >&2
exit 1
EOF
calls linear__find '{\"q\":\"a\"}'
rm -rf .arx/mcp
run "go"
check "a failing program's stderr reaches the model" grep -q 'sign in with: arx mcp-oauth login linear' fake/req-02.json

begin "bridge: a legacy server"
linear_spec >agent.yaml
modern
echo "Not Found" | mcp_reply server-discover "404 Not Found"
rpc '{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":true}},"serverInfo":{"name":"old"},"instructions":"An old server."}' |
  mcp_reply initialize "200 OK" "Content-Type: application/json" "Mcp-Session-Id: sess-1"
: | mcp_reply notifications-initialized "202 Accepted"
echo "gone" | mcp_reply tools-call-01 "404 Not Found"
calls linear__find '{\"q\":\"a\"}' mcp_search '{\"query\":\"\"}'
run "go"
check "a 404 on the first request starts the handshake" [ "$(jq -c '[.method, .params.protocolVersion]' fake/mcp-initialize-01.json)" = '["initialize","2025-11-25"]' ]
check "  then notifications/initialized, with no id" [ "$(jq -c '[.method, has("id")]' fake/mcp-notifications-initialized-01.json)" = '["notifications/initialized",false]' ]
check "later requests carry the session id" has fake/mcp-tools-list-01.hdr "Mcp-Session-Id: sess-1"
check "  and the legacy version" has fake/mcp-tools-list-01.hdr "MCP-Protocol-Version: 2025-06-18"
check "arx sees a modern server" grep -q '"state":"ready","era":"modern"' $EVENTS
check "  with the server's instructions" result_has 2 "linear: An old server (1 tools)"
check "a 404 with a session id starts a new session" [ "$(cat fake/count-initialize)" = 2 ]
check "  and repeats the request once" [ "$(result 1) $(cat fake/count-tools-call)" = "found 3 2" ]
check "the bridge ends the session with DELETE" has fake/mcp-delete.hdr "Mcp-Session-Id: sess-1"

begin "the mcp-oauth plugin"
ln -s "$ROOT/plugins/mcp-oauth" "$ARX_CONFIG_DIR/plugins/mcp-oauth"
export ARX_MCP_OAUTH_DIR="$WS/tokens"
linear_spec 'credential: mcp-oauth' >agent.yaml
modern
calls linear__find '{\"q\":\"a\"}'
run "go"
check "without a sign-in the model gets the login line" grep -q 'not signed in to linear: run `arx mcp-oauth login linear`' fake/req-02.json
mkdir -p tokens
cat >tokens/linear.json <<EOF
{"server": "linear", "url": "https://mcp.linear.example/mcp", "issuer": "https://as.example",
 "resource": "https://mcp.linear.example/mcp", "client_id": "c", "token_endpoint": "https://as.example/token",
 "access_token": "at-123", "refresh_token": "rt", "expires_at": $(($(date +%s) + 3600)), "scopes": ["read"]}
EOF
rm -rf .arx/mcp
calls linear__find '{\"q\":\"a\"}'
run "go"
check "a signed-in server's requests carry the token" has fake/mcp-tools-call-01.hdr "Authorization: Bearer at-123"
check "  and the call works" [ "$(result 1)" = "found 3" ]
check "the token is in no event and no transcript" sh -c "! grep -rq at-123 .arx/sessions/*/events.jsonl .arx/sessions/*/transcript.jsonl"
"$ARX" mcp-oauth status >status.txt 2>&1
check "arx mcp-oauth status lists the server" grep -q "^linear	https://mcp.linear.example/mcp	token for 5[89] min	read" status.txt
check "  and prints no token" lacks status.txt "at-123"
"$ARX" mcp-oauth logout linear >out.txt 2>&1
check "arx mcp-oauth logout drops the tokens" [ ! -e tokens/linear.json ]
"$ARX" mcp-oauth login notes >out.txt 2>&1
code=$?
check "login for an unknown server names the servers" has out.txt "no server called notes in mcp_servers (linear)"

begin "mcp-oauth plugin unit tests"
python3 "$ROOT/plugins/mcp-oauth/tests/test_mcp_oauth.py" >unit.txt 2>&1
code=$?
check "discovery, iss, PKCE, refresh and exit codes" exited 0
[ "$code" -eq 0 ] || tail -20 unit.txt

summary
