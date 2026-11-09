# Installer and settings menus (slug `installer`)

`arx setup` becomes a menu you drive with the arrow keys: a short wizard the
first time, and a settings menu after that for the provider, key, model,
kits, plugins, updates and doctor. All of it stays outside the core binary.

## Goal

- `curl -fsSL .../install.sh | sh` installs arx and, on a terminal, goes
  straight into the setup wizard. Four questions, a test call, done.
- `arx setup` later opens a settings menu: provider and key, model, kit,
  plugins, update and doctor, each one a menu item.
- Every flag path that works today keeps working, with no prompt, for
  scripts and agents.
- The core `arx` binary gains no code for any of this, and its startup
  does not change.
- It works on macOS and Linux terminals, with `NO_COLOR`, on narrow
  terminals, under `curl | sh`, in CI and over a pipe, and Ctrl-C at any
  point leaves your settings as they were.

Not in this plan: a full-screen UI, the TUI (`acp-tui`), what bare `arx`
does on a terminal (the `ui:` spec key belongs to `acp-tui`), `--json`
output for `arx doctor`, and background update checks.

## Current state

Install and settings already live outside the core. The core is a 221 KB
stripped binary (`ls -la arx`: 221264 bytes) that links only libSystem
(`otool -L arx`), from 8,133 lines of C in `src/`, plus vendored cJSON and
libyaml. The commands are bash scripts in `commands/`.

