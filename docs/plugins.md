# Extending arx

Everything outside the core is a plugin, and every plugin is an executable in
any language: a shell script, a Python file, a compiled program. arx starts it,
gives it JSON, and reads what it prints. Nothing is linked into the binary.

People write plugins, and so does the agent itself. The agent's own plugins
live next to the spec, and arx reloads them before every model call, so a tool
the agent writes during a turn is available on its next turn. Plugins you
install live in their own folders and load the same way
([Plugin folders](#plugin-folders)).

[`plugins/`](../plugins) is the arx marketplace: one working plugin of each
kind, each in its own folder. [`examples/plugins/`](../examples/plugins) is a
demo harness that uses all of them, and `make test` runs every one.

| Kind | Where it lives | When it runs | In the marketplace |
|---|---|---|---|
| [Tool](#tools) | `tools/<name>` | when the model calls it | `word-count`, `clock` |
| [Subagent](#subagents) | `tools: {name: {agent: spec.yaml}}` | when the model calls it | `reviewer` |
| [Hook](#hooks) | `hooks/<point>` | at fixed points of the loop | `guard`, `git-context`, `fail-hint` |
| [Compactor](#compactors) | `compaction.strategy: <name or path>` | when the prompt passes the trigger | `keep-last` |
| [Observer](#observers) | `observers: [command]` | for the whole session | `notify` |
| [Driver](#drivers) | anywhere: it runs `arx` | whenever you run it | `examples/plugins/drivers/resume_on_cap.sh` |
| [Command](#commands) | `arx-<name>` in a command folder | when you type `arx <name>` | `commands/arx-setup`, `arx-update` |
| [Skill](#skills) | `<skills dir>/<name>/SKILL.md` | read by the agent when needed | `plugin-authoring` |

Paths are relative to the directory of the spec (`--spec`, default
`./agent.yaml`). Check a harness with `arx check` and list its tools with
`arx tools`.

**With no `./agent.yaml`:** arx uses your defaults from `arx setup`, which are
`config.yaml` in `~/.config/arx/`, or `$ARX_CONFIG_DIR` if you set it. When a
project does have an `agent.yaml`, it is merged over your defaults key by key,
and the project wins. Tools, hooks and skills you put in `~/.config/arx/`
work in every harness, below the project's own.

## Plugin folders

A plugin you install is a folder with a `plugin.yaml`, plus any of `tools/`,
`hooks/`, `skills/` and `commands/`, with the same contracts as below:

```
notify/
  plugin.yaml            # required
  tools/  hooks/  skills/  commands/
  observers/notify.sh    # any other files that plugin.yaml names
```

```yaml
name: notify                 # must match the folder name
version: 0.1.0
description: Reports when a session ends.
arx: ">=0.2"                 # optional: the arx versions it works with
requires: [curl]             # optional: programs it needs on PATH
# The rest merges under the spec, and the spec wins.
observers: ['"$ARX_PLUGIN_DIR/observers/notify.sh"']
tools: {word_count: {timeout: 10s}}
compactors: {keep_last: compactors/keep_last.py}   # compaction.strategy: keep_last
hooks: {before_tool: {fail: closed}}               # options for its own hooks
```

Paths in `plugin.yaml` are relative to the plugin folder. arx checks it with
the same validator as the spec; a plugin that is broken, or that needs a newer
arx, is skipped and the agent is told why, so it cannot stop the harness.

**Where arx looks (the layers), in order:**
1. the spec folder: `tools/`, `hooks/` and the `skills:` folder;
2. project plugins: `<spec folder>/plugins/<name>/`;
3. your config folder: `~/.config/arx/tools/`, `hooks/` and `skills/`;
4. user plugins: `~/.config/arx/plugins/<name>/`.

Layers 3 and 4 are skipped when the spec folder is the config folder.

- **Tools:** the first layer with a working tool of a name wins. A tool the
  agent writes in the spec folder always wins over a plugin's, and the agent
  is told about the tool it hides.
- **Hooks:** each layer's hook for a point runs, in layer order. For
  `before_tool`, the first deny stops the call. `session_start` contexts and
  `after_tool` notes are joined. For `stop`, the first decision wins.
- **Skills and observers:** all of them. `{{skills}}` lists every layer's.
- **Commands:** user plugins only (see [Commands](#commands)).
- **On or off:** every installed plugin is on. `plugins: [notify, guard]` in a
  spec names the only ones to use, and `plugins: []` (or `--set plugins=[]`)
  turns them all off. A list also leaves out layer 3, so the harness is
  exactly the spec folder and the plugins it names. Use a list in experiment
  harnesses, so that something a user adds later cannot change a run.

**Installing:** `arx plugin` (or `arx add` for short) manages them:

| Command | What it does |
|---|---|
| `arx plugin add NAME[@REF]` | `plugins/NAME` from the arx repo, at the tag of your arx (or REF) |
| `arx plugin add OWNER/REPO/PATH[@REF]` | a plugin folder in any GitHub repo |
| `arx plugin add ./PATH` | a folder on this machine; `--link` uses it where it is |
| `arx plugin remove NAME` | deletes the plugin folder (only the link, for `--link`) |
| `arx plugin list` | the installed plugins, their versions and sources |
| `arx plugin new NAME` | a new plugin folder with an example tool |

`add` shows what the plugin adds and asks first; `--yes` skips the question,
and without a terminal it is required. `--project` installs into
`./plugins/` next to `./agent.yaml`, for that harness only. A copied plugin
records where it came from in `.arx-source`. `arx check --plugin DIR` checks a
plugin without installing it.

**A marketplace** is any repo with `plugins/<name>/`. This repo is the default
one, and its plugins are not in the arx release: the release is only the
binary and its commands.

**Developing a plugin:** link it, then change it. A linked plugin's changes
work on the agent's next turn, the same as its own files:

```sh
arx plugin new lint                  # or work in ./plugins/<name> in this repo
arx plugin add --link ./lint
arx check                            # lists it under plugins:, with any problems
```

## What every plugin gets

**Working directory:** the directory `arx` runs in (the work), not the spec
directory.

**Environment:** tools, hooks, compactors and observers all get these
variables:

| Variable | Value |
|---|---|
| `ARX_SESSION` | the session id, e.g. `20261030-221403-a1b2` |
| `ARX_SESSION_DIR` | the absolute session folder (`.arx/sessions/<id>`) |
| `ARX_TURN` | the current turn number |
| `ARX_CWD` | the working directory |
| `ARX_SPEC`, `ARX_SPEC_DIR` | the spec file and its directory |
| `ARX_DEPTH` | 0 for the top-level agent, 1 for a subagent, ... |
| `ARX_BIN` | the arx binary, for `"$ARX_BIN" ctl "$ARX_SESSION" note ...` |
| `ARX_PLUGIN_DIR` | the plugin's folder, for the tools, hooks, observers and commands of a plugin |

**Limits:**
- **Process group:** every plugin runs in its own process group.
- **Timeouts:** at its timeout the whole group gets SIGTERM, then SIGKILL 3
  seconds later.
- **Ctrl-C:** stops the running plugin the same way.

## Tools

An executable file in `tools/`; the file name is the tool name (letters,
digits, `_` and `-`).

- **`<tool> --schema`** must print, within 2 seconds:
  ```json
  {"description": "What it does, for the model.",
   "parameters": {"type": "object", "properties": {...}, "required": [...]}}
  ```
  The answer is cached until the file changes.
- **A call** runs `<tool>` with the arguments as JSON on stdin.
- **The result** is stdout and stderr together. A non-zero exit marks it as an
  error, and the model sees `[exit code N]`.
- **Long output:** the model sees the first 2 KB and the last 6 KB, with a
  marker giving the path of the full output (`tool_output` in the spec changes
  these sizes). The full output is saved as
  `.arx/sessions/<id>/tool-NNNN.out`.
- **Options** in the spec: `tools.<name>.timeout` (default 120s) and
  `tools.<name>.enabled: false`.

If a tool is not executable or its `--schema` fails, it is skipped, and the
agent gets a "Tool problems" note saying why. `bash` and `edit` are built in
and can be turned off with `enabled: false`.

## Subagents

A spec entry with `agent:` makes a tool that runs arx again, one level deeper:

```yaml
tools:
  reviewer: {agent: subagents/reviewer.yaml, description: "...", timeout: 30m}
```

- **Arguments:** the model calls it with `{"task": "..."}`. The subagent starts
  with no other context.
- **Result:** the subagent's final answer. If it stopped at a cap, the result
  says so.
- **Its harness:** the subagent uses its own spec, and its own `tools/` and
  `hooks/` next to that spec. The parent's hooks do not apply to it, but your
  user plugins and `~/.config/arx/` do, unless its spec has a `plugins:` list.
- **Limits:** the parent's `--cap` values are passed down. `--cap depth=N`
  (default 4) limits nesting.
- **Events:** the subagent's events appear in the parent's event stream with
  `"depth"` one higher.

## Hooks

An executable at `hooks/<point>`. It gets a JSON object on stdin, with `point`,
`session` and `turn` added, and may print one JSON object.

| Point | When | Extra input | Output it may print |
|---|---|---|---|
| `session_start` | before the first model call | none | `{"context": "..."}`, added to the first message |
| `before_tool` | before each tool call | `{"tool": {"name", "args"}}` | `{"decision": "deny", "reason": "..."}` |
| `after_tool` | after each tool call | `{"tool": {"name"}, "result": {"text", "error"}}` | `{"note": "..."}`, appended to the result |
| `stop` | when the model replies without calling a tool | `{"last_message": "..."}` | `{"decision": "continue", "message": "..."}` or `{"decision": "restart", "message": "..."}` |

- **Printing nothing** means "carry on".
- **`stop` decisions:**
  - `continue` sends `message` to the agent and keeps going. This is how "never
    stop" loops are built.
  - `restart` clears the context first, Ralph-style.
- **Timeout:** `hooks.<point>.timeout` (default 10s). A plugin sets the
  options of its own hooks in its `plugin.yaml`.
- **More than one:** each [layer](#plugin-folders) can have a hook for a
  point, and they all run in layer order.
- **Failures:** a hook that exits non-zero, times out or prints something that
  is not a JSON object is reported as a `hook` event with an `error`, then
  ignored, so a broken hook cannot stop the agent. Set
  `hooks.<point>.fail: closed` to make a failed `before_tool` hook deny the call
  instead.

## Compactors

`compaction.strategy` is `mask` (the default), `summarize`, `hybrid`,
`restart`, a name from `compactors:` (`compactors: {mine: path}` in the spec,
or a plugin's), or a path to an executable.

- **When it runs:** when the prompt passes `compaction.trigger ×
  context_window`.
- **Input (stdin):**
  ```json
  {"messages": [...], "usage": {"prompt_tokens": 91234}, "context_window": 128000}
  ```
- **Output (stdout):** `{"messages": [...]}`, every message with a `role`. Keep
  each tool result together with the assistant message that called it.
- **No change:** returning the messages unchanged means "nothing to compact".
- **Failure:** a non-zero exit, more than 120 seconds, or bad output makes arx
  use `mask` instead and tell the agent why.
- **Message format:** OpenAI Chat Completions. Fields starting with `_` (such
  as `_out`, the path of a tool's full output) are kept by arx and never sent
  to the model.

## Observers

```yaml
observers: ["$ARX_SPEC_DIR/observers/notify.sh", "cat >> all-events.jsonl"]
```

- **How it runs:** each entry is a `sh -c` command that runs for the whole
  session, with the [event stream](#events) on stdin, one JSON object per line.
- **It can't slow the run:** the pipe never blocks arx, so an observer that
  falls behind loses events instead of slowing the agent.
- **At the end:** observers get end of file when the session ends, and up to
  a second each to finish.
- **Without `observers:`:** anything can read `.arx/sessions/<id>/events.jsonl`
  directly, or use `arx watch --json`.

## Drivers

A driver is any program that runs arx. A supervisor, an evaluation loop and a
CI job are all drivers. It uses only the command line:

| Option | Use |
|---|---|
| `-p TASK` or `-p -` (stdin) | run one task until the agent stops |
| `--json` | print `{"session", "status", "exit", "final_output", "turns", "tokens": {"input", "output"}, "cost"}` on stdout |
| `--events fd:N` or `--events PATH` | also write the event stream there |
| `--resume ID` or `--resume last` | continue a session with its history |
| `--cap turns=N`, `tokens=N`, `usd=N`, `wall=8h`, `depth=N` | hard limits that the spec cannot raise |
| `--set key.path=value` | override a spec value for this run |
| `--quiet` | no terminal view |

Exit codes:
- `0` done
- `1` error
- `2` usage or invalid spec
- `3` a cap was reached
- `4` authentication failed
- `130` interrupted

To control a running session, append commands to its inbox:
- `arx ctl ID|last note "TEXT"`: the agent sees the note on its next turn.
- `arx ctl ID|last stop`: it stops after the current turn.

## Commands

`arx <name>` runs the executable `arx-<name>` with the remaining arguments,
the way `git foo` runs `git-foo`. `arx setup`, `init`, `doctor`, `models`,
`sessions` and `update` are commands like this, written as short scripts in
[`commands/`](../commands).

- **Where arx looks, in order:** the first match wins, so a plugin can add a
  command but cannot replace one of arx's own.
  1. `../libexec/arx/` next to the binary (installed copies);
  2. `commands/` next to the binary (a source checkout);
  3. `~/.config/arx/commands/` (yours; `arx update` never touches it);
  4. `~/.config/arx/plugins/<name>/commands/` (user plugins);
  5. your PATH.
- **Environment:** the command gets `ARX_BIN` (the arx binary) and
  `ARX_LIBEXEC` (the folder it was found in), and a plugin's command also gets
  `ARX_PLUGIN_DIR`.
- **Help:** a line `# arx-<name>: one-line summary` near the top makes it show
  up in `arx help`. `arx help <name>` runs `arx-<name> --help`.
- **Endpoint access:** use `"$ARX_BIN" request /models`, or any other path. It
  calls your endpoint with your key without the key passing through your
  script. `"$ARX_BIN" request --auth-source` says where the key came from
  without showing it.

```sh
#!/bin/sh
# arx-hello: says hello
echo "hello $* from $("$ARX_BIN" version)"
```

## Skills

A skill is a folder `<skills dir>/<name>/SKILL.md`, where `skills:` in the spec
names the directory. It starts with front matter:

```markdown
---
name: plugin-authoring
description: How to add a tool, hook or observer to your own harness.
---
```

`{{skills}}` in a prompt lists every skill's name, description and path. The
agent reads the full file only when it needs it.

## Events

Every event is one JSON line:
`{"v":1,"t":"2026-10-30T22:14:03.120Z","session":"...","depth":0,"turn":7,"type":"...", ...}`.
New fields may be added within `v` 1; nothing is renamed or removed without
changing `v`.

| `type` | Fields |
|---|---|
| `session.start` | `name`, `model`, `spec`, `resumed`, `tools` (count) |
| `turn.start` | none |
| `model.delta` | `text` (streamed model text, batched about every 50 ms) |
| `model.message` | `tokens_in`, `tokens_out`, `cost`, `tool_calls` (count) |
| `model.retry` | `attempt`, `status` (HTTP), `curl_exit`, `wait_s`, `error` |
| `tool.start` | `id`, `name`, `preview` |
| `tool.end` | `id`, `name`, `error`, `preview`. Process tools add `exit`, `secs`, `bytes` and `path` |
| `hook` | `point`, `secs`, `plugin` (for a plugin's hook), and either `decision` or `error` |
| `harness.reload` | `ok`, `ms`; then `tools` (count) or `errors` |
| `compact` | `strategy`, `tokens_before`, `tokens_after` |
| `note` | `text` (harness notes, caps reached) |
| `error` | `error` |
| `session.end` | `status`, `turns`, `tokens`, `cost`, `secs`, `final_output` |

## Session files

`.arx/sessions/<id>/`, and `.arx/sessions/last` points at the newest top-level
session:

| File | Contents |
|---|---|
| `transcript.jsonl` | every message; a `{"_reset":true}` line starts the history over (after compaction) |
| `events.jsonl` | the event stream |
| `meta.json` | turns, tokens, cost and status, for `--resume` |
| `tool-NNNN.out` | full tool outputs |
| `inbox` | commands from `arx ctl` |

## Planned, not built yet

These extend the contracts above; see the [roadmap](roadmap.md).

1. **ACP server (`arx acp`):** the Agent Client Protocol over stdio, for
   editors and custom front-ends:
   - `session/new` and `session/load` map to a new session and `--resume`;
   - `session/prompt` runs the turn loop;
   - `session/cancel` is the Ctrl-C path;
   - events become `session/update` messages;
   - `permissions: ask` sends `session/request_permission` before tool calls.
2. **OpenTUI front-end:** a terminal UI plugin that talks to `arx acp`.
3. **MCP client:** MCP servers declared in the spec become tools. Only two
   built-in tools sit in the prompt: `mcp_search` finds a tool, and
   `mcp_select` adds its full schema on the next turn.
4. **More of `arx plugin`:** `update`, `search`, `eject` (copy a plugin into
   the spec folder so the agent owns it), other marketplaces by name
   (`@acme/lint`), and a `setup:` command that runs once after an install.
