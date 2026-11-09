# ui.sh: how arx's commands ask you something. On a terminal it draws a
# menu with pick (next to this file); in plain mode it prints numbered
# lists and reads a line; without a terminal it asks nothing, so scripts
# and CI get the flag paths. Every command that asks sources this file, so
# they all behave the same:
#
#   . "${ARX_LIBEXEC:-$(dirname "$0")}/lib/ui.sh"   # arx's own commands
#   . "$ARX_LIB/ui.sh"                              # a plugin's command
#
# The mode is set once, here, into UI_MODE:
#   1. ARX_UI=off, plain or menu wins (plain and menu need /dev/tty).
#   2. Else off when stdin is not a terminal, or CI is set.
#   3. Else menu when pick runs, else plain.
# Questions and menus go to /dev/tty, answers to stdout. A function fails
# with 4 when you go back (Esc) and 130 when you cancel (Ctrl-C); pass the
# code to ui_stop. This file is bash 3.2 (macOS /bin/bash): no associative
# arrays, no mapfile, no ${v,,}, no fractional read -t.

UI_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
UI_PICK=$UI_LIB/pick
UI_NAME=${UI_NAME:-$(basename "$0" | sed 's/^arx-/arx /')}
UI_CANCEL_MSG=""

ui__tty=0
if (exec </dev/tty) 2>/dev/null; then ui__tty=1; fi
case "${ARX_UI:-}" in
  off | plain | menu) UI_MODE=$ARX_UI ;;
  *)
    if [ ! -t 0 ] || [ -n "${CI:-}" ]; then
      UI_MODE=off
    elif [ -x "$UI_PICK" ] && "$UI_PICK" version >/dev/null 2>&1; then
      UI_MODE=menu
    else
      UI_MODE=plain
    fi
    ;;
esac
[ "$ui__tty" -eq 1 ] || UI_MODE=off
[ "$UI_MODE" != menu ] || [ -x "$UI_PICK" ] || UI_MODE=plain

# Ctrl-C and SIGTERM: put the terminal back, say so, exit 130. A command
# that has started saving sets UI_CANCEL_MSG to say what is saved.
ui__stty=""
ui__cancel() {
  trap - INT TERM
  [ -z "$ui__stty" ] || stty "$ui__stty" </dev/tty 2>/dev/null
  echo "${UI_CANCEL_MSG:-Cancelled. Nothing changed.}" >&2
  exit 130
}
if [ "$UI_MODE" != off ]; then
  ui__stty=$(stty -g </dev/tty 2>/dev/null)
  trap ui__cancel INT TERM
fi

# Prints a line on the terminal.
ui__say() { printf '%s\n' "$*" >/dev/tty; }

# Reads a line from the terminal into ui__line; fails on end of file.
ui__read() {
  ui__line=""
  printf '%s' "$1" >/dev/tty
  IFS= read -r ui__line </dev/tty
}

# Says there is no terminal to ask on.
ui__noterm() { echo "$UI_NAME: no terminal to ask on${1:+; pass $1}" >&2; }

# True when the locale is UTF-8, so ✓ is safe to print.
ui__utf8() {
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*) return 0 ;;
  esac
  return 1
}

# Prints items $2 as a numbered list for plain mode; $1 is 1 for multi.
ui__list() {
  awk -F'\t' -v multi="$1" -v total="$(grep -c . <<<"$2")" '
    $1 == "" { next }
    {
      n++; label = $2 == "" ? $1 : $2; mark = ""
      if (multi) mark = ($4 ~ /(^|,)checked(,|$)/) ? "[x] " : "[ ] "
      if ($4 ~ /(^|,)off(,|$)/) label = label " (off)"
      if (n <= 20 || total <= 25)
        printf "  %2d) %s%s%s%s\n", n, mark, label, ($3 == "" ? "" : "   "), $3
    }
    END { if (n > 25) printf "  ... and %d more: type a name\n", n - 20 }
  ' <<<"$2"
}

