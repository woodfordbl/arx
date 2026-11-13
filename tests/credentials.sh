#!/usr/bin/env bash
# credentials.sh: credential programs (endpoint.credential), adapters
# (endpoint.adapter) and network hosts (hosts:), and the op-key plugin that
# uses them, against fake-curl. tests/chatgpt.sh covers the chatgpt plugin.
# Run with `make test`.
set -u
. "$(dirname "$0")/lib.sh"

# Writes ./cred, a credential program that logs the reason arx gives it to
# cred.log, then exits with this call's code from cred.exits (a list, one
# per call; 0 or missing prints cred.out).
cred() {
  script cred <<'EOF'
#!/bin/sh
read -r input
echo "$input" | sed -n 's/.*"reason":"\([a-z]*\)".*/\1/p' >>cred.log
n=$(wc -l <cred.log | tr -d ' ')
code=$(awk -v n="$n" '{ print $n }' cred.exits 2>/dev/null)
if [ -n "$code" ] && [ "$code" != 0 ]; then
  echo "cred says no ($code)" >&2
  exit "$code"
fi
cat cred.out
EOF
}

begin "credential program"
cred
echo '{"headers": {"Authorization": "Bearer from-cred", "X-Org": "o1"},
  "base_url": "http://cred.invalid/v2"}' >cred.out
cred_spec 'credential: ./cred, headers: {X-Org: spec, X-Keep: k}' >agent.yaml
sse_text "hi" | reply 1 "200 OK"
OPENAI_API_KEY=env-key run "go"
check "the run succeeds" exited 0
check "its header is sent" has fake/hdr-01.txt "Authorization: Bearer from-cred"
check "it replaces endpoint.headers of the same name" has fake/hdr-01.txt "X-Org: o1"
check "the spec's value is gone" lacks fake/hdr-01.txt "X-Org: spec"
check "other endpoint.headers stay" has fake/hdr-01.txt "X-Keep: k"
check "the key in the environment is not sent" lacks fake/hdr-01.txt "env-key"
check "base_url comes from it" has fake/url-01.txt "http://cred.invalid/v2/chat/completions"
check "it got reason start" [ "$(lines cred.log)" = "start" ]
check "a model.credential event" has .arx/sessions/last/events.jsonl '"type":"model.credential"'
check "the event holds no secret" lacks .arx/sessions/last/events.jsonl "from-cred"

begin "credential value is reused"
cred
echo '{"api_key": "k1"}' >cred.out
cred_spec 'base_url: "http://fake.invalid/v1", credential: ./cred' >agent.yaml
sse_tool bash '{\"command\":\"true\"}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "go"
check "the run succeeds" exited 0
check "one run for two calls" [ "$(lines cred.log)" = "start" ]
check "api_key becomes a bearer header" has fake/hdr-02.txt "Authorization: Bearer k1"
check "base_url stays the spec's" has fake/url-01.txt "http://fake.invalid/v1/chat/completions"

begin "credential that expires"
cred
echo "{\"api_key\": \"k2\", \"expires_at\": $(($(date +%s) + 30))}" >cred.out
cred_spec 'base_url: "http://fake.invalid/v1", credential: ./cred' >agent.yaml
sse_tool bash '{\"command\":\"true\"}' | reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
run "go"
check "the run succeeds" exited 0
check "it runs again before a call when under a minute is left" \
  [ "$(lines cred.log)" = "start expired" ]

begin "credential rejected once"
cred
echo '{"api_key": "k3"}' >cred.out
cred_spec 'base_url: "http://fake.invalid/v1", credential: ./cred' >agent.yaml
echo '{"error": {"message": "token revoked"}}' | reply 1 "401 Unauthorized"
sse_text "ok" | reply 2 "200 OK"
run "go"
check "the call is retried with a new value" exited 0
check "it got reason rejected" [ "$(lines cred.log)" = "start rejected" ]

begin "credential rejected twice"
cred
echo '{"api_key": "k4"}' >cred.out
cred_spec 'base_url: "http://fake.invalid/v1", credential: ./cred' >agent.yaml
echo '{"error": {"message": "token revoked"}}' | reply 1 "401 Unauthorized"
echo '{"error": {"message": "still revoked"}}' | reply 2 "401 Unauthorized"
run "go"
check "the run stops with exit 4" exited 4
check "it asked once more, not again" [ "$(lines cred.log)" = "start rejected" ]
check "the endpoint's reason is shown" has err.txt "still revoked"

begin "credential asks to try later"
cred
echo '{"api_key": "k5"}' >cred.out
echo "75 0" >cred.exits
cred_spec 'base_url: "http://fake.invalid/v1", credential: ./cred' >agent.yaml
sse_text "ok" | reply 1 "200 OK"
run "go"
check "exit 75 is retried" exited 0
check "it ran twice" [ "$(lines cred.log)" = "start start" ]
check "a model.retry event" has .arx/sessions/last/events.jsonl "asked to try again later"

begin "credential asks to try later after a rejection"
cred
echo '{"api_key": "k7"}' >cred.out
echo "0 75 0" >cred.exits
cred_spec 'base_url: "http://fake.invalid/v1", credential: ./cred' >agent.yaml
echo '{"error": {"message": "token revoked"}}' | reply 1 "401 Unauthorized"
sse_text "ok" | reply 2 "200 OK"
run "go"
check "the run succeeds" exited 0
check "it asks for a new value until it gets one" \
  [ "$(lines cred.log)" = "start rejected rejected" ]

begin "credential fails"
cred
echo "1" >cred.exits
cred_spec 'base_url: "http://fake.invalid/v1", credential: ./cred' >agent.yaml
run "go"
check "the run stops with exit 4" exited 4
check "its stderr is shown" has err.txt "cred says no (1)"
check "no model call is made" [ ! -e fake/req-01.json ]

