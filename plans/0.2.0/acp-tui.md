# 0.2.0 plan: `arx acp` and the TUI plugin

Slug `acp-tui`. Roadmap items 4 (`arx acp`) and 5 (a TUI plugin).

## Goal

Editors and custom front-ends drive arx over the Agent Client Protocol
(ACP), and terminal users get an inline TUI that is a plugin. Done means:

- `arx acp` serves ACP v1 on stdio: `initialize`, `session/new`,
  `session/load`, `session/list`, `session/close`, `session/set_mode`,
  `session/prompt`, `session/cancel`, `session/update` and
  `session/request_permission`. Zed connects with
  `{"command": "arx", "args": ["acp"]}` and runs a session with tool calls,
  permission prompts, cancel and load. Permission prompts come from the
  `long-lived-hooks` `ask` contract; until it and `trust` land, `arx acp`
  runs in mode `allow` only.
- One ACP session is one arx session. The ACP `sessionId` is the arx session
  id, so `arx watch`, `arx ctl`, `arx sessions` and `arx --resume` work on it.
- The `tui` plugin (OpenTUI on bun) draws arx inline below your shell
  prompt, talks only to `arx acp`, and runs when you type bare `arx` on a
  terminal with `ui: tui` set.
- The core loop gets no ACP code. The core gets four small contracts that
  are useful on their own: `--input jsonl`, event additions, the `ui:` key
  and `ProcPollWith`. `arx acp` speaks JSON-RPC through `src/base/rpc.c`,
  which `mcp-client` defines and lands first.

## Current state

| Part | Where | What it does today |
|---|---|---|
| Signals | `src/main.c:15-29` | The first SIGINT or SIGTERM sets `g_interrupted`; a second SIGINT calls `_exit(130)`. No `SA_RESTART`, so a blocking `getline` returns `EINTR`. |
| Mode choice | `src/main.c:32-48` | `-p`, or a piped stdin read whole as the task, means headless. A TTY on stdin and no `-p` means interactive. |
| Dispatch | `src/main.c:65-68` | A built-in (`kCommands`, `src/cli/commands.c:227`), else `arx-NAME` (`src/cli/external.c:84-117`), else a usage error. |
| Session open | `src/agent/run.c:34-55` | `--resume` calls `SessionResume` (`src/io/session.c:108`); else `SessionNew` (`:33`): id `YYYYMMDD-HHMMSS-xxxx` under `./.arx/sessions/`, and the `last` link at depth 0. |
| Start | `src/agent/run.c:58-83` | Loads the spec, opens the events, starts observers once, sends `session.start`. |
| Begin | `src/agent/run.c:86-102` | System prompt, `session_start` hook, first message. Once per new session, never on resume. |
| Headless | `src/agent/run.c:105-112` | One prompt, `RunTurns`, exit. With `--resume`, the prompt is added as a user message. |
| Interactive | `src/agent/run.c:116-147` | `getline` per message; the first line goes through `Begin`. Ctrl-C ends the turn; Ctrl-C or EOF at the prompt ends the session; `auth` ends it. |
| Turn loop | `src/agent/loop.c:128-156` | Caps, reload, inbox, notes, compaction, model call, tool calls, stop hook. Checks `g_interrupted` at `:131`. `stop_requested` (`:87`) is never reset, so after `arx ctl stop` every later interactive prompt ends at once. |
| Tool calls | `src/agent/tool_calls.c:211-239` | `tool.start` (`id`, `name`, a 120-char `preview`) goes out before the `before_tool` chain (`:223-227`). A hook `result` or deny ends the call without a run (`:75-83`). `tool.end` (`:157-164`) has `error` and a 100-char `preview`, and goes out before `after_tool` (`:169-185`). After Ctrl-C, queued calls get `[interrupted before this tool ran]` (`:218`, `:289-293`). |
| Hooks | `src/harness/hooks.c:26-31`, `:66-69`, `:98`, `:326` | `before_tool` may print `name`, `args`, `keys`, `result`, or the older `{"decision": "deny", "reason"}`, which sets `is_error`. Default timeout 10 s. `fail: closed` turns a failed hook into a deny. Bands: policy, normal, final. |
| Events | `src/io/events.c:23-35`, `:46-58`, `:106-118`, `:120-131` | `--events -\|fd:N\|PATH`. Every event has `v`, `t`, `session`, `depth`, `turn`, `type`. Model text is batched into `model.delta` every 50 ms. Subagent lines pass through with their own `depth`. Table: `docs/plugins/reference.md:225-253`. |
| Terminal view | `src/io/render.c` | Draws events on stderr; `arx watch` draws a log the same way. The TUI ports it. |
| Subagents | `src/harness/tool_exec.c:110-139` | `arx -p - --spec P --json --quiet --events fd:3` plus the `--cap`s: the model for a driver that runs arx. |
| Processes | `src/base/base.h:154-204` | `ProcStart` with `open_in` and `ProcWrite`, `on_fd3`, `keep_on_interrupt`. `ProcPoll` waits at most 0.1 s and watches only children. Each child gets its own process group. |
| Inbox | `src/cli/commands.c:83-100`, `src/agent/loop.c:81-93` | `arx ctl ID note\|stop` appends `{"cmd": ...}` lines; arx reads them before each model call. |
| Spec keys | `src/harness/fields.c:68-95` | No `ui` and no `permissions` key. |
| Reasoning | `src/model/sse.c` | Not parsed; no thinking events. |
| ACP, JSON-RPC, TUI | none | Nothing exists. `plans/0.2.0/mcp-client.md` (section 14) defines the JSON-RPC module both plans use. |
| Child working folder | `src/base/base.h:154` | `Proc` has no `cwd`; `mcp-client` adds `dir`, which `arx acp` needs to start a child in its session's `cwd`. |

Two gaps shape the design:

- Events carry no user prompts, no full tool arguments and no tool output,
  so a front-end can't draw or replay a session from them.
- The only long-lived input mode reads a TTY.

The earlier TUI notes (claude.ai/artifact/HxRwFnfrUK8nvHh9SoxJmN) could not
be read from this session (not found, or not shared with it). This plan does
not use them.

## Design

### The shape

```text
editor or TUI ─ ACP on stdio ─▶ arx acp ─ one child per session ─▶ arx --input jsonl --quiet --events fd:3
                 ▲      ▲          │  │                                --ask ctl --policy plugins/ask
                 │      │          │  └─ prompts on stdin, SIGINT ───▶  (the `ask` plugin's before_tool
                 │      │          └──── inbox: {"cmd":"answer"} ───▶   hook replies `ask`)
                 │      └ request_permission ◀─ ask, ask.end ◀────── events on fd 3
                 └ session/update ◀── translate ◀──────────────────── events on fd 3
```

`arx acp` is a driver. It never runs the turn loop itself:

- Each ACP session is one long-lived `arx` child in a new `--input jsonl`
  mode, with the lifecycle of interactive mode today. Observers, the
  scheduler and (later) MCP servers start once per session, not once per
  prompt.
- Prompts go to the child's stdin. Events come back on fd 3.
- A cancel is one SIGINT to the child: exactly the Ctrl-C path.
- Permission prompts use the one ask mechanism of 0.2.0, the
  `long-lived-hooks` `ask` contract. `arx acp` passes the shipped `ask`
  plugin with `--policy`, so the agent can't remove it, and runs the child
  with `--ask ctl`. Asks come out as `ask` events; arx acp turns each into
  `session/request_permission` and writes the answer to the session's inbox,
  as `arx ctl answer` does.