# The field $2 of item number $1 among the items in $3.
ui__item() { grep . <<<"$3" | sed -n "$1p" | cut -f "$2"; }

# ui_select TITLE DEFAULT [--filter] [--custom]: one item from stdin
# (VALUE<TAB>LABEL<TAB>NOTE<TAB>FLAGS lines); prints its VALUE.
ui_select() {
  local title=$1 def=$2 items code custom=0 n i
  shift 2
  items=$(cat)
  case " $* " in *" --custom "*) custom=1 ;; esac
  if [ "$UI_MODE" = menu ]; then
    printf '%s\n' "$items" | "$UI_PICK" select --title "$title" ${def:+--default "$def"} "$@"
    code=$?
    [ "$code" -eq 3 ] || return "$code"
    UI_MODE=plain
  fi
  if [ "$UI_MODE" = off ]; then
    [ -n "$def" ] && { printf '%s\n' "$def"; return 0; }
    ui__noterm
    return 2
  fi
  n=$(grep -c . <<<"$items")
  ui__say "$title:"
  ui__list 0 "$items" >/dev/tty
  i=$(grep . <<<"$items" | cut -f1 | grep -nxF -- "$def" | head -1 | cut -d: -f1)
  while :; do
    ui__read "Choose 1-$n${i:+ [$i]}: " || return 4
    [ -n "$ui__line" ] || ui__line=$i
    case "$ui__line" in
      "") continue ;;
      *[!0-9]*)
        code=$(grep . <<<"$items" | awk -F'\t' -v a="$ui__line" '$1 == a || $2 == a { print NR; exit }')
        if [ -z "$code" ] && [ "$custom" -eq 1 ]; then printf '%s\n' "$ui__line"; return 0; fi
        ;;
      *) code=$ui__line ;;
    esac
    if [ -z "$code" ] || [ "$code" -lt 1 ] || [ "$code" -gt "$n" ]; then
      ui__say "Type a number from 1 to $n."
    elif ui__item "$code" 4 "$items" | grep -qE '(^|,)off(,|$)'; then
      ui__say "That one is off: $(ui__item "$code" 3 "$items")"
    else
      ui__item "$code" 1 "$items"
      return 0
    fi
  done
}

# ui_multi TITLE: items from stdin, `checked` ones on to start with; prints
# each chosen VALUE on its own line.
ui_multi() {
  local title=$1 items code n k
  items=$(cat)
  if [ "$UI_MODE" = menu ]; then
    printf '%s\n' "$items" | "$UI_PICK" multi --title "$title"
    code=$?
    [ "$code" -eq 3 ] || return "$code"
    UI_MODE=plain
  fi
  if [ "$UI_MODE" = off ]; then
    awk -F'\t' '$4 ~ /(^|,)checked(,|$)/ { print $1 }' <<<"$items"
    return 0
  fi
  n=$(grep -c . <<<"$items")
  ui__say "$title:"
  ui__list 1 "$items" >/dev/tty
  ui__read "Numbers to turn on, with spaces (0 for none, Enter keeps [x]): " || return 4
  if [ -z "$ui__line" ]; then
    awk -F'\t' '$4 ~ /(^|,)checked(,|$)/ { print $1 }' <<<"$items"
    return 0
  fi
  for k in $ui__line; do
    case "$k" in *[!0-9]* | 0) continue ;; esac
    [ "$k" -le "$n" ] || continue
    ui__item "$k" 4 "$items" | grep -qE '(^|,)off(,|$)' || ui__item "$k" 1 "$items"
  done
  return 0
}

