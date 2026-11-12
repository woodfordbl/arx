#!/usr/bin/env bash
# mcp.sh: the MCP client: the mcp_servers key, the two tools in the prompt,
# search, select, calls and eras, against tests/fake-mcp. mcp-servers.sh has
# the server lifecycle. Run with `make test`.
set -u
. "$(dirname "$0")/mcp-lib.sh"

begin "mcp_servers: validation"
mcp_spec >agent.yaml <<'EOF2'
both: {command: x, url: "https://a.example/mcp"}
old: {url: "https://a.example/sse", type: sse}
bad__name: {command: x}
typo: {comand: x}
none: {}
wrong: {command: x, type: http}
key: {url: "https://a.example/mcp", api_key_env: K}
cred: {command: x, credential: nope}
env: {command: x, env: {A: 1}}
ftp: {url: "ftp://a.example"}
off: {enabled: false}
EOF2
"$ARX" check >check.txt 2>&1
code=$?
check "a bad entry fails the check" exited 2
check "command and url together" has check.txt "mcp_servers.both: give command (stdio) or url (http), not both"
check "type: sse names the fix" has check.txt "mcp_servers.old.type: the HTTP+SSE transport is not supported; use the server's streamable HTTP URL"
check "a bad name" has check.txt 'mcp_servers.bad__name: server names use letters, digits, _ and - (32 max), and no "__"'
check "an unknown key, with its hint" has check.txt 'agent.yaml:8: mcp_servers.typo.comand: unknown key (did you mean "command"?)'
check "neither command nor url" has check.txt "mcp_servers.none: needs command (stdio) or url (http)"
check "type must agree" has check.txt "mcp_servers.wrong.type: http goes with url, not command"
check "api_key_env needs command and credential" has check.txt "mcp_servers.key.api_key_env: needs command and credential"
check "credential must resolve" has check.txt "mcp_servers.cred.credential: not a name in credentials"
check "env values are strings" has check.txt "mcp_servers.env.env.A: must be a string"
check "url is http or https" has check.txt "mcp_servers.ftp.url: must start with http:// or https://"
check "enabled: false alone is fine" lacks check.txt "mcp_servers.off"

begin "mcp_servers: check, hosts and plugins"
mkdir -p plugins/gh/servers
cat >plugins/gh/plugin.yaml <<'EOF2'
name: gh
mcp_servers:
  github: {command: ./servers/run, args: [one]}
  extra: {url: "https://extra.example.com/mcp"}
EOF2
script plugins/gh/servers/run <<'EOF2'
#!/bin/sh
exit 0
EOF2
mcp_spec >agent.yaml <<'EOF2'
notes: {command: ./notes.py, preload: true, keys: []}
linear: {url: "http://mcp.linear.example/mcp", headers: {X-Team: "${TEAM:-a}"}}
local: {url: "http://127.0.0.1:8080/mcp"}
extra: {enabled: false}
EOF2
"$ARX" check >check.txt 2>&1
code=$?
check "the spec is valid" exited 0
check "check lists the servers and their transports" has check.txt "mcp: notes (stdio, not listed) linear (http, not listed) local (http, not listed) github (stdio, not listed)"
check "the spec turns a plugin's server off" lacks check.txt "extra ("
check "check warns about http to a remote host" has check.txt "mcp_servers.linear.url is http, not https"
check "loopback http gets no warning" lacks check.txt "mcp_servers.local.url"
"$ARX" check --hosts >hosts.txt 2>&1
check "--hosts adds each url host" has hosts.txt "mcp.linear.example"
check "--hosts leaves out a server that is off" lacks hosts.txt "extra.example.com"
"$ARX" check --plugin plugins/gh >describe.txt 2>&1
check "check --plugin prints mcp_servers=" has describe.txt "mcp_servers=github extra"
"$ARX" schema >schema.json
check "arx schema has the key" [ "$(jq -r '.properties.mcp_servers.additionalProperties.properties.preload.type | join(",")' schema.json)" = "boolean,array" ]