| Part | Where | What it does today |
|---|---|---|
| Dispatch | `src/main.c:59-71` | A first argument without a leading `-` runs a built-in (`RunBuiltin`), else `arx-<name>` (`RunExternal`). Bare `arx`, `-p` and `--resume` go to `RunAgent` (`src/main.c:31-48`). |
| Command search | `src/cli/external.c:26-55` | `SearchDirs`: `libexec/arx`, `<bin>/commands` (a checkout), `~/.config/arx/commands`, each user plugin's `commands/`, then `PATH`. |
| Command run | `src/cli/external.c:99-117` | Sets `ARX_BIN`, `ARX_LIBEXEC` (the command's own folder) and `ARX_PLUGIN_DIR`, then `execv`. |
| Help listing | `src/cli/external.c:119-181` | Lists every executable `arx-*` in those folders, with the `# arx-<name>: summary` line from its first 512 bytes. |
| Installer | `install.sh:16-27` | Flags `--prefix`, `--version`, `--kit`. |
| | `install.sh:35-45` | Downloads the tarball and `.sha256`, unpacks, runs the bundled `arx-update`. |
| | `install.sh:47-53` | `--kit NAME` runs `arx kit add NAME --default --yes`. |
| | `install.sh:55-59` | Prints a `PATH` hint and `Next: arx setup`. |
| Setup | `commands/arx-setup:11-21` | Flags `--provider`, `--base-url`, `--key-env`, `--model`, `--key-stdin`, `--no-test`. |
| | `commands/arx-setup:47-55` | Interactive when `[ -t 0 ]` and no `--key-stdin`; `ask()` is `read -p` with a default, and returns the default when not interactive. |
| | `commands/arx-setup:57-70` | A numbered provider list (1 to 5). |
| | `commands/arx-setup:89-104` | Writes `config.yaml` (keeps a `.bak`) before the key is checked, and again at `:172`. Ctrl-C between them leaves a half-done config. |
| | `commands/arx-setup:108-151` | Checks the key with `arx request /models`, asks again on 401, saves it in the Keychain or the 0600 `credentials` file. |
| | `commands/arx-setup:155-173` | Lists up to 8 models with `jq`, asks for one, adds `context_window` and `prices`. |
| | `commands/arx-setup:175-189` | Links the shipped `shell` plugin. |
| | `commands/arx-setup:191-198` | A test call capped at $0.02 and 2 turns. |
| Confirmations | `commands/arx-kit:47-57`, `commands/arx-plugin:55-65` | `confirm()`: `[y/N]` with `read -p`. Without a terminal, only `--yes` says yes. |
| Update | `commands/arx-update:59-104` | Checks the tag, downloads, compares the sha256, swaps `bin/arx` and `libexec/arx` with renames. `--check` exits 10. |
| Doctor | `commands/arx-doctor:12-14` | Prints `✓`, `✗` and `!` lines. |
| Build | `Makefile:36` | `SRC := $(wildcard src/*.c src/*/*.c)`: everything under `src/` links into `arx`. |
| | `Makefile:74-101` | `install` and `dist` copy `commands/arx-*`, `plugins/` and `kits/` into `libexec/arx`. |
| Lint | `scripts/lint.sh:16` | Lints `src/` only; no C file over 400 lines. |
| Tests | `tests/cli.sh:83-96` | Setup through flags and `--key-stdin`, with a fake endpoint. |
| | `tests/cli.sh:133-154` | Update from a local release folder (`ARX_UPDATE_DIR`). |
| | `tests/lib.sh:8` | Tests run with `NO_COLOR=1`. |
| Budgets | `tests/bench.sh:4-8` | `arx` at most 400 KB on macOS; `arx version` within 1 ms of `true`. |

### Startup overhead today

The core reads none of this at startup. `FindCommand` and `SearchDirs` run
only from `RunExternal` and `arx help` (`grep -rn FindCommand src` finds
nothing else), and `RunAgent` never reaches them. The only other place that
names `commands/` is `src/harness/describe.c:100`, which runs for
`arx check --plugin` only.

Median of 50 launches on this Mac, minus `/usr/bin/true`:

| Command | Over `true` | Why |
|---|---|---|
| `arx version` | 0.72 ms | the core alone; budget 1.0 ms |
| `arx help` | 2.37 ms | reads every command file for its summary line |
| `arx doctor --help` | 3.37 ms | search, then `execv` of bash |
| `bash -c :` | 0.41 ms | for scale |

**Should anything move out of the core?** No. Each built-in in
`src/cli/commands.c:227-244` either runs inside a session (`tool bash|edit`,
which the shell plugin calls for every tool call), or needs the core's own
spec, auth or session code (`check`, `tools`, `schema`, `request`, `watch`,
`ctl`). Moving `schema` or `watch` to a script saves a few KB of binary and
no startup time, since the loader maps pages on first use. The rule to keep
is the one in place: new user-facing tools go in `commands/`, never in
`src/`.

### What fx gets right

fx installs with `curl -fsSL https://fx.sh/setup.sh | bash`. The script is
197 lines; the menus live inside the 6 MB fx binary. What to take from it,
in arx's own words and code:

| fx does | Why it works | For arx |
|---|---|---|
| One command, no flags needed. | Nothing to read first. | Keep. `install.sh` already works this way. |
| One animated line while it downloads, then one result line. | Quiet, but you can see it is alive. | Copy the quiet output. Use a spinner for the slow steps after the download (key check, model list, plugin installs, update). |
| Interactive only when stdin and stderr are terminals; reads its one question from `/dev/tty`. | Works under `curl \| bash`, where stdin is the script. | Copy: `install.sh` hands setup a stdin of `/dev/tty`. |
| Adds `~/.local/bin` to the right file for zsh, bash or fish, once (it greps first), then erases its question line. | The transcript stays clean, and a rerun adds nothing. | Copy the shell detection, the idempotence and the erased question lines. Do not copy editing the file without asking. |
| `/provider`: provider, then method (browser sign-in or API key), then key source (environment, saved, or paste new). The key is checked before it is saved. | Each screen asks one thing, and the right source is often already there. | Copy the three key sources and check-before-save. |
| Every picker has a direct form: `fx login codex`, `/model QUERY`, `fx provider NAME`. | Scripts and experts skip the menu. | Copy as a rule: every menu answer has a flag. |
| Pickers filter as you type (`/mdl` finds `/model`). | Long lists stay usable. | Copy for the model list, which can hold hundreds of entries. Substring match is enough. |
| Updates download in the background, and the footer says one is ready. | No upgrade step to remember. | Don't copy. The core makes no network calls but model calls. `arx update` stays explicit, and the menu has an Update item. |

## Design

### Where each part lives

```text
bin/arx                       the core; unchanged
libexec/arx/arx-setup         wizard, settings menu, flag paths (bash)
libexec/arx/arx-kit, ...      other commands; a menu when an argument is missing
libexec/arx/lib/ui.sh         shell functions every command sources (bash 3.2)
libexec/arx/lib/pick          the small C program that draws the menus
```

In a checkout the same files sit in `commands/` and `commands/lib/`, and
`make` builds `commands/lib/pick`. `lib/` names don't start with `arx-`, so
`arx help` doesn't list them and `arx lib` is not a command
(`src/cli/external.c:147`).

**Why not `arx-ui`.** An executable `arx-ui` in `libexec/arx` would show up
as `arx ui` in `arx help`, and `ui` is the name `acp-tui` reserves for the
spec key that makes bare `arx` exec a UI. `pick` is a helper, not a command.

### The UI primitive: `pick`

`pick` is a separate C program of about 600 lines in `pick/` (two files,
each under the 400-line lint limit), built by the same `Makefile` with the
same release flags. It links only libc and has no dependencies. Budget: at
most 64 KB on macOS. It draws inline, below the cursor, never on the
alternate screen, so the answers stay in your scrollback.

Why C and not pure bash with `stty`:

- macOS ships bash 3.2. Its `read -t` takes whole seconds, so a script
  cannot tell a lone Esc from the start of an arrow key sequence without a
  one-second stall.
- Redrawing a list from bash forks `tput` or prints by hand, flickers over
  ssh, and needs a `SIGWINCH` trap per script.
- A crash or Ctrl-C in the middle of a bash `stty raw` leaves the terminal
  broken. `pick` restores the terminal on every exit path in one place.
- One binary serves every command and every plugin, so the menus look and
  behave the same everywhere.

Putting the same code in the core (`arx pick`) would cost no startup time
but grows the binary and mixes concerns. `gum` or `fzf` would be a
dependency arx can't assume. Both are rejected.

#### `pick` command line

```text
pick select  [--title T] [--default VALUE] [--filter] [--custom]
             [--height N] [--quiet]
pick multi   [--title T] [--min N] [--height N] [--quiet]
pick input   [--title T] [--default TEXT] [--placeholder TEXT] [--quiet]
pick secret  [--title T] [--quiet]
pick confirm [--title T] [--default yes|no] [--quiet]
pick spin    [--title T] (--pid PID | -- COMMAND [ARG...])
```

- **Items** (`select`, `multi`): read from stdin, one per line, fields
  separated by tabs: `VALUE<TAB>LABEL<TAB>NOTE<TAB>FLAGS`. Only `VALUE` is
  required; `LABEL` defaults to `VALUE`. `FLAGS` is a comma list of
  `checked` (preselected in `multi`) and `off` (shown dimmed, not
  selectable; the note says why). At most 10,000 items and 4 KB per line.
- **Keys**: read from `/dev/tty`, never from stdin. All drawing goes to
  `/dev/tty`. stdout carries only the answer, so `$(pick ...)` works.
- **Answer on stdout**: `select` prints the chosen `VALUE`. `multi` prints
  each chosen `VALUE` on its own line, in list order, or nothing.
  `input` and `secret` print the text. `confirm` prints nothing.
  `spin -- COMMAND` passes the command's stdout through.
- **`--filter`**: typing filters the list (case-insensitive substring of
  `VALUE` and `LABEL`). **`--custom`**: when the filter matches nothing,
  Enter accepts the typed text as the value (for endpoints that list no
  models).
- **`--default`**: the item the cursor starts on, or the text in the box.
- **The answered line**: when you answer, `pick` erases its lines and
  leaves one: `✓ Title  label`. `--quiet` leaves nothing. `secret` leaves
  `✓ Title  (hidden)`.
- **`spin`**: shows `⠋ Title` with the elapsed seconds after 2 s. With
  `-- COMMAND`, it runs the command with stdin from `/dev/null`, passes
  stdout through, buffers stderr (up to 64 KB) and prints it after the
  spinner line clears if the command fails. With `--pid PID`, it polls
  `kill(PID, 0)` every 80 ms, for work a script runs in the background.
  Without a terminal it runs the command with no spinner, so `spin` never
  exits 3.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | answered (`confirm`: yes) |
| 1 | `confirm`: no |
| 2 | usage error |
| 3 | no terminal: `/dev/tty` doesn't open, `TERM` is unset or `dumb`, or the terminal is under 20 columns |
| 4 | Esc: go back one step |
| 130 | Ctrl-C: cancel |
| other | `spin -- COMMAND`: the command's own exit code |

Keys:

| Key | In a list | In a text box |
|---|---|---|
| Up, Down, Ctrl-P, Ctrl-N | move | |
| `k`, `j` | move (not while filtering) | |
| PgUp, PgDn, Home, End | move by a page, to the ends | Home, End: start, end of line |
| Left, Right | | move the cursor |
| Enter | choose (`multi`: done) | done |
| Space | `multi`: turn on or off | a space |
| typing | `--filter`: filter | text |
| Backspace, Ctrl-U, Ctrl-W | edit the filter | delete a character, the line, a word |
| Esc | back (exit 4) | back (exit 4) |
| Ctrl-C | cancel (exit 130) | cancel (exit 130) |
| Ctrl-D | | on an empty box: back |
| Ctrl-Z | suspend; redraws on `fg` | suspend; redraws on `fg` |

#### Terminal handling in `pick`

- **Raw mode**: on the `/dev/tty` descriptor, clear `ICANON`, `ECHO`,
  `ISIG`, `IEXTEN`, `ICRNL` and `IXON`; `VMIN=1`, `VTIME=0`. Output
  processing stays on. With `ISIG` off, Ctrl-C arrives as byte 3 and
  `pick` handles it, so the restore always runs before exit 130.
- **Restore**: the saved `termios` and a visible cursor come back on every
  exit: normal, error, `SIGTERM`, `SIGHUP`, `SIGQUIT` (each handler
  restores, then re-raises with the default action), and Ctrl-Z (restore,
  `SIGTSTP` to itself, raw mode and a redraw on `SIGCONT`). `spin` keeps
  `ISIG` on, so Ctrl-C reaches the child too; `pick` waits for it and
  exits 130.
- **Keys**: arrows as `ESC [ A` and `ESC O A` (application cursor mode, as
  in some tmux and vim setups); Home and End as `ESC [ H`, `ESC [ 1 ~`,
  `ESC O H` and the `F`/`4 ~` forms. After a lone `ESC`, `pick` waits
  50 ms with `poll()` before it calls it Esc. Bracketed paste is on in text
  boxes, so a pasted key arrives as one block, and newlines inside a paste
  are dropped.
- **Width**: `TIOCGWINSZ` on the tty for every frame, then `COLUMNS`, then
  80. No line is ever as wide as the terminal, so the terminal never wraps
  one and the redraw math holds. Labels and notes are cut with `…`, by
  display width (`mbrtowc` and `wcwidth`), never inside a UTF-8 sequence.
  Under 50 columns, notes are hidden. Under 20 columns, `pick` exits 3 and
  the caller falls back to plain prompts.
- **Height**: a list shows at most `--height` rows (default 8), and never
  more than the terminal's rows minus 4. A list that scrolls shows
  `↑ 3 more` and `↓ 12 more` lines.
- **Redraw**: move to the first line of the block (`\r`, then `ESC [ n A`),
  clear to the end of the screen (`ESC [ J`), draw. `SIGWINCH` redraws.
  The cursor is hidden while a list is shown.
- **Color**: one accent color for the cursor row and the title, dim for
  notes and `off` items, green for `✓`, red for errors. With `NO_COLOR` set
  and not empty, `pick` writes no color or style codes at all; the `›`
  marker alone shows the cursor row, and `off` items get `(off)` after the
  label.
- **Glyphs**: `› ● ○ ✓ ⠋` when `nl_langinfo(CODESET)` is UTF-8 (after
  `setlocale(LC_CTYPE, "")`), else `> [x] [ ] + |/-\`.

### `ui.sh`: the shell side

`commands/lib/ui.sh` is the only place that decides how to ask, so every
command behaves the same. It is bash 3.2: no associative arrays, no
`mapfile`, no `${var,,}`, no fractional `read -t`.

```sh
# in a command
. "${ARX_LIBEXEC:-$(dirname "$0")}/lib/ui.sh"
provider=$(ui_select "Provider" "$default" <<EOF
vercel	Vercel AI Gateway	one key for many providers
openrouter	OpenRouter	one key for many providers
EOF
) || ui_stop $?
```

| Function | Does | Off mode |
|---|---|---|
| `ui_select TITLE DEFAULT [--filter] [--custom]` | one item from stdin | prints `DEFAULT`, or fails as `ui_need` would |
| `ui_multi TITLE` | items from stdin, `checked` ones preselected | prints the `checked` values |
| `ui_input TITLE DEFAULT` | a line of text | prints `DEFAULT` |
| `ui_secret TITLE` | a hidden line | fails as `ui_need` would |
| `ui_confirm TITLE yes\|no` | yes or no | returns 1 (no); callers check `--yes` first, as today |
| `ui_spin TITLE -- CMD...` | `CMD` with a spinner | runs `CMD` |
| `ui_wait TITLE PID` | a spinner until `PID` exits | returns at once |
| `ui_done LABEL TEXT` | prints `✓ LABEL  TEXT` | prints nothing |
| `ui_pause` | waits for any key | returns at once |
| `ui_need FLAG` | prints `arx setup: no terminal to ask on; pass FLAG` | the same, exit 2 |
| `ui_stop CODE` | 130: prints `Cancelled. Nothing changed.`, exits 130; 4 returns 4 to the caller (back) | |

The mode is set once, when the file is sourced, into `UI_MODE`:

1. `ARX_UI=off`, `plain` or `menu` wins. `plain` and `menu` still need
   `/dev/tty` to open; if it doesn't, the mode is `off`.
2. Else `off` when stdin is not a terminal (`[ -t 0 ]`, the same test
   commands use today) or `CI` is set and not empty.
3. Else `menu` when `lib/pick` exists and runs; else `plain`.

**Plain mode** is today's experience: numbered lists and `read -p`, with
answers read from `/dev/tty`. It covers `TERM=dumb` (Emacs shell), screen
readers, terminals under 20 columns, and a release built without `pick`.
`pick` exit code 3 drops the rest of the session to plain mode.

**Ctrl-C in bash**: `ui.sh` saves `stty -g` at source time and sets an
`INT` and `TERM` trap that restores it, prints `Cancelled. Nothing
changed.` and exits 130. Commands keep their own `EXIT` traps.

**Plugin commands** can source the same file. They need its path, and
`ARX_LIBEXEC` points at the plugin's own `commands/` folder
(`src/cli/external.c:105`). So `RunExternal` also exports `ARX_LIB`: the
`lib/` folder next to arx's own commands. That is two lines in
`src/cli/external.c` on the command path, not in the agent loop (see Open
decision 7).

### `arx setup`

One command, three ways in. The core never runs it on its own.

| You run | On a terminal | Without one |
|---|---|---|
| `arx setup` with no `config.yaml` model | the wizard | today's flow: defaults, key from `--key-stdin` or the environment |
| `arx setup` with a model set | the settings menu | today's flow (same as above) |
| `arx setup --wizard` | the wizard, even when set up | today's flow |
| `arx setup --if-needed` | the wizard when not set up; else one line, exit 0 | today's flow when not set up; else one line, exit 0 |
| `arx setup STEP` | that step's menu, then exit | that step from its flags |
| any of today's flags | those answers are taken; the wizard asks only the rest | today's flow |

The last row is today's rule (flags pre-answer, a terminal asks the rest),
kept. Without a terminal, every run behaves byte for byte as today: the
same defaults (provider `vercel`), the same messages (`The key works.`,
`Saved the key in ...`, `Wrote .../config.yaml (model ...)`), the same
files and exit codes.

New flags and arguments:

| Flag | Meaning |
|---|---|
| `STEP` | `provider`, `key`, `model`, `kit`, `plugins` or `path`: run one step. `arx setup model --model ID` sets only the model. |
| `--provider chatgpt` | a new provider value: Sign in with ChatGPT (below) |
| `--kit NAME\|none` | the kit step: `none` unsets `kit:` in `config.yaml` |
| `--add-to-path` | the path step: add the bin folder to your shell's startup file |
| `--wizard` | the wizard even when set up |
| `--if-needed` | stop with one line when a model is already set (for `install.sh`) |

#### The wizard (first run)

Each question is one `pick`, and each answer collapses to one line. Esc
goes back a step; Esc on the first step and Ctrl-C cancel. Nothing is saved
until the last question is answered.

```text
Set up arx. Esc goes back, Ctrl-C quits; nothing is saved until the end.
✓ Provider  OpenRouter
✓ API key   from $OPENROUTER_API_KEY, checked
✓ Model     anthropic/claude-sonnet-5.5
✓ Kit       coding
✓ PATH      added to ~/.zshrc
✓ Test      "arx is ready" in 1.2 s

  arx            talk to the agent in this folder
  arx init       start a harness here
  arx setup      change any of this later
```

1. **Provider**. Skipped when `--provider` is given.

   ```text
   ? Provider   ↑↓ move · Enter choose · Esc back
   › Vercel AI Gateway   one key for many providers
     OpenRouter          one key for many providers   found $OPENROUTER_API_KEY
     OpenAI              an OpenAI API key
     ChatGPT plan        sign in with ChatGPT
     Ollama              models on this machine       running
     Other               any OpenAI-compatible URL
   ```

   The cursor starts on the first provider whose key variable is set,
   else Vercel AI Gateway (today's default). Ollama says `running` when
   `http://localhost:11434/v1/models` answers within 300 ms. ChatGPT plan
   is `off`, with the note `needs python3`, when `python3` is missing.
   Other asks for the base URL (`pick input`, default
   `http://localhost:8000/v1`, as today).

2. **API key**. Skipped for Ollama, for ChatGPT, and with `--key-stdin`.
   A `select` of the sources that exist, then the key box when needed:
   - `Keep the saved key` (when `arx request --auth-source` finds one for
     this variable)
   - `Use $OPENROUTER_API_KEY from your environment` (when it is set)
   - `Paste a new key` (`pick secret`)

   The key is checked with `ui_spin "Checking the key" -- arx request
   /models`, as today (`commands/arx-setup:138`). A 401 (exit 4) says so
   and asks again. Any other failure asks `Save it anyway?`.

3. **Model**. Skipped when `--model` is given. `ui_spin "Listing models"`
   fetches `/models` once, then `pick select --filter --custom` shows every
   model with its context and prices in the note
   (`200k · $3 in · $15 out`), the provider's default first. Without `jq`
   or a list, it is a text box with the default.

4. **Kit**. Asked only when `config.yaml` has no `kit:`, so `install.sh
   --kit` isn't asked again. Items: `No kit` (bash and edit only, the
   default), then each shipped and installed kit with its `description`
   from `arx check --kit-dir`.

