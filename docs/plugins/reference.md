# Plugin reference

The exact fields, variables, events, files, commands and exit codes. For what
each kind does, see its page from the [plugin guide](../plugins.md).

## plugin.yaml

Every plugin folder has a `plugin.yaml`. arx checks it with the same
validator as `agent.yaml`, so an unknown key or a wrong type is an error with
a line number. Only these keys are allowed:

| Key | Type | Meaning |
|---|---|---|
| `name` | string | The plugin's name: letters, digits, `_` and `-`. It must match the folder name. |
| `version` | string | The plugin's version, such as `0.1.0`. `arx plugin list` shows it. |
| `description` | string | One line about what it adds. `arx plugin add` shows it. |
| `arx` | string | The arx versions it works with, as `">=0.2.0"`. A release of arx that is older skips the plugin. A build that is not a release accepts any plugin. |
| `requires` | string list | Programs it needs on `PATH`, such as `[python3]`. `arx plugin add` warns when one is missing. arx does not check it when it loads the plugin. |
| `tools` | map | Options for its tools, or subagent tools: `{name: {timeout, enabled, agent, description}}`. See [Tool options](#tool-options). |
| `hooks` | map | Options for its own hooks: `{point: {timeout, fail, band, changes}}`. See [Hook options](#hook-options). |
| `replaces` | string list | Tools it hides on purpose, such as `[bash]`, so `arx check` does not warn about them. |
| `observers` | string list | Shell commands fed the event stream. See [Observers](observers.md). |
| `compactors` | map | Named compaction programs: `{name: path}`. See [Compactors](compactors.md). |

```yaml
name: notify                 # must match the folder name
version: 0.1.0
description: Reports when a session ends.
arx: ">=0.2.0"               # optional
requires: [curl]             # optional
observers: ['"$ARX_PLUGIN_DIR/observers/notify.sh"']
tools: {word_count: {timeout: 10s}}
compactors: {keep_last: compactors/keep_last.py}
hooks: {before_tool: {fail: closed, band: policy, changes: [result]}}
replaces: [bash]
```

**How the keys are used:**

- **Paths** (`tools.<name>.agent`, `compactors`) are relative to the plugin
  folder.
- **`tools` and `compactors`** merge under the spec, key by key. Where the
  spec sets the same value, the spec wins.
- **`observers`** are added to the spec's list, and run with
  `ARX_PLUGIN_DIR` set.
- **`hooks`** apply only to the plugin's own hooks. The spec's `hooks:`
  does not apply to them.
- **Settings** from the active list can change `tools` and `hooks`, and reach
  the plugin's hooks as `ARX_PLUGIN_SETTINGS`. See
  [The active list](kits.md#the-active-list).
- **Not allowed:** `instructions`, `model`, `model_settings` and the other
  spec keys. A plugin cannot change the system prompt or the model today.

### Tool options

| Key | Type | Default | Meaning |
|---|---|---|---|
| `timeout` | duration | `120s` (`30m` for a subagent) | Seconds, or `10s`, `5m`, `1h`. |
| `enabled` | boolean | `true` | `false` hides the tool from the model. |
| `agent` | string | | A spec path: makes this tool a [subagent](subagents.md). |
| `description` | string | | The description the model sees, for a subagent. |

The names under `tools:` use letters, digits, `_` and `-`, up to 64
characters.

### Hook options

| Key | Type | Default | Meaning |
|---|---|---|---|
| `timeout` | duration | `10s` | At the timeout the hook fails. |
| `fail` | string | `open` | `open` ignores a failed hook. `closed` makes a failed `before_tool` hook deny the call. |
| `band` | string | `normal` | `policy`, `normal` or `final`. See [Bands](hooks.md#bands). |
| `changes` | string list | | The fields the hook changes; `arx check` warns when two hooks at one point change the same field. |

The keys under `hooks:` must be hook points: `session_start`,
`before_model`, `after_model`, `before_tool`, `after_tool`, `stop`.

## kit.yaml

| Key | Type | Meaning |
|---|---|---|
| `name` | string | The kit's name: letters, digits, `_` and `-`. It must match the folder name. |
| `version` | string | The kit's version. |
| `description` | string | One line about the agent it makes. |
| `plugins` | plugin list | Its plugins, in order. Required, unless it has `extends`. |
| `model_settings` | map | Extra request fields. |
| `prompt` | string | The system prompt file, relative to the kit folder. |
| `extends` | string | A kit this one starts from (up to 8 deep). |
| `enable` | plugin list | Plugins to add to the kit it extends. |
| `disable` | string list | Plugins to leave out of it. |

A **plugin list** has names (`guard`), references (`acme/tools/lint`,
`guard@v0.2.0`) and entries with settings (`never-stop: {message: "..."}`).
A kit holds no executable files. See [Kits](kits.md).

## Spec keys for plugins

These `agent.yaml` (and `config.yaml`) keys build the
[active list](kits.md#the-active-list):

| Key | Type | Meaning |
|---|---|---|
| `kit` | string | The kit: its plugins, in order, its prompt and its settings. |
| `plugins` | plugin list | The only plugins to use, in order (default: all installed). |
| `enable` | plugin list | Plugins to add to the kit or the list. |
| `disable` | string list | Plugins to leave out. |

### Checking a plugin

`arx check --plugin DIR` checks a plugin folder without loading it. It
prints `key=value` lines, which `arx plugin` reads:

```
name=notify
version=0.1.0
description=Reports when a session ends.
arx=
requires=curl
missing=
tools=
hooks=
skills=
commands=
```

`tools` lists tool files, not schema files (`tools/<name>.json`). `missing`
lists the programs in `requires` that are not on `PATH`. If the
plugin is not valid, it prints the problems on stderr and exits 2. It does
not check that `name` matches the folder name; loading does.

`arx check --kit-dir DIR` does the same for a kit folder, with the keys
`name`, `version`, `description`, `extends`, `plugins`, `enable` and
`disable`.

`arx check` reports the whole harness: a `kit:` line when there is a kit,
then `tools:`, `hooks:`, `plugins:` (in order), `problems:` and `warnings:`.
`arx check --list` prints the active list as tab-separated rows (position,
name, state, why, folder) for scripts; `arx plugin list` shows it as a
table.

## Environment

Tools, hooks, compactors and observers run with these variables:

| Variable | Value |
|---|---|
| `ARX_SESSION` | the session id, such as `20261030-221403-a1b2` |
| `ARX_SESSION_DIR` | the absolute session folder, `.arx/sessions/<id>` |
| `ARX_TURN` | the current turn number |
| `ARX_CWD` | the working directory: the folder `arx` runs in |
| `ARX_SPEC` | the spec file |
| `ARX_SPEC_DIR` | the spec folder |
| `ARX_DEPTH` | `0` for the top-level agent, `1` for a subagent, and so on |
| `ARX_BIN` | the arx binary, for `"$ARX_BIN" ctl "$ARX_SESSION" note ...` |
| `ARX_PLUGIN_DIR` | the absolute plugin folder; only for the tools, hooks, observers and scheduler of a plugin |
| `ARX_PLUGIN_SETTINGS` | the plugin's settings from the active list, as JSON (`{}` when it has none); only for a plugin's hooks |

| Kind | Gets the variables above | Gets `ARX_PLUGIN_DIR` |
|---|---|---|
| Tool (a call) | yes | in a plugin |
| Tool (`--schema`) | no | no |
| Tool (`tools/<name>.json`) | no process runs | — |
| Hook | yes, and `ARX_PLUGIN_SETTINGS` in a plugin | in a plugin |
| Scheduler | yes | in a plugin |
| Compactor | yes | no |
| Observer | yes | in a plugin |
| Command | no; it gets `ARX_BIN` and `ARX_LIBEXEC` | in a user plugin |

**Processes:**

- Tools, hooks, compactors and observers run from the working directory, not
  from their own folder.
- Tools, subagents, hooks and compactors run in their own process group. At
  the timeout, or on Ctrl-C, the whole group gets SIGTERM, then SIGKILL 3
  seconds later.
- For tools, compactors and `--schema`, arx reads stderr together with
  stdout. For hooks, it keeps stderr apart.

## Hook points

| Point | Input | Output it may print |
|---|---|---|
| `session_start` | none | `{"context": "..."}` |
| `before_model` | `{"messages", "tools", "model", "settings", "reason"}` | any of `messages`, `tools`, `model`, `settings` |
| `after_model` | `{"reply", "usage", "finish"}` | `reply` |
| `before_tool` | `{"id", "name", "args"}` | any of `name`, `args`, `result`; or `{"decision": "deny", "reason": "..."}` |
| `after_tool` | `{"call": {"id", "name", "args"}, "result", "is_error"}` | `result`; or `{"note": "..."}` |
| `stop` | `{"last_message": "..."}` | `{"decision": "continue" or "restart", "message": "..."}` |

Every input also has `point`, `session` and `turn`. At the four middle points
the hooks form a chain, and each prints only the fields it changes. See
[Hooks](hooks.md).

## Events

Every event is one JSON line with these fields first:

```json
{"v":1,"t":"2026-10-30T22:14:03.120Z","session":"...","depth":0,"turn":7,"type":"..."}
```

New fields may be added within `v` 1. Nothing is renamed or removed without a
new `v`.

| `type` | Fields |
|---|---|
| `session.start` | `name`, `model`, `spec`, `resumed`, `tools` (a count) |
| `turn.start` | none |
| `model.delta` | `text`: streamed model text, batched about every 50 ms |
| `model.message` | `tokens_in`, `tokens_out`, `cost`, `tool_calls` (a count) |
| `model.retry` | `attempt`, `status` (HTTP), `curl_exit`, `wait_s`, `error` |
| `tool.start` | `id`, `name`, `preview` |
| `tool.end` | `id`, `name`, `error`, `preview`; process tools add `exit`, `secs`, `bytes` and `path` |
| `hook` | `point`, `secs`, `plugin` (for a plugin's hook), `band` (outside `normal`); `changed` (the fields the hook changed), `decision`, `ignored` (a change dropped after a policy result), or `error` |
| `harness.reload` | `ok`, `ms`, and `tools` (a count) or `errors` |
| `compact` | `strategy`, `tokens_before`, `tokens_after` |
| `note` | `text`: harness notes, and caps reached |
| `error` | `error`; also when a scheduler plugin fails |
| `session.end` | `status`, `turns`, `tokens`, `cost`, `secs`, `final_output` |

A subagent's events appear in its parent's stream with a higher `depth`.

## Session files

Each session has a folder `.arx/sessions/<id>/` in the working directory.
`.arx/sessions/last` points at the newest top-level session.

| File | Contents |
|---|---|
| `transcript.jsonl` | every message; a `{"_reset":true}` line starts the history over, after compaction |
| `events.jsonl` | the event stream |
| `meta.json` | turns, tokens, cost and status, for `--resume` |
| `tool-NNNN.out` | the full output of each process tool call |
| `inbox` | commands from `arx ctl` |

With a kit that pins versions, arx also writes `kit.lock` next to the spec.

## arx tool

`arx tool bash|edit` runs a tool of the [shell plugin](tools.md#bash-and-edit)
with the arguments as JSON on stdin. `arx tool NAME --schema` prints its
schema.

| Tool | Arguments | Exit code |
|---|---|---|
| `bash` | `{"command": "..."}`, run with `sh -c` in the working directory, with stdin empty | the command's exit code |
| `edit` | `{"path", "old", "new"}`: replaces `old`, which must occur exactly once; an empty `old` creates a new file | `0`, or `1` when the edit cannot be made |

Arguments that are not valid give exit `1` and a message. A name other than
`bash` or `edit` is a usage error (exit `2`).

## arx plugin

`arx plugin` installs, lists and removes plugin folders. `arx add` is short
for `arx plugin add`.

| Command | What it does |
|---|---|
| `arx plugin add NAME[@REF]` | installs `plugins/NAME` from the arx repo, at the tag of your arx, or at REF (a tag, branch or commit) |
| `arx plugin add OWNER/REPO/PATH[@REF]` | installs a plugin folder from any GitHub repo, at REF or the default branch |
| `arx plugin add ./PATH` | installs a folder on this machine; a path needs a `/` |
| `arx plugin add FILE.tar.gz` | installs from a tarball with one plugin folder in it |
| `arx plugin remove NAME` | deletes the plugin folder; for a link, only the link |
| `arx plugin list` | the plugins in the order a run here uses them, with version, scope, position, state (`on`, `off`, `broken`, `missing`), the reason, and the source |
| `arx plugin enable NAME` | adds it to `enable:` in `./agent.yaml` (`config.yaml` with `--global`), and takes it out of `disable:` |
| `arx plugin disable NAME` | adds it to `disable:` in `./agent.yaml` (`config.yaml` with `--global`) |
| `arx plugin new NAME [DIR]` | makes a plugin folder with a `plugin.yaml` and an example tool, in `plugins/NAME` if `plugins/` exists, else in `NAME` |

| Option | Meaning |
|---|---|
| `--project` | use `./plugins/`, next to `./agent.yaml`: this harness only |
| `--link` | use a local folder where it is, for development |
| `--force` | replace a plugin that is already installed |
| `--yes` | do not ask; required when there is no terminal |
| `--no-enable` | do not add a new plugin to `enable:` when the kit or list here would leave it off |

- **Where it installs:** `~/.config/arx/plugins/<name>/` (a user plugin, on
  in every harness), or `./plugins/<name>/` with `--project`.
- **Checks:** `add` runs `arx check --plugin` first, shows what the plugin
  adds and what it needs, and asks before it changes anything.
- **Source record:** a copied plugin has a `.arx-source` file with its
  source, commit and install time. `list` reads it.
- **A build that is not a release** gets plugins from `main` of the arx
  repo, not from a tag.
- **Kits:** `arx kit add|list|remove` installs kits and their plugins. See
  [Kit commands](kits.md#commands).

| Variable | Use |
|---|---|
| `ARX_PLUGIN_REPO` | the default marketplace, instead of `woodfordbl/arx` |
| `ARX_DOWNLOAD_URL` | where the arx repo downloads from, instead of `https://arx-documentation.vercel.app` |

## Exit codes

| Code | `arx` and `arx -p` | `arx check --plugin`, `--kit-dir` | `arx plugin`, `arx kit` |
|---|---|---|---|
| `0` | done | valid | done |
| `1` | error | | an error, or a question answered no |
| `2` | usage, a spec that is not valid, or a missing or bad kit | not valid | usage |
| `3` | a cap was reached | | |
| `4` | authentication failed | | |
| `130` | interrupted | | |

`arx check` exits 0 when the spec is valid, even when it lists skipped tools
or plugins under `problems:`.
