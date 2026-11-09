#!/usr/bin/env bash
# cli.sh: tests the command line around the agent: help, external commands,
# user defaults, API key lookup, `arx request`, and the arx-* commands
# (setup, init, doctor, models, sessions, update). Run with `make test`.
set -u
. "$(dirname "$0")/lib.sh"

# Writes user defaults (config.yaml) for the fake endpoint.
defaults() {
  cat >"$ARX_CONFIG_DIR/config.yaml" <<'EOF'
model: test-model
endpoint: {base_url: "http://fake.invalid/v1", api_key_env: TEST_KEY, retry_base: 0.01}
EOF
}

# A models list, as /models returns it.
models_json() {
  echo '{"data":[{"id":"test-model","context_window":64000,"pricing":{"input":"0.0000001","output":"0.0000005"}},{"id":"other-model"}]}'
}

begin "help and dispatch"
"$ARX" help >help.txt 2>&1
check "help lists built-ins" has help.txt 'request'
check "help lists external commands" has help.txt 'setup '
check "help shows summaries" has help.txt 'update arx to the latest release'
"$ARX" help setup >setup-help.txt 2>&1
check "help COMMAND runs its --help" has setup-help.txt 'usage: arx setup'
mkdir bin
script bin/arx-hello <<'EOF'
#!/bin/sh
# arx-hello: says hello
echo "hello $* from $(basename "$ARX_BIN")"
EOF
PATH="$PWD/bin:$PATH" "$ARX" hello world >hello.txt 2>&1
check "arx foo runs arx-foo on PATH" has hello.txt 'hello world from arx'
"$ARX" nosuchcommand >/dev/null 2>&1
code=$?
check "unknown command is a usage error" exited 2

begin "user defaults"
rm agent.yaml
"$ARX" check >check.txt 2>&1
code=$?
check "no spec and no defaults says what to do" has check.txt 'arx setup'
defaults
"$ARX" check >check.txt 2>&1
check "defaults alone are a spec" has check.txt 'model test-model'
echo "name: project" >agent.yaml
echo "context_window: 5000" >>agent.yaml
"$ARX" check >check.txt 2>&1
check "project spec merges over defaults" has check.txt 'config.yaml'
echo "modl: typo" >>"$ARX_CONFIG_DIR/config.yaml"
"$ARX" check >check.txt 2>&1
check "a typo in defaults names config.yaml and its line" has check.txt 'config.yaml:3: modl'

begin "API key lookup"
defaults
rm agent.yaml
(umask 077 && echo "TEST_KEY=stored-key" >"$ARX_CONFIG_DIR/credentials")
sse_text "hi" | reply 1 "200 OK"
run "go"
check "saved key is sent" has fake/hdr-01.txt 'Authorization: Bearer stored-key'
sse_text "hi" | reply 2 "200 OK"
TEST_KEY=env-key "$ARX" -p go --quiet >/dev/null 2>&1
check "environment variable wins" has fake/hdr-02.txt 'Authorization: Bearer env-key'
"$ARX" request --auth-source >src.txt 2>&1
check "auth source is named, not shown" has src.txt 'credentials file'
check "auth source hides the key" lacks src.txt 'stored-key'

begin "arx request"
defaults
rm agent.yaml
models_json | reply 1 "200 OK"
"$ARX" request /models >out.txt 2>&1
code=$?
check "prints the body" has out.txt '"test-model"'
check "exits 0 on 200" exited 0
reply 2 "401 Unauthorized" <<<'{"error":{"message":"bad key"}}'
"$ARX" request /models >/dev/null 2>&1
code=$?
check "exits 4 on 401" exited 4

begin "arx setup (non-interactive)"
rm agent.yaml
models_json | reply 1 "200 OK"
models_json | reply 2 "200 OK"
models_json | reply 3 "200 OK"
printf 'sk-test' | "$ARX" setup --provider custom --base-url http://fake.invalid/v1 \
  --key-env TEST_KEY --model test-model --key-stdin --no-test >setup.txt 2>&1
check "writes the model" has "$ARX_CONFIG_DIR/config.yaml" 'model: "test-model"'
check "writes the endpoint" has "$ARX_CONFIG_DIR/config.yaml" 'api_key_env: TEST_KEY'
check "adds context and prices" has "$ARX_CONFIG_DIR/config.yaml" 'prices: {input: 0.1, output: 0.5}'
check "saves the key" has "$ARX_CONFIG_DIR/credentials" 'TEST_KEY=sk-test'
# GNU/busybox `stat -c` first: on busybox, `stat -f` means filesystem status.
check "key file is private" test "$(stat -c %a "$ARX_CONFIG_DIR/credentials" 2>/dev/null ||
  stat -f %Lp "$ARX_CONFIG_DIR/credentials")" = 600
