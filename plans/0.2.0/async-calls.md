# Plan: calls that do not block (`async-calls`)

Slug: `async-calls`. Release: arx 0.2.0. Status: plan only, no code changed.

## Goal

A scheduler plugin can move a tool call to the background. The model gets
the result `started as c7` at once and goes on working. When the call ends,
its real result reaches the agent as a `[harness]` note, through the session
inbox. A subagent can then start without a wait.

What ships:

- **A core contract**: two new scheduler messages (`detach`, `cancel`), a
  session-wide table of calls in flight, result delivery through the inbox,
  `arx ctl ID cancel CALL`, and three event changes for front-ends.
- **A plugin**, `plugins/background`: the policy. It decides which calls go
  to the background and how many run at once, and it gives the model a
  `cancel_call` tool.

The built-in scheduler never moves a call to the background. Without the
plugin, every run behaves as in 0.1.0.

### Why the core must change

A scheduler plugin alone can't do this today, for four reasons:

1. **It can't run the call.** `ready` carries `id`, `name` and `keys`, not the
   arguments (`src/agent/scheduler.c:133`). Even with them, the plugin would
   lose arx's output capture, timeouts, process groups, `after_tool` hooks
   and subagent event forwarding (`src/harness/tool_exec.c:110`).
2. **The loop ends the run when the model stops.** A reply without tool
   calls goes to the stop hook and then exits (`src/agent/loop.c:146`). A
   headless run would end, and kill, the work it started in the background.
3. **The calls live for one reply.** The call table is a local array in
   `RunToolCalls` (`src/agent/tool_calls.c:317`), and `RunQueue` returns only
   when every call is done (`src/agent/tool_calls.c:301`).
4. **The only late channel is an operator note.** `arx ctl note` reaches the
   agent as "Note from your operator" (`src/agent/loop.c:89`). That is the
   wrong voice for a tool result, and it doesn't survive `--resume`.

The change stays a contract, not policy in the loop: arx runs, tracks and
delivers background calls, and a plugin decides which calls those are.

## Current state

| Part | Today | Where |
|---|---|---|
| Call table | one array per reply; `Call.id` and `Call.args` are borrowed from the reply message | `src/agent/tool_calls.c:142`, `:317` |
| Run loop | starts calls by keys or by the plugin, polls until every call is done | `src/agent/tool_calls.c:284` |
| Built-in scheduler | starts a queued call when its keys conflict with no running call and no earlier queued call | `src/agent/tool_calls.c:244` |
| Plugin scheduler | `start` launches, `result` ends a call without a run, always as an error | `src/agent/tool_calls.c:263`, `:276` |
| Scheduler protocol | arx sends `ready {id, name, keys}`, `done {id, secs, is_error, backoff}`, `tick`; reads `start`, `wake_at`, `result` | `src/agent/scheduler.c:133`, `:143`, `:163` |
| Scheduler failure | an `error` event, then the built-in scheduler for the rest of the session | `src/agent/scheduler.c:55` |
| Scheduler env | `ToolEnv` only; no `ARX_PLUGIN_SETTINGS` | `src/agent/scheduler.c:98` |
| Plugin settings env | built for hooks only | `src/harness/hooks.c:71` |
| Results in history | tool messages in call order, after the whole queue ends | `src/agent/tool_calls.c:330` |
| Turn end | no tool calls: the stop hook decides, else `kExitDone` | `src/agent/loop.c:146`, `:109` |
| Inbox | `inbox` file in the session folder; read once per turn, before the model call; knows `stop` and `note` | `src/agent/loop.c:81`, `:135`; `src/io/session.c:162` |
| Inbox writer | `arx ctl ID stop|note TEXT` appends one JSON line with `O_APPEND` | `src/cli/commands.c:84`; `src/base/util.c:230` |
| Resume | skips every inbox line written before the resume, as stale | `src/io/session.c:118` |
| meta.json | `turns`, `tool_seq`, tokens, cost, status | `src/io/session.c:144`, `:93` |
| Ctrl-C | queued calls get `[interrupted before this tool ran]`; ProcPoll kills running children unless `keep_on_interrupt` | `src/agent/tool_calls.c:289`; `src/base/proc.c:213` |
| Waits | the model call (`curl`), hooks and compactors use `ProcRun`, which polls only its own child | `src/model/llm.c:94`; `src/harness/hooks.c:105`; `src/harness/compact.c:236` |
| Subagent | `arx -p - --spec ... --events fd:3`; keys `[]`; timeout 30 minutes | `src/harness/tool_exec.c:110`; `src/harness/keys.c:84`; `src/harness/tools.c:328` |
| Forwarded events | each subagent event line is written and drawn at once | `src/io/events.c:121` |
| Events | `tool.start {id, name, preview}`, `tool.end {id, name, error, preview, exit, secs, bytes, path}` | `src/agent/tool_calls.c:223`, `:157` |
| Session end | `session.end`, meta.json, result; nothing stops running work but process exit | `src/agent/run.c:173` |
| Interactive | `getline` at the prompt; Ctrl-C ends the turn, not the session | `src/agent/run.c:116` |
| Signals | first Ctrl-C sets `g_interrupted`; a second one exits at once | `src/main.c:15` |
| Tests | the scheduler test matches `ready` exactly | `tests/runtime.sh:297` |

