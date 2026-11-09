#!/usr/bin/env bash
# ui.sh: tests pick (the menu program in commands/lib), ui.sh (the shell
# side) and arx setup's wizard and menu on a pseudo-terminal, driven by
# tests/pty.py. Run with `make test`.
# Without python3 the terminal cases are skipped.
set -u
. "$(dirname "$0")/lib.sh"
PICK=$ROOT/commands/lib/pick
UI=$ROOT/commands/lib/ui.sh

if ! command -v python3 >/dev/null; then
  echo "  skip  ui: python3 is missing, so no terminal tests"
  exit 0
fi

# pty [pty.py options] -- COMMAND...: runs on a pty; sets $code. The screen
# goes to screen.txt and stdout to out.txt.
pty() {
  python3 "$ROOT/tests/pty.py" --screen screen.txt --out out.txt "$@"
  code=$?
}

# The screen without escape sequences, one drawn line per line; with
# --widest, only the width of the widest line, in characters.
plain() {
  python3 -c '
import re, sys
s = open("screen.txt", "rb").read().decode("utf-8", "replace")
s = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b.", "", s)
lines = re.split(r"[\r\n]+", s)
print(max(map(len, lines)) if sys.argv[1:] else "\n".join(lines))' "$@"
}

# True when out.txt is exactly the arguments, one per line.
answer() { [ "$(cat out.txt)" = "$(printf '%s\n' "$@")" ]; }

items() {
  printf 'a\tAlpha\tthe first\nb\tBeta\tthe second\n'
  printf 'c\tGamma\tthe third\toff\nd\tDelta\nm\tMason\t\tchecked\n'
}

begin "pick select"
items >items.txt
pty --stdin items.txt --keys '<down><enter>' -- "$PICK" select --title Letter
check "Down, Enter picks the second" answer b
check "it leaves the answered line" has screen.txt 'Letter    Beta'
pty --stdin items.txt --keys '<down><down><down><enter>' -- "$PICK" select
check "Down skips nothing: the fourth" answer d
pty --stdin items.txt --keys '<enter>' -- "$PICK" select --default d
check "--default starts on that item" answer d
pty --stdin items.txt --keys '<down><down><enter><esc>' -- "$PICK" select
check "Enter on an off item does nothing" exited 4
check "and prints nothing" test ! -s out.txt
pty --stdin items.txt --keys 'jj<down><enter>' -- "$PICK" select
check "j moves down too" answer d
pty --stdin items.txt --keys '<down><enter>' -- "$PICK" select --quiet --title Letter
check "--quiet leaves no answered line" lacks screen.txt 'Letter    Beta'

begin "pick select --filter"
items >items.txt
pty --stdin items.txt --keys 'son<enter>' -- "$PICK" select --filter
check "typing filters the list" answer m
check "the filter hides what doesn't match" test "$(plain | grep -c Alpha)" -le 2
pty --stdin items.txt --keys 'ETA<enter>' -- "$PICK" select --filter
check "the filter ignores case" answer b
pty --stdin items.txt --keys 'zz-model<enter>' -- "$PICK" select --filter --custom
check "--custom takes the typed text" answer zz-model
pty --stdin items.txt --keys 'zz<enter><esc>' -- "$PICK" select --filter
check "without --custom, no match means no answer" exited 4

begin "pick multi"
items >items.txt
pty --stdin items.txt --keys '<space><down><space><enter>' -- "$PICK" multi
check "Space turns items on; checked ones start on" answer a b m
pty --stdin items.txt --keys '<end><space><enter>' -- "$PICK" multi --title Turn
check "turning the checked one off leaves nothing" test ! -s out.txt
check "the answered line says none" has screen.txt 'none'
pty --stdin items.txt --keys '<end><space><enter><space><enter>' -- "$PICK" multi --min 1
check "--min 1 waits for one" answer m
check "and says so" has screen.txt 'choose at least 1'

begin "pick input and secret"
pty --keys 'hello<enter>' -- "$PICK" input --title Name --default 'x '
check "input returns the text after the default" answer 'x hello'
pty --keys '<c-u>abc<left><left>Z<end>!<enter>' -- "$PICK" input --default old
check "Ctrl-U, Left and End edit the line" answer 'aZbc!'
pty --keys 'sk-secret-123<enter>' -- "$PICK" secret --title Key
check "secret returns the text" answer sk-secret-123
check "the secret never reaches the screen" lacks screen.txt 'secret-123'
check "its answered line says hidden" has screen.txt '(hidden)'
pty --keys '<paste:pasted-key\n><enter>' -- "$PICK" secret
check "a paste drops its newline" answer pasted-key
pty --keys '<c-d>' -- "$PICK" input
check "Ctrl-D on an empty box goes back" exited 4

