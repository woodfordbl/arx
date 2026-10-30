# Extending arx

Everything outside the core is a plugin, and every plugin is an executable in
any language: a shell script, a Python file, a compiled program. arx starts it,
gives it JSON, and reads what it prints. Nothing is linked into the binary.

People write plugins, and so does the agent itself. Plugins live next to the
spec, and arx reloads them before every model call, so a tool the agent writes
during a turn is available on its next turn.

[`examples/plugins/`](../examples/plugins) has one working example of each
kind, wired together in one spec, and `make test` runs every one of them.

| Kind | Where it lives | When it runs | Example |
|---|---|---|---|
| [Tool](#tools) | `tools/<name>` | when the model calls it | `tools/word_count`, `tools/now` |
| [Subagent](#subagents) | `tools: {name: {agent: spec.yaml}}` | when the model calls it | `subagents/reviewer.yaml` |
| [Hook](#hooks) | `hooks/<point>` | at fixed points of the loop | `hooks/before_tool`, `after_tool`, `stop`, `session_start` |
| [Compactor](#compactors) | `compaction.strategy: <path>` | when the prompt passes the trigger | `compactors/keep_last.py` |
| [Observer](#observers) | `observers: [command]` | for the whole session | `observers/notify.sh` |
| [Driver](#drivers) | anywhere: it runs `arx` | whenever you run it | `drivers/resume_on_cap.sh` |
| [Skill](#skills) | `<skills dir>/<name>/SKILL.md` | read by the agent when needed | `skills/plugin-authoring` |

Paths are relative to the directory of the spec (`--spec`, default
`./agent.yaml`). Check a harness with `arx check` and list its tools with
`arx tools`.

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
  `hooks/` next to that spec. The parent's hooks do not apply to it.
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
- **Timeout:** `hooks.<point>.timeout` (default 10s).
- **Failures:** a hook that exits non-zero, times out or prints something that
  is not a JSON object is reported as a `hook` event with an `error`, then
  ignored, so a broken hook cannot stop the agent. Set
  `hooks.<point>.fail: closed` to make a failed `before_tool` hook deny the call
  instead.

## Compactors

`compaction.strategy` is `mask` (the default), `summarize`, `hybrid`,
`restart`, or a path to an executable.

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
| `hook` | `point`, `secs`, and either `decision` or `error` |
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

These extend the contracts above; see the roadmap in the README.

1. **External commands:** `arx foo` runs `arx-foo` from PATH or
   `~/.arx/plugins/*/bin`, git-style, so front-ends and drivers install like
   any command.
2. **Plugin packs:** `plugins: [dir, ...]` in the spec merges a folder of
   `tools/`, `hooks/` and `skills/`, plus a `plugin.yaml` with observers and MCP
   servers, into the harness.
3. **ACP server (`arx acp`):** the Agent Client Protocol over stdio, for
   editors and custom front-ends:
   - `session/new` and `session/load` map to a new session and `--resume`;
   - `session/prompt` runs the turn loop;
   - `session/cancel` is the Ctrl-C path;
   - events become `session/update` messages;
   - `permissions: ask` sends `session/request_permission` before tool calls.
4. **OpenTUI front-end (`arx-tui`):** a terminal UI that talks to `arx acp`.
5. **MCP client:** MCP servers declared in the spec become tools. Only two
   built-in tools sit in the prompt: `mcp_search` finds a tool, and
   `mcp_select` adds its full schema on the next turn.