5. **PATH**. Asked only when the folder of `ARX_BIN` is not on `PATH`.
   `Add it to ~/.zshrc` (the default) or `I'll add it myself`. The file
   comes from `$SHELL`: zsh `~/.zshrc`; bash `~/.bash_profile` on macOS
   when it exists, else `~/.bashrc`; fish
   `~/.config/fish/conf.d/arx.fish`; any other shell gets the printed
   line only. The added block is `# Added by arx setup` and one `export`
   line, and is skipped when the file already names the folder.

6. **Save**. In this order: save the key (Keychain or `credentials`, as
   today), write `config.yaml` to a temporary file and rename it over the
   old one (keeping `config.yaml.bak`), add the kit with `arx kit add NAME
   --default --yes`, add the shell plugin (`commands/arx-setup:175-189`),
   edit the startup file. Each line of the summary appears as its part
   finishes. A failure stops there and names what was already saved.

7. **Test call**. As today, with `ui_spin`, unless `--no-test`.

**ChatGPT plan**: setup runs `arx plugin add chatgpt --yes` (the shipped
copy), writes `endpoint: {base_url: https://api.openai.com/v1, credential:
chatgpt, adapter: responses}`, and, on a terminal, runs `arx chatgpt login`
before the model step. Without a terminal it writes the config and prints
`Run arx chatgpt login to sign in.`

