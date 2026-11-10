#!/usr/bin/env bash
# mcp.sh: the MCP client: the mcp_servers key, mcp_search and mcp_select,
# server starts and calls, against tests/fake-mcp. Run with `make test`.
set -u
. "$(dirname "$0")/lib.sh"

# Prints the spec with the YAML on stdin under mcp_servers.
mcp_spec() {
  spec
  echo "mcp_servers:"
  sed 's/^/  /'
}

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
check "check lists the servers and their transports" has check.txt "mcp: notes (stdio) linear (http) local (http) github (stdio)"
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

summary