### Decision: `arx acp` lives in the core binary, outside the loop

`arx acp` is a built-in command, with its code in a new folder `src/acp/`.
It is not `commands/arx-acp`. Why:

1. **It must be C.** Editors start it with no runtime around it. A bash
   command can't multiplex stdin and several children, and python or bun
   would add a dependency for every editor user.
2. **It reuses the core's parts in one link**: `proc.c` (process groups,
   fd 3, `ProcWrite`), `json.c`, cJSON, and `rpc.c`, the JSON-RPC module
   that the MCP client also links. A separate binary would link `base/` twice and add a
   second artifact to build, release, install and `arx update`.
3. **Driver and child are one version.** arx acp starts each child as
   `$ARX_BIN`, its own executable, so the events and flags it relies on
   (`--input jsonl`, `--ask ctl`, `prompt.end`, `ask`) are always there.
4. **It costs little**: an estimated +20 KB on the 183 KB macOS binary
   (budget 400 KB), and nothing at startup, since no ACP code runs unless
   `argv[1]` is `acp`.
5. **It keeps "not more code in the core loop".** `src/acp/` sits beside
   `cli/` and uses only `base/`. It never includes `agent.h`: the process it
   drives runs the unchanged loop. `arx watch` (`render.c`) and `arx tool
   bash` (`shell_tools.c`) set the precedent: front-end and plugin code in
   the binary, run as their own process.

Layers: `main → cli → acp → base`.

### Core contracts