#### The settings menu

`arx setup` on a terminal, once a model is set:

```text
arx 0.2.0 · OpenRouter · anthropic/claude-sonnet-5.5 · kit coding
These are your defaults (~/.config/arx/config.yaml); agent.yaml overrides them.

› Provider and key   OpenRouter, key in macOS Keychain
  Model              anthropic/claude-sonnet-5.5
  Kit                coding
  Plugins            7 on, 2 off
  Update             arx 0.2.0 installed
  Doctor             check the install, key and endpoint
  Quit
```

- **Provider and key**: the provider, key and model steps, then a save.
  The model step starts on the current model when the new list has it.
- **Model**: the model step, then a save.
- **Kit**: the kit list, with the current default kit marked. Choosing one
  runs `arx kit add NAME --default` (its own summary and confirmation, now
  a `pick confirm`); `No kit` runs `arx config unset kit --global`.
- **Plugins**: a `select` of four actions:
  - `Turn plugins on or off`: a `multi` of installed plugins, `checked`
    when on in the active list (`arx check --list`, columns
    `at name state why dir`). Saving runs `arx plugin enable NAME
    --global` or `arx plugin disable NAME --global` for each change.
  - `Add plugins`: a `multi` of shipped plugins that aren't installed
    (`libexec/arx/plugins/*`, read with `arx check --plugin`); a plugin
    whose `missing=` isn't empty is `off` with `needs bun`. Then one
    confirmation and `arx plugin add NAME --yes` for each.
  - `Find more plugins`: `ui_spin` around `arx plugin search` (from
    `arx-plugin`), then the same as `Add plugins`.
  - `Remove a plugin`: a `select`, then `arx plugin remove NAME` with its
    own confirmation.
