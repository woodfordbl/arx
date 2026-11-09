# setup-steps.sh: the steps of `arx setup`, sourced by commands/arx-setup
# after ui.sh. Each step_* asks one thing, or nothing when a flag (or the
# lack of a terminal) answers it, and returns 0 when it asked, 5 when it
# asked nothing, 4 for Esc and 130 for Ctrl-C. Nothing here writes a file
# until save_all; the key check and the model list read a probe spec in
# $tmp, so a cancelled setup leaves config.yaml as it was. bash 3.2.

# Shows a path with ~ for the home folder.
pretty() { case "$1" in "$HOME"/*) echo "~${1#"$HOME"}" ;; *) echo "$1" ;; esac; }

# Prints $1 without a terminal (today's messages), else "✓ $2  $3".
report() { if [ "$UI_MODE" = off ]; then echo "$1"; else ui_done "$2" "$3"; fi; }

# Sets p_url, p_env (the key's variable), p_def (default model), p_label
# and p_note for provider $1.
provider_info() {
  p_def="" p_env=""
  case "$1" in
    vercel) p_url=https://ai-gateway.vercel.sh/v1 p_env=AI_GATEWAY_API_KEY \
      p_def=anthropic/claude-haiku-5.5 p_label="Vercel AI Gateway" p_note="one key for many providers" ;;
    openrouter) p_url=https://openrouter.ai/api/v1 p_env=OPENROUTER_API_KEY \
      p_label=OpenRouter p_note="one key for many providers" ;;
    openai) p_url=https://api.openai.com/v1 p_env=OPENAI_API_KEY p_def=gpt-5-mini \
      p_label=OpenAI p_note="an OpenAI API key" ;;
    chatgpt) p_url=https://api.openai.com/v1 p_label="ChatGPT plan" p_note="sign in with ChatGPT" ;;
    ollama) p_url=http://localhost:11434/v1 p_label=Ollama p_note="models on this machine" ;;
    custom) p_url="" p_env=ARX_API_KEY p_label=Other p_note="any OpenAI-compatible URL" ;;
    *) echo "arx setup: unknown provider $1" >&2; return 2 ;;
  esac
}

# Reads the current defaults: cur_model, cur_url, cur_env, cur_provider,
# cur_kit, and `keep`, the lines that choose plugins (kit:, plugins:,
# enable:, disable:), which a rewrite keeps.
read_current() {
  local p
  cur_model="" cur_url="" cur_env="" cur_provider="" cur_kit="" keep=""
  [ -f "$config" ] || return 0
  cur_model=$("$arx" config get model --global)
  cur_kit=$("$arx" config get kit --global)
  cur_url=$(endpoint_field base_url) cur_env=$(endpoint_field api_key_env)
  cur_provider=custom
  for p in vercel openrouter openai ollama; do
    provider_info "$p" && [ "$cur_url" != "$p_url" ] || cur_provider=$p
  done
  [ "$(endpoint_field credential)" != chatgpt ] || cur_provider=chatgpt
  keep=$(awk '/^(kit|plugins|enable|disable):/ {k = 1; print; next}
    k && /^[ \t-]/ {print; next} {k = 0}' "$config" 2>/dev/null)
}

# The value of endpoint key $1 in config.yaml (flow or block mapping).
endpoint_field() {
  sed -n "s/.*[{ ,]$1: *\"\{0,1\}\([^\",} ]*\).*/\1/p" "$config" | head -1
}

# The endpoint line for the chosen provider.
endpoint_line() {
  if [ "$provider" = chatgpt ]; then
    echo "endpoint: {base_url: \"$base_url\", credential: chatgpt, adapter: responses}"
  elif [ -n "$key_env" ]; then
    echo "endpoint: {base_url: \"$base_url\", api_key_env: $key_env}"
  else
    echo "endpoint: {base_url: \"$base_url\"}"
  fi
}