# ui_input TITLE DEFAULT [--quiet]: a line of text.
ui_input() {
  local code
  if [ "$UI_MODE" = menu ]; then
    "$UI_PICK" input --title "$1" ${2:+--default "$2"} "${@:3}"
    code=$?
    [ "$code" -eq 3 ] || return "$code"
    UI_MODE=plain
  fi
  if [ "$UI_MODE" = off ]; then printf '%s\n' "$2"; return 0; fi
  ui__read "$1${2:+ [$2]}: " || return 4
  printf '%s\n' "${ui__line:-$2}"
}

# ui_secret TITLE [--quiet]: a line of text that is never shown.
ui_secret() {
  local code
  if [ "$UI_MODE" = menu ]; then
    "$UI_PICK" secret --title "$1" "${@:2}"
    code=$?
    [ "$code" -eq 3 ] || return "$code"
    UI_MODE=plain
  fi
  if [ "$UI_MODE" = off ]; then ui__noterm; return 2; fi
  printf '%s (hidden): ' "$1" >/dev/tty
  IFS= read -r -s ui__line </dev/tty || return 4
  printf '\n' >/dev/tty
  printf '%s\n' "$ui__line"
}

# ui_confirm TITLE yes|no [--quiet]: succeeds for yes. Without a terminal
# it says no; check for --yes first.
ui_confirm() {
  local code
  if [ "$UI_MODE" = menu ]; then
    "$UI_PICK" confirm --title "$1" --default "${2:-no}" "${@:3}"
    code=$?
    [ "$code" -eq 3 ] || return "$code"
    UI_MODE=plain
  fi
  [ "$UI_MODE" != off ] || return 1
  while :; do
    ui__read "$1 $([ "${2:-no}" = yes ] && echo '[Y/n]' || echo '[y/N]') " || return 4
    case "${ui__line:-$2}" in
      y | Y | yes) return 0 ;;
      n | N | no | "") return 1 ;;
    esac
  done
}

# ui_spin TITLE -- COMMAND [ARG...]: runs COMMAND (not a shell function)
# with a spinner on a terminal, stdin from /dev/null, and its stdout
# passed through. Its stderr shows only if it fails.
ui_spin() {
  local title=$1
  shift
  [ "${1:-}" != -- ] || shift
  if [ "$UI_MODE" = menu ]; then
    "$UI_PICK" spin --title "$title" -- "$@"
    return
  fi
  "$@" </dev/null
}

# ui_wait TITLE PID: a spinner until PID exits. Returns at once without a
# menu; `wait PID` for its exit code either way.
ui_wait() {
  [ "$UI_MODE" != menu ] || "$UI_PICK" spin --title "$1" --pid "$2"
}

# ui_done LABEL TEXT: prints "✓ LABEL  TEXT", aligned with pick's answers.
ui_done() {
  [ "$UI_MODE" != off ] || return 0
  local mark=+ green="" bold="" reset=""
  if ui__utf8; then mark=✓; fi
  if [ "$UI_MODE" = menu ] && [ -z "${NO_COLOR:-}" ]; then
    green=$'\033[32m' bold=$'\033[1m' reset=$'\033[0m'
  fi
  printf '%s%s%s %s%-8s%s  %s\n' "$green" "$mark" "$reset" "$bold" "$1" "$reset" "$2" >/dev/tty
}

# ui_pause: waits for a key (Enter in plain mode).
ui_pause() {
  [ "$UI_MODE" != off ] || return 0
  if [ "$UI_MODE" = menu ]; then
    printf 'Press any key to go back.' >/dev/tty
    IFS= read -r -s -n 1 ui__line </dev/tty
    printf '\r\033[K' >/dev/tty
  else
    ui__read "Press Enter to go back. "
  fi
  return 0
}

# ui_need FLAG: exits 2, saying which flag answers the question instead.
ui_need() {
  ui__noterm "$1"
  exit 2
}

# ui_stop CODE: 130 cancels (exit 130), 4 returns 4 (go back), 2 exits 2;
# any other code is returned.
ui_stop() {
  case "$1" in
    130) ui__cancel ;;
    2) exit 2 ;;
    *) return "$1" ;;
  esac
}