- **Update**: `ui_spin "Checking for a release" -- arx update --check`.
  Exit 10 asks `Install arx 0.2.1?`, runs `arx update` with a spinner, then
  re-execs `arx setup` from the new `libexec`. Opening the menu makes no
  network call.
- **Doctor**: runs `arx doctor` in place, then `ui_pause`.
- **Quit**, Esc or `q`: exit 0. Ctrl-C: exit 130.

When `./agent.yaml` sets `kit:`, `enable:` or `disable:`, the header adds
one line: `This folder's agent.yaml overrides: kit research`.

### The other commands

- **`arx kit add`** with no `REF`, and **`arx plugin add`**, `remove`,
  `enable` or `disable` with no `NAME`: on a terminal, a `pick` of the
  candidates. Without one: the usage error, exit 2, as today.
- **`confirm()`** in `arx-kit` and `arx-plugin` becomes `ui_confirm`. The
  no-terminal message (`not a terminal, so nothing changed; add --yes to
  go ahead`) and exit 1 stay.
- **`arx update`**: on a terminal, the download runs under `ui_wait`. The
  printed lines, the exit codes (0, 1, 2, 10) and the swap don't change.
- **`arx doctor`**, **`arx models`**, **`arx sessions`**, **`arx config`**
  and **`arx init`**: no change. Their output is read by scripts and tests.