begin "pick confirm"
for case in 'y no 0' 'n yes 1' '<enter> yes 0' '<enter> no 1' 'Y no 0'; do
  set -- $case
  pty --keys "$1" -- "$PICK" confirm --title Go --default "$2"
  check "$1 with default $2 exits $3" exited "$3"
done

begin "pick keys and signals"
items >items.txt
pty --stdin items.txt --stty stty.txt --keys '<down><esc>' -- "$PICK" select
check "Esc exits 4" exited 4
pty --stdin items.txt --keys '<esc><sleep:0.01>[B<enter>' -- "$PICK" select
check "Esc and [B within 50 ms is Down" answer b
pty --stdin items.txt --stty stty.txt --keys '<down><c-c>' -- "$PICK" select
check "Ctrl-C exits 130" exited 130
check "and restores the terminal" has stty.txt same
pty --stdin items.txt --stty stty.txt --keys '<down><signal:TERM>' -- "$PICK" select
check "SIGTERM ends it" exited 143
check "and restores the terminal too" has stty.txt same
pty --stty stty.txt --keys 'ab<c-c>' -- "$PICK" input
check "Ctrl-C in a text box restores the terminal" has stty.txt same
check "and turns bracketed paste off" has screen.txt $'\033[?2004l'

begin "pick screens"
items >items.txt
pty --stdin items.txt --env NO_COLOR=1 --keys '<enter>' -- "$PICK" select --title T
check "NO_COLOR: no color codes" test "$(grep -c $'\033\\[[0-9;]*m' screen.txt)" -eq 0
pty --stdin items.txt --env NO_COLOR= --keys '<enter>' -- "$PICK" select --title T
check "colors otherwise" has screen.txt $'\033[36m'
pty --stdin items.txt --cols 30 --keys '<enter>' -- "$PICK" select --title 'A long title for a narrow terminal'
check "30 columns: every line is narrower" test "$(plain --widest)" -lt 30
check "30 columns: notes are hidden" lacks screen.txt 'the first'
pty --stdin items.txt --cols 15 -- "$PICK" select
check "15 columns: no terminal (3)" exited 3
pty --stdin items.txt --env TERM=dumb -- "$PICK" select
check "TERM=dumb: no terminal (3)" exited 3
pty --stdin items.txt --no-tty -- "$PICK" select
check "no controlling terminal: select exits 3" exited 3
pty --no-tty -- "$PICK" spin -- true
check "no controlling terminal: spin still runs" exited 0
seq 1 200 >many.txt
pty --stdin many.txt --rows 10 --keys '<pgdn><pgdn><enter>' -- "$PICK" select
check "200 items in 10 rows show what's below" has screen.txt '194 more'
check "PgDn moves by a page" answer 13
pty --stdin items.txt --env LC_ALL=C --keys '<enter>' -- "$PICK" select --title T
check "LC_ALL=C: ASCII only" test "$(LC_ALL=C grep -c '[^[:print:][:cntrl:]]' screen.txt)" -eq 0

begin "pick spin"
python3 "$ROOT/tests/pty.py" --out out.txt --err err.txt -- \
  "$PICK" spin --title Work -- sh -c 'echo out; echo err >&2; exit 7'
code=$?
check "passes stdout through" answer out
check "shows stderr when it fails" has err.txt err
check "exits with the command's code" exited 7
python3 "$ROOT/tests/pty.py" --out out.txt --err err.txt -- \
  "$PICK" spin --title Work -- sh -c 'echo quiet >&2'
check "keeps stderr to itself on success" lacks err.txt quiet
sleep 0.3 &
pty -- "$PICK" spin --title Wait --pid $!
check "--pid waits for the process" exited 0
"$PICK" select --nope </dev/null >/dev/null 2>&1
code=$?
check "an unknown option is a usage error" exited 2

begin "ui.sh modes"
# A script that sources ui.sh and asks one question.
printf 'a\tAlpha\nb\tBeta\nc\tGamma\n' >letters.txt
cat >ask.sh <<EOF
#!/usr/bin/env bash
. "$UI"
ui_select Letter a <letters.txt
code=\$?
echo "code \$code mode \$UI_MODE" >&2
[ "\$code" -eq 0 ] || ui_stop "\$code"
EOF
chmod +x ask.sh