# Writes the probe: a spec for the chosen endpoint and a config folder
# that holds only the saved keys (and plugins, for ChatGPT's credential).
probe_write() {
  mkdir -p "$tmp/probe/config"
  ln -sf "$config_dir/credentials" "$tmp/probe/config/credentials"
  rm -f "$tmp/probe/config/plugins"
  [ "$provider" != chatgpt ] || ln -s "$config_dir/plugins" "$tmp/probe/config/plugins"
  { echo "model: probe"; endpoint_line; } >"$tmp/probe/agent.yaml"
}

# Runs COMMAND in a subshell with the chosen key in its environment (or
# none, to use the saved one). The key never goes on a command line.
with_key() {
  (
    if [ -n "$key_env" ]; then
      case "$key_how" in
        keep) unset "$key_env" ;;
        new | env | stdin) export "$key_env=$key" ;;
      esac
    fi
    "$@"
  )
}

# The folder that holds the plugins or kits ($1) shipped with arx.
shipped_dir() {
  local d
  for d in "${ARX_LIBEXEC:-$lib/..}" "${ARX_LIBEXEC:-$lib/..}/.."; do
    if [ -d "$d/$1" ]; then (cd "$d/$1" && pwd -P); return 0; fi
  done
  return 1
}

# Adds the shipped plugin $1 as a link, so it follows `arx update`.
add_shipped() {
  local dir
  dir=$(shipped_dir plugins) && [ -f "$dir/$1/plugin.yaml" ] &&
    "$arx" plugin add --link "$dir/$1" --yes
}

# The provider list, with notes on what is already here.
provider_items() {
  local p note flags
  for p in vercel openrouter openai chatgpt ollama custom; do
    provider_info "$p"
    note=$p_note flags=""
    if [ -n "$p_env" ] && [ -n "$(printenv "$p_env")" ]; then note="$note   found \$$p_env"; fi
    if [ "$p" = chatgpt ] && ! command -v python3 >/dev/null; then note="needs python3" flags=off; fi
    if [ "$p" = ollama ] && curl -fsS -m 0.3 -o /dev/null "$p_url/models" 2>/dev/null; then
      note="$note   running"
    fi
    printf '%s\t%s\t%s\t%s\n' "$p" "$p_label" "$note" "$flags"
  done
}

# Step 1: the provider, and the base URL for Other.
step_provider() {
  local def="" p code
  if [ -n "$f_provider" ] || [ "$UI_MODE" = off ]; then
    provider=${f_provider:-vercel}
    provider_info "$provider" || return 2
    base_url=${f_base_url:-$p_url} key_env=${f_key_env:-$p_env}
    [ -z "$base_url" ] || return 5
    base_url=$(ui_input "Base URL (ending in /v1)" "http://localhost:8000/v1") || return
    [ "$UI_MODE" = off ] && return 5 || return 0
  fi
  for p in vercel openrouter openai; do
    provider_info "$p"
    [ -n "$def" ] || [ -z "$(printenv "$p_env")" ] || def=$p
  done
  [ -z "$cur_provider" ] || def=$cur_provider
  while :; do
    provider=$(provider_items | ui_select "Provider" "${def:-vercel}") || return
    def=$provider
    provider_info "$provider"
    base_url=${f_base_url:-$p_url} key_env=${f_key_env:-$p_env}
    [ -z "$base_url" ] || return 0
    [ "$cur_provider" = custom ] && p=$cur_url || p=http://localhost:8000/v1
    base_url=$(ui_input "Base URL" "$p")
    code=$?
    [ "$code" -eq 4 ] || return "$code"
  done
}

# Where a saved key for key_env is, if there is one.
saved_key_where() {
  (
    unset "$key_env" VERCEL_OIDC_TOKEN
    ARX_CONFIG_DIR=$tmp/probe/config "$arx" request --spec "$tmp/probe/agent.yaml" --auth-source 2>/dev/null
  ) | grep -v '^no key found'
}

# Checks the key against the endpoint; returns arx request's exit code.
check_key() {
  with_key ui_spin "Checking the key" -- env ARX_CONFIG_DIR="$tmp/probe/config" \
    "$arx" request --spec "$tmp/probe/agent.yaml" /models >/dev/null 2>&1
}