## Design

### Words

- **Background call** (in code: *detached*): a call whose placeholder result
  went to the model, and which runs on, or waits to run, after its reply's
  results are in the history.
- **In flight**: a background call whose result the agent hasn't seen yet.
- **Call id**: the short id arx gives a background call, `c1`, `c2`, and so
  on. The model's own tool call id (`call_abc...`, `toolu_...`) stays the
  `id` in the scheduler protocol and in events.

### Call ids

- arx gives an id when it moves a call to the background, not before. Calls
  that run in the foreground get none.
- The id is `c` plus a counter for the session: `c1`, `c2`, and so on. The
  counter is `call_seq` in `meta.json`, so ids never repeat in a session,
  across `--resume` too.
- arx assigns the id, not the scheduler, so ids stay unique when the plugin
  restarts or falls back.
- Why not the model's id: provider ids are long and opaque, and the model
  must copy the id to cancel a call. `c7` is three tokens.
- Everywhere a call is named (`cancel`, `arx ctl ... cancel`, the
  `cancel_call` tool), arx takes the short id or the model's id.

### Scheduler protocol

This is the one scheduler protocol table for 0.2.0 (README, "Settled across
plans", item 5). Two plans add to it: this one, and `long-lived-hooks`
("Scheduler messages", open decision 14). The **Added by** column says which
plan adds each message or field; `0.1.0` means it exists today. Every
addition is a new message or a new field, so a scheduler written for 0.1.0,
which ignores what it doesn't know, still works.

**From arx:**

| Message | Meaning | Added by |
|---|---|---|
| `{"waiting": {"id", "name", "keys"}}` | A call entered its `before_tool` hooks and holds these keys. arx sends one for each call, in call order, when the reply arrives. | long-lived-hooks |
| `{"ready": {"id", "name", "keys", "kind", "args"}}` | The call left its hooks and is queued. | 0.1.0 (`id`, `name`, `keys`) |
| ↳ `kind` | `"tool"`, or `"agent"` for a subagent. | async-calls |
| ↳ `args` | The arguments after the `before_tool` hooks, as an object. | async-calls |
| ↳ out of call order | `ready` can come out of call order, since each call's hooks run on their own. | long-lived-hooks |
| `{"done": {"id", "secs", "is_error", "backoff", "ran"}}` | A call ended. `backoff` is what an `after_tool` hook printed, or `null`. | 0.1.0 (`id`, `secs`, `is_error`, `backoff`) |
| ↳ for a background call | Sent when the call ends, possibly turns later. | async-calls |
| ↳ for a call that never started | Sent for a call that ended without its process starting: one that ended in its hooks (a hook's result, a deny, or Ctrl-C), and a queued call that was cancelled or stopped. `secs` is 0 and `is_error` is true. | long-lived-hooks (in hooks), async-calls (queued) |
| ↳ `ran` | `true` when the call's process started, `false` when it never did. | long-lived-hooks |
| `{"tick": <unix secs>}` | The time the scheduler asked for with `wake_at` has come. | 0.1.0 |

**From the scheduler:**

| Message | Meaning | Added by |
|---|---|---|
| `{"start": ["call_4", ...]}` | Start these queued calls now. | 0.1.0 |
| ↳ any call in the table | Applies to any queued call in the session's table, not only to the current reply's, so a held background call can start turns later. | async-calls |
| `{"wake_at": <unix secs>}` | Send a `tick` at this time. | 0.1.0 |
| `{"result": {"id", "text"}}` | End a queued call without a run, with this text as an error result. | 0.1.0 |
| ↳ for a queued background call | The text is delivered as a note, with status `error`. | async-calls |
| `{"detach": ["call_4", ...]}` | Give each call its placeholder result now, and keep it in the session's table. A queued call stays queued until a later `start`; a running call keeps running. | async-calls |
| `{"cancel": ["call_4", "c7", ...]}` | Cancel each call: see [Cancel](#cancel). Takes model ids or short ids. | async-calls |

Rules that cover the whole table:

- **Ids.** Every message uses the model's call id (`call_4`), as in 0.1.0.
  Only `cancel` also takes a short id (`c7`).
- **`done` is sent once per call** that the scheduler saw in `waiting` or
  `ready`, except a call that the scheduler itself ended with `result`, as
  today. So a scheduler can count what is in flight.
- **One line can hold several keys**, as today: `{"start": ["x"], "detach":
  ["x"]}` starts a call and moves it to the background at once.
- **`detach` needs `ready`.** A call that is still `waiting` (in its hooks,
  or waiting for a person's answer through the `ask` contract) can't move
  to the background; arx ignores that `detach`, as it ignores one for an
  unknown id or a call that already ended.
- **Bad values.** A `detach` or `cancel` value that is not a list of strings
  is a bad line, and arx falls back to the built-in scheduler.
- **Environment.** A plugin's scheduler gets `ARX_PLUGIN_SETTINGS`, as its
  hooks do (async-calls), and `ARX_STATE_DIR` and `ARX_DATA_DIR`
  (`.arx/data/<name>/`) through `ToolEnv` (plugin-state).

### The placeholder result

When a call moves to the background, arx ends the call's slot in the reply
with this tool result (not an error):

```text
started as c7 in the background. Its result comes later in a [harness] note.
Keep working; when you have nothing else to do, reply without a tool call and
arx waits for it. Output so far: /abs/.arx/sessions/<id>/tool-0007.out
```

- **`queued as c7 ...`** in place of `started` when the scheduler holds the
  call. The `Output so far` line is missing then, and for subagents.
- The hint about waiting stops the model from `sleep`ing in `bash`. When the
  plugin can add `instructions` (slug `plugin-yaml-keys`), the hint moves
  there and the placeholder keeps its first sentence.
- `after_tool` hooks don't see the placeholder. They run once, on the real
  result, when the call ends.

### Keys of a background call

A background call keeps its keys while it runs, except `*`, which arx drops
when the call moves to the background.

- A named key still holds: a background `edit` of `a.c` (`file:a.c`) makes a
  later `edit` of `a.c` wait, in this reply or a later one.
- `*` would make every later call wait until the background call ends, which
  defeats the point. The model has been told the call runs on; it owns the
  conflict, as with a background shell anywhere else.
- The built-in scheduler follows this rule after a fallback. A scheduler
  plugin should follow it too; `plugins/background` does.

### The session's call table

The call table moves from `RunToolCalls` to the agent. It holds the calls of
the current reply and every background call in flight.

- `RunToolCalls` prepares the reply's calls as today, then polls the table
  until each call of this reply is done or in the background. Then it writes
  the reply's tool messages, in call order, with the placeholder for each
  background call.
- A call in the table owns copies of its model id and arguments, since
  compaction can free the reply message.
- **One poll function, `CallsPoll`**, runs the table: it reads the
  scheduler's messages, starts calls (by the plugin, or by keys), and
  finishes calls whose process ended. arx calls it while tools run, at the
  start of each turn, and while it waits for a result.
- **Pipes don't stall.** A background call's process, and the scheduler's,
  join a registry in `src/base/proc.c` that every `ProcPoll` round serves,
  so `ProcRun` for the model call, hooks and compactors drains their pipes
  and enforces their timeouts too. Only `CallsPoll` finishes a call, so no
  agent code runs inside `ProcPoll`.

### When a background call ends

`CallsPoll` finishes it the same way as a foreground call, then delivers:

1. sends `tool.end` (with `call` and `detached`);
2. runs the `after_tool` hooks on the real result, with the real call;
3. sends `done` to the scheduler;
4. appends a `result` line to the inbox;
5. writes `meta.json`.

**Inbox line**, one JSON object, written by arx with `O_APPEND`:

```json
{"cmd": "result", "call": "c7", "id": "call_abc", "name": "reviewer",
 "preview": "Review src/a.c", "status": "ok", "secs": 42.1,
 "text": "...the result, as a foreground call would show it..."}
```

| `status` | When | Note header |
|---|---|---|
| `ok` | exit 0 | `c7 (reviewer: Review src/a.c) finished after 42s:` |
| `error` | non-zero exit, timeout, could not start, or a scheduler `result` | `c7 (...) failed after 3s:` |
| `cancelled` | `cancel` from the scheduler, `arx ctl` or `cancel_call` | `c7 (...) was cancelled after 10s:` |
| `stopped` | Ctrl-C, or the session ended | `c7 (...) was stopped after 10s:` |

The `text` is what a foreground call would give: the head and tail of the
output with the path of the full output, a subagent's final answer, or the
`[exit code N]`, `[timed out ...]`, `[cancelled]` and `[interrupted]` lines.
The preview is cut to 60 characters, so that the note still makes sense
after compaction.

**Why the inbox and not memory:** the inbox is already the one ordered
channel for what reaches the agent between turns. A file is also what
`--resume` can read back, and what a driver or front-end can read without
arx.

### When the model sees a result

- **Before its next model call.** `ReadInbox` turns each new `result` line
  into one paragraph of the turn's `[harness]` note (`src/agent/loop.c:95`).
  Results that end in the same poll share one note.
- **A delivered result leaves `calls` in meta.json.** "Delivered" means the
  note is in the history, not that the call ended.
- **A reply without tool calls, with calls in flight, does not end the
  run.** arx skips the stop hook and waits. The wait ends at the first of:
  a `result` line, an operator `note` or `stop` in the inbox, Ctrl-C, or the
  `wall` cap. Then the loop runs the next turn as usual. Each wait costs one
  turn per batch of results, not one per call.
- **The stop hook runs only when nothing is in flight.** So "done" means
  that the agent's own work is done.
- The wait is bounded: each call has its tool timeout (120 s, or 30 minutes
  for a subagent), and the `wall` cap applies while arx waits.

### Cancel

Three ways in, one function (`CallCancel`):

| From | How |
|---|---|
| The scheduler | `{"cancel": ["c7"]}`, applied at the next `CallsPoll` |
| A person or a front-end | `arx ctl ID|last cancel c7` appends `{"cmd": "cancel", "call": "c7"}` to the inbox |
| The model | the `cancel_call` tool of `plugins/background`, which runs `"$ARX_BIN" ctl "$ARX_SESSION" cancel c7` |

- **A running call**: arx sends SIGTERM to its process group, and SIGKILL 3
  seconds later, without waiting (new `ProcStop`). The result is its output
  so far plus `[cancelled]`, with status `cancelled`. `after_tool` runs.
- **A queued call**: it ends at once with `[cancelled before it started]`.
  The scheduler gets `done` with `ran: false`.
- **A call that already ended, or an unknown id**: ignored.
- **`arx ctl ... cancel`** checks `calls` in `meta.json` first, and exits 2
  with `no call c9 in flight (in flight: c7, c8)` when the id isn't there.
- arx reads `cancel` lines at the start of each turn and while it waits. A
  `cancel_call` made in a reply takes effect before the next model call.

### Errors

| Case | What happens |
|---|---|
| The tool can't start when it moves to the background | it ends at once; the model gets the error as the normal result, not a placeholder |
| A queued background call can't start later | status `error`, delivered as a note |
| Non-zero exit or timeout | status `error`; the text carries `[exit code N]` or `[timed out ...]` |
| The scheduler exits or prints a bad line with calls in flight | the `error` event as today; running calls go on; the built-in scheduler starts the queued ones by their keys, with no limit |
| An `after_tool` hook fails | as today: the hook's `fail` option decides |
| arx can't append to the inbox | an `error` event, and the note goes straight to the agent's notes in memory |
| The scheduler never starts a queued background call | the run waits until Ctrl-C or the `wall` cap, as a foreground call does today; listed in Common mistakes |

### Limits on calls in flight

- **The plugin sets the limit**: `max` in its settings, default 4 background
  calls running at once. More calls get `queued as cN`, and start when one
  ends.
- **No core limit in 0.2.0.** Parallel subagents in one reply have no core
  limit today either. Each subagent still gets the parent's caps, so a low
  `max` is the guard on cost.
- After a fallback to the built-in scheduler there is no limit.

### Session end, Ctrl-C and `--resume`

**Session end** (a cap, an error, `arx ctl stop`, `/exit`, end of input):
before `session.end`, `CallsShutdown` stops every call in flight (SIGTERM,
then SIGKILL after 3 seconds), ends the queued ones, runs `after_tool`,
sends `done`, and appends `result` lines with status `stopped`. They stay
in `calls` in meta.json, since the agent hasn't seen them. A headless run
that ends normally has nothing in flight, because the loop waits first.

**Ctrl-C** stops background calls too, as it stops foreground ones.
`ProcPoll` already kills every child that is not `keep_on_interrupt`, and
arx doesn't set that flag on tools. This matches ACP: `session/cancel` asks
the agent to stop every tool call.

- Headless: the run ends (`kExitInterrupted`), through `CallsShutdown`.
- Interactive: the turn ends. The `stopped` results reach the agent with
  your next message, so it knows what didn't finish.
- A second Ctrl-C exits at once, as today.

**`--resume`**: for each call still in `calls` in meta.json, arx looks for
its `result` line in the inbox:

- found (it ended, or the session stopped it): arx delivers it as the normal
  note before the first model call;
- not found (arx was killed): arx adds `c7 (reviewer: ...) did not finish:
  the session stopped while it ran. Output so far: PATH.`

Then `calls` is empty. arx doesn't restart lost calls; the model can call
again. `note`, `stop` and `cancel` lines from before the resume stay stale,
as today.

### Front-ends (slug `acp-tui`)

Events, additive within `v` 1:

| Event | Fields | When |
|---|---|---|
| `tool.run` (new) | `id`, `name` | a call's process starts: any call, foreground or background |
| `tool.detach` (new) | `id`, `name`, `call` (`"c7"`), `queued` (bool) | the placeholder goes to the model |
| `tool.end` | adds `call` and `detached: true` for a background call | the call ends, possibly turns later |

Proposed ACP mapping, for the `acp-tui` plan to confirm:

| arx | ACP `session/update` |
|---|---|
| `tool.start` | `tool_call`, status `pending` |
| `tool.run` | `tool_call_update`, status `in_progress` |
| `tool.detach` | `tool_call_update`, status unchanged, `_meta: {"arx": {"call": "c7", "background": true}}` |
| `tool.end` | `tool_call_update`, status `completed` or `failed` |

- Because a turn doesn't end while calls are in flight, every update for a
  background call arrives inside the `session/prompt` that started it. The
  front-end shows the call as in progress while the model streams on.
- `session/cancel` takes the Ctrl-C path, so background calls end
  `stopped` before the prompt's response.
- A per-call cancel button sends an ACP extension method,
  `_arx/cancel_call {sessionId, call}`, which `arx acp` maps to the inbox
  `cancel` line.
- The terminal view draws `tool.detach` as one line (`↳ c7 reviewer runs in
  the background`) and `tool.end` when it comes. It doesn't draw a
  background subagent's own events while the parent streams; they still go
  to `events.jsonl`, so `arx watch` shows them.

### The `background` plugin

```text
plugins/background/
  plugin.yaml
  scheduler            # Python 3: the policy
  tools/cancel_call    # sh: validates the id, runs arx ctl ... cancel
  tools/cancel_call.json
```

```yaml
# plugin.yaml
name: background
version: 0.1.0
description: Runs subagents and chosen tools in the background, so the agent keeps working.
arx: ">=0.2"
requires: [python3]
```

Settings, from the active list:

```yaml
plugins:
  - shell
  - background: {agents: true, tools: [long_build], after: 30s, max: 4}
```

| Setting | Default | Meaning |
|---|---|---|
| `agents` | `true` | move every subagent call (`kind: agent`) to the background at once |
| `tools` | `[]` | also move calls to these tools at once |
| `after` | none | move any other call to the background when it still runs after this long (`wake_at`, then `detach`) |
| `max` | `4` | background calls running at once; the rest wait queued |

The scheduler starts foreground calls by keys, as the built-in scheduler
does. It treats a background call's keys as held, minus `*`.

`cancel_call` takes `{"id": "c7"}` and declares the keys `[]`. It reads
`calls` from `$ARX_SESSION_DIR/meta.json`: for an unknown id it exits 1 and
lists the calls in flight, with their names and ages.

## Implementation steps

In order. Each step leaves `make test` green.

1. **Session-lived children** (`src/base/proc.c`, `src/base/base.h`):
   `ProcKeep(child)` and `ProcRelease(child)` add a child to, and remove it
   from, a registry that every `ProcPoll` round serves (feed, drain, reap,
   timeout). A child is in the registry or in the caller's list, never both.
   Add `ProcStop(child)`: SIGTERM to the group, SIGKILL after the grace
   period, without waiting. Put the scheduler's child in the registry
   (`src/agent/scheduler.c`). Coordinate the API with `long-lived-hooks` and
   `mcp-client`.
2. **Plugin env for schedulers** (`src/harness/hooks.c`, `src/harness/tool_exec.c`,
   `src/harness/harness.h`, `src/agent/scheduler.c`): move `HookEnv` into a
   shared `PluginEnv(a, layer)` and use it in `SchedOpen`.
3. **The session's call table** (`src/agent/agent.h`, `src/agent/tool_calls.c`):
   move `Call` and its array onto `Agent`; copy `id` and `args`; split
   `RunQueue` into `CallsPoll(a, wait)` and a loop that ends when this
   reply's calls are done. No behavior change yet; the runtime tests guard it.
4. **Scheduler messages** (`src/agent/scheduler.c`, `src/agent/agent.h`):
   `ready` gains `kind` and `args`. `SchedPoll` fills a `SchedOut {start,
   results, detach, cancel}`. Validate `detach` and `cancel` as lists of
   strings. `SchedDone` takes `ran`, and arx sends `done` with `ran: false`
   for a queued call that is cancelled or stopped. `long-lived-hooks` adds
   `SchedWaiting` and the in-hooks `done` in the same file: whichever plan
   lands first adds the `ran` parameter, and the other uses it.
5. **Background calls** (new `src/agent/background.c`, `src/agent/agent.h`):
   `CallDetach` (short id, placeholder text, drop `*`, `ProcKeep`,
   `tool.detach`), delivery on end (`result` inbox line, meta), `CallCancel`,
   `CallsInFlight`, `CallsWait`, `CallsShutdown`, `CallsResume`.
   `src/harness/tool_exec.c`: a `cancelled` flag on `ToolRun` for the
   `[cancelled]` line, and quiet forwarding for a background subagent.
6. **Session files** (`src/io/session.c`, `src/io/io.h`): `call_seq` and
   `calls` in `meta.json` (load and write); `SessionInboxAppend`;
   `SessionInboxFind(s, call)` for resume.
7. **The loop** (`src/agent/loop.c`): `CallsPoll` before `ReadInbox`;
   `ReadInbox` handles `result` (a note paragraph) and `cancel`; a reply
   without tool calls and with calls in flight goes to `CallsWait`, not to
   the stop hook.
8. **Lifecycle** (`src/agent/run.c`): `CallsResume` after `OpenSession` on
   resume; `CallsShutdown` before `session.end` in `Finish`.
9. **Events and view** (`src/agent/tool_calls.c`, `src/io/events.c`,
   `src/io/render.c`, `src/io/io.h`): `tool.run`, `tool.detach`, the new
   `tool.end` fields, `EventForward` without drawing for a background
   subagent, and the view's lines for both new events.
10. **`arx ctl ... cancel`** (`src/cli/commands.c`, usage line at
    `src/cli/commands.c:240`): validate against `meta.json`, append the
    line.
11. **The plugin** (`plugins/background/`): `plugin.yaml`, `scheduler`,
    `tools/cancel_call` and its schema; a row in `plugins/README.md`.
12. **Tests and docs**, below.

## Tests

New file `tests/background.sh`, run by `tests/run.sh`, with a test scheduler
built like the `sched` helper in `tests/runtime.sh:258` and a `nap` tool that
sleeps and writes marker files.

| Test | Checks |
|---|---|
| detach at start | req-02 has `started as c1`; the model replies with text; arx waits; req-03 has `c1 (nap: ...) finished after`; exit 0; the stop hook ran once, after the note |
| keeps working | turn 2 calls another tool while c1 runs; c1's note arrives in a later request; the history has one tool message per call, in call order |
| queued | `detach` without `start`, `start` on `tick`: placeholder says `queued as c1`; `tool.run` comes after `tool.detach` |
| ids | two background calls get `c1` and `c2`; after `--resume`, the next one is `c3` |
| cancel from a tool | the tool runs `arx ctl "$ARX_SESSION" cancel c1`; the nap's group got SIGTERM (no end marker); the note says `was cancelled`; `after_tool` saw `[cancelled]` |
| cancel from the scheduler | `{"cancel": ["call_1"]}` (model id) works the same |
| cancel queued | ends with `[cancelled before it started]`; the scheduler log has `done` with `"ran": false` |
| ctl cancel unknown | exit 2; the message lists the calls in flight |
| errors | a background call that exits 1 gives `failed after` and `[exit code 1]`; a timeout gives `[timed out` |
| Ctrl-C | `kill -INT` while arx waits: the call is `stopped`; `after_tool` ran; exit code of an interrupt; meta.json `calls` lists c1 |
| session end by cap | `--cap turns=2` with a call in flight: its process is stopped; the inbox has a `stopped` line |
| resume after a stop | `--resume`: req-01 of the new run has `c1 (nap: ...) was stopped`; meta.json `calls` is empty after |
| resume after a crash | `kill -9` arx with a call in flight; `--resume` gives `did not finish` |
| scheduler failure | the scheduler exits after `detach`: the `error` event; the result still arrives |
| keys | after a fallback, a background `*` call doesn't block the next call; a background `file:x` call blocks a later `file:x` call |
| wall cap | `--cap wall=1s` with a 5 s background nap: exits 3 within 2 s |
| no pipe stall | a background tool prints 1 MB while the fake model call takes 1 s: the tool ends on time |
| events | `tool.detach` has `call` and `queued`; `tool.end` has `call` and `detached`; `tool.run` for every call |
| ready fields | update the exact match at `tests/runtime.sh:297` to include `kind` and `args` |

`tests/plugins.sh` gets a block for `plugins/background`: `agents: true`
moves a test subagent to the background; `max: 1` queues the second call;
`after: 0.3s` moves a long `nap` to the background; `cancel_call` with an
unknown id exits 1 and lists c1.

## Docs to change

Written to `docs/WRITING.md`: lead with the answer, name the mechanism and
the numbers, one idea per paragraph, no em dashes.

| Page | Change |
|---|---|
| `docs/plugins/schedulers.md` | the two message tables become the one protocol table in this plan's Design, without the **Added by** column, and `long-lived-hooks` adds no table of its own; a new section "Run calls in the background" (the placeholder, the keys rule, when the model sees a result, cancel, session end and resume); new Common mistakes rows (a held call that never starts, detaching a call the model needs at once); remove the Planned section |
| `docs/plugins/subagents.md` | replace Planned with "Run a subagent in the background": `arx plugin add background`, the `agents` setting, and the cost of a wake turn |
| `docs/plugins/planned.md` | remove the row and the section "Calls that do not block" |
| `docs/plugins/reference.md` | events `tool.run`, `tool.detach`, new `tool.end` fields; inbox line types (`result`, `cancel`); `call_seq` and `calls` in `meta.json`; the scheduler row of the env table gets `ARX_PLUGIN_SETTINGS` |
| `docs/plugins/tools.md` | Keys: one bullet, "a background call drops `*`" |
| `docs/plugins/hooks.md` | `after_tool` runs for a background call when it ends, and its `turn` is the turn it ended in |
| `docs/cli.md` | `arx ctl ID|last cancel CALL` under Controlling a session |
| `docs/concepts.md` | the turn loop: the inbox step also delivers results; a reply without tool calls waits while calls are in flight. Also fix "runs them one after the other", which has been wrong since the tool runtime |
| `docs/architecture.md` | the file table: `agent/background.c` |
| `plugins/README.md` | a `background` row |
| `plugins/background/plugin.yaml` | comments on the settings, as `never-stop` does |

## Dependencies

| Slug | What we share | Order |
|---|---|---|
| `acp-tui` | the `tool.run`, `tool.detach` and `tool.end` fields, the ACP mapping above, and `_arx/cancel_call` mapped to the inbox `cancel` line | land the events before or with `arx acp` |
| `long-lived-hooks` | the `ProcKeep` registry in `src/base/proc.c`: long-lived hook processes also need their pipes served during the model call. Concurrent `before_tool` hooks touch `Prepare` in `src/agent/tool_calls.c`, which step 3 moves. The scheduler protocol table in this plan holds their `waiting` and `done.ran`. The inbox dispatcher in `ReadInbox` handles their `answer` lines next to `result` and `cancel`. A call waiting for an `ask` answer can't move to the background | build the registry once, in whichever lands first; land step 3 before concurrent hooks; one `SchedDone` with `ran` |
| `mcp-client` | MCP server processes are session-lived children (the registry). An MCP tool call is a request on a shared connection, not a process, so a background MCP call needs a `ToolRun` that has no `ProcChild` | agree that `CallsPoll` asks a `ToolRun` if it is done, rather than polling a child |
| `plugin-yaml-keys` | `instructions` would let `plugins/background` explain background calls once, so the placeholder can drop its hint | optional; either order |
| `plugin-state` | none needed: the plugin keeps its state in its process, and the in-flight list is core state in `meta.json`. Its scheduler still gets `ARX_STATE_DIR` and `ARX_DATA_DIR` (`.arx/data/<name>/`) through `ToolEnv` | none |
| `climb` | a driver that stops a run with `arx ctl stop` gets `stopped` results for calls in flight | none |
| `trust`, `sandboxes`, `arx-plugin` | none; `plugins/background` installs with `arx plugin add` like any plugin | none |

## Size and risks

**Size: L.** About 600 lines of C across 12 files, a new `background.c`,
the plugin (about 150 lines of Python and a small tool), about 300 lines of
tests, and edits to 11 docs. The code isn't large, but it changes the loop's
end condition, the call table and resume.

| Risk | Mitigation |
|---|---|
| Moving the call table to the agent can break call order or `after_tool` on the hot path | step 3 is a pure refactor, landed alone, behind the existing runtime tests |
| A scheduler that holds a call and never starts it makes the run wait | the `wall` cap and Ctrl-C end it; a Common mistakes row; the plugin always starts held calls when a slot frees |
| Every result wakes a turn | results that end in the same poll share one note; `max` bounds the batch |
| Dropping `*` lets a background shell run beside foreground edits | documented; the model was told the call runs on; named keys still hold |
| Interactive users can't chat while a call runs, and Ctrl-C stops it | documented; the TUI over ACP is the place for a richer model |
| Serving registry children inside nested `ProcPoll` rounds | only `CallsPoll` finishes a call; registry callbacks only fill buffers |
| The terminal view mixes a background subagent's lines with streamed text | the view doesn't draw a background subagent's events |
| Large subagent answers grow the inbox file | the file is per session; one line per result |

## Open decisions

1. **Interactive mode: wait, or go back to the prompt?** With calls in
   flight, the turn waits for them before the prompt comes back. The other
   way lets you type while they run, but `getline` would have to join the
   poll loop. **Recommend: wait in 0.2.0**; revisit with the TUI, where ACP
   already allows updates during a prompt.
2. **Does Ctrl-C stop background calls?** **Recommend: yes.** It matches ACP
   `session/cancel`, it needs no new process flag, and no call outlives the
   turn that you stopped.
3. **Keys of a background call.** **Recommend: drop `*`, keep named keys.**
   Keeping `*` blocks every later call; dropping all keys loses the
   per-file lock.
4. **The plugin's default policy.** **Recommend: every subagent goes to the
   background (`agents: true`), and no tool does unless named.** The worst
   case is one wake turn when the model needs the answer at once.
5. **The model chooses per call** (a `background` argument added by a
   `before_model` hook). **Recommend: not in 0.2.0.** `ready.args` makes it
   a plugin change later, with no core change.
6. **Where the "how to wait" hint lives.** **Recommend: in the placeholder
   until `plugin-yaml-keys` lands, then in the plugin's `instructions`.**
7. **Delivery through the inbox file or memory.** **Recommend: the inbox
   file.** It gives `--resume` the results and keeps one ordered channel.
8. **Short ids from a session counter.** **Recommend: `cN` from
   `call_seq`.** The model's ids are long; tying ids to `tool-NNNN.out`
   fails for queued calls, which have no output file yet.
9. **`arx ctl ID result CALL TEXT`**, for work that a scheduler hands to
   another machine. **Recommend: not in 0.2.0.** A scheduler can already
   end a held call with `result`.
10. **A core cap on calls in flight** (`--cap background=N`). **Recommend:
    no.** The plugin's `max` covers it, and there is no core cap on parallel
    subagents today.
11. **`tool.run` for every call, or only background ones.** **Recommend:
    every call.** One rule, and front-ends can show calls that wait on keys.
12. **Wake once per result, or once all are in.** **Recommend: once per
    batch.** The model can act on the first answer; replying without a tool
    call waits for the next.
13. **The plugin's name.** **Recommend: `background`**, the word the model
    and the docs use; `async` reads as a language feature.
