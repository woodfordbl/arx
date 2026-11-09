# setup-save.sh: how `arx setup` saves what the steps chose, the test call,
# and `arx setup STEP`. Sourced by commands/arx-setup after setup-steps.sh.
# The save runs in a fixed order (key, config.yaml, kit, shell plugin,
# PATH) and a failure names what is already saved. bash 3.2.

# Saves the key: macOS Keychain, else the 0600 credentials file. Neither
# path puts the key on a command line, so it never shows in a process list.
save_key() {
  if [ "$(uname)" = Darwin ] && [ -z "${ARX_DISABLE_KEYCHAIN:-}" ]; then
    if printf 'add-generic-password -U -s arx -a %s -w "%s"\n' "$key_env" "$1" |
      security -i >/dev/null 2>&1; then
      report "Saved the key in your macOS Keychain (service arx, account $key_env)." \
        Saved "the key in your macOS Keychain"
      return 0
    fi
  fi
  local file=$config_dir/credentials
  mkdir -p "$config_dir" || return 1
  (umask 077 && touch "$file" && {
    grep -v "^$key_env=" "$file"
    echo "$key_env=$1"
  } >"$file.tmp") || return 1
  chmod 600 "$file.tmp" && mv "$file.tmp" "$file" || return 1
  report "Saved the key in $file (readable only by you)." Saved "the key in $(pretty "$file")"
}

# Writes config.yaml through a temporary file and a rename, keeping the
# old one as config.yaml.bak. $1 is the model, $2 extra lines.
write_config() {
  local new=$config.arx-setup.$$
  mkdir -p "$config_dir" || return 1
  {
    echo "# Written by \`arx setup\` on $(date +%Y-%m-%d). A project's agent.yaml"
    echo "# overrides any key here; rerun \`arx setup\` to change them."
    echo "model: \"$1\""
    endpoint_line
    if [ -n "${2:-}" ]; then echo "$2"; fi
    if [ -n "$keep" ]; then echo "$keep"; fi
  } >"$new" || { rm -f "$new"; return 1; }
  if [ -f "$config" ]; then cp "$config" "$config.bak" || return 1; fi
  mv "$new" "$config"
}

# The context_window and prices lines for $model, from the model list.
model_extra() {
  printf '%s' "$models" | jq -r --arg m "$model" '
    def per_million: tonumber * 1e9 | round / 1000;
    .data[]? | select(.id == $m) |
    [ (if .context_window then "context_window: \(.context_window)" else empty end),
      (if .pricing.input then "prices: {input: \(.pricing.input | per_million), output: \(.pricing.output | per_million)}" else empty end)
    ] | join("\n")' 2>/dev/null
}

# Stops after a failed save, naming what is saved already.
save_failed() {
  echo "arx setup: $1${saved:+; already saved: $saved}" >&2
  exit 1
}

# Saves the key and config.yaml; `all` also the kit, the shell plugin and
# PATH. Ctrl-C from here on says what is saved.
save_all() {
  saved=""
  UI_CANCEL_MSG="Stopped. Nothing is saved yet."
  if [ -n "$key_env" ] && [ -n "$key" ]; then
    save_key "$key" || save_failed "could not save the key"
    saved="the key"
    UI_CANCEL_MSG="Stopped. The key is saved; config.yaml is not changed."
  fi
  write_config "$model" "$(model_extra)" || save_failed "could not write $config"
  report "Wrote $config (model $model)." Saved "$(pretty "$config") (model $model)"
  saved="${saved:+$saved and }config.yaml"
  UI_CANCEL_MSG="Stopped. Your settings are saved."
  if [ "$provider" = chatgpt ]; then save_chatgpt; fi
  [ "${1:-all}" = all ] || return 0
  if [ -n "$kit" ]; then set_kit "$kit" || save_failed "could not set the kit $kit"; fi
  save_shell_plugin
  save_path
}

# ChatGPT plan without a terminal: add the plugin and say to sign in.
save_chatgpt() {
  [ -e "$config_dir/plugins/chatgpt" ] || add_shipped chatgpt >/dev/null ||
    save_failed "could not add the chatgpt plugin"
  "$arx" chatgpt status >/dev/null 2>&1 || echo "Run \`arx chatgpt login\` to sign in."
}

# Makes $1 the default kit (adding it first if needed), or none.
set_kit() {
  [ "$1" != "${cur_kit:-none}" ] || return 0
  if [ "$1" = none ]; then
    "$arx" config unset kit --global || return 1
    report "There is no default kit now." Kit "none"
  elif [ -e "$config_dir/kits/$1" ]; then
    "$arx" config set kit "$1" --global || return 1
    report "Your default kit is $1." Kit "$1, your default"
  elif [ "$UI_MODE" = off ]; then
    "$arx" kit add "$1" --default --yes
  else
    ui_spin "Adding the kit $1" -- "$arx" kit add "$1" --default --yes >/dev/null || return 1
    ui_done Kit "$1, your default"
  fi
}

# arx has no tools of its own: bash and edit come from the shell plugin,
# which ships next to these commands. A link keeps it at the version of arx
# after `arx update`. Without a copy here, it comes from the arx repo.
save_shell_plugin() {
  local ref=shell link="" dir
  [ ! -e "$config_dir/plugins/shell" ] && [ ! -L "$config_dir/plugins/shell" ] || return 0
  if dir=$(shipped_dir plugins) && [ -f "$dir/shell/plugin.yaml" ]; then ref=$dir/shell link=--link; fi
  if "$arx" plugin add $link "$ref" --yes >/dev/null; then
    report "Turned on the shell plugin: the agent's bash and edit tools." Tools "bash and edit (the shell plugin)"
  else
    echo "arx setup: could not add the shell plugin, so the agent has no tools; try \`arx plugin add shell\`." >&2
  fi
}