begin "the prompt cost: two tools"
"$ARX" tools >tools.json
check "no servers: no mcp_search" [ "$(jq -r '[.[].function.name] | join(" ")' tools.json)" = "bash edit" ]
{ mcp_spec <<'EOF2'
github: {command: ./none, description: GitHub issues and pull requests}
linear: {url: "https://mcp.linear.example/mcp"}
notes: {command: ./none, enabled: false}
EOF2
  echo 'tools: {github__create_issue: {timeout: 5}, other: {timeout: 5}}'
} >agent.yaml
"$ARX" tools >tools.json
check "with servers the set gains mcp_search and mcp_select only" \
  [ "$(jq -r '[.[].function.name] | join(" ")' tools.json)" = "bash edit mcp_search mcp_select" ]
jq -r '.[2].function.description' tools.json >about.txt
check "mcp_search names the servers" has about.txt "these MCP servers: github (GitHub issues and pull requests), linear. Then call mcp_select"
check "a server that is off is not named" lacks about.txt "notes"
check "mcp_search needs a query" [ "$(jq -c '.[2].function.parameters.required' tools.json)" = '["query"]' ]
"$ARX" check >check.txt 2>&1
check "tools.<server>__<tool> needs no file" lacks check.txt "tools.github__create_issue is configured"
check "another missing tool is still reported" has check.txt "tools.other is configured but tools/other is missing"
check "nothing starts for a check" [ ! -e .arx/mcp ]

begin "search"
gh_spec 'description: Issues and pull requests' >agent.yaml
calls mcp_search '{\"query\":\"\"}' \
  mcp_search '{\"query\":\"create issue\"}' \
  mcp_search '{\"query\":\"pull requests\"}' \
  mcp_search '{\"query\":\"delet\"}' \
  mcp_search '{\"query\":\"repository\",\"limit\":2}' \
  mcp_search '{\"query\":\"issue\",\"server\":\"nope\"}' \
  mcp_search '{\"query\":\"zebra\"}' \
  mcp_search '{\"query\":\"GH__ECHO\"}'
run "go"
check "an empty query lists the servers" result_has 1 "gh: Issues and pull requests (5 tools)"
check "the search starts the server once" [ "$(starts gh)" = 1 ]
check "it writes the cache" [ "$(jq '.tools | length' .arx/mcp/gh.json)" = 5 ]
check "create_issue ranks first for \"create issue\"" \
  [ "$(result 2 | sed -n 2p)" = "gh__create_issue: Create a new issue in a repository. (repo, title, body?)" ]
check "the first line counts the matches" result_has 2 'of 5 tools match "create issue":'
check "the last line names mcp_select" result_has 2 "Call mcp_select with the names you want."
check "camelCase names split into words" [ "$(result 3 | sed -n 2p | cut -d: -f1)" = "gh__listPullRequests" ]
check "a prefix finds the word" [ "$(result 4 | sed -n 2p | cut -d: -f1)" = "gh__delete_repo" ]
check "limit cuts the list" [ "$(result 5 | grep -c '^gh__')" = 2 ]
check "limit says how many matched" result_has 5 "; the best 2:"
check "an unknown server lists the servers" result_has 6 'No MCP server is called "nope"'
check "no match says so" result_has 7 'No tool of 5 matches "zebra"'
check "an exact name ranks first, in any case" [ "$(result 8 | sed -n 2p | cut -d: -f1)" = "gh__echo" ]
check "the request still has two MCP tools" [ "$(tool_names 9)" = "bash edit mcp_search mcp_select" ]
calls mcp_search '{\"query\":\"create issue\"}'
run "go"
check "a second session searches the cache with no start" [ "$(starts gh)" = 1 ]
check "  and finds the same tool" result_has 1 "gh__create_issue:"
gh_spec 'description: Issues, timeout: 30' >agent.yaml
calls mcp_search '{\"query\":\"create issue\"}'
run "go"
check "a changed entry lists again" [ "$(starts gh)" = 2 ]
calls mcp_search '{\"query\":\"create issue\"}'
FAKE_MCP_TTL=1 run "go"
check "a fresh list is used" [ "$(starts gh)" = 2 ]
calls mcp_search '{\"query\":\"create issue\"}'
jq '.ttlMs = 2000 | .listed_at -= 5' .arx/mcp/gh.json >cache.tmp && mv cache.tmp .arx/mcp/gh.json
run "go"
check "an expired ttlMs lists again" [ "$(starts gh)" = 3 ]