Four changes of this plan, and one from `mcp-client`
([section 5](#5-the-json-rpc-module-from-mcp-client)).

#### 1. `--input jsonl`

```text
--input jsonl          read prompts as JSON lines on stdin and keep running
```

- One JSON object per line: `{"prompt": "TEXT"}`. Other keys are ignored. A
  line that isn't an object with a string `prompt` gives an `error` event
  (`"error": "bad input line: ..."`), and arx reads on.
- arx runs the interactive loop (`Interactive`, `src/agent/run.c:116`) with
  these differences: no `›` prompt on stderr, and `/exit` is text, not a
  command. EOF ends the session, as today.
- `EINTR` at the read is not EOF. arx clears the error, resets
  `g_interrupted` and reads on, so a SIGINT that lands just after a prompt
  ended can't end the session.
- Each prompt resets `stop_requested`, so `arx ctl ID stop` ends the current
  prompt, not every later one. Interactive mode gets the same fix.
- An `auth` result ends the session, as in interactive mode.
- It implies interactive mode although stdin is a pipe: `src/main.c:37-40`
  must not read stdin as the task. With `-p` it is a usage error: `arx:
  --input jsonl does not take -p`.
- `jsonl` is the only value now. The flag leaves room for others.

#### 2. Events

All additive within `v` 1:

| Event | Change | Sent |
|---|---|---|
| `prompt.start` (new) | `text`: the prompt as given, cut at 64 KB | when a user prompt enters the session: the `-p` task, each interactive line, each `--input jsonl` prompt. Not for `stop` hook messages or `[harness]` notes. |
| `prompt.end` (new) | `status` (`done`, `cap`, `error`, `auth`, `interrupted`; `policy` once `trust` lands), `turns`, `tokens`, `cost`, `final_output` (cut at 2000) | when `RunTurns` returns in interactive and `--input jsonl` modes; headless has `session.end` |
| `tool.start` | adds `args`: the parsed arguments, or the raw string when it is not JSON. Left out, with `args_cut: true`, when its JSON is over 16 KB. | as today, before `before_tool` |
| `tool.run` (new, shared with `async-calls`) | `id`, `name` | when the call's process starts (`Launch`, `tool_calls.c:196`). Whichever of `async-calls` and `acp-tui` lands first adds it. |
| `tool.end` | adds `output`: the first 2 KB of the result as the tool returned it, before `after_tool` | as today |
| `session.start` | adds `context_window` and `cwd` | as today |

With these, `events.jsonl` holds the whole visible session: prompts, text,
tool calls with their arguments and output, and notes. `arx acp` replays a
session from it, and the terminal view and the TUI can draw the same things.
The cost is at most 18 KB per tool call, data the transcript already holds.

#### 3. The `ui:` spec key

```yaml
# ~/.config/arx/config.yaml
ui: tui     # bare `arx` on a terminal runs `arx tui` instead of the built-in view
```

- A string: a command name without `/`. `none` or empty means the built-in
  view. Row in `kTopFields`: `{"ui", kString, NULL, "Command that draws
  interactive runs (arx-NAME), or none"}`.
- `RunAgent` (`src/main.c:32`) reads it only for an interactive run on a
  terminal: no command, no `-p`, no `--input`, stdin and stdout are TTYs,
  and no `--json` or `--events`. It loads the spec, reads `ui`, frees the
  spec, and calls `RunUi(name, argc, argv)` in `src/cli/external.c`.
- `RunUi` execs `arx-NAME` (found by `FindCommand`) with every original
  option (`--spec`, `--kit`, `--set`, `--cap`, `--resume`), and `ARX_BIN`
  and `ARX_LIBEXEC` set, as for any command.
- A missing command prints `arx: ui: no command arx-tui; using the built-in
  view` and the run goes on. A spec that doesn't load also goes on, and
  arx reports the spec error as today.
- `--set ui=none` turns it off for one run. No new flag.
- The agent can edit `ui` in `agent.yaml`. That's harmless: it only picks a
  front-end, from the next launch.

#### 4. `ProcPollWith`

`arx acp` waits on its stdin and its children at once.
`ProcPoll` (`src/base/base.h:197`) watches only children and wakes every
0.1 s:

```c
// Like ProcPoll, and also waits on `extra` (poll(2) entries the caller
// fills; revents is set on return). Waits up to `max_wait` seconds; the
// 0.1 s cap applies only while a child has a timeout or g_interrupted is
// set.
void ProcPollWith(ProcChild* const* kids, int n, struct pollfd* extra,
                  int n_extra, double max_wait);
```

`ProcPoll(kids, n, w)` becomes `ProcPollWith(kids, n, NULL, 0, w)`. The
same file gets `ProcKeep` and `ProcRelease` from `async-calls`, and `dir`
(the child's working folder) and `ProcCloseInput` from `mcp-client`. `arx
acp` uses both of `mcp-client`'s: `dir` starts a child in its session's
`cwd`, and `ProcCloseInput` ends a session. They land in any order.

#### 5. The JSON-RPC module, from `mcp-client`

`arx acp` uses `src/base/rpc.c` as `plans/0.2.0/mcp-client.md` section 14
defines it, and adds nothing to it. It lands first, in its own pull
request, before either plan's other steps. In short: one peer in either
role, newline-delimited JSON, no I/O of its own. The owner calls `RpcFeed`
with the bytes it reads and gives a `write` function. Calls are
asynchronous (`RpcCall` returns the id and runs `done` once with
`kRpcOk`, `kRpcError`, `kRpcTimeout` or `kRpcClosed`), and a `request`
handler answers now or later with `RpcReply` or `RpcReplyError`.

How `arx acp` uses it:

| Need | Call |
|---|---|
| Read the client | `RpcFeed(peer, ...)` with the bytes from fd 0, when `ProcPollWith` says it is readable |
| Write the client | `write` = `WriteAll(1, ...)`. `arx acp` is the only writer on fd 1. |
| Methods from the client | the `request` handler. `session/prompt` and `session/load` answer later: `arx acp` keeps `cJSON_Duplicate(id, 1)` until `prompt.end` or the end of the replay. |
| `session/cancel` | the `notify` handler |
| Updates and `_arx/event` | `RpcNotify` |
| `session/request_permission` | `RpcCall` with no timeout; `done` writes the answer to the inbox. `RpcForget` when the `ask.end` event comes first. |
| Bad lines | the module answers `-32700` and `-32600` in the server role; `bad_line` logs to stderr |
| Shutdown | `RpcClose("closed")` on EOF, then `RpcFree` |

`mcp-client` section 14 confirms two points this relies on: a `timeout` of
0 means no deadline, and the `id`, `params` and `value` that handlers and
callbacks get are borrowed, so an owner that answers later keeps
`cJSON_Duplicate(id, 1)`.

Codes that only ACP uses live in `src/acp/`: `-32000` authentication
required, `-32002` not found, `-32800` cancelled.

### `arx acp`

#### Command line

```text
arx acp [--permissions ask|allow] [--spec PATH] [--kit NAME] [--set K=V]...
        [--cap K=V]... [--policy DIR]...
```

- `--permissions` is the mode new sessions start in. Default `ask`. Until
  `long-lived-hooks` part 3 and `trust` both land, `allow` is the only mode:
  the default is `allow`, and `--permissions ask` is a usage error
  (`arx: --permissions ask needs the ask contract, which this build lacks`).
- `--spec`, `--kit`, `--set`, `--cap` and `--policy` pass to every child. A
  relative `--spec` or `--policy` is made absolute first, because each child
  runs in its session's `cwd`. Without `--spec`, each child finds
  `agent.yaml` in its `cwd`, else your defaults, as `arx` does.
- `--json`, `--events`, `-p`, `--resume` and `--input` are usage errors.
- stdout carries only ACP messages. arx acp's own log lines and each
  child's stderr go to stderr, one line each, prefixed `[SESSION]`.
- SIGINT gets a handler that does nothing, so a front-end in the same
  process group can't kill it. (Not `SIG_IGN`, which children would
  inherit.) SIGTERM, or EOF on stdin, shuts it down.

#### A session's child

For `session/new`, and for `session/load` with `--resume ID`:

1. arx acp checks that `cwd` is an absolute directory, else `-32602`.
2. It starts the child with `ProcStart` (`open_in`, `on_fd3`, and `dir:
   cwd` from `mcp-client`):

   ```text
   $ARX_BIN --input jsonl --quiet --events fd:3 --ask ctl [--resume ID]
            [passthrough options] --policy ASK_PLUGIN_DIR
            [--set mcp_servers.NAME=JSON]...
   ```

   `ASK_PLUGIN_DIR` is the `ask` plugin that ships with arx:
   `BINDIR/../libexec/arx/plugins/ask` when installed, `BINDIR/plugins/ask`
   in a source checkout, found the way `FindCommand` finds commands
   (`src/cli/external.c:26-55`). It is the last policy, so your own
   policies decide first. Without the ask contract (see `--permissions`),
   the child gets neither `--ask ctl` nor the `ask` plugin.
3. It waits up to 5 s for `session.start` on fd 3, and answers with that
   event's `session` as the `sessionId`. If the child exits first, the
   answer is `-32603` with the child's stderr, such as a spec error with its
   line number.

`mcpServers` in `session/new` and `session/load` become session overrides
of `mcp_servers.NAME`, as `mcp-client` section 14 and its dependencies row
set out. `--set` is the override that every reload applies:

| ACP entry | `--set mcp_servers.NAME=JSON` |
|---|---|
| stdio `{name, command, args, env: [{name, value}]}` | `{command, args, env: {NAME: VALUE}}` |
| `{type: "http", name, url, headers: [{name, value}]}` | `{url, headers: {NAME: VALUE}}` |
| `{type: "sse", ...}` | the request fails with `-32602`: `sse MCP servers are not supported` |

Values of `env` and `headers` often hold tokens, and argv is visible to
`ps`. So arx acp never puts them on the command line: it puts each value in
the child's environment as `ARX_ACP_MCP_N` and writes `"${ARX_ACP_MCP_N}"`
in the JSON, which `mcp-client` expands when the server starts. A server
named like one in the spec overrides it for this session. Before
`mcp-client` lands, arx acp accepts the field and ignores it, with a log
line.

#### Methods

| ACP | Kind | What arx acp does |
|---|---|---|
| `initialize` | request | answers as below, with `protocolVersion: 1` |
| `authenticate` | request | `-32601`: arx has no ACP sign-in; `arx setup` does it |
| `session/new` | request | starts a child; answers `{sessionId, modes}` |
| `session/load` | request | checks `CWD/.arx/sessions/ID/` (else `-32002`), starts the child with `--resume ID`, replays `events.jsonl` as updates, then answers `{modes}`. A session already open on this connection is replayed and keeps its child. |
| `session/list` | request | sessions in `CWD/.arx/sessions/`, newest first, 50 per page: `sessionId`, `cwd`, `title` (the first `prompt.start`, cut at 80 characters; else transcript line 2, as `arx sessions` does), `updatedAt` (mtime of `events.jsonl`). The cursor is the page's last id. |
| `session/close` | request | closes the child's stdin, so it ends the session (`session.end`, `meta.json`); SIGTERM after 3 s. `{}`, also for an unknown id. |
| `session/set_mode` | request | `ask` or `allow`; sends `current_mode_update`. Takes effect at the next ask; an ask already open stays open. |
| `session/prompt` | request | flattens the content to text, writes `{"prompt": TEXT}` to the child, answers on `prompt.end` |
| `session/cancel` | notification | one SIGINT to the child when a prompt runs; else nothing |
| `_arx/note` | request | `{sessionId, text}`: appends `{"cmd": "note", "text"}` to the session's inbox, as `arx ctl ID note` does. `{}`. |
| `_arx/cancel_call` | request | `{sessionId, call}`: inbox `{"cmd": "cancel", "call"}`, the `async-calls` contract; `-32601` until it lands |
| `session/update` | notification out | the event mapping below |
| `session/request_permission` | request out | the permission flow below |
| `_arx/event` | notification out | `{sessionId, event}`: every raw event at every depth, live and in replay, only for a client that sent `clientCapabilities._meta.arx.events: true` |

A second `session/prompt` while one runs gets `-32600` ("a prompt is
already running"). An unknown session id gets `-32002`.

`initialize` answers:

```json
{"protocolVersion": 1,
 "agentInfo": {"name": "arx", "title": "arx", "version": "0.2.0"},
 "agentCapabilities": {
   "loadSession": true,
   "promptCapabilities": {"image": false, "audio": false, "embeddedContext": true},
   "mcpCapabilities": {"http": true, "sse": false},
   "sessionCapabilities": {"list": {}, "close": {}},
   "_meta": {"arx": {"events": true, "note": true}}},
 "authMethods": []}
```

`mcpCapabilities` is `{"http": true, "sse": false}` once `mcp-client`
lands, as its plan asks, and `{"http": false, "sse": false}` before.
`session/new` and `session/load` return `modes`:

```json
{"currentModeId": "ask", "availableModes": [
  {"id": "ask", "name": "Ask", "description": "Ask before tool calls that change things"},
  {"id": "allow", "name": "Allow", "description": "Run tool calls without asking"}]}
```

Without the ask contract, `availableModes` lists only `allow`.

#### Prompt content

arx acp joins the content blocks into one text, with blank lines between:

| Block | Text |
|---|---|
| `text` | as is |
| `resource_link` | `[file: PATH]` for a `file://` URI, else `[link: URI]` |
| `resource` (embedded) | `<context uri="URI">`, a newline, the text, a newline, `</context>`. A `blob` gets `-32602`. |
| `image`, `audio` | `-32602`: not advertised |

#### Stop reasons

| `prompt.end` status | Answer to `session/prompt` |
|---|---|
| `done` | `{"stopReason": "end_turn"}` |
| `interrupted` | `{"stopReason": "cancelled"}` |
| `cap` | `{"stopReason": "max_turn_requests"}` |
| `policy` (`trust`, exit 5) | `{"stopReason": "refusal"}` |
| `auth` | error `-32000`: `authentication failed: run arx setup` |
| `error` | error `-32603` with the last `error` event's text |
| the child exits during a prompt | error `-32603`: `arx exited (code N)`. The next prompt starts a new child with `--resume`. |

Every answer carries `_meta.arx`: `session`, `turns`, `tokens`, `cost` and
`context_window`. It always comes after the prompt's last update, because
arx acp sends updates in event order and answers when it reads `prompt.end`.

#### Events to `session/update`

One translator serves live events and replay. Only `depth: 0` events become
updates; deeper ones go out only as `_arx/event`.

| arx event | `session/update` |
|---|---|
| `prompt.start` | replay only: `user_message_chunk` with `{type: text}`. Live, the client has its own prompt. |
| `model.delta` | `agent_message_chunk` with `{type: text, text}` |
| `tool.start` | `tool_call`: `toolCallId: id`, `title: "NAME: PREVIEW"`, `kind` (below), `status: pending`, `rawInput: args`, and `locations: [{path}]` when `args.path` is a string. For `edit`, also `content: [{type: diff, path, oldText: args.old or null, newText: args.new}]`, with `path` made absolute against the session's `cwd`. |
| `tool.run` | `tool_call_update` with `status: in_progress` |
| `tool.detach` (`async-calls`) | `tool_call_update`, status unchanged, `_meta: {arx: {call, background: true}}` |
| `tool.progress` (`mcp-client`) | `tool_call_update`, `content: [{type: content, content: {type: text, text: "MESSAGE (PROGRESS/TOTAL)"}}]`, replaced by each new one and by `tool.end` |
| `tool.end` | `tool_call_update` with `status: completed`, or `failed` when `error`; `content`: the `output` text, plus a `resource_link` to `path` (the full `tool-NNNN.out`) when there is one |
| `note`; `harness.reload` with `ok: false`; rejected `harness.edit` (`trust`); `mcp.server` with `state: failed` (`mcp-client`) | `agent_thought_chunk`: `[harness] TEXT` |
| `compact` | `compaction_update` `completed`, only for a client with `session.compaction` |
| `model.retry`, `error` | `notice` (`warning`, `error`), only for a client with `session.notices` |
| `ask`, `ask.end` (`long-lived-hooks`) | not updates: `session/request_permission` and its end, as "Permissions" describes |
| `session.start`, `turn.start`, `model.message`, `model.credential`, `hook`, `prompt.end`, `session.end` | nothing. `prompt.end` answers the prompt; usage goes in its `_meta`. |

Tool kinds: `bash` is `execute`, `edit` is `edit`, a subagent tool (`agent:`
in its options) is `think`, and any other tool is `other`. An MCP call's
name is already `SERVER__TOOL`, and `tool.start` carries `server`, so its
title is `SERVER TOOL: PREVIEW`. MCP calls pass `before_tool`, so mode
`ask` covers them too.

`session/load` reads `events.jsonl` line by line through the same
translator, then answers. In logs without `tool.run`, `tool.end` alone ends
a call. Sessions from 0.1 have no `prompt.start`, so they replay without
your prompts.

#### Permissions

arx has one way to ask a person: the `ask` contract of `long-lived-hooks`
("Ask a person", and "`arx acp` as an ask handler" in
`plans/0.2.0/long-lived-hooks.md`). `arx acp` is one of its handlers, on
the contract's `ctl` path. It adds no hook, socket or second mechanism.

- **Who asks.** The `ask` plugin, a long-lived `before_tool` hook in the
  `policy` band with `fail: closed`, which ships with arx
  (`libexec/arx/plugins/ask`). arx acp passes it to every child with
  `--policy`, so the agent can't turn it off, and `trust` passes it on to
  subagents. Its defaults decide which calls need a yes: every tool whose
  keys are not `[]`. Any other `before_tool` hook, such as your own guard,
  can reply `ask` too, and arx acp handles those asks the same way.
- **Who answers.** Each child runs with `--ask ctl`, and `long-lived-hooks`
  passes `--ask ctl` on to its subagents. The child writes an `ask` event
  (`call`, `name`, `args`, `plugin`, `policy`, `title`, `options`,
  `timeout`, plus `session`, `depth` and `turn`) and waits. arx acp answers
  by appending `{"cmd": "answer", "call": CALL, "option": OPTION_ID}` to
  `CWD/.arx/sessions/SESSION/inbox`, where `SESSION` is the event's
  `session`: the subagent's own inbox for a subagent's ask. Subagents start
  in the parent's working folder, so their sessions sit in the same
  `.arx/sessions/`. arx acp never uses `last`, which a subagent's session
  moves. The line is the one `arx ctl ID answer CALL OPTION_ID` writes, so
  you can also answer from another terminal. While an ask is open, arx
  checks the inbox every 20 ms.
- **The order of events.** For each call, `tool.start` comes before any
  `ask`, and `ask.end` before `tool.end`. So the client always has the
  `tool_call` before the request. For a subagent's call (depth > 0), whose
  `tool.start` is not an update, arx acp first sends a `tool_call` built
  from the `ask` event (title `NAME (subagent): TITLE`).

For each `ask` event, arx acp does this:

1. **Mode `allow`**, and the ask comes from the `ask` plugin as a policy
   layer (`plugin` is `ask` and `policy` is `true`): it answers at once with
   the ask's `allow_once` option, without asking the client. An ask from
   any other hook goes to the client in both modes, because that hook is
   your guard, not the mode's.
2. **An earlier "always" in this ACP session**, for this tool `name` and an
   option of the same kind (`allow_always` or `reject_always`): it answers
   at once with this ask's option of that kind. The `ask` plugin keeps
   "always" for its own arx session (in `ARX_STATE_DIR`, so `session/load`
   keeps it). arx acp keeps it across the parent and its subagents, which
   are separate arx sessions.
3. **Otherwise** it sends `session/request_permission`:

   | `ask` event | `session/request_permission` |
   |---|---|
   | `call` | `toolCall.toolCallId` |
   | `title` | `toolCall.title` |
   | `name` | `toolCall.kind` (the tool-kind map in "Events to `session/update`") |
   | `args` | `toolCall.rawInput`: the call as the asking hook saw it |
   | each option's `id`, `label`, `kind` | `optionId`, `name`, `kind` (the kinds are ACP's) |

4. **The client's outcome**: `selected` with an option id writes `answer
   CALL OPTION_ID`. `cancelled` after a `session/cancel` writes nothing:
   the SIGINT already closed the ask. `cancelled` without one, or an
   outcome arx acp doesn't know, writes the dismiss line `{"cmd": "answer",
   "call": CALL, "cancelled": true}` (what `arx ctl ID answer CALL
   --cancel` writes). arx then writes `ask.end` with `"why": "dismissed"`,
   and the `ask` plugin denies the call. arx acp writes it only while the
   ask is open, so no stray `error` event follows.

Closing an ask:

- **`session/cancel`** is one SIGINT to the child. arx writes `ask.end`
  with `"why": "interrupted"` for each open ask, in the parent and its
  subagents, and ends those calls with `[interrupted before this tool
  ran]`. ACP has the client answer the pending request with `cancelled`;
  arx acp drops that answer.
- **An ask that ends without the client**, by its `timeout`, an answer from
  `arx ctl`, or a per-call cancel (`_arx/cancel_call`), writes `ask.end`.
  ACP has no message to withdraw a request, so arx acp calls `RpcForget`
  and drops the client's later answer. The tool's `tool_call_update` shows
  how the call ended.
- **What you approve** is the call as it is at the ask (`args`), after
  earlier policy hooks. A `normal` hook that rewrites it later still shows
  as `[ran as: ...]` in the result.

**Until `long-lived-hooks` part 3 and `trust` both land**, `arx acp` ships
with mode `allow` only. Its children get no `--ask` flag and no `ask`
plugin, so a hook that replies `ask` gets `--ask none`'s answer:
`cancelled`, `"why": "no one to ask"`.

#### Shutdown and failures

- EOF on stdin or SIGTERM: arx acp closes every child's stdin, waits up to
  3 s, then `ProcFinish` (SIGTERM, then SIGKILL). Pending prompts get
  `-32603`, and open asks end as the child stops. It exits 0.
- A child that exits between prompts is started again with `--resume` at
  the next prompt. After two failed starts in a row, the session's prompts
  fail with the child's stderr.
- arx acp writes nothing in a session folder except inbox lines: `answer`,
  `note` and `cancel`.

### The TUI plugin

#### Folder

```text
plugins/tui/
  plugin.yaml          name, requires: [bun], setup
  README.md
  package.json         exact versions; bun.lock committed
  tsconfig.json
  commands/arx-tui     bash launcher
  src/main.tsx         options, starts `arx acp`, new or load, mounts the view
  src/client.ts        the ACP client and _arx/event
  src/store.ts         events to view state: a port of src/io/render.c
  src/scrollback.ts    writes finished blocks above the footer
  src/view/            Footer, Live, ToolRow, Permission, Input, Status, SessionPicker
  src/history.ts       input history
  tests/               bun test
```

```yaml
# plugins/tui/plugin.yaml
name: tui
version: 0.1.0
description: A terminal UI for arx, drawn inline below your prompt.
arx: ">=0.2"
requires: [bun]
setup: bun install --frozen-lockfile --production
```

It has no tools, hooks or skills, so being in the active list costs
nothing. `ui` is not a `plugin.yaml` key: you opt in with `arx config set
--global ui tui`, and `arx plugin add tui` prints that line when it's done.

Dependencies, pinned to exact versions: `@opentui/core`, `@opentui/solid`
(open decision 7), `solid-js`, and `@agentclientprotocol/sdk`, the official
ACP TypeScript library. Using the library also checks arx acp against the
reference schema.

#### Launcher

`commands/arx-tui` (bash):

1. If `bun`, `node_modules/` or the setup stamp is missing, it prints the
   fix (install bun, or `arx plugin setup tui`) on stderr, then runs `exec
   "$ARX_BIN" "$@" --set ui=none`, so you get the built-in view.
2. Else it runs `exec bun "$ARX_PLUGIN_DIR/src/main.tsx" "$@"`.

`main.tsx` takes the options `arx` got:

- `--resume ID|last` becomes `session/load`. It resolves `last` by reading
  `.arx/sessions/last`.
- `--spec`, `--kit`, `--set`, `--cap` and `--policy` go to `arx acp`.
- It starts `$ARX_BIN acp --permissions ask ...` with stderr piped (shown
  only if arx acp exits early), sends `initialize` with
  `_meta.arx.events: true`, then `session/new` with `cwd: process.cwd()` and
  `mcpServers: []`.

#### Layout: inline

The TUI uses OpenTUI's `screenMode: "split-footer"` with
`externalOutputMode: "capture-stdout"`. OpenTUI owns a footer at the bottom
of the screen, and what the TUI writes to stdout scrolls into the terminal's
own scrollback above it. There is no alternate screen: the session stays in
your scrollback after you exit, and you scroll and copy with your terminal.

- **Scrollback**, written once and never redrawn:
  - your prompt, as `› TEXT` in bold;
  - agent text, by complete lines, with light markdown: bold headings, dim
    code fences, styled inline code;
  - tool calls when they end: `● bash  make test`, then `  ✓ 2.1s  42
    passed` or `  ✗ exit 1  ...`;
  - subagent activity, indented by depth;
  - `[harness]` notes, reloads, compactions and retries, one dim line each.

  It draws what `render.c` draws, from the same events (`_arx/event`).
- **Footer**, which grows with its content up to half the screen:
  - the current partial line of agent text;
  - running tool calls, one row each with a spinner and the elapsed time (at
    most 5, then `+N more`);
  - a permission prompt, when one is pending;
  - the input box, which grows to 8 rows;
  - the status line: `MODEL · SESSION · N turns · 91k tokens · $0.31 ·
    ask`.

The TUI draws from `_arx/event` and uses standard ACP for control: prompt,
cancel, modes, permission, load and list. So it shows all that `arx watch`
shows, subagents included, while editors get the standard mapping.

#### Keys and commands

| Key | What it does |
|---|---|
| Enter | sends the prompt. While a prompt runs, sends the text as an operator note (`_arx/note`), which the agent sees before its next model call. |
| Shift-Enter, Alt-Enter, Ctrl-J | a new line |
| Esc, Ctrl-C (while a prompt runs) | `session/cancel` |
| Ctrl-C (idle, empty input) | the first press shows `Ctrl-C again to exit`; the second exits |
| Ctrl-D (empty input) | exits |
| Up, Down | input history, for this project |
| Shift-Tab | switches the mode, `ask` and `allow` (`session/set_mode`) |
| y, a, n, Esc, 1-9 | in a permission prompt: the ask's `allow_once`, `allow_always` and `reject_once` options; Esc is `reject_once`; a digit picks any option by its place |

Commands at the input: `/exit`, `/new` (a new session), `/resume [ID]` (a
`session/list` picker, then `session/load`), `/mode ask|allow` and `/help`.
Other text that starts with `/` goes to the agent.

On exit, the TUI closes arx acp's stdin and prints one line:
`session 20261109-131500-a1b2 · arx --resume 20261109-131500-a1b2`.

Input history goes to `$ARX_DATA_DIR/history` when `plugin-state` gives
commands `ARX_DATA_DIR`, else `.arx/data/tui/history`. It keeps 500
entries.

Not in 0.2.0: mouse, a full-screen mode, images, `@file` completion, themes,
skills as slash commands.

## Implementation steps

`src/base/rpc.c` lands before everything else, in its own pull request
(`mcp-client` step 1). Part 1 comes next. Parts 2 and 3 can then run in
parallel once step 9 gives part 3 a working `arx acp`.

### Part 1: core contracts

1. **Events** (`src/agent/run.c`, `src/agent/tool_calls.c`): `prompt.start`
   where a prompt enters (`Begin` at `run.c:99`, `:109`, `:133`);
   `prompt.end` after `RunTurns` in `Interactive`; `args` on `tool.start`
   (`tool_calls.c:223`, from `c->model_call`); `output` on `tool.end`
   (`SendEnd`, `:157`); `tool.run` in `Launch` (`:196`) unless `async-calls`
   added it; `context_window` and `cwd` on `session.start` (`run.c:75`).
   `tool_calls.c` has 345 lines: stay under 400, or move `Preview` and
   `ArgsText` to a helper file.
2. **`--input jsonl`**: parse it and add it to `PrintOptions`
   (`src/cli/options.c`); `int input_jsonl` in `Agent`
   (`src/agent/agent.h`); the mode choice (`src/main.c:37-41`); JSON lines,
   the `EINTR` retry and the `stop_requested` reset in `Interactive`
   (`src/agent/run.c`).
3. **`ProcPollWith`** in `src/base/proc.c` and `src/base/base.h`. If
   `mcp-client` hasn't added `dir` and `ProcCloseInput` to `Proc` yet, add
   them here, to its spec.
4. **`rpc.c`**: nothing to build here; it comes from `mcp-client`'s first
   pull request.
5. **`ui:`**: the field row (`src/harness/fields.c`), `RunUi`
   (`src/cli/external.c`, `src/cli/cli.h`), the check in `RunAgent`
   (`src/main.c`).
6. The tests for steps 1-5, and a green `make bench`.

### Part 2: `arx acp`

7. **`src/acp/acp.h`**: `AcpMain` and the session struct (id, cwd, child,
   mode, the "always" choices by tool name and kind, the open asks by call
   id with their pending request ids, the pending prompt id, whether a
   SIGINT was sent).
8. **`src/acp/server.c`**: options, signals, the main loop (`ProcPollWith`
   over stdin and the children), `initialize`, dispatch, errors and
   shutdown. Register
   `{"acp", "[--permissions ask|allow] [options]", "serve the Agent Client
   Protocol on stdio, for editors and the TUI", AcpCommand}` in `kCommands`
   (`src/cli/commands.c:227`).
9. **`src/acp/sessions.c`**: the child's argv and environment, with
   `mcpServers` turned into `--set` entries and `ARX_ACP_MCP_N` variables;
   `session/new`, `/load`, `/close`, `/list`, `/set_mode`, `/prompt` with
   content flattening, and `/cancel`; restart with `--resume`; `_arx/note`
   and `_arx/cancel_call`.
10. **`src/acp/translate.c`**: events to updates, tool kinds, diffs, replay
    of `events.jsonl`, and `_arx/event`.
11. **`src/acp/ask.c`**, after `long-lived-hooks` part 3 and `trust`: find
    the shipped `ask` plugin; add `--ask ctl` and `--policy ASK_PLUGIN_DIR`
    to the child's argv; map `ask` events to `request_permission`, with a
    `tool_call` first for a subagent's call; mode `allow` and the "always"
    choices; write `answer` and dismiss lines to the inbox of the event's
    `session` (never `last`); on
    `ask.end`, `RpcForget` the open request. Until then, steps 7 to 10 ship
    with mode `allow` only.
12. `Makefile` (`src/acp/*.c`) and `make lint` (each file 400 lines or
    fewer).
13. `tests/acp.sh` with its helpers, in `make test` and CI.
14. A check by hand in Zed (`"agent_servers": {"arx": {"command": "arx",
    "args": ["acp"]}}`): new session, prompt, tool call, permission, cancel,
    load, an edit diff.

### Part 3: the TUI plugin

15. **Spike, then go or no-go** (1-2 days): OpenTUI `split-footer` with
    captured stdout in Terminal.app, iTerm2, kitty, Ghostty, tmux and a
    Linux xterm. Stream 2,000 lines, resize, grow and shrink the footer,
    Ctrl-Z, and time the first frame. If it fails, fall back to
    `main-screen` with a fixed footer, and report.
16. The `plugins/tui/` scaffold: `plugin.yaml`, `package.json` and
    `bun.lock`, `tsconfig.json`, `commands/arx-tui` with its fallback, and
    `README.md`. It needs `arx-plugin`'s `setup:` key first, or `arx check
    --plugin plugins/tui` fails.
17. `src/client.ts`: spawn `arx acp`, the library's client connection, the
    `requestPermission` handler, the `_arx/event` notification and
    `_arx/note`.
18. `src/store.ts`: the reducer, a port of `render.c` (depth indent, tool
    rows, notes, reloads).
19. `src/scrollback.ts` and `src/view/`: the footer, the live line, tool
    rows, the permission prompt, the input box and the status line.
20. Keys, commands, history, the mode switch and the exit line.
21. Tests (`bun test`), run from `tests/plugins.sh` (skipped without bun)
    and in CI (`oven-sh/setup-bun`, pinned).

### Part 4: docs

22. The pages in "Docs to change", in the same pull requests as the code
    they describe.

## Tests

### `tests/run.sh` (core)

- A `-p` task gives `prompt.start`. `tool.start` has `args.command`,
  `tool.end` has `output`, `session.start` has `context_window` and `cwd`,
  and `tool.run` comes between `tool.start` and `tool.end`.
- Arguments over 16 KB: `tool.start` has no `args` and has `args_cut: true`.
- `--input jsonl`: two prompts run in one process and one session, each
  ends with `prompt.end` `done`, and the second model request holds the
  first exchange.
- `--input jsonl`: a bad line gives an `error` event and the next good line
  runs; EOF ends the session with `session.end`.
- `--input jsonl`: a SIGINT while idle doesn't end the session. A SIGINT
  during `sleep 30` gives `prompt.end` `interrupted` within 2 s, and the
  next prompt works.
- `--input jsonl`: `arx ctl last stop` ends one prompt, not the next.
- `--input jsonl -p x` exits 2.

### `tests/cli.sh`

A `tests/pty` helper runs a command under a pseudo-terminal: `script -q
/dev/null CMD` on macOS, `script -qec CMD /dev/null` on Linux.

- `ui: fake`, with `$ARX_CONFIG_DIR/commands/arx-fake` that prints its
  arguments: bare `arx --cap turns=3` under the pty runs it with `--cap
  turns=3`.
- No exec with `-p`, with a piped stdin, with `--json`, with `--set
  ui=none`, or without a TTY.
- `ui: missing` prints the warning and runs the built-in view.
- `arx schema` lists `ui`, and `arx check` accepts it.

### `tests/acp.sh` (new suite)

The suite's helpers: `acp_start` runs `"$ARX" acp` as a bash coprocess with
a log, `acp_send JSON` writes a line, and `acp_expect JQ_FILTER [SECS]`
reads lines until one matches (`jq -e`), else fails and prints the log.
`$SID` comes from `session/new`.

- `initialize`: `protocolVersion` 1, `loadSession`, `sessionCapabilities.list`
  and `promptCapabilities.embeddedContext`.
- `session/new`: the id is an arx id, and `.arx/sessions/ID/` is under the
  request's `cwd`, not the test's.
- A text reply: `agent_message_chunk` `Hello`, then `{"stopReason":
  "end_turn"}`, and no update for that prompt after it.
- Two prompts: the same child pid, and the second request holds the first
  exchange.
- A `bash` call in mode `allow`: `tool_call` (`kind: execute`,
  `rawInput.command`), `tool_call_update` `in_progress`, then `completed`
  with the output text.
- An `edit` call: `diff` content with an absolute `path`, `oldText` and
  `newText`.
- A cancel during `sleep 30`: `stopReason: cancelled` within 2 s, the
  tool's process group is gone, and the next prompt works.
- Without the ask contract: `availableModes` is only `allow`, `arx acp
  --permissions ask` exits 2, and the child's argv has no `--ask` and no
  `--policy` for `ask`.

With `long-lived-hooks` part 3 and `trust` (mode `ask`):

- The child runs with `--ask ctl` and `--policy .../plugins/ask` (seen in
  `ps`), and a spec that disables `ask` still gets asked.
- `request_permission` comes after the call's `tool_call` and before the
  tool runs, with `toolCallId`, `rawInput` from the ask's `args`, and the
  `ask` plugin's four options. Allow: the inbox gets `{"cmd": "answer",
  "call", "option": "allow"}`, and the file the tool writes exists.
  Reject: it doesn't, and the update is `failed` with the plugin's deny.
- Always allow: a second `bash` call in the session isn't asked; after
  `session/load` it still isn't (the plugin's `ARX_STATE_DIR`).
- Mode `allow`: the `ask` plugin's asks are answered at once with
  `allow_once`, and no request reaches the client. A spec hook that replies
  `ask` still reaches the client in mode `allow`.
- `session/set_mode` gives `current_mode_update`, and the next ask follows
  the new mode.
- A subagent's `bash` call: a `tool_call` for it, then the request; the
  answer lands in the subagent's own inbox, and "always allow" from the
  parent's ask covers it.
- A cancel while a permission is pending: `ask.end` with `"why":
  "interrupted"`, the client's `cancelled` answer is dropped, `stopReason:
  cancelled`, and the tool didn't run.
- `arx ctl SID answer CALL allow` from another terminal while a request is
  open: the tool runs, and the client's later answer writes nothing.
- An unknown outcome, or `cancelled` without a `session/cancel`, writes the
  dismiss line; `ask.end` has `"why": "dismissed"`, and the tool didn't
  run.
- An ask from a spec hook in mode `allow` (`plugin` not `ask`, or `policy`
  not `true`) reaches the client.
- `session/load` replays `user_message_chunk`, `agent_message_chunk`,
  `tool_call` and `tool_call_update` from `events.jsonl` before its answer,
  and the next prompt continues the history.
- `session/load` of an unknown id gives `-32002`. `session/list` lists
  newest first, with titles.
- `session/close`: `meta.json` has status `done`, and the child is gone.
- Errors: an unknown method gives `-32601`, a bad line `-32700`, a prompt
  while one runs `-32600`, a bad `agent.yaml` a `session/new` error with the
  line number, a fake 401 `-32000`, and `limits.max_turns: 1`
  `max_turn_requests`.
- Content: a `resource_link` and an embedded `resource` reach the model
  request as `[file: ...]` and `<context uri=...>`.
- `_arx/note` writes the inbox line, and the note is in the next model
  request. `_arx/event` arrives only after the opt-in.
- `mcpServers` (after `mcp-client`): a stdio entry with `env: [{name:
  TOKEN, value: s3cret}]` starts the server with `TOKEN=s3cret`, and
  `s3cret` is in no process's argv (`ps -o args`). An `sse` entry fails
  with `-32602`. `initialize` says `"http": true`.
- Every stdout line of `arx acp` parses as JSON-RPC, while a tool prints to
  stdout and stderr and a hook writes to stderr.
- EOF on stdin: `arx acp` exits 0 within 3 s, with no child left.

### `plugins/tui/tests/` (`bun test`)

- `store.test.ts`: recorded event streams (text, tools, subagents, notes,
  reloads) give the expected scrollback lines and footer state.
- `client.test.ts`: a real `arx acp` (`ARX=./arx-debug`, `tests/fake-curl`)
  for a new session, a prompt, a tool call with an auto-answered
  permission, a cancel and a load. The library checks every message
  against the ACP schema.
- `view.test.tsx`: footer snapshots from OpenTUI's in-memory output
  (`bufferedOutput: "memory"`): idle, streaming, two running tools, a
  permission prompt.
- `launcher.test.ts`: `arx-tui` without `node_modules` prints the fix and
  runs `arx ... --set ui=none`.

## Docs to change

Each page follows `docs/WRITING.md`: one page type, a first sentence that
defines the subject, and nothing planned in the present tense.

| Page | Change |
|---|---|
| `docs/acp.md` (new, guide) | "Editors and ACP": what `arx acp` is; Zed setup (`agent_servers`); the two modes and `--permissions`, and that the `ask` plugin asks (link to its page) and `arx ctl ID answer` can answer too; one ACP session is one arx session (`arx watch ID`, `arx ctl ID note`); `mcpServers`; the mapping tables from this plan as reference sections; caps and limits in long sessions. Ends with Related. Add it to `src/lib/nav.mjs` in arx-docs. |
| `docs/tui.md` (new, guide) | "The terminal UI": install (`arx plugin add tui`; needs bun), turn it on (`arx config set --global ui tui`), off for one run (`--set ui=none`), the layout, keys and commands, notes while the agent works. Ends with Related. Add it to the nav. |
| `docs/cli.md` | `arx acp` in the command block, with a section; `--input jsonl` in the options table; under "Running an agent", that `ui:` hands interactive runs to a command. |
| `docs/spec.md` | `ui` under "Top-level keys". |
| `docs/plugins/reference.md` | Events: `prompt.start`, `prompt.end`, `tool.run`, and the new `args`, `output`, `context_window` and `cwd` fields. |
| `docs/concepts.md` | Sessions: an editor can drive a session. Events: prompts are in the stream. Next steps links `acp.md`. |
| `docs/architecture.md` | `src/acp/` in the source table (`rpc.c` comes with `mcp-client`) and the mermaid layout; a decision row "Front-ends drive arx as child processes"; suite and check counts; the binary size after the build. |
| `docs/roadmap.md` | Items 4 and 5 become **done**, with links; their sections go. |
| `docs/plugins/planned.md` | The Front-ends row and section go. |
| `docs/getting-started.md` | Next steps: the terminal UI and editors. |
| `README.md` | One line each for editors (ACP) and the TUI. |
| `plugins/tui/README.md` | What it is, that it needs bun, its keys, and how to work on it (`arx plugin add --link`). |

## Dependencies

| Slug | What `acp-tui` needs or shares | Hard? |
|---|---|---|
| `long-lived-hooks` | Part 3: the `ask` contract (`ask` reply, `--ask ctl` passed on to subagents, the inbox `answer` line read every 20 ms, the `ask` and `ask.end` events with `args`, `plugin`, `policy`, `session` and `depth`; the inbox dismiss line `{"cmd": "answer", "call", "cancelled": true}`) and the shipped `ask` plugin: four options (`allow`, `allow-always`, `reject`, `reject-always`), "always" memory in `ARX_STATE_DIR`, and a built-in hook (`exec "$ARX_BIN" hook ask`), so it needs no `python3`. Its section "`arx acp` as an ask handler" is the other half of this plan's "Permissions". Also: concurrent `before_tool` chains, so asks for calls that don't conflict wait side by side. | Yes for mode `ask`. Until part 3 lands, `arx acp` ships with mode `allow` only. |
| `trust` | `--policy DIR`: repeatable, a plugin-shaped folder, passed to subagents, policy hooks first, `fail: closed` honored (`plans/0.2.0/trust.md`, "CLI"). arx acp passes the `ask` plugin with it. Exit 5 (`policy`) maps to `refusal`; rejected `harness.edit` events become thought chunks. | Yes for mode `ask`, with `long-lived-hooks`. |
| `mcp-client` | `src/base/rpc.c` as its section 14 defines it, landed first in its own pull request; `arx acp` adds nothing to it. `dir` and `ProcCloseInput` in `Proc`. `mcpServers` becomes `--set mcp_servers.NAME=...` with secrets passed through `${ARX_ACP_MCP_N}` expansion; `sse` is refused; `mcpCapabilities: {"http": true, "sse": false}`. `tool.start.server`, `tool.progress` and `mcp.server` map to updates. | Hard for `rpc.c`, which `arx acp` can't work without. Soft for the rest: ACP ignores `mcpServers` until MCP lands. |
| `arx-plugin` | The `setup:` key (runs `bun install`), `arx plugin setup NAME`, the setup stamp gate, and `requires:` checked before setup. Its examples call the plugin `acp-tui`; the plugin is named `tui` (command `arx-tui`, `ui: tui`). | Yes for the TUI: `plugins/tui` doesn't validate without `setup:`. |
| `async-calls` | `tool.run` (shared: the first to land adds it), `tool.detach`, `tool.end.call`, and `_arx/cancel_call` mapped to the inbox `cancel` line. This plan confirms its proposed ACP mapping. It also edits `proc.c` (`ProcKeep`) and `tool_calls.c`. | Soft. |
| `plugin-state` | `ARX_DATA_DIR` (`.arx/data/<name>/`) for a plugin's command: the TUI's history. `ARX_STATE_DIR` for the `ask` plugin's "always" memory, so `session/load` keeps it. | Soft. |
| `plugin-yaml-keys` | Edits `src/harness/fields.c` too; `ui` goes in `kTopFields`. | Shared file only. |
| `sandboxes`, `climb` | None. | |

Files shared with other plans: `src/harness/fields.c`,
`src/agent/tool_calls.c` (`async-calls`, `long-lived-hooks`),
`src/base/proc.c` and `base.h` (`async-calls`, `mcp-client`), `src/main.c`,
the events table in `docs/plugins/reference.md`, `docs/cli.md`, and the
`Makefile` test target.

## Size and risks

**Size: L.** Part 1 is S (about 250 lines of C with tests). Part 2 is M
(about 1,250 lines of C in `src/acp/`, and a suite of about 40 checks;
`rpc.c` is `mcp-client`'s). Part 3 is M (about 1,500 lines of TypeScript).

| Risk | Mitigation |
|---|---|
| OpenTUI's `split-footer` mode is newer than its full-screen mode: resize, wrapping of captured output, tmux. | The step 15 spike comes before any other TUI work, with a `main-screen` fallback. |
| ACP churn: `session/list`, `usage_update`, notices and compaction updates are newer than the baseline, and a strict client (Zed's typed schema) may reject an update kind it doesn't know. | Send only baseline kinds unless the client advertised the capability; usage goes in `_meta`. Pin the library version in the TUI tests, so a schema change fails CI. |
| `trust` or `long-lived-hooks` part 3 slips. | Ship `arx acp` with mode `allow` only, and turn on mode `ask` when both land (step 11). Don't add a second ask path to work around it. |
| A client that never answers a request leaves the call waiting. | The `ask` plugin's `timeout` setting ends it; the default is no limit, as at the terminal. `session/cancel` always ends it. |
| SIGINT races: a second SIGINT calls `_exit`, and a SIGINT just after `prompt.end` hits the idle read. | arx acp sends at most one SIGINT per prompt and never when idle; `--input jsonl` retries `EINTR`; a lost child restarts with `--resume`. |
| Long-lived children meet caps: `--cap wall` counts idle time, and `limits.max_turns` (200) counts every prompt of a session. | Document both in `acp.md` and `tui.md`; a front-end can start a new session. |
| Bun, and OpenTUI's native library per platform; the size of `node_modules`. | The TUI is an optional plugin, and its launcher falls back to the built-in view. |
| `events.jsonl` grows with `args` and `output`. | Capped at 16 KB + 2 KB per call. |
| TUI startup: bun, OpenTUI, arx acp and the child. | Budget: first frame in 300 ms on an M1, measured in the spike. |
| An editor's permission UI may need a `tool_call` before the request. | Always send `tool_call` first, also for subagent calls. |

## Open decisions

1. **Where `arx acp` lives.** Recommend a built-in command in the core
   binary, with its code in `src/acp/` and never in the agent process, for
   the reasons in "Decision" on this page. The alternative,
   `commands/arx-acp` as a second C binary, has the same code and adds a
   second link and release artifact for no gain.
2. **One child per session, or one per prompt.** Recommend one long-lived
   child per ACP session (`--input jsonl`): observers, the scheduler and MCP
   servers start once, and `session/new` returns the real id at once. One
   `arx -p --resume` per prompt needs no input mode, but restarts MCP
   servers on every prompt and needs a way to make an empty session.
3. **Where the permission check lives.** Decided (release decision 1): the
   `long-lived-hooks` `ask` contract is the one ask mechanism. The shipped
   `ask` plugin asks, passed with `--policy` so the agent can't remove it;
   the child runs with `--ask ctl`; arx acp maps `ask` events to
   `session/request_permission` and answers in the inbox. The first
   draft's generated hook, `arx acp ask` client and socket are dropped.
4. **Where the mode is set.** Decided (settled point 7: no `permissions:`
   spec key): `arx acp --permissions ask|allow` sets the starting mode,
   ACP modes switch it, and the default is `ask` once the contract lands.
   Mode `allow` answers only the `ask` plugin's asks; asks from your own
   hooks still reach the client.
5. **The scope of "always".** Recommend the ACP session: the `ask` plugin
   keeps it for its arx session in `ARX_STATE_DIR` (so `session/load`
   keeps it), and arx acp extends it to that session's subagents. Keeping
   it per project, in the plugin's `ARX_DATA_DIR`, is a change to the `ask`
   plugin for later, not to arx acp.
6. **What `session/load` replays.** Recommend `events.jsonl`, with the new
   `prompt.start` events, through the same translator as live updates: it
   survives compaction and `restart`. The alternative, `transcript.jsonl`
   from its last reset, shows only what the model sees now.
7. **The TUI's binding.** Recommend `@opentui/solid`: fine-grained updates
   suit streamed text, and OpenTUI's largest app uses it. `@opentui/react`
   works too.
8. **The TUI as the default for bare `arx`.** Recommend opt-in (`ui: tui`)
   in 0.2.0, and a second look at the default once `arx setup` can install
   it.
9. **Tool kinds.** Recommend the fixed map (`bash` is execute, `edit` is
   edit, subagents are think, the rest other) in 0.2.0, and a `kind` tool
   option later if editors need more.
10. **Subagents in editors.** Recommend: their calls appear only when they
    need a permission, and the rest goes out as `_arx/event` to clients that
    opt in. Folding them into the parent call's content can come later.
11. **Typing while the agent works, in the TUI.** Recommend an operator
    note (`_arx/note`, written to the inbox), the arx way to steer a run.
    The alternative queues the text as the next prompt.
12. **Editor features left out of 0.2.0**: the client's `fs/*` (unsaved
    buffers) and `terminal/*`, `authenticate` with a terminal method that
    runs `arx setup`, skills as slash commands (`available_commands_update`),
    `agent_thought_chunk` for model reasoning, which arx doesn't parse yet,
    and MCP elicitation routed to the ACP client (`mcp-client` leaves
    elicitation out of 0.2.0). Recommend leaving all of them out; none
    blocks Zed.
