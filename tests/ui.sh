#!/usr/bin/env bash
# ui.sh: tests pick (the menu program in commands/lib) and ui.sh (the shell
# side) on a pseudo-terminal, driven by tests/pty.py. Run with `make test`.
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

summary