# Adds arx's folder to PATH in the startup file, once.
save_path() {
  local rc line
  [ "$path_how" = add ] || return 0
  rc=$(startup_file)
  if [ -z "$rc" ]; then
    echo "Add $bindir to your PATH: export PATH=\"$bindir:\$PATH\""
  elif grep -qF "$bindir" "$rc" 2>/dev/null; then
    report "$(pretty "$rc") already adds $bindir to PATH." PATH "already in $(pretty "$rc")"
  else
    line="export PATH=\"$bindir:\$PATH\""
    [ "${rc%.fish}" = "$rc" ] || line="set -gx PATH \"$bindir\" \$PATH"
    mkdir -p "$(dirname "$rc")" && printf '\n# Added by arx setup\n%s\n' "$line" >>"$rc" ||
      save_failed "could not write $rc"
    report "Added $bindir to PATH in $(pretty "$rc"); open a new terminal to use it." \
      PATH "added to $(pretty "$rc")"
  fi
}

# The test call: one cheap task, capped at $0.02 and 2 turns.
step_test() {
  local reply code start=$SECONDS
  [ "$run_test" -eq 1 ] || return 0
  mkdir -p "$tmp/test"
  [ "$UI_MODE" != off ] || echo "Test call..."
  reply=$(cd "$tmp/test" && ui_spin "Test call" -- "$arx" -p "Reply with exactly: arx is ready" \
    --quiet --cap usd=0.02 --cap turns=2 2>&1)
  code=$?
  if [ "$UI_MODE" = off ]; then
    if [ "$code" -eq 0 ]; then echo "  $reply"; else echo "  The test call failed (exit $code): $reply"; fi
  elif [ "$code" -eq 0 ]; then
    ui_done Test "\"$reply\" in $((SECONDS - start)) s"
  else
    [ "$code" -ne 130 ] || ui_stop 130
    echo "The test call failed (exit $code): $reply" >&2
  fi
}

# Loads the current endpoint, for steps that change part of it.
use_current() {
  [ -n "$cur_model" ] || { echo "arx setup: arx is not set up yet; run \`arx setup\` first" >&2; exit 1; }
  provider=$cur_provider base_url=$cur_url key_env=$cur_env model=$cur_model
  provider_info "$provider"
}

# Sets the model, its context size and prices, and nothing else.
save_model() {
  local line key value
  "$arx" config set model "\"$model\"" --global || save_failed "could not write $config"
  for key in context_window prices; do
    line=$(model_extra | grep "^$key: ")
    value=${line#"$key: "}
    if [ -n "$line" ]; then
      "$arx" config set "$key" "$value" --global
    else
      "$arx" config unset "$key" --global
    fi
  done
  report "Set the default model to $model." Saved "model $model in $(pretty "$config")"
}

# `arx setup STEP` and the menu's items: one step, then its save.
run_step() {
  local code
  case "$1" in
    provider)
      [ "$UI_MODE" != off ] || [ -n "$f_provider" ] || ui_need --provider
      run_steps provider key model || return 4
      save_all core ;;
    key)
      use_current
      [ -n "$key_env" ] || { echo "$p_label needs no API key."; return 0; }
      [ "$UI_MODE" != off ] || [ "$key_how" = stdin ] || [ -n "$(printenv "$key_env")" ] ||
        ui_need --key-stdin
      step_key
      code=$?
      case "$code" in 0 | 5) ;; *) return "$code" ;; esac
      saved=""
      if [ -n "$key" ]; then save_key "$key" || save_failed "could not save the key"; fi ;;
    model)
      use_current
      [ "$UI_MODE" != off ] || [ -n "$f_model" ] || ui_need --model
      key_how=""  # the usual lookup: the environment, then the saved key
      step_model
      code=$?
      case "$code" in 0 | 5) save_model ;; *) return "$code" ;; esac ;;
    kit)
      kit=$f_kit
      [ "$UI_MODE" != off ] || [ -n "$kit" ] || ui_need --kit
      if [ -z "$kit" ]; then kit=$(kit_items | ui_select Kit "${cur_kit:-none}") || return; fi
      # A new kit from the menu shows its plugins and asks, as `arx kit add`.
      if [ "$kit" != none ] && [ "$UI_MODE" != off ] && [ ! -e "$config_dir/kits/$kit" ]; then
        "$arx" kit add "$kit" --default
        return 0
      fi
      set_kit "$kit" || save_failed "could not set the kit $kit" ;;
    plugins)
      if [ "$UI_MODE" = off ]; then
        echo "arx setup: no terminal to ask on; use \`arx plugin\` to add, remove, enable or disable plugins" >&2
        return 2
      fi
      menu_plugins ;;
    path)
      [ "$UI_MODE" != off ] || [ "$add_path" -eq 1 ] || ui_need --add-to-path
      step_path
      code=$?
      case "$code" in 0 | 5) ;; *) return "$code" ;; esac
      [ -n "$path_how" ] || ! on_path || report "$bindir is on your PATH." PATH "already set"
      save_path ;;
  esac
}