begin "select"
gh_spec >agent.yaml
calls mcp_select '{\"names\":[\"gh__create_issue\",\"gh__echo\"]}' \
  mcp_select '{\"names\":[\"gh__create_isue\"]}' \
  mcp_select '{\"drop\":[\"gh__echo\"]}'
run "go"
check "select says what it added" result_has 1 "Selected gh__create_issue, gh__echo. 2 MCP tools are selected."
check "the next request has the selected tools, in order" \
  [ "$(tool_names 2)" = "bash edit mcp_search mcp_select gh__create_issue gh__echo" ]
check "  with the full schema" [ "$(jq -c '.tools[4].function.parameters.required' fake/req-02.json)" = '["repo","title"]' ]
check "  without \$schema" [ "$(jq '.tools[4].function.parameters | has("$schema")' fake/req-02.json)" = false ]
check "  and the full description" [ "$(jq -r '.tools[4].function.description' fake/req-02.json)" = "Create a new issue in a repository. It needs a title." ]
check "an unknown name is an error with the closest names" result_has 2 'No MCP tool is called "gh__create_isue". Closest: gh__create_issue'
check "drop removes a tool" result_has 3 "Dropped gh__echo. 1 MCP tool is selected."
check "  from the next request" [ "$(tool_names 4)" = "bash edit mcp_search mcp_select gh__create_issue" ]
check "selected.json holds the selection" [ "$(cat .arx/sessions/last/mcp/selected.json)" = '["gh__create_issue"]' ]
id=$(basename "$(readlink .arx/sessions/last)")
calls
run "more" --resume "$id"
check "--resume keeps the selection" [ "$(tool_names 1)" = "bash edit mcp_search mcp_select gh__create_issue" ]
python3 -c 'import json; print(json.dumps([{"name": "t%d" % i, "description": "Tool %d" % i, "inputSchema": {"type": "object"}} for i in range(40)]))' >many.json
echo "gh: {command: $FAKE_MCP, args: [gh, many.json]}" | mcp_spec >agent.yaml
names=$(python3 -c 'print(",".join("\\\"gh__t%d\\\"" % i for i in range(33)))')
calls mcp_select "{\\\"names\\\":[$names]}"
run "go"
check "over 32 tools is an error" result_has 1 "At most 32 MCP tools are selected at once, and this makes 33. Nothing changed."
check "  and selects nothing" [ "$(tool_names 2)" = "bash edit mcp_search mcp_select" ]

begin "calls"
gh_spec 'preload: [echo]' >agent.yaml
calls gh__echo '{\"text\":\"hi\"}' \
  gh__delete_repo '{\"repo\":\"a/b\"}' \
  gh__echo '{\"kind\":\"error\"}' \
  gh__echo '{\"kind\":\"structured\"}' \
  gh__echo '{\"kind\":\"image\"}' \
  gh__echo '{\"kind\":\"link\"}' \
  gh__echo '{\"kind\":\"long\"}' \
  gh__echo '{\"kind\":\"input\"}' \
  gh__echo '{\"kind\":\"rpc\"}' \
  gh__nope '{}'
run "go"
check "a preloaded tool is in the first request" [ "$(tool_names 1)" = "bash edit mcp_search mcp_select gh__echo" ]
check "  and its server started before it" [ "$(starts gh)" = 1 ]
check "text comes back" [ "$(result 1)" = "echo: hi" ]
check "the server gets its own tool name and the arguments" \
  grep -q '"method": *"tools/call", *"params": *{"name": *"delete.repo", *"arguments": *{"repo": *"a/b"}' fake/mcp-gh.jsonl
check "a call to an unselected catalog tool runs" [ "$(result 2)" = "delete.repo: " ]
check "  and arx selects it" [ "$(tool_names 3)" = "bash edit mcp_search mcp_select gh__echo gh__delete_repo" ]
check "isError gives the text" [ "$(result 3)" = "it broke" ]
check "  and an error" [ "$(grep '"tool.end"' $EVENTS | sed -n 3p | jq .error)" = true ]
check "structuredContent alone comes back as JSON" [ "$(result 4)" = '{"n":3,"ok":true}' ]
check "an image is saved to a file" result_has 5 "[image/png, 1 KB: $WS/.arx/sessions/"
image=$(result 5 | sed -n 's/.*: \(.*\.png\)\]$/\1/p')
check "  with its bytes" grep -q "PNG fake image bytes" "$image"
check "  named after the call's output file" [ "$(basename "$image")" = "tool-0005-2.png" ]
check "a resource link is one line" [ "$(result 6)" = "[resource: file:///a.txt (a.txt, text/plain)]" ]
check "long output is cut" result_has 7 "bytes omitted; full output: $WS/.arx/sessions/"
check "  with all of it in tool-NNNN.out" [ "$(grep -c 'line of output' .arx/sessions/last/tool-0007.out)" = 2000 ]
check "input_required is an error that names the request" \
  [ "$(result 8)" = "the server asked for input arx cannot give (elicitation/create): Which repo?" ]