### `install.sh`

It stays a small POSIX sh script, about 75 lines.

```text
sh install.sh [--prefix DIR] [--version vX.Y.Z] [--kit NAME] [--no-setup]
```

1. Download, verify and install as today (`install.sh:29-45`), printing
   `Downloading arx v0.2.0 for darwin-arm64...` first.
2. `--kit NAME`: today's line (`install.sh:47-53`), unchanged.
3. Hand off when all of these hold: no `--no-setup`, `CI` empty, stdout is
   a terminal (`[ -t 1 ]`), and `(exec </dev/tty) 2>/dev/null` succeeds.
   The subshell matters: a failed redirection on a special built-in like
   `:` exits a POSIX shell.

   ```sh
   "$prefix/bin/arx" setup --if-needed </dev/tty ||
     echo "arx is installed. Run \`arx setup\` when you're ready."
   exit 0
   ```

   The install succeeded, so a cancelled setup still exits 0.
4. Otherwise print today's `PATH` hint and `Next: arx setup`
   (`install.sh:55-59`), unchanged.

A reinstall over a set-up arx prints `arx is already set up (model
anthropic/claude-sonnet-5.5). Change it with arx setup.` and exits.

### Environment variables

| Variable | Read by | Effect |
|---|---|---|
| `ARX_UI` | `ui.sh` | `menu`, `plain` or `off`; overrides the terminal test |
| `NO_COLOR` | `pick` | set and not empty: no color or style codes |
| `CI` | `ui.sh`, `install.sh` | set and not empty: never ask, never hand off |
| `TERM` | `pick` | unset or `dumb`: exit 3, so plain mode |
| `COLUMNS`, `LINES` | `pick` | used only when `TIOCGWINSZ` fails |
| `ARX_LIB` | plugin commands | set by `RunExternal`: arx's `lib/` folder |
| `ARX_DISABLE_KEYCHAIN` | `arx-setup` | as today |

### What the core gains

Nothing on the agent path. With Open decision 7 taken, `RunExternal`
exports `ARX_LIB` (two lines), which runs only when a command is
dispatched, after the agent has been ruled out. `bin/arx` stays the only
file the agent needs; `tests/bench.sh` keeps the startup budget.

## Implementation steps

1. **`pick/term.c`, `pick/term.h`**: raw mode, restore and signal
   handlers, key decoder (with the 50 ms Esc wait and bracketed paste),
   width by `wcwidth`, the redraw, glyph and color choice.
2. **`pick/pick.c`**: argument parsing, item reading, the six verbs, exit
   codes.
3. **`Makefile`**: `PICK_SRC := $(wildcard pick/*.c)`; target
   `commands/lib/pick` with `$(REL)` and `$(GC)`, stripped; make
   `all: arx commands/lib/pick` the first target; `test` depends on it;
   `install` and `dist` copy `commands/lib/` to `libexec/arx/lib/`;
   `uninstall` already removes `libexec/arx`; `static` builds both; `format`
   includes `pick/`. **`.gitignore`**: `/commands/lib/pick`.
   **`scripts/lint.sh`**: lint `pick/*.c pick/*.h` with the same rules.
4. **`commands/lib/ui.sh`**: mode choice, the functions, the plain-mode
   fallback, the `INT` trap.
5. **`tests/pty.py`** and **`tests/ui.sh`**: the pty driver and the
   `pick` and `ui.sh` tests (see Tests). Add `tests/ui.sh` to `make test`.
6. **`commands/arx-setup`**: split into step functions (`step_provider`,
   `step_key`, `step_model`, `step_kit`, `step_path`, `save`, `step_test`),
   a wizard loop over them that handles 4 (back) and 130 (cancel), the
   settings menu, `STEP` arguments, `--wizard`, `--if-needed`, `--kit`,
   `--add-to-path` and `--provider chatgpt`. Move the config write to the
   save step. If the file passes 400 lines, move the steps to
   `commands/lib/setup-steps.sh`.
7. **`commands/arx-kit`, `commands/arx-plugin`**: `confirm()` through
   `ui_confirm`; a picker for a missing `REF` or `NAME` on a terminal.
   Land this after the `arx-plugin` changes to the same files.