begin "credential output is checked"
cred
cred_spec 'base_url: "http://fake.invalid/v1", credential: ./cred' >agent.yaml
echo 'not json' >cred.out
run "go"
check "output that is not JSON stops the run" exited 4
check "the reason is shown" has err.txt "not usable"
printf '{"headers": {"X-A": "one\\r\\nX-Injected: two"}}\n' >cred.out
rm -f cred.log
run "go"
check "a header with a line break is refused" has err.txt "one-line string"
echo '{"expires_at": "soon"}' >cred.out
run "go"
check "expires_at must be a number" has err.txt "expires_at must be a number"

begin "credential validation"
cred_spec 'credential: nope' >agent.yaml
"$ARX" check >check.txt 2>&1
check "an unknown credential is an error" has check.txt "endpoint.credential: not a name in credentials"
cred_spec 'adapter: nope, base_url: "http://x.invalid"' >agent.yaml
"$ARX" check >check.txt 2>&1
check "an unknown adapter is an error" has check.txt "endpoint.adapter: not a name in adapters"
cred_spec 'retry_attempts: 1' >agent.yaml
"$ARX" check >check.txt 2>&1
check "without a credential base_url is required" has check.txt "endpoint.base_url: required"
cred
cred_spec 'credential: ./cred' >agent.yaml
"$ARX" check >check.txt 2>&1
check "with one it is not" has check.txt "ok:"
check "check names the credential" has check.txt "credential: ./cred"
{ cred_spec 'credential: ./cred'; echo 'hosts: ["https://api.example.com/v1"]'; } >agent.yaml
"$ARX" check >check.txt 2>&1
check "hosts are bare names" has check.txt "is not a host name"

begin "credentials and hosts from a plugin"
mkdir -p plugins/keys
cat >plugins/keys/plugin.yaml <<'EOF'
name: keys
version: 0.1.0
description: test credential plugin
credentials: {k: creds/k}
hosts: [vault.example.com, api.example.com]
EOF
script plugins/keys/creds/k <<'EOF'
#!/bin/sh
echo '{"api_key": "from-plugin"}'
EOF
mkdir -p plugins/other
printf 'name: other\nhosts: [other.example.com]\n' >plugins/other/plugin.yaml
{ cred_spec 'base_url: "http://api.example.com/v1", credential: k'
  echo 'hosts: [files.example.com]'; } >agent.yaml
"$ARX" check >check.txt 2>&1
check "check names the credential" has check.txt "credential: k"
check "check lists the hosts" has check.txt "hosts: api.example.com files.example.com vault.example.com other.example.com"
"$ARX" check --hosts >hosts.txt 2>&1
check "--hosts prints one per line, each once" \
  [ "$(lines hosts.txt)" = "api.example.com files.example.com vault.example.com other.example.com" ]
sse_text "ok" | reply 1 "200 OK"
run "go"
check "the plugin's program runs" has fake/hdr-01.txt "Authorization: Bearer from-plugin"
echo 'plugins: [keys]' >>agent.yaml
"$ARX" check --hosts >hosts.txt 2>&1
check "a plugin outside the active list adds no hosts" lacks hosts.txt "other.example.com"
"$ARX" check --plugin plugins/keys >describe.txt
check "check --plugin lists credentials" has describe.txt "credentials=k"
check "check --plugin lists hosts" has describe.txt "hosts=vault.example.com api.example.com"

begin "adapter"
script adapt <<'EOF'
#!/bin/sh
# Logs the command line it is given, then runs it unchanged.
printf '%s\n' "$@" >>adapter-args.txt
exec "$@"
EOF
cred_spec 'base_url: "http://fake.invalid/v1", adapter: ./adapt' >agent.yaml
sse_text "adapted" | reply 1 "200 OK"
run "go"
check "the run succeeds" exited 0
check "the reply comes through" has out.txt "adapted"
check "it gets curl first" [ "$(head -n 1 adapter-args.txt)" = "$ARX_CURL" ]
check "and the URL last" [ "$(tail -n 1 adapter-args.txt)" = "http://fake.invalid/v1/chat/completions" ]
echo '{"data": []}' | reply 2 "200 OK"
"$ARX" request /models >models.txt 2>&1
check "arx request goes through it too" [ "$(tail -n 1 adapter-args.txt)" = "http://fake.invalid/v1/models" ]
cred
echo '{"api_key": "k6"}' >cred.out
cred_spec 'base_url: "http://fake.invalid/v1", credential: ./cred' >agent.yaml
"$ARX" request --auth-source >source.txt 2>&1
check "--auth-source names the program" has source.txt "the credential program ./cred"

begin "op-key plugin"
mkdir -p plugins bin
ln -s "$ROOT/plugins/op-key" plugins/op-key
script bin/op <<'EOF'
#!/bin/sh
[ "$*" = "read --no-newline op://Private/test/credential" ] || {
  echo "op: unexpected arguments: $*" >&2
  exit 1
}
printf 'sk-from-1password'
EOF
cred_spec 'base_url: "http://fake.invalid/v1", credential: op-key' >agent.yaml
sse_text "ok" | reply 1 "200 OK"
PATH="$WS/bin:$PATH" ARX_OP_REF=op://Private/test/credential run "go"
check "the run succeeds" exited 0
check "the key from op is sent" has fake/hdr-01.txt "Authorization: Bearer sk-from-1password"
PATH="$WS/bin:$PATH" run "go"
check "without ARX_OP_REF it stops" exited 4
check "and says what to set" has err.txt "set ARX_OP_REF"

summary