check "validated the key with the endpoint" has fake/hdr-01.txt 'Bearer sk-test'

"$ARX" setup model --model other-model </dev/null >model.txt 2>&1
check "setup model --model sets only the model" has "$ARX_CONFIG_DIR/config.yaml" 'model: "other-model"'
check "and keeps the endpoint" has "$ARX_CONFIG_DIR/config.yaml" 'api_key_env: TEST_KEY'
check "and drops the old model's prices" lacks "$ARX_CONFIG_DIR/config.yaml" 'prices:'
"$ARX" setup model </dev/null >model.txt 2>&1
code=$?
check "setup model without a terminal asks for --model" has model.txt 'no terminal to ask on; pass --model'
check "and exits 2" exited 2
"$ARX" setup --if-needed </dev/null >needed.txt 2>&1
check "--if-needed once set up prints one line" has needed.txt 'arx is already set up (model other-model)'
rm "$ARX_CONFIG_DIR/config.yaml" "$ARX_CONFIG_DIR/credentials"
"$ARX" setup </dev/null >nokey.txt 2>&1
code=$?
check "no flags and no key: no key given" has nokey.txt 'arx setup: no key given'
check "exits 2" exited 2
check "and writes nothing" test ! -e "$ARX_CONFIG_DIR/config.yaml"
"$ARX" kit add </dev/null >/dev/null 2>&1
code=$?
check "kit add with no REF is a usage error" exited 2
"$ARX" plugin enable </dev/null >/dev/null 2>&1
code=$?
check "plugin enable with no NAME is a usage error" exited 2

begin "arx init"
defaults
rm agent.yaml
"$ARX" init >init.txt 2>&1
check "writes agent.yaml" test -f agent.yaml
check "writes the system prompt" test -f prompts/system.md
"$ARX" check >check.txt 2>&1
check "the new harness checks out" has check.txt 'ok:'
"$ARX" init >init2.txt 2>&1
check "does not overwrite" has init2.txt 'kept    agent.yaml'
mkdir research && (cd research && "$ARX" init autoresearch >/dev/null 2>&1)
check "autoresearch template has a stop hook" test -x research/hooks/stop
check "autoresearch template has program.md" test -f research/program.md

begin "arx models, sessions and doctor"
defaults
rm agent.yaml
(umask 077 && echo "TEST_KEY=k" >"$ARX_CONFIG_DIR/credentials")
models_json | reply 1 "200 OK"
"$ARX" models test >models.txt 2>&1
check "models lists ids" has models.txt 'test-model'
check "models marks the default" grep -q '^\* test-model' models.txt
check "models shows prices per million" grep -qE 'test-model +0\.1 +0\.5' models.txt
sse_text "done" | reply 2 "200 OK"
run "count the files"
"$ARX" sessions >sessions.txt 2>&1
check "sessions lists the run" has sessions.txt 'count the files'
check "sessions shows its status" has sessions.txt 'done'
models_json | reply 3 "200 OK"
models_json | reply 4 "200 OK"
"$ARX" doctor >doctor.txt 2>&1
check "doctor finds the key" has doctor.txt 'API key from the arx credentials file'
check "doctor reaches the endpoint" has doctor.txt 'endpoint answers (2 models)'
check "doctor finds the model" has doctor.txt 'model test-model is available'

begin "arx update"
os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m | sed 's/aarch64/arm64/')
mkdir -p prefix/bin prefix/libexec/arx release/arx-$os-$arch/bin release/arx-$os-$arch/libexec/arx
cp "$ARX" prefix/bin/arx
cp "$ROOT"/commands/arx-* prefix/libexec/arx/
printf '#!/bin/sh\necho "arx 9.9.9"\n' >release/arx-$os-$arch/bin/arx
chmod +x release/arx-$os-$arch/bin/arx
cp "$ROOT"/commands/arx-* release/arx-$os-$arch/libexec/arx/
tar -C release -czf release/arx-$os-$arch.tar.gz arx-$os-$arch
(cd release && { sha256sum arx-$os-$arch.tar.gz 2>/dev/null || shasum -a 256 arx-$os-$arch.tar.gz; } >arx-$os-$arch.tar.gz.sha256)
echo v9.9.9 >release/latest
ARX_UPDATE_DIR=$PWD/release prefix/bin/arx update --check >check.txt 2>&1
code=$?
check "--check sees the new release" exited 10
ARX_UPDATE_DIR=$PWD/release prefix/bin/arx update >update.txt 2>&1
check "update installs it" has update.txt '-> 9.9.9'
check "the new binary is in place" has <(prefix/bin/arx version) 'arx 9.9.9'
echo "0000  arx-$os-$arch.tar.gz" >release/arx-$os-$arch.tar.gz.sha256
echo v9.9.10 >release/latest
ARX_UPDATE_DIR=$PWD/release ARX_BIN=$PWD/prefix/bin/arx "$ROOT/commands/arx-update" >bad.txt 2>&1
check "a bad checksum changes nothing" has bad.txt 'checksum mismatch'

