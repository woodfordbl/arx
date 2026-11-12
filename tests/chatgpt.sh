#!/usr/bin/env bash
# chatgpt.sh: the chatgpt plugin against fake-curl: the responses adapter
# (translation, the prompt-cache prefix and session key, failures,
# settings), the chatgpt credential, `arx models`, and the plugin's Python
# unit tests. Run with `make test`.
set -u
. "$(dirname "$0")/lib.sh"

# A Responses stream with the text $1.
resp_text() {
  printf 'event: response.created\ndata: {"type":"response.created"}\n\n'
  printf 'data: {"type":"response.output_text.delta","delta":"%s"}\n\n' "$1"
  printf 'data: {"type":"response.completed","response":{"usage":'
  printf '{"input_tokens":120,"input_tokens_details":{"cached_tokens":96},'
  printf '"output_tokens":7}}}\n\n'
}

# A Responses stream that calls tool $1 with the JSON arguments $2 (escaped
# for a JSON string), in two pieces.
resp_tool() {
  local half=$((${#2} / 2)) item
  item='"type":"function_call","id":"fc_1","call_id":"call_1"'
  printf 'data: {"type":"response.output_item.added","item":{%s,' "$item"
  printf '"name":"%s","arguments":""}}\n\n' "$1"
  printf 'data: {"type":"response.function_call_arguments.delta",'
  printf '"item_id":"fc_1","delta":"%s"}\n\n' "${2:0:$half}"
  printf 'data: {"type":"response.function_call_arguments.delta",'
  printf '"item_id":"fc_1","delta":"%s"}\n\n' "${2:$half}"
  printf 'data: {"type":"response.output_item.done","item":{%s,' "$item"
  printf '"name":"%s","arguments":"%s"}}\n\n' "$1" "$2"
  printf 'data: {"type":"response.completed","response":{}}\n\n'
}

# A Responses stream that fails with the error code $1.
resp_fail() {
  printf 'data: {"type":"response.failed","response":{"error":'
  printf '{"code":"%s","message":"failed: %s"}}}\n\n' "$1" "$1"
}

# Writes a chatgpt sign-in record to $ARX_CHATGPT_DIR/auth.json, with the
# scopes in $1.
signed_in() {
  mkdir -p "$ARX_CHATGPT_DIR"
  cat >"$ARX_CHATGPT_DIR/auth.json" <<EOF
{"client_id": "oaiapp_test", "subject": "user-1", "access_token": "plan-token",
 "refresh_token": "refresh-1", "expires_at": $(($(date +%s) + 3600)),
 "refreshed_at": 0, "scopes": [$1]}
EOF
}

begin "responses adapter"
mkdir -p plugins
ln -s "$ROOT/plugins/chatgpt" plugins/chatgpt
{ cred_spec 'base_url: "http://fake.invalid/v1", adapter: responses'
  echo 'model_settings: {temperature: 0.2, max_tokens: 100}'; } >agent.yaml
resp_tool bash '{\"command\":\"echo hi\"}' | reply 1 "200 OK"
resp_text "all done" | reply 2 "200 OK"
run "go"
check "the run succeeds" exited 0
check "the reply's text comes through" has out.txt "all done"
check "the call goes to /responses" [ "$(cat fake/url-01.txt)" = "http://fake.invalid/v1/responses" ]
check "store false, stream true, instructions" json fake/req-01.json \
  "j['store'] is False and j['stream'] is True and j['instructions']"
check "unsupported settings are left out" json fake/req-01.json \
  "not {'messages', 'temperature', 'max_tokens', 'stream_options'} & set(j)"
check "the tools are in one namespace" json fake/req-01.json \
  "j['tools'][0]['type'] == 'namespace' and 'bash' in [t['name'] for t in j['tools'][0]['tools']]"
check "the tool call goes back with its namespace" json fake/req-02.json \
  "{'type': 'function_call', 'call_id': 'call_1', 'name': 'bash', 'arguments': '{\"command\":\"echo hi\"}', 'namespace': 'arx'} in j['input']"
check "and its result" json fake/req-02.json \
  "[i['output'] for i in j['input'] if i.get('type') == 'function_call_output'] == ['hi\\n']"
check "usage is counted" has .arx/sessions/last/events.jsonl '"tokens_in":120'
check "and the cached part of it" has .arx/sessions/last/events.jsonl '"tokens_cached":96'

# For the prompt cache, each request must start with the bytes of the one
# before it, under one session key. Templates render once; a retry resends.
begin "responses adapter: each request extends the one before"
mkdir -p plugins prompts
ln -s "$ROOT/plugins/chatgpt" plugins/chatgpt
echo 'Today is {{date}}, turn {{turn}}, session {{session}}.' >prompts/system.md
printf '{{file:notes.md}}\n\n{{prompt}}\n' >prompts/first.md
echo "notes v1" >notes.md
script hooks/stop <<'EOF'
#!/bin/sh
echo '{"decision": "continue", "message": "Next experiment."}'
EOF
{ cred_spec 'base_url: "http://fake.invalid/v1", adapter: responses'
  echo 'instructions: [{file: prompts/system.md}]'
  echo 'first_message: {file: prompts/first.md}'; } >agent.yaml
resp_tool bash '{\"command\":\"echo notes v2 >notes.md; echo one\"}' | reply 1 "200 OK"
reply 2 "500 Internal Server Error" <<<'{"error":{"message":"oops"}}'
resp_text "first answer" | reply 3 "200 OK"
resp_tool bash '{\"command\":\"echo two\"}' | reply 4 "200 OK"
resp_text "second answer" | reply 5 "200 OK"
run "go" --cap turns=4
check "a retry sends the same bytes" cmp fake/req-02.json fake/req-03.json
# extends A B: B is A with items added at the end of its input list.
extends() {
  python3 -c 'import sys; a, b = (open(p, "rb").read() for p in sys.argv[1:])
assert a.endswith(b"]}") and b.startswith(a[:-2] + b", ")' "$1" "$2"
}
for n in 1 3 4; do
  check "request $((n + 1)) starts with the bytes of request $n" \
    extends "fake/req-0$n.json" "fake/req-0$((n + 1)).json"
done
check "templates are rendered once" json fake/req-05.json \
  "'turn 0,' in j['instructions'] and 'notes v1' in j['input'][0]['content']"
check "one UUID names the session, in a session_id header too" json fake/req-05.json \
  "len(j['prompt_cache_key']) == 36 and all('session_id: %s' % j['prompt_cache_key'] in open('fake/hdr-0%d.txt' % n).read() for n in (1, 5))"

begin "responses adapter: failures"
mkdir -p plugins
ln -s "$ROOT/plugins/chatgpt" plugins/chatgpt
cred_spec 'base_url: "http://fake.invalid/v1", adapter: responses' >agent.yaml
resp_fail subscription_sharing_usage_limit_exceeded | reply 1 "200 OK"
resp_text "after the wait" | reply 2 "200 OK"
run "go"
check "a usage limit is retried" exited 0
check "as HTTP 429" has .arx/sessions/last/events.jsonl '"status":429'
resp_fail subscription_sharing_user_not_eligible | reply 3 "200 OK"
run "go"
check "a user who is not eligible stops the run" exited 4
check "with OpenAI's reason" has err.txt "subscription_sharing_user_not_eligible"

begin "responses adapter: settings from a plugin"
mkdir -p plugins/terse
ln -s "$ROOT/plugins/chatgpt" plugins/chatgpt
printf 'name: terse\nmodel_settings: {verbosity: low, temperature: 0.3}\n' >plugins/terse/plugin.yaml
cred_spec 'base_url: "http://fake.invalid/v1", adapter: responses' >agent.yaml
resp_text "short" | reply 1 "200 OK"
run "go"
check "the run succeeds" exited 0
check "verbosity becomes text.verbosity" json fake/req-01.json "j['text'] == {'verbosity': 'low'}"
check "temperature is left out, not an error" json fake/req-01.json \
  "not {'temperature', 'verbosity'} & set(j)"

begin "chatgpt credential"
mkdir -p plugins
ln -s "$ROOT/plugins/chatgpt" plugins/chatgpt
export ARX_CHATGPT_DIR="$WS/chatgpt"
cred_spec 'base_url: "https://api.openai.com/v1", credential: chatgpt, adapter: responses' >agent.yaml
signed_in '"chatgpt.tokens.use.direct", "offline_access", "openid"'
resp_text "from the plan" | reply 1 "200 OK"
run "go"
check "the run succeeds" exited 0
check "the access token is sent" has fake/hdr-01.txt "Authorization: Bearer plan-token"
check "to api.openai.com" [ "$(cat fake/url-01.txt)" = "https://api.openai.com/v1/responses" ]
check "and never shown" lacks .arx/sessions/last/events.jsonl "plan-token"
"$ARX" check --hosts >hosts.txt
check "--hosts lists auth.openai.com and api.openai.com" \
  [ "$(lines hosts.txt)" = "api.openai.com auth.openai.com" ]
signed_in '"openid", "email"'
run "go"
check "without plan usage it stops" exited 4
check "and says why" has err.txt "plan usage is not allowed"
rm "$ARX_CHATGPT_DIR/auth.json"
run "go"
check "before sign-in it stops" exited 4
check "and says to sign in" has err.txt "arx chatgpt login"
unset ARX_CHATGPT_DIR

begin "arx models lists the ChatGPT plan's models"
cred_spec 'base_url: "https://api.openai.com/v1"' >agent.yaml
echo '{"models": [{"slug": "gpt-6.1-sol", "visibility": "list"},
  {"slug": "internal-model", "visibility": "hide"}]}' | reply 1 "200 OK"
"$ARX" models >models.txt 2>&1
check "it lists the visible slugs" has models.txt "gpt-6.1-sol"
check "and leaves out hidden ones" lacks models.txt "internal-model"

begin "chatgpt plugin unit tests"
python3 "$ROOT/plugins/chatgpt/tests/test_chatgpt.py" >unit.txt 2>&1
check "sign-in, refresh, ID tokens and the adapter" has unit.txt "OK"
[ "$failed" -eq 0 ] || tail -20 unit.txt

summary