pty --env ARX_UI=plain --err err.txt --keys '<wait:Choose>2<enter>' -- ./ask.sh
check "plain mode: a numbered list" has screen.txt ' 2) Beta'
check "plain mode: 2 picks the second" answer b
pty --err err.txt --keys '<down><down><enter>' -- ./ask.sh
check "menu mode on a terminal" has err.txt 'mode menu'
check "and pick answers" answer c
pty --env ARX_UI=off --err err.txt -- ./ask.sh
check "ARX_UI=off asks nothing and takes the default" answer a
pty --env CI=1 --err err.txt -- ./ask.sh
check "CI=1 asks nothing" has err.txt 'mode off'
./ask.sh </dev/null >out.txt 2>err.txt
check "no terminal: off" has err.txt 'mode off'
pty --env TERM=dumb --err err.txt --keys '<wait:Choose><enter>' -- ./ask.sh
check "pick exit 3 drops to plain" has err.txt 'mode plain'
pty --err err.txt --stty stty.txt --keys '<c-c>' -- ./ask.sh
check "Ctrl-C: Cancelled. Nothing changed." has err.txt 'Cancelled. Nothing changed.'
pty --env ARX_UI=plain --err err.txt --stty stty.txt --keys '<wait:Choose><c-c>' -- ./ask.sh
check "Ctrl-C in plain mode exits 130" exited 130
check "and leaves the terminal as it was" has stty.txt same

# A models list, as /models returns it.
models_json() {
  echo '{"data":[{"id":"test-model","context_window":64000,"pricing":{"input":"0.0000001","output":"0.0000005"}},{"id":"other-model"}]}'
}

# Replies to calls N... with the models list.
models_for() { for n in "$@"; do models_json | reply "$n" "200 OK"; done; }

# A fresh config folder with the shell plugin, as after setup.
fresh_config() {
  export ARX_CONFIG_DIR=$WS/$1
  mkdir -p "$ARX_CONFIG_DIR/plugins"
  ln -s "$ROOT/plugins/shell" "$ARX_CONFIG_DIR/plugins/shell"
}

# Comments aside, true when config.yaml in folders $1 and $2 match.
same_config() { diff <(grep -v '^#' "$WS/$1/config.yaml") <(grep -v '^#' "$WS/$2/config.yaml"); }

# Runs arx setup on a pty with arx's folder on PATH, so the PATH step is
# not asked. Extra pty.py options come first, then -- and setup's.
setup_pty() { pty --env PATH="$(dirname "$ARX"):$PATH" "$@"; }

# The keys that answer the wizard: Other, the fake URL, a pasted key, the
# second model, no kit.
WIZARD='<wait:Provider><end><enter><wait:Base URL><c-u>http://fake.invalid/v1<enter>'
WIZARD="$WIZARD<wait:API key><sleep:0.2>sk-test<enter><wait:Model><down><enter><wait:Kit><enter>"

begin "arx setup: the wizard"
rm agent.yaml
models_for 1 2 3 4
fresh_config flags
printf sk-test | "$ARX" setup --provider custom --base-url http://fake.invalid/v1 \
  --key-env ARX_API_KEY --model other-model --key-stdin --no-test >flags.txt 2>&1
fresh_config wizard
setup_pty --keys "$WIZARD" -- "$ARX" setup --no-test
check "it finishes" exited 0
check "it says how to go back and quit" has screen.txt 'Esc goes back, Ctrl-C quits'
check "it writes the same config.yaml as the flags" same_config flags wizard
check "it saves the pasted key" has "$WS/wizard/credentials" 'ARX_API_KEY=sk-test'
check "the key never reaches the screen" lacks screen.txt 'sk-test'
check "it checked the key" has fake/hdr-03.txt 'Bearer sk-test'

begin "arx setup: Ctrl-C and Esc"
rm agent.yaml
models_for 1 2 3 4 5 6
fresh_config cfg
printf sk-old | "$ARX" setup --provider custom --base-url http://fake.invalid/v1 \
  --key-env ARX_API_KEY --model other-model --key-stdin --no-test >/dev/null 2>&1
cp "$ARX_CONFIG_DIR/config.yaml" before.yaml
cp "$ARX_CONFIG_DIR/credentials" before.cred
setup_pty --stty stty.txt --keys '<wait:Provider><enter><wait:Base URL><enter><wait:API key><down><enter><wait:API key><sleep:0.2>sk-new<enter><wait:Model><c-c>' \
  -- "$ARX" setup --wizard --no-test
check "Ctrl-C at the model step exits 130" exited 130
check "and says nothing changed" has screen.txt 'Cancelled. Nothing changed.'
check "config.yaml is as it was" cmp before.yaml "$ARX_CONFIG_DIR/config.yaml"
check "the saved key is as it was" cmp before.cred "$ARX_CONFIG_DIR/credentials"
check "the terminal is as it was" has stty.txt same
setup_pty --keys '<wait:Provider><enter><wait:Base URL><enter><wait:API key><enter><wait:Model><esc><wait:Keep the saved key><c-c>' \
  -- "$ARX" setup --wizard --no-test
check "Esc at the model step goes back to the key" exited 130