8. **`commands/arx-update`**: the spinner on a terminal.
9. **`install.sh`**: `--no-setup` and the handoff. Update its header
   comment and usage line.
10. **`src/cli/external.c`**: export `ARX_LIB` in `RunExternal` (Open
    decision 7).
11. **`tests/cli.sh`**, **`tests/bench.sh`**: the new cases and the `pick`
    size budget.
12. **Docs**: the pages listed in Docs to change.

## Tests

`tests/pty.py` (python3, already a dev dependency of `tests/bench.sh`)
starts a command on a new pty with a given size and environment, writes key
bytes with short pauses, and saves the screen bytes, stdout and exit code.
`tests/ui.sh` skips its pty cases, with a message, when python3 is missing.

`tests/ui.sh`, for `pick`:

- `select`: Down, Down, Enter prints the third value; `--default` starts
  on that item; Enter on an `off` item does nothing.
- `select --filter`: typing `son` leaves only matching items;
  `--custom` with no match returns the typed text.
- `multi`: Space on two items and Enter prints both, in list order;
  `checked` items start on.
- `input` and `secret`: the typed text comes back; the secret never
  appears in the screen bytes; a bracketed paste with a trailing newline
  returns the text without it.
- `confirm`: `y`, `n` and Enter with each default.
- Esc exits 4; Esc followed by `[A` within 50 ms is an arrow, not Esc.
- Ctrl-C exits 130 and the pty's `stty -g` matches the value before.
- `SIGTERM` during `select` restores the terminal too.
- `NO_COLOR=1`: no `ESC [` sequence with `m` in the screen bytes.
- A 30-column pty: no drawn line is 30 columns or wider; notes are hidden.
  A 15-column pty: exit 3.
- `TERM=dumb`: exit 3.
- No controlling terminal (`setsid` before exec): `select` exits 3;
  `spin -- true` runs and exits 0.
- `spin -- sh -c 'echo out; echo err >&2; exit 7'`: stdout `out`, `err`
  on stderr, exit 7.
- A list of 200 items in a 10-row pty shows `↓` and scrolls with PgDn.
- `LC_ALL=C`: ASCII glyphs only.

`tests/ui.sh`, for `ui.sh` and `arx setup`:

- `ARX_UI=plain` on a pty: a numbered list, and `2` Enter picks the second.
- `ARX_UI=off` on a pty: `arx setup --provider custom --base-url ...
  --key-env TEST_KEY --model test-model --key-stdin --no-test` asks
  nothing, as without a terminal.
- `CI=1` on a pty: no prompt.
- The wizard on a pty against the fake endpoint (custom URL, pasted key,
  model from the list, no kit, no PATH change, `--no-test`) writes the same
  `config.yaml` as the flag path, apart from the date comment.
- Ctrl-C at the model step: exit 130, `Cancelled. Nothing changed.`, and
  `config.yaml` and `credentials` are byte for byte as before.
- Esc at the model step goes back to the key step.
- The settings menu: Model, pick another, Quit: only `model:` changed.
- `arx setup --if-needed` with a model set prints one line and exits 0.
- The PATH step adds one block to a fake `$HOME/.zshrc`, and a second run
  adds nothing.

`tests/cli.sh`:

- Every existing setup, kit, plugin and update case passes unchanged.
- `arx setup </dev/null` with no flags and no key: exit 2,
  `no key given`, as today.
- `arx kit add </dev/null` and `arx plugin enable </dev/null`: exit 2.
- `install.sh` against a local release (`ARX_DOWNLOAD_URL=file://...`)
  with `</dev/null` and stdout to a file: installs, prints `Next: arx
  setup`, asks nothing. The same with `--no-setup` on a pty.
- With `libexec/arx/lib/` deleted from a test prefix, `arx check` and a
  scripted `arx -p` run pass: the agent never needs the UI files.
- A plugin command sees `ARX_LIB` and can source `ui.sh` from it.

`tests/bench.sh`: `commands/lib/pick` at most 64 KB on macOS and 256 KB on
Linux; the `arx` budgets stay as they are.

## Docs to change

Each page follows `docs/WRITING.md`: lead with the answer, sentence-case
headings, no em dashes, every command runnable as shown. Until the release
ships, new behavior is marked **Planned:**.

- **`docs/getting-started.md`** (tutorial): "Install arx" says the
  installer continues into setup on a terminal and shows the finished
  transcript in a `text` block; `--no-setup` for scripts. "Connect a
  model" shows the wizard, the keys (arrows, Enter, Esc, Ctrl-C) and that
  nothing is saved until the end. A `[!TIP]` for `ARX_UI=plain`.
- **`docs/cli.md`** (reference): the `arx setup` row becomes its own
  section, with the three ways in, `STEP`, every flag (old and new),
  and the rule "flags answer, a terminal asks the rest". New rows in
  "Environment" for `ARX_UI`, `NO_COLOR`, `CI` and `ARX_LIB`. Exit code
  130 for a cancelled command. The `install.sh` flags.
- **`docs/plugins/commands.md`** (guide): a section "Ask a question in a
  command": source `$ARX_LIB/ui.sh`, the function table, and the rule
  that a command must work without a terminal.
- **`docs/architecture.md`** (project): where install and settings live,
  why `pick` is a separate program, and that the agent path never loads
  them.