begin "ARX_LIB, and the agent without lib/"
"$ARX" plugin new libdemo >/dev/null 2>&1
script libdemo/commands/arx-libdemo <<'END'
#!/usr/bin/env bash
# arx-libdemo: sources ui.sh from ARX_LIB
. "$ARX_LIB/ui.sh" && echo "lib=$ARX_LIB mode=$UI_MODE"
END
"$ARX" plugin add --link ./libdemo --yes </dev/null >/dev/null 2>&1
"$ARX" libdemo </dev/null >lib.txt 2>&1
check "a plugin command sees ARX_LIB" has lib.txt "lib=$ROOT/commands/lib"
check "and sources ui.sh from it" has lib.txt 'mode=off'
"$ARX" plugin remove libdemo --yes </dev/null >/dev/null 2>&1
mkdir -p prefix/bin prefix/libexec/arx
cp "$ARX" prefix/bin/arx
cp "$ROOT"/commands/arx-* prefix/libexec/arx/
check "an install without libexec/arx/lib checks out" prefix/bin/arx check
sse_text "done" | reply 1 "200 OK"
prefix/bin/arx -p go --quiet >out.txt 2>err.txt
check "and runs the agent" has out.txt 'done'

begin "arx plugin"
plugins=$ARX_CONFIG_DIR/plugins
"$ARX" plugin new demo >new.txt 2>&1
check "new makes a plugin" "$ARX" check --plugin demo
"$ARX" plugin add ./demo </dev/null >add.txt 2>&1
code=$?
check "add without a terminal asks for --yes" has add.txt 'add --yes'
check "and changes nothing" test ! -e "$plugins/demo"
"$ARX" plugin add ./demo --yes </dev/null >add.txt 2>&1
check "add --yes copies the folder" test -x "$plugins/demo/tools/demo"
check "it records the source" has "$plugins/demo/.arx-source" "source=$(pwd -P)/demo"
"$ARX" check >check.txt 2>&1
check "the harness uses it" has check.txt 'plugins: demo'
"$ARX" plugin add ./demo --yes </dev/null >add.txt 2>&1
code=$?
check "a second add needs --force" exited 1
"$ARX" plugin list >list.txt 2>&1
check "list shows it" grep -qE '^demo +0\.1\.0 +user' list.txt
"$ARX" plugin remove demo --yes </dev/null >/dev/null 2>&1
check "remove deletes it" test ! -e "$plugins/demo"
"$ARX" add --link ./demo --yes </dev/null >/dev/null 2>&1
check "arx add --link makes a link" test -L "$plugins/demo"
"$ARX" plugin remove demo --yes </dev/null >/dev/null 2>&1
check "removing a link keeps the folder" test -f demo/plugin.yaml
mkdir -p repo/arx-abc1234/plugins mirror/woodfordbl/arx mirror/acme/kit
cp -R demo repo/arx-abc1234/plugins/
tar -czf mirror/woodfordbl/arx/v1.2.3.tar.gz -C repo arx-abc1234
tar -czf mirror/acme/kit/HEAD.tar.gz -C repo arx-abc1234
export ARX_PLUGIN_MIRROR=$PWD/mirror
"$ARX" plugin add demo@v1.2.3 --yes </dev/null >add.txt 2>&1
check "a bare name comes from the arx repo" has "$plugins/demo/.arx-source" 'source=woodfordbl/arx/plugins/demo@v1.2.3'
check "with the commit it came from" has "$plugins/demo/.arx-source" 'commit=arx-abc1234'
"$ARX" plugin add acme/kit/plugins/demo --force --yes </dev/null >add.txt 2>&1
check "OWNER/REPO/PATH comes from that repo" has "$plugins/demo/.arx-source" 'source=acme/kit/plugins/demo@HEAD'
"$ARX" plugin add nosuch@v1.2.3 --yes </dev/null >add.txt 2>&1
check "a missing plugin is explained" has add.txt 'has no plugins/nosuch'
unset ARX_PLUGIN_MIRROR
"$ARX" plugin add ./demo --project --yes </dev/null >add.txt 2>&1
check "--project installs next to agent.yaml" test -f plugins/demo/plugin.yaml
rm -rf "$plugins"

summary
