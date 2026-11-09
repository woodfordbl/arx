# setup-menu.sh: the settings menu that `arx setup` opens on a terminal
# once a model is set: provider and key, model, kit, plugins, update and
# doctor. Sourced by commands/arx-setup after setup-save.sh. Opening it
# makes no network call. bash 3.2.

# The dot between parts of a line.
menu_dot() { if ui__utf8; then echo " · "; else echo ", "; fi; }

# Where the key comes from, for the menu (no network call).
menu_key_note() {
  local where
  case "$cur_provider" in chatgpt) echo "ChatGPT sign-in"; return ;; esac
  [ -n "$cur_env" ] || { echo "no key needed"; return; }
  where=$(cd "$tmp" && "$arx" request --auth-source 2>/dev/null)
  case "$where" in
    "the macOS Keychain") echo "key in macOS Keychain" ;;
    "the arx credentials file") echo "key in $(pretty "$config_dir/credentials")" ;;
    "an environment variable") echo "key from \$$cur_env" ;;
    "") echo "no key saved" ;;
    *) echo "key from ${where#the }" ;;
  esac
}

# The header: version, provider, model and kit, and what this folder's
# agent.yaml overrides.
menu_header() {
  local dot over="" k v
  dot=$(menu_dot)
  provider_info "$cur_provider"
  ui__say "arx $("$arx" version 2>/dev/null | awk '{print $2}')$dot$p_label$dot$cur_model${cur_kit:+${dot}kit $cur_kit}"
  ui__say "These are your defaults ($(pretty "$config")); agent.yaml overrides them."
  if [ -f agent.yaml ]; then
    for k in kit enable disable; do
      v=$("$arx" config get "$k" --file agent.yaml 2>/dev/null | tr '\n' ' ')
      [ -z "$v" ] || over="$over${over:+; }$k ${v% }"
    done
    [ -z "$over" ] || ui__say "This folder's agent.yaml overrides: $over"
  fi
  ui__say ""
}

# The menu's items, with the current values as notes.
menu_items() {
  local counts
  provider_info "$cur_provider"
  counts=$(cd "$tmp" && "$arx" check --list 2>/dev/null |
    awk -F'\t' '{ n[$3 == "on"]++ } END { printf "%d on, %d off", n[1], n[0] }')
  printf 'provider\tProvider and key\t%s, %s\n' "$p_label" "$(menu_key_note)"
  printf 'model\tModel\t%s\n' "$cur_model"
  printf 'kit\tKit\t%s\n' "${cur_kit:-none}"
  printf 'plugins\tPlugins\t%s\n' "$counts"
  printf 'update\tUpdate\tarx %s installed\n' "$("$arx" version 2>/dev/null | awk '{print $2}')"
  printf 'doctor\tDoctor\tcheck the install, key and endpoint\n'
  printf 'quit\tQuit\n'
}

# The settings menu. Esc, q or Quit exits 0; Ctrl-C exits 130. Each item
# saves its own change, so Ctrl-C later keeps what was saved.
settings_menu() {
  local last=provider choice code
  menu_header
  while :; do
    choice=$(menu_items | ui_select Settings "$last" --quiet)
    code=$?
    case "$code" in 0) ;; 4) exit 0 ;; *) ui_stop "$code"; exit "$code" ;; esac
    last=$choice
    case "$choice" in
      quit) exit 0 ;;
      update) menu_update ;;
      doctor) "$arx" doctor; ui_pause ;;
      *) run_step "$choice" ;;
    esac
    code=$?
    [ "$code" -ne 130 ] || ui_stop 130
    UI_CANCEL_MSG="Cancelled. What you saved before stays; nothing else changed."
    read_current
  done
}

# Update: check for a release, ask, install it, and restart from the new
# copy (the old files were swapped out by rename).
menu_update() {
  local out code tag
  out=$(ui_spin "Checking for a release" -- "$arx" update --check 2>&1)
  code=$?
  case "$code" in
    0) ui_done Update "${out%.}"; return 0 ;;
    130) return 130 ;;
    10) ;;
    *) ui__say "$out"; return 0 ;;
  esac
  tag=$(sed -n 's/.*; \(.*\) is available.*/\1/p' <<<"$out")
  ui_confirm "Install arx $tag?" yes
  code=$?
  [ "$code" -eq 0 ] || { [ "$code" -ne 130 ] || return 130; return 0; }
  "$arx" update || return 0
  exec "$arx" setup
}