check "a JSON-RPC error gives its code" [ "$(result 9)" = "MCP error -32602: no such thing" ]
check "a name the server lacks is an unknown tool" result_has 10 'unknown tool "gh__nope"'
check "tool.end has the server" [ "$(grep '"tool.end"' $EVENTS | head -1 | jq -r .server)" = gh ]
check "the servers stop with the session" [ "$(grep -c '"state":"stop"' $EVENTS)" = 1 ]
check "  and the process is gone" sh -c "! kill -0 $(cat fake/mcp-gh.pid) 2>/dev/null"
mkdir other && cp agent.yaml other/ && cd other && mkdir fake && export FAKE_DIR=$PWD/fake
gh_spec >agent.yaml
calls gh__echo '{\"text\":\"cold\"}' gh__missing '{}'
run "go"
check "a tool of a server that has not listed runs" [ "$(result 1)" = "echo: cold" ]
check "  after the server listed" [ "$(jq '.tools | length' .arx/mcp/gh.json)" = 5 ]
check "  and is selected with its schema" [ "$(jq -c '.tools[4].function.parameters.properties | keys' fake/req-02.json)" = '["kind","text"]' ]
check "a name it does not list fails" result_has 2 'unknown tool "gh__missing"'

begin "names, include and exclude"
cat >tools.json <<'EOF2'
[{"name": "a.b", "description": "First."}, {"name": "a_b", "description": "Second."},
 {"name": "a_tool_with_a_very_long_name_that_goes_on_and_on_past_sixty_four_chars", "description": "Long."},
 {"name": "drop_me", "description": "Gone."}, {"name": "x_off", "description": "Off."}]
EOF2
{ echo "gh: {command: $FAKE_MCP, args: [gh, tools.json], exclude: [\"drop_*\"], include: [\"a*\", \"drop_*\", \"x_*\"]}" | mcp_spec
  echo 'tools: {gh__x_off: {enabled: false}}'; } >agent.yaml
calls mcp_search '{\"query\":\"first second long gone off\"}'
run "go"
check "other characters become _" result_has 1 "gh__a_b: First."
check "a second tool with that name gets a hash" result | grep -Eq '^gh__a_b_[0-9a-f]{6}: Second\.'
check "a long name is cut to 62 characters with a hash" [ "$(result 1 | grep 'Long\.' | cut -d: -f1 | tr -d '\n' | wc -c | tr -d ' ')" = 62 ]
check "an excluded tool does not exist" sh -c "! grep -q drop_me fake/req-02.json"
check "tools.<name>.enabled: false removes a tool" sh -c "! grep -q x_off fake/req-02.json"

