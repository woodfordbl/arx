# Plugin reference

The plugin reference lists every field, variable, event, file, command and
exit code that arx defines for plugins. For what each kind does and when to
use it, see its guide from [Plugins](../plugins.md).

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
| `observers` | string list | Shell commands that arx feeds the event stream. See [Observers](observers.md). |
| `compactors` | map | Named compaction programs: `{name: path}`. See [Compactors](compactors.md). |
| `credentials` | map | Named credential programs: `{name: path}`. See [Credentials](credentials.md). |
| `adapters` | map | Named adapters: `{name: path}`. See [Adapters](adapters.md). |
| `hosts` | string list | The network hosts its programs connect to, such as `[api.openai.com]`. See [Hosts](#hosts). |
| `instructions` | text list | Text that arx adds to the system prompt, after the spec's prompt: a string, `{file: path}` or a list of them. See [Prompt text and model settings](prompt.md). |
| `model_settings` | map | Request fields, as in the spec. `null` removes a field. They rank below the spec, the kit and `config.yaml`. See [Prompt text and model settings](prompt.md). |
| `mcp_servers` | map | MCP servers it adds, with the keys of the spec's [`mcp_servers`](../spec.md#mcp_servers). A `command` with `/`, and `cwd`, are relative to the plugin folder. See [Servers in a plugin](../mcp.md#servers-in-a-plugin). |

A `plugin.yaml` that uses every key:

```yaml
# plugin.yaml
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
instructions: {file: prompts/instructions.md}
model_settings: {parallel_tool_calls: true}
```

arx uses the keys this way:

- **Paths** (`tools.<name>.agent`, `compactors`, `credentials`,
  `adapters`, `instructions`): relative to the plugin folder. A path in
  `instructions` must also stay inside it.
- **`tools`, `compactors`, `credentials` and `adapters`**: merged under the
  spec, key by key. Where the spec sets the same value, the spec wins.
- **`hosts`**: added to the spec's `hosts`, each host once.
- **`observers`**: added to the spec's list, and run with `ARX_PLUGIN_DIR`
  set.
- **`hooks`**: apply only to the plugin's own hooks. The spec's `hooks:`
  does not apply to them.
- **`instructions`**: added to the system prompt after the spec's prompt and
  one blank line, or where the spec's prompt names
  `{{plugin_instructions}}`, in layer order. The text may use `{{date}}`,
  `{{cwd}}`, `{{session}}`, `{{turn}}` and `{{file:PATH}}`, and no other
  template variable.
- **`model_settings`**: merged under the spec, the kit and `config.yaml`,
  field by field. Among plugins, the first one to set a field wins. It
  cannot set `model`, `messages`, `tools`, `stream` or `stream_options`.
- **Settings**: settings from the active list can change `tools`, `hooks`
  and `model_settings`, which they merge over, and `instructions`, which a
  value replaces and `null` drops. All of them reach the plugin's hooks as
  `ARX_PLUGIN_SETTINGS`. See [The active list](kits.md#the-active-list).
- **Not allowed**: `model`, `endpoint` and the other spec keys. A plugin
  cannot change the model or the endpoint.

### Tool options

| Key | Type | Default | Meaning |
|---|---|---|---|
| `timeout` | duration | `120s` (`30m` for a subagent) | Seconds, or `10s`, `5m`, `1h`. |
| `enabled` | boolean | `true` | `false` hides the tool from the model. |
| `agent` | string | | A spec path. It makes this tool a [subagent](subagents.md). |
| `description` | string | | For a subagent, the description the model sees. |

The names under `tools:` use letters, digits, `_` and `-`, up to 64
characters.

### Hook options

| Key | Type | Default | Meaning |
|---|---|---|---|
| `timeout` | duration | `10s` | At the timeout, the hook fails. |
| `fail` | string | `open` | `open` ignores a failed hook. `closed` stops the hooks after it at that point, and a failed `before_tool` hook then denies the call. Use `closed` for a guard. |
| `band` | string | `normal` | `policy`, `normal` or `final`. See [Bands](hooks.md#bands). |
| `changes` | string list | | The fields the hook changes. `arx check` warns when two hooks at one point change the same field. |

The keys under `hooks:` must be hook points: `session_start`,
`before_model`, `after_model`, `before_tool`, `after_tool`, `stop`.

## kit.yaml

A kit holds no executable files. See [Kits](kits.md).

| Key | Type | Meaning |
|---|---|---|
| `name` | string | The kit's name: letters, digits, `_` and `-`. It must match the folder name. |
| `version` | string | The kit's version. |
| `description` | string | One line about the agent it makes. |
| `plugins` | plugin list | Its plugins, in order. Required, unless it has `extends`. |
| `model_settings` | map | Extra request fields. |
| `prompt` | string | The system prompt file, relative to the kit folder. |
| `extends` | string | A kit this one starts from, up to 8 deep. |
| `enable` | plugin list | Plugins to add to the kit it extends. |
| `disable` | string list | Plugins to leave out of it. |

A plugin list holds names (`guard`), references (`acme/tools/lint`,
`guard@v0.2.0`) and entries with settings (`never-stop: {message: "..."}`).

## Spec keys for plugins

These `agent.yaml` (and `config.yaml`) keys build the
[active list](kits.md#the-active-list):

| Key | Type | Meaning |
|---|---|---|
| `kit` | string | The kit: its plugins, in order, its prompt and its settings. |
| `plugins` | plugin list | The only plugins to use, in order. The default is all installed plugins. |
| `enable` | plugin list | Plugins to add to the kit or the list. |
| `disable` | string list | Plugins to leave out. |

## arx check

`arx check --plugin DIR` checks a plugin folder without loading it. It
prints `key=value` lines, which `arx plugin` reads:

```text
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

- **`tools`**: the tool files, not the schema files (`tools/<name>.json`).
- **`missing`**: the programs in `requires` that are not on `PATH`.
- **A plugin that is not valid**: arx prints the problems on stderr and
  exits 2.
- **The folder name**: not checked here. Loading checks that `name` matches
  it.

Then come `credentials=`, `adapters=` and `hosts=`, the names from
`plugin.yaml`, and two more lines:

```text
instructions=121
model_settings=parallel_tool_calls temperature
```

- **`instructions`**: the size in bytes of the raw text that the plugin adds
  to the prompt, before it renders. Empty when it adds none.
- **`model_settings`**: the top-level fields it sets.

`arx plugin add` shows the hosts as `network`, the text as `prompt` and the
fields as `settings`.

`arx check --kit-dir DIR` does the same for a kit folder, with the keys
`name`, `version`, `description`, `extends`, `plugins`, `enable` and
`disable`.

`arx check` with no option reports the whole harness: a `kit:` line when
there is a kit, `credential:` and `adapter:` lines when the endpoint names
them, then `hosts:`, `tools:`, `hooks:`, `prompt:`, `model_settings:` (when
there are settings), `plugins:` (in order), `problems:` and `warnings:`:

```text
prompt: kit coding; plugins add test-runner (121 bytes)
model_settings: reasoning_effort="medium" (spec), parallel_tool_calls=true (plugin test-runner)
```

- **`prompt:`**: where the base prompt comes from (`agent.yaml`,
  `kit NAME`, `config.yaml`, `--set` or `default`), then the plugins that
  add text, with the size of their raw text.
- **`model_settings:`**: each field as compact JSON, with its source:
  `spec` (the spec, the kit, `config.yaml` or `--set`) or `plugin NAME`.
- **`warnings:`**: two hooks at one point that change the same field, a
  plugin that hides a tool without `replaces:`, two plugins that set one
  model setting to different values, and a plugin that adds more than 4096
  bytes to the prompt. `arx check --list` prints the active list as tab-separated
rows (position, name, state, why, folder) for scripts. `arx plugin list`
shows the same list as a table.

### Hosts

`arx check --hosts` prints the network hosts a run needs, one per line, each
once: the host of `endpoint.base_url`, then the spec's `hosts:`, then the
`hosts:` of each plugin in the active list, in list order. Feed it to an
egress allowlist:

```sh
ALLOW_HOSTS=$(arx check --hosts | tr '\n' ' ')   # e.g. for a proxy config
```

The list covers what the spec and plugins declare. A tool that reaches a
host it does not declare is not on it, so check a new plugin's `hosts:`
before you trust the list.

## Environment

arx sets these variables for tools, hooks, schedulers, compactors and
observers. The second table shows which kind gets which. When a run starts,
arx removes any `ARX_PLUGIN_DIR`, `ARX_PLUGIN_SETTINGS`, `ARX_STATE_DIR` and
`ARX_DATA_DIR` it inherited, so only a plugin's own programs see them.

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
| `ARX_PLUGIN_DIR` | the absolute plugin folder; only for the programs of a plugin |
| `ARX_PLUGIN_SETTINGS` | the plugin's settings from the active list, as JSON (`{}` when it has none); only for a plugin's hooks and scheduler |
| `ARX_STATE_DIR` | `$ARX_SESSION_DIR/plugins/<name>`: the plugin's state for this session; arx doesn't make it. See [Plugin state](concepts.md#plugin-state) |
| `ARX_DATA_DIR` | `<working folder>/.arx/data/<name>`: the plugin's data across sessions; arx doesn't make it |

| Kind | Gets the variables above | Gets `ARX_PLUGIN_DIR` | Gets `ARX_STATE_DIR` | Gets `ARX_DATA_DIR` |
|---|---|---|---|---|
| Tool (a call) | yes | in a plugin | in a plugin | in a plugin |
| Tool (`--schema`) | no | no | no | no |
| Tool (`tools/<name>.json`) | no process runs | no process runs | no process runs | no process runs |
| Hook | yes, and `ARX_PLUGIN_SETTINGS` in a plugin | in a plugin | in a plugin | in a plugin |
| Scheduler | yes, and `ARX_PLUGIN_SETTINGS` in a plugin | in a plugin | in a plugin | in a plugin |
| Compactor | yes | in a plugin | in a plugin | in a plugin |
| Observer | yes | in a plugin | in a plugin | in a plugin |
| Command | no; it gets `ARX_BIN` and `ARX_LIBEXEC` | in a user plugin | no | in a user plugin |
| Credential or adapter | no | no | no | no |

### Processes

- **Working directory**: tools, hooks, compactors and observers run from the
  working directory, not from their own folder.
- **Process groups**: tools, subagents, hooks and compactors run in their
  own process group. At the timeout, or on Ctrl-C, the whole group gets
  SIGTERM, then SIGKILL 3 seconds later.
- **stderr**: for tools, compactors and `--schema`, arx reads stderr
  together with stdout. For hooks, it keeps stderr apart.

## Hook points

| Point | Input | Output it may print |
|---|---|---|
| `session_start` | none | `{"context": "..."}` |
| `before_model` | `{"messages", "tools", "model", "settings", "reason"}`; `settings` is `model_settings` from the spec, the kit, `config.yaml` and plugins, merged | any of `messages`, `tools`, `model`, `settings` |
| `after_model` | `{"reply", "usage", "finish"}` | `reply` |
| `before_tool` | `{"id", "name", "args", "keys"}`, and `server` for a call to an MCP tool | any of `name`, `args`, `keys`, `result`; or `{"decision": "deny", "reason": "..."}` |
| `after_tool` | `{"call": {"id", "name", "args"}, "result", "is_error"}` | `result`, `backoff`; or `{"note": "..."}` |
| `stop` | `{"last_message": "..."}` | `{"decision": "continue" or "restart", "message": "..."}` |

Every input also has `point`, `session` and `turn`. At the four middle points
the hooks form a chain, and each prints only the fields it changes. See
[Hooks](hooks.md).

## Events

Every event is one JSON line with these fields first:

```json
{"v":1,"t":"2026-10-30T22:14:03.120Z","session":"...","depth":0,"turn":7,"type":"..."}
```

arx may add new fields within `v` 1. It renames or removes nothing without a
new `v`.

| `type` | Fields |
|---|---|
| `session.start` | `name`, `model`, `spec`, `resumed`, `tools` (a count), `context_window` (tokens), `cwd` (the working folder) |
| `prompt.start` | `text`: a prompt from you, cut at 64 KB. Sent for the `-p` task, each interactive line and each `--input jsonl` prompt, not for hook messages or harness notes. |
| `turn.start` | none |
| `model.delta` | `text`: streamed model text, batched about every 50 ms |
| `model.message` | `tokens_in`, `tokens_out`, `cost`, `tool_calls` (a count) |
| `model.retry` | `attempt`, `status` (HTTP), `curl_exit`, `wait_s`, `error` |
| `model.credential` | `program`, `reason` (`start`, `expired` or `rejected`), `secs`, and `expires_in` or `error`; never the value |
| `tool.start` | `id`, `name`, `preview`, and `args`: the arguments as the model wrote them, parsed, or the raw string when they are not JSON. Arguments over 16 KB are left out, and `args_cut` is `true`. Sent before the `before_tool` hooks.; `server` for an MCP tool |
| `tool.run` | `id`, `name`: the call's process started. A call that a hook answered or denied has none. |
| `tool.detach` | `id`, `name`, `call` (the short id, such as `"c7"`), `queued` (true when the scheduler holds it): the call moved to the [background](schedulers.md#run-calls-in-the-background) and the model got the placeholder |
| `tool.end` | `id`, `name`, `error`, `preview`, and `output`: the first 2 KB of the result, before the `after_tool` hooks; process tools add `exit`, `secs`, `bytes` and `path`; a background call adds `call` and `detached: true`, and its event can come turns later; `server` for an MCP tool |
| `tool.progress` | `id`, `name`, `server`, `progress`, and `total` and `message` when the server sent them: an MCP server's progress for a call that runs |
| `mcp.server` | `server`, `state` (`start`, `ready`, `exit`, `failed` or `stop`); `era` (`modern` or `legacy`) and `version` once known; `tools` and `secs` for `ready`; `code` for `exit`; `error` for `failed` |
| `hook` | `point`, `secs`, `plugin` (for a plugin's hook), `band` (outside `normal`); `changed` (the fields the hook changed), `decision`, `ignored` (a change dropped after a policy result), or `error` |
| `harness.reload` | `ok`, `ms`, and `tools` (a count) or `errors` |
| `compact` | `strategy`, `tokens_before`, `tokens_after` |
| `note` | `text`: harness notes, and caps reached |
| `error` | `error`; also sent when a scheduler plugin fails |
| `prompt.end` | `status` (`done`, `cap`, `error`, `auth` or `interrupted`), `turns`, `tokens` and `cost` (the session's totals so far), `final_output` (this prompt's answer, cut at 2000 bytes). Sent when a prompt's turns end in interactive and `--input jsonl` runs. A headless run has only `session.end`. |
| `session.end` | `status`, `turns`, `tokens`, `cost`, `secs`, `final_output` |

A subagent's events appear in its parent's stream with a higher `depth`.

The stream holds the whole visible session: your prompts, the model's text,
and each tool call with its arguments and the start of its output. A
front-end can draw or replay a session from `events.jsonl` alone. The cost
is at most 18 KB per tool call.

## Session files

Each session has a folder `.arx/sessions/<id>/` in the working directory.
`.arx/sessions/last` points at the newest top-level session.

| File | Contents |
|---|---|
| `transcript.jsonl` | every message; a `{"_reset":true}` line starts the history over, after compaction |
| `events.jsonl` | the event stream |
| `meta.json` | turns, tokens, cost and status, for `--resume`; `call_seq` and `calls` for background calls |
| `tool-NNNN.out` | the full output of each tool call that ran |
| `tool-NNNN-N.png` | an image or other file that an MCP tool returned, named after the call's output file |
| `mcp/selected.json` | the MCP tools the agent selected, as a list of names |
| `mcp/<server>.log` | an MCP server's stderr, its log messages and the lines it printed that were not JSON-RPC |
| `inbox` | commands from `arx ctl`, and the results of background calls; see [Inbox lines](#inbox-lines) |
| `plugins/<name>/` | a plugin's `ARX_STATE_DIR`, when the plugin made it |

With a kit that pins versions, arx also writes `kit.lock` next to the spec.

arx keeps each MCP server's tool list in `.arx/mcp/<server>.json` in the
working directory, across sessions: the entry's hash, the era, the protocol
version, the server's instructions, the list time, `ttlMs`, and the tools as
the server listed them. A replacement `mcp_search` can read these files.

### Background calls in meta.json

`meta.json` holds two fields for
[background calls](schedulers.md#run-calls-in-the-background):

| Field | Contents |
|---|---|
| `call_seq` | the number of the last short id, so `c7` is never used twice in a session |
| `calls` | the calls whose result the agent has not seen: `[{"call", "id", "name", "preview", "at", "out"}]`. `at` is the unix time the call moved to the background, and `out` is its output file once it runs |

A call leaves `calls` when its note is in the history, not when it ends.
`arx ctl ID cancel` and `--resume` read this list.

### Inbox lines

The `inbox` file has one JSON object per line. arx reads the new lines
before each model call. Writers append whole lines with `O_APPEND`, so
anything that can write a file can steer a run.

| Line | Written by | Effect |
|---|---|---|
| `{"cmd": "note", "text"}` | `arx ctl ID note TEXT` | the agent sees the text as a `[harness]` note |
| `{"cmd": "stop"}` | `arx ctl ID stop` | the run ends after the current turn |
| `{"cmd": "cancel", "call"}` | `arx ctl ID cancel CALL` | arx cancels that background call |
| `{"cmd": "result", "call", "id", "name", "preview", "status", "secs", "text"}` | arx, when a background call ends | the agent sees the result as a paragraph of a `[harness]` note |

In a `result` line, `call` is the short id, `id` is the model's id,
`preview` is the call's arguments cut to 60 bytes, and `status` is `ok`,
`error`, `cancelled` or `stopped`. After `--resume`, arx skips the `note`,
`stop` and `cancel` lines from before the resume. It still delivers the
`result` of each call listed in `calls`.

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

## arx mcp

`arx mcp` lists, searches and calls the MCP servers of the spec without a
session. See [MCP servers](../mcp.md).

| Command | What it does |
|---|---|
| `arx mcp list` | One tab-separated line per server: name, transport, and the cached tools or `not listed`. It starts nothing. |
| `arx mcp list --refresh` | Starts every server and lists its tools again. Exit `1` when one fails. |
| `arx mcp list --json` | The same as a JSON list: `name`, `transport`, `url` or `command`, `tools`, `era`, `version`, `age`. |
| `arx mcp search QUERY [--server S]` | Prints what `mcp_search` prints for the query. |
| `arx mcp call SERVER TOOL` | Makes one call. `TOOL` is the server's own name for it, and the arguments are JSON on stdin. Exit `1` for an error result. |
| `arx mcp http` | The HTTP bridge. arx starts it for each `url` server, with the entry in `ARX_MCP_SERVER`. |

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
| `arx plugin list` | lists the plugins in the order a run here uses them, with version, scope, position, state (`on`, `off`, `broken`, `missing`), the reason, and the source |
| `arx plugin enable NAME` | adds it to `enable:` in `./agent.yaml` (`config.yaml` with `--global`), and takes it out of `disable:` |
| `arx plugin disable NAME` | adds it to `disable:` in `./agent.yaml` (`config.yaml` with `--global`) |
| `arx plugin new NAME [DIR]` | makes a plugin folder with a `plugin.yaml` and an example tool, in `plugins/NAME` if `plugins/` exists, else in `NAME` |

| Option | What it does |
|---|---|
| `--project` | uses `./plugins/`, next to `./agent.yaml`: this harness only |
| `--link` | uses a local folder where it is, for development |
| `--force` | replaces a plugin that is already installed |
| `--yes` | does not ask; required when there is no terminal |
| `--no-enable` | does not add a new plugin to `enable:` when the kit or list here would leave it off |

- **Where it installs**: `~/.config/arx/plugins/<name>/` (a user plugin, on
  in every harness), or `./plugins/<name>/` with `--project`. Use
  `--project` when only this harness should load the plugin. A project
  plugin cannot add [commands](commands.md).
- **Checks**: `add` runs `arx check --plugin` first, shows what the plugin
  adds and what it needs, and asks before it changes anything.
- **Source record**: a copied plugin has a `.arx-source` file with its
  source, commit and install time. `list` reads it.
- **A build that is not a release**: gets plugins from `main` of the arx
  repo, not from a tag.
- **Kits**: `arx kit add|list|remove` installs kits and their plugins. See
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