# The installed plugins as items: checked when on in the active list.
installed_items() {
  (cd "$tmp" && "$arx" check --list 2>/dev/null) |
    awk -F'\t' '{ printf "%s\t%s\t%s\t%s\n", $2, $2, $4, ($3 == "on" ? "checked" : "") }'
}

# Plugins: turn on or off, add shipped ones, find more, or remove one.
menu_plugins() {
  local action
  action=$({
    printf 'toggle\tTurn plugins on or off\n'
    printf 'add\tAdd plugins\tthe ones that came with arx\n'
    if "$arx" plugin --help 2>&1 | grep -q 'plugin search'; then
      printf 'find\tFind more plugins\tin the marketplaces\n'
    fi
    printf 'remove\tRemove a plugin\n'
  } | ui_select Plugins toggle) || return
  "plugins_$action"
}

# Turns plugins on or off in your defaults.
plugins_toggle() {
  local items chosen
  items=$(installed_items)
  [ -n "$items" ] || { ui__say "No plugins are installed."; return 0; }
  chosen=$(printf '%s\n' "$items" | ui_multi "Plugins on") || return
  printf '%s\n' "$items" | CHOSEN=$chosen awk -F'\t' '
    BEGIN { n = split(ENVIRON["CHOSEN"], c, "\n"); for (i = 1; i <= n; i++) on[c[i]] = 1 }
    ($1 in on) && $4 != "checked" { print "enable " $1 }
    !($1 in on) && $4 == "checked" { print "disable " $1 }' |
    while read -r verb name; do "$arx" plugin "$verb" "$name" --global; done
}

# Adds the plugins in $1 that you choose, after one confirmation. Each row
# is NAME<TAB>NOTE<TAB>FLAGS<TAB>REF, where REF is a folder (added as a
# link) or a name for `arx plugin add`.
plugins_choose() {
  local rows=$1 chosen count name ref
  [ -n "$rows" ] || { ui__say "There is nothing new to add."; return 0; }
  chosen=$(printf '%s\n' "$rows" | awk -F'\t' '{ printf "%s\t%s\t%s\t%s\n", $1, $1, $2, $3 }' |
    ui_multi "Add plugins") || return
  count=$(grep -c . <<<"$chosen")
  [ "$count" -gt 0 ] || return 0
  ui_confirm "Plugins run with your permissions. Add $count?" yes || return
  for name in $chosen; do
    ref=$(awk -F'\t' -v n="$name" '$1 == n { print $4 }' <<<"$rows")
    if [ -d "$ref" ]; then set -- --link "$ref"; else set -- "${ref:-$name}"; fi
    if ui_spin "Adding $name" -- "$arx" plugin add "$@" --yes >/dev/null; then
      ui_done Added "$name"
    fi
  done
}

# Adds plugins that came with arx (linked, so they follow `arx update`).
plugins_add() {
  local dir rows
  dir=$(shipped_dir plugins) || { ui__say "This arx has no plugins folder."; return 0; }
  rows=$(for d in "$dir"/*/; do
    name=$(basename "$d")
    [ -f "$d/plugin.yaml" ] && [ ! -e "$config_dir/plugins/$name" ] || continue
    info=$("$arx" check --plugin "$d" 2>/dev/null) || continue
    missing=$(sed -n 's/^missing=//p' <<<"$info")
    if [ -n "$missing" ]; then
      printf '%s\tneeds %s\toff\t%s\n' "$name" "$missing" "$dir/$name"
    else
      printf '%s\t%s\t\t%s\n' "$name" "$(sed -n 's/^description=//p' <<<"$info")" "$dir/$name"
    fi
  done)
  plugins_choose "$rows"
}

# Finds plugins in the marketplaces (`arx plugin search --tsv`: name,
# version, kind, installed, description).
plugins_find() {
  local rows
  rows=$(ui_spin "Searching the marketplaces" -- "$arx" plugin search --tsv 2>/dev/null |
    awk -F'\t' '$3 == "plugin" && $4 == "-" {
      printf "%s\t%s\t%s\t%s\n", $1, $5, ($2 == "-" ? "off" : ""), $1 }')
  plugins_choose "$rows"
}

# Removes one plugin, with `arx plugin remove`'s own confirmation.
plugins_remove() {
  local name
  name=$(installed_items | cut -f1-3 | ui_select "Remove a plugin" "") || return
  "$arx" plugin remove "$name"
  return 0
}