begin "eras"
gh_spec >agent.yaml
calls gh__echo '{\"text\":\"m\"}'
run "go"
check "modern: server/discover, no handshake" sh -c "grep -q server/discover fake/mcp-gh.jsonl && ! grep -q initialize fake/mcp-gh.jsonl"
check "  every request carries _meta" [ "$(grep -c 'io.modelcontextprotocol/protocolVersion' fake/mcp-gh.jsonl)" = 3 ]
check "  mcp.server ready says the era" grep -q '"state":"ready","era":"modern","version":"2026-07-28","tools":5' $EVENTS
rm -rf .arx/mcp fake/mcp-gh.jsonl
calls gh__echo '{\"text\":\"l\"}'
FAKE_MCP_MODE=legacy run "go"
check "legacy: initialize after server/discover fails" [ "$(jq -r .method fake/mcp-gh.jsonl | tr '\n' ' ')" = "server/discover initialize null notifications/initialized tools/list tools/call " ]
check "  the call works" [ "$(result 1)" = "echo: l" ]
check "  a ping gets {}" grep -q '"id":900,"result":{}' fake/mcp-gh.jsonl
check "  legacy requests carry no _meta" sh -c "! grep tools/list fake/mcp-gh.jsonl | grep -q _meta"
check "  the cache records the era" [ "$(jq -r '.era + " " + .version' .arx/mcp/gh.json)" = "legacy 2025-06-18" ]
rm -f fake/mcp-gh.jsonl
calls gh__echo '{\"text\":\"l\"}'
FAKE_MCP_MODE=legacy run "go"
check "  the second start skips the probe" [ "$(head -1 fake/mcp-gh.jsonl | jq -r .method)" = initialize ]
rm -rf .arx/mcp fake/mcp-gh.jsonl
calls gh__echo '{\"text\":\"s\"}'
t0=$(now)
FAKE_MCP_MODE=silent run "go"
t1=$(now)
check "a silent server falls back to initialize" [ "$(result 1)" = "echo: s" ]
check "  after 5 seconds" sh -c "! awk -v a=$t0 -v b=$t1 'BEGIN { exit !(b - a < 5) }' && awk -v a=$t0 -v b=$t1 'BEGIN { exit !(b - a < 9) }'"
rm -rf .arx/mcp
calls gh__echo '{\"text\":\"o\"}'
FAKE_MCP_MODE=old run "go"
check "a modern server without our revision fails, with its versions" \
  [ "$(jq -r '.messages[-2].content' fake/req-02.json)" = 'the MCP server gh failed: it speaks MCP ["2099-01-01"], and arx speaks 2026-07-28' ]
check "  and a [harness] note says so, with the log" result_has 1 "The MCP server gh failed: it speaks MCP"
rm -rf .arx/mcp
calls mcp_search '{\"query\":\"issue\"}'
FAKE_MCP_MODE=pages run "go"
check "a list in pages is followed" result_has 1 "of 5 tools match"

begin "arx mcp"
mcp_spec >agent.yaml <<EOF2
gh: {command: $FAKE_MCP, args: [gh], description: Issues}
dead: {command: $FAKE_MCP, args: [dead], env: {FAKE_MCP_MODE: dies}}
EOF2
"$ARX" mcp list >list.txt 2>&1
check "list shows each server, not listed" [ "$(tr '\t' ' ' <list.txt)" = "gh stdio not listed
dead stdio not listed" ]
check "  and starts nothing" [ "$(starts gh)" = 0 ]
"$ARX" mcp list --refresh >list.txt 2>err.txt
code=$?
check "list --refresh lists the tools" grep -q "^gh	stdio	5 tools	modern	listed 0 min ago" list.txt
check "  says which server failed, with its log" grep -q "^dead	stdio	failed: it exited 3 times in 5 minutes (last code 4) (log: .arx/mcp/dead.log)" list.txt
check "  and exits 1" exited 1
"$ARX" mcp list --json >list.json
check "list --json has the cached tools" [ "$(jq -c '.[0] | [.name, .transport, .tools, .era]' list.json)" = '["gh","stdio",5,"modern"]' ]
"$ARX" mcp search "create issue" --server gh >search.txt 2>&1
calls mcp_search '{\"query\":\"create issue\",\"server\":\"gh\"}'
run "go"
check "arx mcp search prints what mcp_search prints" [ "$(cat search.txt)" = "$(result 1)" ]
echo '{"text": "from the cli"}' | "$ARX" mcp call gh echo >call.txt 2>&1
code=$?
check "arx mcp call makes one call" [ "$(cat call.txt) $code" = "echo: from the cli 0" ]
echo '{"kind": "error"}' | "$ARX" mcp call gh echo >call.txt 2>&1
code=$?
check "  and exits 1 for an error result" [ "$(cat call.txt) $code" = "it broke 1" ]
"$ARX" mcp call gh nope </dev/null >call.txt 2>&1
code=$?
check "  an unknown tool is a usage error" exited 2
"$ARX" doctor >doctor.txt 2>&1
check "arx doctor lists each server again" grep -q "MCP server gh (stdio): 5 tools" doctor.txt
check "  and warns about one that fails" grep -q "! MCP server dead (stdio) failed: it exited 3 times" doctor.txt
"$ARX" help mcp >help.txt 2>&1
check "arx help has the command" has help.txt "search QUERY [--server S]"

summary