- **`docs/roadmap.md`** (project): add the item, then remove it when it
  ships.
- **`README.md`**: the install lines and one sentence on `arx setup`.
- **`install.sh`** and **`commands/arx-setup`** header comments and usage
  text.

## Dependencies

| Slug | How |
|---|---|
| `arx-plugin` | Soft. `Find more plugins` uses `arx plugin search`; a tab-separated form (`--tsv`) would save parsing its table. Shipped plugins with `setup:` are copied, not linked, by `arx setup` (its section 6); setup calls `arx plugin add`, which owns that rule. Both plans edit `commands/arx-plugin` and `commands/arx-kit`, so step 7 here lands after it. Both use a non-`arx-` folder in `libexec/arx/` for sourced bash. |
| `plugin-yaml-keys` | Soft. The plugin lists show `description` and the `missing=` line of `arx check --plugin`. New keys need nothing here. |
| `acp-tui` | Coordination, not a blocker. It owns bare `arx` on a terminal and the `ui:` key; this plan claims neither, and names nothing `ui`. The TUI plugin shows up in `Add plugins` (`off` with `needs bun` until bun is installed). Its own settings screen can call `arx setup STEP` with flags. |
| `trust` | None for 0.2.0. A "Policy" menu item could come later. |
| `mcp-client`, `climb`, `sandboxes`, `plugin-state`, `async-calls`, `long-lived-hooks`, `wasm` | None. |

Nothing blocks this item. Steps 1 to 6, 8 and 9 can land first in the
release; step 7 waits for `arx-plugin`.

## Size and risks

**Size: M.** About 600 lines of C, 150 of `ui.sh`, 250 more in
`arx-setup`, 40 in other commands, 20 in `install.sh`, 300 of tests and
the pty driver. No change to the agent.

Risks:

- **Terminal edge cases**: reflow when a terminal shrinks under an inline
  menu, odd `TERM` values, tmux and screen. Lines shorter than the width
  and a redraw on `SIGWINCH` handle most; plain mode and `ARX_UI=plain`
  are the way out for the rest.
- **The changed rerun**: `arx setup` on a terminal, once set up, shows the
  menu instead of asking everything again. Only people at a terminal see
  it; `--wizard` restores the old path.
- **A release without `pick`**: if `dist` or `static` misses it, `ui.sh`
  falls back to plain mode, so setup still works. A `dist` check that the
  tarball holds `libexec/arx/lib/pick` catches it.
- **`curl | sh` reading the terminal** surprises some readers. The handoff
  needs stdout and `/dev/tty` to be terminals and `CI` empty, and
  `--no-setup` turns it off.
- **Partial saves**: the key is saved before `config.yaml` is written. If
  the write fails, setup says the key is saved and the config is not, and
  `arx doctor` shows the state.
- **Self-update from the menu** replaces `libexec/arx` under the running
  script. The swap is by rename, so bash keeps reading the old file; the
  menu re-execs `arx setup` after an update.
- **bash 3.2**: every script must run on macOS's `/bin/bash`. Run
  `tests/ui.sh` on macOS in CI.

## Open decisions

1. **The UI primitive.** A separate C program `pick` in `libexec/arx/lib/`,
   pure bash with `stty`, or a hidden built-in. *Recommended*: `pick`. It
   keeps the core untouched, handles Esc and Ctrl-C correctly on bash 3.2,
   and gives plugins the same menus.
2. **The settings entry point.** `arx setup` (wizard first, menu after),
   or a second command such as `arx settings`. *Recommended*: `arx setup`
   only. One name to remember, and the menu items are the wizard's steps.
   `arx config` stays the low-level key editor.
3. **`install.sh` hands off by default.** *Recommended*: yes on a
   terminal, with `--no-setup`, never when `CI` is set, and
   `--if-needed` so a reinstall doesn't ask again.
4. **Editing shell startup files.** *Recommended*: only after you say yes
   in the PATH step, or with `--add-to-path`. Never without a terminal.
5. **The kit default in the wizard.** *Recommended*: `No kit` (bash and
   edit), the first item, so the install stays bare unless you pick one.
   Coding is the next item.
6. **Sign in with ChatGPT as a provider.** *Recommended*: yes, as
   `--provider chatgpt`, `off` with `needs python3` when python3 is
   missing.
7. **`ARX_LIB` for plugin commands.** *Recommended*: yes. Two lines in
   `RunExternal`, on the command path only, and plugin commands get the
   same menus. Without it, plugins find `ui.sh` through `ARX_BIN`.
8. **What Esc does.** Back one step, or cancel. *Recommended*: back (exit
   4); Esc on the first step cancels.
9. **1Password as a key source** (the `op-key` plugin). *Recommended*: not
   in 0.2.0. `op-key` reads `ARX_OP_REF` from the environment, so setup has
   nowhere to save the reference yet.
10. **Bare `arx` with no model on a terminal** could exec `arx setup`.
    *Recommended*: no. Keep the core's message that says to run
    `arx setup`; the `ui:` key from `acp-tui` is the place for that kind
    of exec.
11. **An update check when the menu opens.** *Recommended*: no. The menu
    makes no network call until you choose Update.
12. **Glyphs.** *Recommended*: Unicode when the locale is UTF-8, ASCII
    otherwise, with no setting to change it.