# Step 2: the key: the saved one, the environment's, or a pasted one, then
# a check. ChatGPT signs in instead; Ollama needs nothing.
step_key() {
  local items n how code where
  probe_write
  if [ "$provider" = chatgpt ]; then chatgpt_signin; return; fi
  [ -n "$key_env" ] || return 5
  if [ "$UI_MODE" = off ] || [ "$key_how" = stdin ]; then
    [ "$key_how" = stdin ] || key=$(printenv "$key_env") key_how=env
    [ -n "$key" ] || { echo "arx setup: no key given" >&2; return 2; }
    check_key
    code=$?
    if [ "$code" -eq 0 ]; then
      [ "$key_how" = stdin ] && how="from stdin" || how="from \$$key_env"
      report "The key works." "API key" "$how, checked"
    else
      echo "arx setup: could not check the key (arx request exited $code); saving it anyway." >&2
    fi
    return 5
  fi
  where=$(saved_key_where)
  items=$([ -z "$where" ] || printf 'keep\tKeep the saved key\tin %s\n' "${where#the }"
    [ -z "$(printenv "$key_env")" ] || printf 'env\tUse $%s from your environment\n' "$key_env"
    printf 'new\tPaste a new key\n')
  n=$(grep -c . <<<"$items")
  while :; do
    how=new
    if [ "$n" -gt 1 ]; then how=$(printf '%s\n' "$items" | ui_select "API key" "" --quiet) || return; fi
    key="" key_how=$how
    [ "$how" != env ] || key=$(printenv "$key_env")
    if [ "$how" = new ]; then
      key=$(ui_secret "API key" --quiet)
      code=$?
      if [ "$code" -eq 4 ] && [ "$n" -gt 1 ]; then continue; fi
      [ "$code" -eq 0 ] || return "$code"
      [ -n "$key" ] || continue
    fi
    check_key
    code=$?
    case "$how" in keep) how="the saved key" ;; env) how="from \$$key_env" ;; *) how=pasted ;; esac
    case "$code" in
      0) ui_done "API key" "$how, checked"; return 0 ;;
      130) return 130 ;;
      4) ui__say "The endpoint rejected that key; try again."; continue ;;
    esac
    ui_confirm "Could not check the key (arx request exited $code). Save it anyway?" yes
    case $? in
      0) ui_done "API key" "$how, not checked"; return 0 ;;
      130) return 130 ;;
    esac
  done
}

# ChatGPT plan: add the shipped chatgpt plugin, then sign in. Without a
# terminal, save_all adds it and says to sign in.
chatgpt_signin() {
  [ "$UI_MODE" != off ] || return 5
  if [ ! -e "$config_dir/plugins/chatgpt" ]; then
    add_shipped chatgpt >/dev/null || { ui__say "Could not add the chatgpt plugin."; return 4; }
    UI_CANCEL_MSG="Cancelled. The chatgpt plugin is added; nothing else changed."
  fi
  if ! "$arx" chatgpt status >/dev/null 2>&1; then
    "$arx" chatgpt login </dev/tty || { ui__say "The ChatGPT sign-in did not finish."; return 4; }
  fi
  ui_done ChatGPT "signed in"
}