begin "arx setup: the settings menu"
rm agent.yaml
models_for 1 2 3
fresh_config cfg
printf sk-old | "$ARX" setup --provider custom --base-url http://fake.invalid/v1 \
  --key-env ARX_API_KEY --model other-model --key-stdin --no-test >/dev/null 2>&1
cp "$ARX_CONFIG_DIR/config.yaml" before.yaml
setup_pty --keys '<wait:Settings><esc>' -- "$ARX" setup
check "a set-up arx opens the menu" has screen.txt 'Provider and key'
check "Esc quits it" exited 0
check "opening it makes no network call" test "$(cat fake/count)" -eq 2
setup_pty --keys '<wait:Settings><down><enter><wait:Model>test<enter><wait:Settings>q' -- "$ARX" setup
check "Model, pick another, Quit" exited 0
check "the model changed" has "$ARX_CONFIG_DIR/config.yaml" 'model: "test-model"'
check "nothing else did" test "$(diff before.yaml "$ARX_CONFIG_DIR/config.yaml" | grep '^[<>]' |
  grep -vcE '^[<>] (model|context_window|prices):')" -eq 0
setup_pty --keys '<wait:Settings><down><down><down><enter><wait:? Plugins><down><enter><wait:? Add plugins><down><space><enter><wait:Add 1?><enter><wait:Added><wait:Settings><esc>' \
  -- "$ARX" setup
check "Plugins, Add plugins adds a shipped one" test -L "$ARX_CONFIG_DIR/plugins/clock"
setup_pty --keys '<wait:Settings><down><down><down><enter><wait:? Plugins><enter><wait:? Plugins on><space><enter><wait:Settings><esc>' \
  -- "$ARX" setup
check "Plugins, Turn plugins on or off writes disable:" has "$ARX_CONFIG_DIR/config.yaml" 'disable: [clock]'
setup_pty --keys '<wait:Settings><down><down><enter><wait:? Kit><down><down><enter><wait:[y/N]>y<enter><wait:Settings><esc>' \
  -- "$ARX" setup
check "Kit adds a kit and makes it the default" has "$ARX_CONFIG_DIR/config.yaml" 'kit: explorer'
mkdir release && echo v9.9.9 >release/latest
setup_pty --env ARX_UPDATE_DIR="$WS/release" \
  --keys '<wait:Settings><end><up><up><enter><wait:Install arx>n<wait:Settings><esc>' -- "$ARX" setup
check "Update checks for a release and asks first" has screen.txt 'Install arx 9.9.9?'
check "and no changes nothing" exited 0
"$ARX" setup --if-needed </dev/null >needed.txt 2>&1
code=$?
check "--if-needed with a model set says so" has needed.txt 'arx is already set up (model test-model)'
check "and exits 0" exited 0
check "in one line" test "$(wc -l <needed.txt)" -eq 1

begin "arx setup: PATH"
mkdir home
fresh_config cfg
pty --env HOME="$WS/home" --env SHELL=/bin/zsh --keys '<wait:PATH><enter>' -- "$ARX" setup path
check "the PATH step adds a block to ~/.zshrc" has home/.zshrc '# Added by arx setup'
check "naming arx's folder" has home/.zshrc "export PATH=\"$(dirname "$ARX"):\$PATH\""
pty --env HOME="$WS/home" --env SHELL=/bin/zsh --keys '<wait:PATH><enter>' -- "$ARX" setup path
check "a second run adds nothing" test "$(grep -c 'Added by arx setup' home/.zshrc)" -eq 1
HOME=$WS/home SHELL=/bin/bash "$ARX" setup path --add-to-path </dev/null >path.txt 2>&1
check "--add-to-path works without a terminal" has home/.bashrc '# Added by arx setup'
"$ARX" setup path </dev/null >path.txt 2>&1
code=$?
check "without a terminal or the flag, it asks for the flag" has path.txt 'pass --add-to-path'

begin "arx setup: no questions"
rm agent.yaml
models_for 1 2 3 4
fresh_config off
pty --env ARX_UI=off --keys 'sk-test<enter><c-d>' -- "$ARX" setup --provider custom \
  --base-url http://fake.invalid/v1 --key-env ARX_API_KEY --model test-model --key-stdin --no-test
check "ARX_UI=off on a terminal asks nothing" lacks screen.txt '? '
check "and sets up" has "$ARX_CONFIG_DIR/config.yaml" 'model: "test-model"'
fresh_config ci
pty --env CI=1 --env AI_GATEWAY_API_KEY=sk-ci -- "$ARX" setup --no-test
check "CI=1 on a terminal asks nothing" lacks screen.txt '? '
check "and takes the defaults" has "$ARX_CONFIG_DIR/config.yaml" 'ai-gateway.vercel.sh'

summary