# The models in $models as items, the provider's default first, with
# context and prices in the note.
model_items() {
  local sep=", "
  command -v jq >/dev/null || return 0
  if ui__utf8; then sep=" · "; fi
  printf '%s' "$models" | jq -r --arg def "$p_def" --arg sep "$sep" '
    def short: if . >= 1000000 then "\(. / 1000000 | floor)M"
      elif . >= 1000 then "\(. / 1000 | floor)k" else tostring end;
    def usd: (tonumber? // empty) * 1e9 | round / 1000 | "$\(.)";
    [.data[]? | select(.id | type == "string")]
    | (map(select(.id == $def)) + map(select(.id != $def)))[]
    | [.id, .id, ([(.context_window | numbers | short),
        (.pricing.input // empty | usd + " in"),
        (.pricing.output // empty | usd + " out")] | join($sep))]
    | @tsv' 2>/dev/null
}

# Step 3: the model. The list comes from /models once; it also gives the
# context size and prices that save_all writes.
step_model() {
  local first start items
  probe_write
  models=$(with_key ui_spin "Listing models" -- env ARX_CONFIG_DIR="$tmp/probe/config" \
    "$arx" request --spec "$tmp/probe/agent.yaml" /models 2>/dev/null)
  [ "$?" -ne 130 ] || return 130
  if [ -n "$f_model" ]; then model=$f_model; return 5; fi
  first=$(printf '%s' "$models" | jq -r '.data[0].id // empty' 2>/dev/null)
  if [ "$UI_MODE" = off ]; then
    model=${p_def:-$first}
    [ -n "$model" ] || [ "$provider" != chatgpt ] || ui_need --model
    return 5
  fi
  start=${p_def:-$first}
  [ "$provider" != "$cur_provider" ] || start=${cur_model:-$start}
  items=$(model_items)
  model=""
  while [ -z "$model" ]; do
    if [ -n "$items" ]; then
      model=$(printf '%s\n' "$items" | ui_select "Model" "$start" --filter --custom) || return
    else
      model=$(ui_input "Model" "$start") || return
    fi
  done
}

# The kits to choose from: none, then shipped and installed ones.
kit_items() {
  local d name desc seen=" " shipped
  shipped=$(shipped_dir kits) || shipped=/nonexistent
  printf 'none\tNo kit\tbash and edit only\n'
  for d in "$shipped"/*/ "$config_dir"/kits/*/; do
    [ -f "$d/kit.yaml" ] || continue
    name=$(basename "$d")
    case "$seen" in *" $name "*) continue ;; esac
    seen="$seen$name "
    desc=$("$arx" check --kit-dir "$d" 2>/dev/null | sed -n 's/^description=//p')
    [ "$name" != "$cur_kit" ] || desc="(default) $desc"
    printf '%s\t%s\t%s\n' "$name" "$name" "$desc"
  done
}

# Step 4: the kit, asked only when config.yaml has none (so install.sh
# --kit isn't asked again). `none` keeps the install bare.
step_kit() {
  kit=$f_kit
  [ -z "$kit" ] || return 5
  [ "$UI_MODE" != off ] && [ -z "$cur_kit" ] || return 5
  kit=$(kit_items | ui_select "Kit" none) || return
}

# The shell startup file to add PATH to, from $SHELL; empty for others.
startup_file() {
  case "${SHELL##*/}" in
    zsh) echo "${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash)
      if [ "$(uname)" = Darwin ] && [ -f "$HOME/.bash_profile" ]; then
        echo "$HOME/.bash_profile"
      else
        echo "$HOME/.bashrc"
      fi ;;
    fish) echo "${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/arx.fish" ;;
  esac
}

# True when arx's bin folder is on PATH.
on_path() {
  local d IFS=:
  for d in $PATH; do
    if [ -n "$d" ] && [ "$d" -ef "$bindir" ]; then return 0; fi
  done
  return 1
}

# Step 5: PATH, asked only when arx's folder is not on it. Nothing is
# edited without a yes here or --add-to-path.
step_path() {
  local rc
  path_how="" bindir=$(dirname "${ARX_BIN:-/nonexistent/arx}")
  if [ "$add_path" -eq 1 ]; then path_how=add; return 5; fi
  [ "$UI_MODE" != off ] && [ -n "${ARX_BIN:-}" ] || return 5
  ! on_path || return 5
  rc=$(startup_file)
  if [ -z "$rc" ]; then
    ui_done PATH "add $bindir to your PATH"
    return 5
  fi
  ui__say "$(pretty "$bindir") is not on your PATH."
  path_how=$(printf 'add\tAdd it to %s\nskip\tI'\''ll add it myself\n' "$(pretty "$rc")" |
    ui_select PATH add) || return
}
