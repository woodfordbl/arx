# Long-lived and concurrent hooks

Slug: `long-lived-hooks`. Plan for arx 0.2.0.

## Goal

Make hooks cheap to call often and able to wait without holding up the run:

- **Long-lived hooks**: a hook with `run: session` starts once for the
  session and reads one JSON request per line. It keeps its state in memory
  and starts no process for each call.
- **Concurrent hooks**: each tool call runs its own `before_tool` and
  `after_tool` chain. A call whose hook waits, for a slow check or for a
  person, holds up only that call and the later calls whose keys conflict
  with it.
- **Ask a person**: a `before_tool` hook can print `ask`. arx asks the
  person at the terminal, through `arx ctl`, or through `arx acp`, and runs
  the hook again with the answer. This is how `permissions: ask` works,
  through a new `ask` plugin. It is the only way arx asks a person
  (decided on 2026-11-09), and `arx acp` is one of its handlers.

All three are contracts on the existing hook runner and tool runtime. The
turn loop does not change shape.

## Current state

What exists today, at commit `c6a0908`:

- **One process for each hook run.** `RunOne` builds a `Proc` and calls
  `ProcRun`, which blocks until the hook exits
  (`src/harness/hooks.c:90-136`). The `timeout` option, 10 seconds by
  default (`hooks.c:98`), is a deadline on the whole process
  (`src/base/proc.c:169`, `proc.c:205-229`).
- **Chains.** `HookChain` loops over the three bands and then the layers,
  prints the object for each hook, and merges its answer
  (`hooks.c:366-394`). A `policy` result is final (`KeepResult`,
  `hooks.c:351-363`). `HookRun` does the same for `session_start` and `stop`
  (`hooks.c:186-213`).
- **`before_tool` holds every call of the reply.** `RunToolCalls` calls
  `Prepare` for each call in order (`src/agent/tool_calls.c:322-328`).
  `Prepare` runs the `before_tool` chain to the end before it returns
  (`tool_calls.c:211-239`, `BeforeTool` at `tool_calls.c:75-83`). Only then
  does `RunQueue` start any tool (`tool_calls.c:329`). One slow hook on
  call 1 delays every call.
- **`after_tool` blocks the runtime.** `Complete` runs the `after_tool`
  chain inside `RunQueue`'s loop (`tool_calls.c:169-185`,
  `tool_calls.c:97-118`). While it runs, arx reads no pipe of the other
  running tools. It clears `g_interrupted` around the chain so that Ctrl-C
  does not kill the hook (`tool_calls.c:108-112`).
- **The built-in scheduler** starts each queued call, in call order, whose
  keys conflict with no running call and no call queued before it
  (`tool_calls.c:244-259`, `KeysConflict` at `src/harness/keys.c:109`).
- **A long-lived precedent.** A scheduler plugin is one process for the
  session that speaks JSON lines: started with `open_in` and
  `keep_on_interrupt` (`src/agent/scheduler.c:85-111`), lines read in
  `SchedPoll` (`scheduler.c:187-215`), stderr dropped
  (`scheduler.c:35-39`), and never restarted after a failure
  (`scheduler.c:55-65`).
- **Process helpers.** `ProcStart`, `ProcWrite`, `ProcPoll` and
  `ProcFinish` already serve many children from one `poll()` loop
  (`proc.c:143-297`). Two parts are missing for a long-lived hook: a way to
  close stdin and let the child exit (`ProcFinish` sends SIGTERM at once,
  `proc.c:281-288`), and output past 1 MB (`BufferSink` stops at 1 MB,
  `src/base/util.c:115-118`). The 1 MB cap also applies to a per-call hook
  today, so a `before_model` hook that prints a history over 1 MB fails.
- **Hook options.** `kHook` has `timeout`, `fail`, `band` and `changes`
  (`src/harness/fields.c:41-46`). `band` is checked in
  `src/harness/validate.c:230-250`. `HookOptions` reads them from
  `plugin.yaml` or the spec (`hooks.c:47-50`). `changes` only feeds the
  `arx check` warning (`src/cli/check.c:79-120`).
- **Environment.** `HookEnv` is `ToolEnv` plus `ARX_PLUGIN_SETTINGS`
  (`hooks.c:73-85`, `src/harness/tool_exec.c:60-73`). `ARX_TURN` is fixed
  when the process starts (`tool_exec.c:65`).
- **Reload and lifecycle.** `MaybeReload` swaps the spec between turns
  (`src/agent/loop.c:44-78`). The signature covers `hooks/` and every
  `plugin.yaml` (`src/harness/signature.c:63-94`). `Start` opens the session
  (`src/agent/run.c:58-83`), `Begin` runs `session_start`
  (`run.c:86-102`), and `AgentMain` ends with `Finish` (`run.c:189-210`).
- **The inbox.** `arx ctl ID stop|note` appends a line to
  `<session>/inbox` (`src/cli/commands.c:83-107`). arx reads it once per
  turn (`src/io/session.c:161-181`, `loop.c:81-93`).
- **`arx check`** prints each point and the plugins that add a hook to it
  (`check.c:43-63`).
- **`permissions: ask`** exists only as a line in `docs/roadmap.md:43`.
  There is no code.

## Design

### The `run` option

A hook declares that it is long-lived with one new option:

```yaml
# plugin.yaml
hooks:
  before_tool: {run: session, band: policy, fail: closed, timeout: 5s}
```

| Option | Default | Meaning |
|---|---|---|
| `run` | `call` | `call` starts the hook each time the run reaches its point, as today. `session` starts it once for the session; it then reads one request per line. |

- **Where**: the spec's `hooks:` (for the spec and config folders) and
  `plugin.yaml`'s `hooks:`, the same as the other options.
- **Points**: all six. `before_tool` and `after_tool` gain the most.
- **Validation**: `hooks.<point>.run must be call or session`.
- **`arx check`**: a long-lived hook shows `[session]` after its plugin:
  `hooks: before_tool(guard,ask[session]) after_tool(fail-hint)`. A hook in
  the spec folder shows `before_tool[session]`.
- **Environment**: every hook gets `ARX_HOOK_RUN=call` or
  `ARX_HOOK_RUN=session`, so one script can serve both modes and a person
  can test it by hand.

**One process for each file.** arx keys a process by its layer and the real
path of the executable. Points of one layer whose files resolve to the same
file, such as `hooks/after_tool -> before_tool`, share one process when all
of them say `run: session`. Each request names its `point`. A point of that
file with `run: call` still starts a new process for each run.

### The line protocol

Both sides write compact UTF-8 JSON, one object per line, ending in `\n`.
The hook must flush stdout after each line. stdout carries answers only;
logs go to stderr.

Messages from arx, on the hook's stdin:

| Message | When | Shape |
|---|---|---|
| request | the run reaches the point | the input a per-call hook gets (the point's fields, plus `point`, `session` and `turn`), plus `"req": N` |
| cancel | arx no longer wants the answer: Ctrl-C, a timeout, or the session ends with requests open | `{"cancel": N}` |

Messages from the hook, on its stdout:

| Message | Shape |
|---|---|
| answer | `{"req": N, ...}` with the fields a per-call hook may print at that point. `{"req": N}` alone changes nothing. |

The rules:

- **`req`** is an integer that starts at 1 for each process and grows by 1
  for each request. arx never reuses one.
- **Order**: the hook can answer in any order. arx matches each answer to
  its request by `req`.
- **Late answers**: arx ignores an answer to a request that is not open
  (cancelled or timed out).
- **Unknown keys**: the hook must ignore keys and message kinds it doesn't
  know. A message with `point` is a request, and a message with `cancel` is
  a cancel. arx can add kinds later.
- **Blank lines** from the hook are ignored.
- **Line size**: up to 64 MB. A longer line is a bad line.
- **End of input**: stdin closes when the session ends. The hook saves what
  it must and exits.

An exchange with two calls, where the hook answers the second first:

```text
arx  → {"req":1,"point":"before_tool","session":"20261109-101500-a1b2","turn":3,"id":"call_1","name":"bash","args":{"command":"rm -rf build"},"keys":["*"]}
arx  → {"req":2,"point":"before_tool","session":"20261109-101500-a1b2","turn":3,"id":"call_2","name":"edit","args":{"path":"a.py","old":"x","new":"y"},"keys":["file:a.py"]}
hook → {"req":2}
hook → {"req":1,"decision":"deny","reason":"no rm -rf; ask the operator"}
```

A complete long-lived hook, for the docs:

```python
#!/usr/bin/env python3
# hooks/before_tool, with run: session: counts calls by tool name.
import json
import sys

counts = {}
for line in sys.stdin:
    message = json.loads(line)
    if "point" not in message:
        continue                    # a cancel, or a kind this hook doesn't know
    name = message["name"]
    counts[name] = counts.get(name, 0) + 1
    answer = {"req": message["req"]}
    if name == "bash" and counts[name] > 50:
        answer["result"] = "denied: 50 bash calls is the limit for this session"
    print(json.dumps(answer), flush=True)
```

### Startup, shutdown and reload

| Moment | What arx does |
|---|---|
| Session start, new or `--resume` | Starts every `run: session` hook of the active layers, in layer order, without waiting for them. This happens after the session folder opens and before the `session_start` hooks run, so the startup overlaps the first model call. |
| A request | Writes the line. If the process is not running (after a crash), starts it first. |
| Hot reload | After a reload that succeeded, arx compares each process with the new layers. It stops a process when its layer is gone, when no point uses its file with `run: session`, or when its file (path, modification time, size) or its environment changed. `ARX_TURN` does not count. It starts the hooks that are new. A process that did not change keeps running, with its state. A reload happens between turns, so no request is open. |
| Session end | Closes the stdin of every process, waits up to 2 seconds in all for them to exit, then stops each process group that is left (SIGTERM, then SIGKILL 3 seconds later). A reload stops a process the same way. |
| Between requests | arx reads the process's pipes in every poll round, also during the model call, so it sees a crash at once and the hook's stderr never fills its pipe. |
| Ctrl-C | The process keeps running: it is in its own process group, like a scheduler (`keep_on_interrupt`). arx sends `cancel` for each open request. |
| arx is killed | stdin closes, so a hook that exits at end of input exits. |

- **Environment**: the process gets `HookEnv` when it starts, plus
  `ARX_HOOK_RUN=session`. That includes `ARX_STATE_DIR`
  (`$ARX_SESSION_DIR/plugins/<name>/`) and `ARX_DATA_DIR`
  (`.arx/data/<name>/`) from slug `plugin-state`, and `ARX_SANDBOX` (slug
  `sandboxes`). A change to
  any of them restarts the process at the next reload, by the environment
  rule above.
- **`ARX_TURN`** is the turn when the process started. Read `turn` from each
  request instead.
- **State across `--resume`**: a resumed session gets new processes, and
  `session_start` does not run again. A hook that must remember across
  `--resume` writes to `ARX_STATE_DIR` as it goes and reads it when it
  starts.
- **Subagents**: each subagent is its own session, so it starts its own
  processes.

### Timeouts and crashes

| Case | The request | The process | `error` in the `hook` event |
|---|---|---|---|
| No answer within `timeout` (default 10 s, counted from when arx writes the line) | fails, as a per-call hook that timed out | keeps running; arx sends `{"cancel": N}` | `timed out` |
| An answer with a field of the wrong type | fails | keeps running | `printed a bad "args"` |
| The process cannot start | fails | counts as a crash | `could not start the hook` |
| The process exits | every open request fails | started again at the next request | `the hook exited (exit N): <last 300 bytes of stderr>` |
| A line that is not a JSON object, or has no integer `req` | every open request fails | arx stops it; started again at the next request | `printed a bad line: <first 200 bytes>` |
| The third crash in one session | that request and every later one fail at once | not started again until a reload changes its file or environment | `crashed 3 times; off until its file changes` |

- **`fail`** works per request, as today. With `fail: closed`, a failed
  `before_tool` request denies the call with
  `denied: the before_tool hook failed (fail: closed)`.
- **A `hook.process` event** marks each start, exit and stop:
  `{"type": "hook.process", "plugin", "path", "state": "start"|"exit"|"stop", "code", "error"}`.
- **stderr**: arx keeps the last 4 KB of each process's stderr for error
  text and drops the rest. A hook that needs a log writes it to a file in
  `ARX_STATE_DIR`.

### Concurrent `before_tool` and `after_tool`

Each call of a reply runs its own chain. The runtime starts a call as soon
as its own `before_tool` chain ends and its keys allow, without waiting for
the chains of the other calls. Each call's `after_tool` chain starts when
its tool ends and runs inside the runtime's `poll()` loop, so it no longer
stops arx from reading the other tools' output.

A call moves through these states:

```text
hooks ──► queued ──► running ──► after ──► done
  │ ▲                                       ▲
  ▼ │                                       │
asking            (a result, a deny or Ctrl-C ends the call here)
```

The other four points have one object at a time and run as they do today,
through the same engine.

### Ordering guarantees

What still holds:

1. **For one call, nothing changes.** Hooks run by band (`policy`, `normal`,
   `final`), then in layer order. Each gets the object as the hook before it
   left it. A `policy` result is final. A printed `result` ends the chain.
2. **One copy of a per-call hook at a time.** arx never runs two processes
   of one per-call hook at once. It gives a per-call hook the calls one at a
   time, in the order they reach it. With no waits, that is call order.
3. **A long-lived hook gets each request as soon as a call reaches it.** It
   can hold several requests and answer them in any order.
4. **Results go to the model in call order.** The transcript is the same as
   when the calls run one at a time.
5. **`after_tool` runs for every call that ran**, also after an error, a
   timeout or Ctrl-C. Ctrl-C does not stop its hook processes; their own
   timeout does. This replaces the `g_interrupted` swap at
   `tool_calls.c:108-112`.

What no longer holds:

- **No order across calls.** A later call's hooks, and its tool, can run
  while an earlier call waits in its hooks.
- **A tool can run before another call's `before_tool` hooks.** Today every
  `before_tool` hook of the reply runs before the first tool starts. Now a
  hook for call 3 can see the files after call 1's edit ran.

### Keys while a call is in its hooks

Keys keep conflicting calls in the model's order:

- **A held call.** A call in its `before_tool` hooks, or waiting for an
  answer, holds the keys it has now: the keys from the tool's schema, or
  the keys an earlier hook in its chain printed.
- **`changes: [keys]`.** If a hook that has not run yet for that call
  declares `changes: [keys]`, the call holds `["*"]` until that hook has
  run, because its keys can still change.
- **The built-in scheduler** treats a held call as a call queued before the
  later ones. A later call that conflicts with it waits, so calls that
  conflict still start in the model's order. A later call that does not
  conflict starts at once.
- **The final keys** apply when the chain ends, as `FinalKeys` does today
  (`tool_calls.c:60-71`).
- **A hook that widens keys without declaring it** can find a later
  conflicting call already running. arx does not stop that call. Its `hook`
  event gets `"warning": "keys changed after call_3 started"`.

So an approval wait on `bash`, whose keys are `["*"]`, still holds every
later call: `bash` runs alone and in order. The gain is for calls that don't
conflict: reads with `[]`, edits to other files, and subagents.

**A scheduler plugin** needs to know about held calls. The one scheduler
protocol table lives in `plans/0.2.0/async-calls.md`, which owns it (release
plan, "Settled across plans" item 5). This plan adds two entries to that
table and defines no messages of its own:

- **`waiting`**: a call entered its `before_tool` hooks and holds these keys.
  One for each call, in call order, when the reply arrives.
- **`ran` in `done`**: `false` for a call that ended in its hooks (a result,
  a deny, a cancel or Ctrl-C), so the scheduler can forget it. Today such a
  call sends no `done`.

Because of held calls, `ready` can now come out of call order. A scheduler
that ignores what it doesn't know keeps working.

### Ask a person

This contract is the one way arx asks a person, decided on 2026-11-09
(release plan, "Decisions" item 1). The terminal, `arx ctl` and `arx acp`
are its handlers. There is no other channel: the `arx acp ask` client and
its socket from the first `acp-tui` draft are dropped, and there is no
`permissions:` spec key.

A `before_tool` hook can print `ask` in place of a decision. arx asks a
person and runs the same hook again with the answer. The person's wait
happens in arx, not in the hook, so a per-call hook can ask too, and its
timeout stays short.

| Field | In the input | If the hook prints it |
|---|---|---|
| `ask` | no | arx asks a person, then runs this hook again for this call with `answer` |
| `answer` | only in the run after an ask | ignored |

```json
{"ask": {"title": "Run bash: rm -rf build",
         "options": [{"id": "once", "label": "Allow", "kind": "allow_once"},
                     {"id": "always", "label": "Always allow bash", "kind": "allow_always"},
                     {"id": "no", "label": "Deny", "kind": "reject_once"}],
         "timeout": 600}}
```

- **`title`**: a string. The default is the call's `tool.start` preview,
  such as `bash: rm -rf build`.
- **`options`**: a list of `{id, label, kind}`. `id` uses letters, digits,
  `_` and `-`, and is unique in the list. `kind` is one of the ACP kinds:
  `allow_once`, `allow_always`, `reject_once` or `reject_always`. arx gives
  them to the front-end and does not act on them; the hook does. The
  default is
  `[{"id":"allow","label":"Allow","kind":"allow_once"},{"id":"deny","label":"Deny","kind":"reject_once"}]`.
- **`timeout`**: seconds to wait for an answer. The default is no limit:
  arx waits until an answer or Ctrl-C.
- **Only at `before_tool`.** Other points ignore `ask`, as they ignore any
  field they do not list.
- **With other fields**: `name`, `args` and `keys` apply first. A `result`
  or a deny ends the chain, and the `ask` is ignored.
- **A bad `ask`** (not an object, or bad options) fails the hook, so `fail`
  decides.

What arx does with an ask:

1. The call moves to `asking`. It holds its keys. The hook is free for other
   calls: a per-call hook has exited, and a long-lived hook has answered
   the request.
2. arx writes an `ask` event and hands the ask to whoever answers (see
   `--ask` below).
3. When the answer comes, arx writes an `ask.end` event and runs the same
   hook again for this call. The input is the object as it was, plus
   `"answer": {"option": "<id>"}`, or
   `"answer": {"cancelled": true, "why": "timeout"}` (or
   `"why": "no one to ask"`, or `"why": "dismissed"` when the person closed
   the ask without a choice).
4. The hook decides as usual: print nothing to let the call run, print a
   `result` or a deny, or ask again. A hook can ask at most 3 times for one
   call; a fourth `ask` fails the hook.
5. On Ctrl-C, arx closes each open ask (`ask.end` with
   `"cancelled": true, "why": "interrupted"`) and ends the call with
   `[interrupted before this tool ran]`. It does not run the hook again.
6. On a `cancel` line for that call in the inbox (from `async-calls`:
   `arx ctl ID cancel CALL`), arx closes the ask (`ask.end` with
   `"why": "cancelled"`) and ends only that call with
   `[cancelled before this tool ran]`. The same applies to a call that is
   still in its hooks.

**Order of events**: for each call, arx writes `tool.start` before any `ask`
for it, and `ask.end` before its `tool.end`. A call has at most one open ask
at a time, because one hook works on a call at a time.

**Who answers** depends on the new `--ask` flag:

| `--ask` | Who answers | Default when |
|---|---|---|
| `terminal` | The person at the terminal. arx prints the title and numbered options on stderr and reads the number from stdin. `arx ctl` can answer too. | stdin and stderr are terminals, the view is on (no `-q`), and the prompt did not come from stdin |
| `ctl` | Whoever writes an `answer` line to the session's inbox: `arx ctl`, or a front-end such as `arx acp` | never; the front-end or you set it |
| `none` | Nobody. arx answers `cancelled` with `"why": "no one to ask"` at once. | every other run |

**Subagents** ask through their parent. A subagent gets `--ask ctl` when its
parent's mode is `terminal` or `ctl`, and `--ask none` when it is `none`.
Its `ask` events reach the parent's stream with the subagent's `session` and
`depth`, as all its events do (`EventForward`, `src/io/events.c:121`). An
answer goes to the subagent's own inbox: `arx ctl SUBAGENT_SESSION answer
CALL OPTION`. A parent in `terminal` mode prompts for its subagents' asks
too, and writes each answer to that subagent's inbox.

The terminal prompt shows one ask at a time, in the order they came:

```text
? bash: rm -rf build
  1 Allow   2 Always allow bash   3 Deny
  answer:
```

An empty line or a bad number asks again. Ctrl-C works as it does today.

**`arx ctl ID|last answer CALL_ID OPTION_ID`** appends
`{"cmd": "answer", "call": "call_2", "option": "once"}` to the inbox.
**`arx ctl ID|last answer CALL_ID --cancel`** appends
`{"cmd": "answer", "call": "call_2", "cancelled": true}`: the person
dismissed the ask without a choice. arx then writes `ask.end` with
`"cancelled": true, "why": "dismissed", "by": "ctl"`, and runs the hook again
with `"answer": {"cancelled": true, "why": "dismissed"}`, as for a timeout.

- **Polling**: while an ask is open, arx reads the inbox every 20 ms (one
  `stat`, then a read when the size grew), so a front-end that answers at
  once adds little to the call.
- **Bad lines**: an answer for a call with no open ask, with an unknown
  option, or with neither `option` nor `cancelled`, writes an `error` event
  and changes nothing. The first answer wins.
- **Use the session id, not `last`**: a subagent's session also moves
  `.arx/sessions/last`, so a front-end answers by the `session` of the
  `ask` event.

**Events** (each also has `session`, `depth` and `turn`, as every event
does):

| Event | Fields |
|---|---|
| `ask` | `call` (the tool call id), `name` (the tool), `args` (the call as the asking hook got it), `plugin` (the `name` in the layer's `plugin.yaml`, for a plugin and for a policy folder), `policy: true` (for a policy folder's hook, as `trust` marks its `hook` events), `title`, `options`, `timeout` |
| `ask.end` | `call`, then `option` and `by` (`terminal` or `ctl`), or `cancelled: true` and `why` (`timeout`, `no one to ask`, `dismissed`, `interrupted` or `cancelled`) |

`args` is there because a `policy` hook before the asking hook may have
changed the call. The person approves the call as it is at the ask. A
`normal` hook that rewrites it later still shows as `[ran as: ...]`.

### `arx acp` as an ask handler

`arx acp` (slug `acp-tui`) is one handler of this contract, not a second
mechanism. It drives one `arx --input jsonl` child for each ACP session, so
it uses the `ctl` path:

- **It starts each child with `--ask ctl`** and with the `ask` plugin as a
  policy layer (`--policy`, slug `trust`), so the agent can't turn it off.
  `trust` passes `--policy` on to subagents, and this plan passes
  `--ask ctl` on to them.
- **It reads `ask` events on fd 3** and answers by appending the `answer`
  line to the inbox of the event's `session`. For a subagent's ask, that is
  the subagent's inbox. `arx acp` writes the line itself or runs
  `arx ctl`; the line is the same.

What it needs from the contract, and where the contract gives it:

| ACP need | What arx gives |
|---|---|
| Send `tool_call` before `session/request_permission` | `tool.start` (`id`, `name`) comes before the call's `ask`, also for a subagent's call, whose events are forwarded. The `ask` event repeats `call` and `name`, and adds `args`, `session` and `depth`, so `arx acp` can build the `toolCall` from the ask alone when it needs to. |
| Map the request | `call` is `toolCallId`. Each option's `id`, `label` and `kind` are `optionId`, `name` and `kind`; the kinds are ACP's. A `selected` outcome becomes `{"cmd":"answer","call":CALL,"option":OPTION_ID}`. A `cancelled` outcome, or one `arx acp` doesn't know, becomes `{"cmd":"answer","call":CALL,"cancelled":true}`; if `session/cancel` already closed the ask, arx drops that line with an `error` event. |
| Subagent sessions | A subagent runs in its parent's working folder, so its session is in the same `.arx/sessions/` (`src/io/session.c:14`); answer into `.arx/sessions/<event session>/inbox`. |
| Tell the `ask` plugin from other askers | `plugin: "ask"` with `policy: true`. In mode `allow`, `arx acp` answers only those at once, and sends asks from any other hook to the client. |
| "Always allow" for each ACP session | One ACP session is one arx session, plus its subagents. The `ask` plugin remembers "always" for its arx session (in memory and in `ARX_STATE_DIR`, so `session/load` keeps it). For the subagents, `arx acp` keeps the choices of its ACP session by tool `name` and option `kind`. A later ask for that tool, from the parent or a subagent, it answers at once with that ask's option of the same kind, without asking the client. |
| `session/cancel` closes open asks | `session/cancel` is one SIGINT to the child, the Ctrl-C path. arx writes `ask.end` with `"why": "interrupted"` for each open ask, in the parent and in each subagent, and ends those calls. ACP has the client answer the pending request with `cancelled`, and `arx acp` drops that answer. |
| Close one ask | A per-call cancel (`cancel CALL` in the inbox, from `async-calls`) ends that ask with `"why": "cancelled"`. An ask `timeout` ends it with `"why": "timeout"`. Each writes `ask.end`; ACP has no message to withdraw a request, so `arx acp` drops the client's later answer. |
| Mode `allow` | `arx acp` answers each ask of the `ask` plugin at once with its `allow_once` option. The 20 ms inbox read bounds the delay. |

Mode `ask` in `arx acp` waits for part 3 of this plan (steps 5 and 6) and
for `trust`. Until both land, `arx acp` ships with mode `allow` only.

### The `ask` plugin: `permissions: ask`

`permissions: ask` is a plugin, not a spec key. `plugins/ask` is a
long-lived `before_tool` hook in the `policy` band:

```yaml
# plugins/ask/plugin.yaml
name: ask
version: 0.1.0
description: Asks a person before a tool call runs.
hooks: {before_tool: {run: session, band: policy, fail: closed, changes: [result]}}
```

Its hook is one line, `exec "$ARX_BIN" hook ask`: the code is in the arx
binary, as `bash` and `edit` are, so it needs no other program.

Its settings, from the active list:

```yaml
enable:
  - ask: {tools: [bash, edit], allow: ["bash:git status", "bash:ls"], timeout: 600}
```

| Setting | Default | Meaning |
|---|---|---|
| `tools` | every call whose `keys` are not `[]`, so read-only tools and subagents run without a yes | The tools that need a yes. |
| `allow` | none | Calls that need no yes: `<tool>`, or `<tool>:<start of the preview>`. The preview is the `command`, `path` or `task`. |
| `timeout` | none | Seconds before an ask ends as `cancelled`. |

- **Options**, the four that `arx acp` shows: `allow` "Allow"
  (`allow_once`), `allow-always` "Always allow `<tool>` in this session"
  (`allow_always`), `reject` "Reject" (`reject_once`), and `reject-always`
  "Always reject `<tool>` in this session" (`reject_always`).
- **Memory**: an "always" choice lasts for the arx session. The hook keeps
  it in memory and in `$ARX_STATE_DIR/choices.json` when `ARX_STATE_DIR` is
  set, so `--resume` keeps it. An "always reject" denies at once with
  `denied: rejected for this session`.
- **A reject**: the deny `denied: rejected by the person`.
- **No answer**: `cancelled` becomes the deny
  `denied: no one approved this call`.
- **Headless runs**: with `--ask none`, every call that needs a yes is
  denied at once. That is the safe default for a run that no one watches.

Two ways to turn it on:

- **At the terminal or with `arx ctl`**: enable the plugin, or pass it with
  `--policy` so the agent can't turn it off.
- **Through `arx acp`**: `arx acp` passes it with `--policy` and
  `--ask ctl` (see the section above). It uses the copy that ships next to
  the binary, as `shell` does (`libexec/arx/plugins/ask`), so it can't
  drift from arx.

## Implementation steps

Each step keeps `make test` and `make lint` green. `make lint` allows 400
lines per file (`scripts/lint.sh:44-49`), so the new code goes in new files.

This plan builds on three steps of sibling plans. Whichever plan lands first
builds them, once:

- `trust` step 1 splits `src/harness/hooks.c` into `hooks.c` and
  `chain.c`, and exports `HookRunOne` and `HookPath`.
- `async-calls` step 1 adds `ProcKeep`, `ProcRelease` and `ProcStop` to
  `src/base/proc.c`: a registry of session-lived children that every
  `ProcPoll` round serves.
- `async-calls` step 3 moves the call table onto `Agent` and splits
  `RunQueue` into `CallsPoll`.

1. **Line helpers** (`src/base/proc.c`, `src/base/util.c`, `src/base/base.h`).
   - Long-lived hook processes go in the `ProcKeep` registry, so arx reads
     their pipes and sees a crash in every poll round, also during the model
     call.
   - `ProcClose(ProcChild*)`: close stdin and let the child exit. Used by the
     graceful stop, before `ProcStop`.
   - `LineSink`: a `DataFn` without the 1 MB cap, up to 64 MB, and
     `LinePop(Buffer*)`, which returns the next complete line.
   - `ProcPoll` takes one extra file descriptor to watch, for the terminal
     answer. Pass `-1` for none.
   - Move `scheduler.c`'s line reading (`scheduler.c:187-203`) onto
     `LinePop`. No behavior change.
   - Per-call hook output (`hooks.c:92-103`) uses `LineSink`, so it is no
     longer cut at 1 MB.

2. **A hook engine that does not block** (new `src/harness/hook_task.c`,
   `src/harness/hooks.c`, `src/harness/chain.c`, `src/harness/harness.h`).
   - `HookTask`: one chain over one object, run as steps. API:
     `HookTaskStart(a, point, object)`, `HookTaskKids(task, kids, max)` for
     `ProcPoll`, `HookTaskStep(task)` (returns 1 when done),
     `HookTaskResult(task)`, `HookTaskCancel(task)` and `HookTaskFree(task)`.
   - A registry of busy per-call hooks keyed by layer and point, with a FIFO
     of waiting tasks, so one hook runs one process at a time.
   - `Apply`, `Merge`, `Legacy` and `KeepResult` stay in `chain.c`, and
     `Combine` in `hooks.c`. A step starts `HookRunOne`'s process with
     `ProcStart` in place of `ProcRun`. `HookRun` and `HookChain` become
     wrappers that start a task and step it until it is done.
   - No behavior change. `tests/hooks.sh` must pass unchanged.

3. **Concurrent calls** (`src/agent/tool_calls.c`, `src/agent/scheduler.c`,
   `src/agent/agent.h`).
   - States `kHooks`, `kAsking` and `kAfter` next to `kQueued`, `kRunning`
     and `kDone`.
   - `Prepare` starts the call's `before_tool` task and returns.
   - `CallsPoll` (from `async-calls`) steps every task, moves calls whose
     chain ended to `kQueued` (or ends them), and adds the tasks' children
     to `ProcPoll`.
   - `StartByKeys` treats `kHooks` and `kAsking` calls as queued before the
     later calls, with their held keys, or `["*"]` when a hook still to run
     declares `changes: [keys]`.
   - `Complete` starts the `after_tool` task. The call reaches `kDone` and
     `SchedDone` when the task ends. Remove the `g_interrupted` swap; start
     `after_tool` hook processes with `keep_on_interrupt`.
   - Ctrl-C: cancel the tasks of `kHooks` and `kAsking` calls and end those
     calls with `[interrupted before this tool ran]`.
   - Scheduler: `SchedWaiting(id, name, keys)` sends `waiting`; `SchedDone`
     gains `ran`.
   - The key warning: in `FinalKeys`, when the new keys conflict with a
     later call that already started, add `warning` to the last `hook`
     event of the chain.

4. **Long-lived hooks** (new `src/harness/hook_live.c`,
   `src/harness/hook_task.c`, `src/harness/fields.c`,
   `src/harness/validate.c`, `src/harness/hooks.c`, `src/agent/run.c`,
   `src/agent/loop.c`, `src/cli/check.c`).
   - `run` in `kHook` (`fields.c:41-46`), checked like `band`
     (`validate.c:230-250`).
   - The hook environment adds `ARX_HOOK_RUN` on top of `PluginEnv` (the
     shared plugin environment from `async-calls` step 2), so schedulers
     do not get it.
   - `hook_live.c`: the processes keyed by layer and real path; start with
     `open_in`, `keep_on_interrupt` and `LineSink`, then `ProcKeep`; `req`
     numbers; `HookLiveSend` and `HookLiveCancel`; deadlines per request;
     reading
     answers and handing them to the waiting `HookTask`; the crash count;
     the stderr tail; the `hook.process` event.
   - `HookLiveOpen(a)` starts and reconciles the processes. Call it in
     `Start` after the session opens (`run.c:58-83`, before `Begin`), and in
     `MaybeReload` after a reload that succeeded (`loop.c:59-74`).
   - `HookLiveClose(a)` stops them all. Call it in `AgentMain` after
     `Finish` (`run.c:202`).
   - `hook_task.c`: a step whose hook is long-lived sends the request and
     waits for its answer, not a process.
   - `check.c:43-63`: print `[session]`.

5. **Ask a person** (new `src/agent/ask.c`, `src/agent/agent.h`,
   `src/harness/hooks.c`, `src/harness/hook_task.c`,
   `src/agent/tool_calls.c`, `src/cli/options.c`, `src/cli/commands.c`,
   `src/io/render.c`).
   - `hooks.c`: `ask` in `before_tool`'s fields (`hooks.c:29`), with a
     type check in `FieldOk`.
   - `hook_task.c`: a step that gets `ask` ends with "asking". `Resume`
     runs the same hook again with `answer`. Count asks per hook and call.
   - `ask.c`: the open asks, the `ask` and `ask.end` events (with `call`,
     `name` and `args`), the three modes, the timeout per ask, and one
     internal `AskAnswer(call, option)` that the terminal prompt and the
     inbox both use. No handler API for other code: `arx acp` runs in its
     own process and answers through the inbox.
   - The inbox: `SessionReadInbox` moves an offset, so one reader must
     handle every command. `ReadInbox` (`loop.c:81-93`) becomes the one
     dispatcher for `stop`, `note`, `answer`, and the `cancel` and `result`
     lines of `async-calls`. The runtime calls it every 20 ms while an ask
     is open, and as `async-calls` says while only a background call is
     open; a `note` still waits for the next turn. A `cancel` for a call in
     `kHooks` or `kAsking` ends that call.
   - `tool_calls.c`: `kAsking`, and the terminal descriptor in `ProcPoll`
     when the mode is `terminal`.
   - `options.c`: `--ask terminal|ctl|none` and its default; usage text.
   - `commands.c`: `arx ctl ID|last answer CALL OPTION`
     (`commands.c:83-107`).
   - `render.c`: draw `ask` and `ask.end`, and the prompt.
   - Subagents: add `--ask ctl` or `--ask none` to the subagent's command
     line (`src/harness/tool_exec.c:107-113`), next to the `--policy` that
     `trust` adds there. In `terminal` mode, `EventForward`
     (`src/io/events.c:121`) hands a subagent's `ask` event to the prompt,
     which answers into that subagent's inbox.

6. **The `ask` plugin** (`plugins/ask/plugin.yaml`,
   `plugins/ask/hooks/before_tool`, `plugins/ask/README.md`,
   `plugins/README.md`, new `src/cli/ask_hook.c`, `src/cli/commands.c`,
   `Makefile`).
   - The hook is built in, as `bash` and `edit` are (`shell_tools.c`):
     `hooks/before_tool` is `exec "$ARX_BIN" hook ask`. So the plugin needs
     no python3 on an editor user's machine, and can't drift from the
     binary that `arx acp` runs.
   - `src/cli/ask_hook.c`: a long-lived line loop with the settings and the
     four options above. It reads `ARX_PLUGIN_SETTINGS` once at start, and
     `$ARX_STATE_DIR/choices.json` when it exists.
   - `make install` and the release put a copy in
     `libexec/arx/plugins/ask`, next to `shell`, for `arx acp` to pass with
     `--policy`. `arx plugin` installs it like any plugin.
   - Nothing in `commands/` changes.

7. **Docs**: see Docs to change.

## Tests

Add to `tests/hooks.sh` (long-lived hooks, with a helper `live PATH` like
`hook PATH` that writes a Python line loop):

| Case | Check |
|---|---|
| One process for many calls | three `before_tool` requests; the hook writes its pid to a file each time; one pid, and one `hook.process` start |
| State | the hook counts requests and puts the count in a `result`; the third call sees 3 |
| Out of order | the hook holds `req` 1 until `req` 2 arrives, then answers 2 then 1; both calls get the right change |
| `req` and fields | the request has `req`, `point`, `session` and `turn`; `ARX_HOOK_RUN=session` |
| Timeout, fail open | the hook never answers one call; the call runs after `timeout: 1s`; the hook got `{"cancel": 1}`; the pid is unchanged |
| Timeout, fail closed | the same with `fail: closed`; `denied: the before_tool hook failed (fail: closed)` |
| Crash and restart | the hook exits after its first answer; the second call gets a new pid; `the hook exited` in the event |
| Crash budget | the hook exits at once; after 3 crashes the event says `crashed 3 times`, and no new pid appears |
| Bad line | the hook prints `hello`; `printed a bad line: hello`; a new process next time |
| Reload keeps it | a `before_tool` turn, then a tool call that edits an unrelated file; same pid |
| Reload restarts it | the agent's edit changes the hook file; new pid, and the old process saw end of input |
| Settings restart it | a change to the plugin's settings restarts it |
| Shutdown | the hook writes `bye` on end of input; the file has `bye` after the run |
| Shared file | `hooks/after_tool` links to `hooks/before_tool`, both `run: session`; one pid; requests with both points |
| Decision points | `session_start` and `stop` as long-lived hooks: context joins, `continue` works |
| Big answer | a long-lived `before_model` hook prints 2 MB of messages; the request has them. The same for a per-call hook (the 1 MB cap is gone). |
| `arx check` | `before_tool(p[session])`; `run: forever` is a problem |

Add to `tests/runtime.sh` (concurrency, with `nap` and a hook that sleeps
for one call):

| Case | Check |
|---|---|
| A waiting call holds only itself | call 1 (`nap`, keys `["file:a"]`) has a hook that sleeps 2 s; call 2 (`nap`, `[]`) starts and ends first; `log.txt` order |
| Conflicts keep order | call 2 has keys `["file:a"]`; it waits for call 1's hook and tool; order `start-1 end-1 start-2 end-2` |
| `*` holds everything | call 1 is `bash`; call 2 waits |
| `changes: [keys]` holds `*` | a later hook declares `changes: [keys]`; call 2 waits even with `[]` |
| One copy of a per-call hook | a per-call hook takes a lock file and fails if it is taken; three calls; no failure |
| A long-lived hook gets requests at once | the hook logs arrival times; three requests arrive before the first answer |
| Results in call order | `result_ids` is `call_1 call_2 call_3` when call 3 ends first |
| `after_tool` does not block | call 1's `after_tool` sleeps 2 s; call 2's tool output (over 64 KB) is read and call 2 ends meanwhile |
| Ctrl-C while in hooks | SIGINT during a hook's sleep; the waiting calls end with `[interrupted before this tool ran]`; a long-lived hook got `cancel` and still runs |
| `after_tool` after Ctrl-C | the existing case still passes without the `g_interrupted` swap |
| Scheduler messages | the scheduler log has `waiting` for each call in order, `ready` out of order, and `done` with `ran: false` for a denied call |
| Key warning | an undeclared hook widens call 1's keys after call 2 started; the `hook` event has `warning` |

Add `tests/ask.sh` (new):

| Case | Check |
|---|---|
| `--ask none` | a hook prints `ask`; it runs again at once with `"cancelled": true, "why": "no one to ask"`; events `ask` and `ask.end` |
| `--ask ctl`, allow | run in the background; wait for the `ask` event; `arx ctl last answer call_1 once`; the hook got `"option": "once"`; the tool ran |
| `--ask ctl`, deny | answer `no`; the result is the hook's deny |
| Other calls go on | call 1 asks; call 2 (`[]`) ends before the answer |
| Ask timeout | `"timeout": 1`; `"why": "timeout"` after about 1 s |
| Ctrl-C | SIGINT while asking; `ask.end` with `"why": "interrupted"`; the hook did not run again |
| Bad answers | an unknown call and an unknown option each write an `error` event; the ask stays open |
| Dismissed | `arx ctl ID answer call_1 --cancel`: `ask.end` with `"why": "dismissed"`; the hook ran again with that answer |
| Policy marker | the `ask` plugin passed with `--policy` (when `trust` has landed): the `ask` event has `"plugin": "ask"` and `"policy": true`; a spec-folder hook's ask has neither |
| Ask limit | a hook that always asks fails on the fourth |
| Bad `ask` | `"options": []` fails the hook; `fail: closed` denies |
| Not at other points | an `after_tool` hook that prints `ask` changes nothing |
| Terminal | under `python3 -c 'import pty; ...'`, the prompt shows and `2` selects the second option |
| Event order and fields | for each call, `tool.start` comes before `ask`, and `ask.end` before `tool.end`; `ask` has `call`, `name`, `args`, `session` and `depth` |
| Cancel one call | `arx ctl last cancel call_1` while it asks: `ask.end` with `"why": "cancelled"`; call 1 ends with `[cancelled before this tool ran]`; call 2 runs |
| Subagent asks | a subagent's `before_tool` hook asks; with `--ask ctl` on the parent, the parent's stream has the `ask` with the subagent's `session` and `depth` 1; `arx ctl SUBAGENT answer call_1 allow` lets it run. With `--ask none`, the subagent's ask is cancelled at once. |
| Subagent asks, Ctrl-C | SIGINT to the parent while a subagent asks: the subagent's `ask.end` with `"why": "interrupted"` reaches the parent's stream |
| An ACP-style handler | a small script reads the `--events` stream and answers every `ask` at once into the inbox of the event's `session`, choosing the `allow_once` option; three calls run; each ask closes within 100 ms |
| The `ask` plugin | `allow` skips the ask; the four options have the ACP kinds; `allow-always` skips the next ask for that tool and `reject-always` denies it at once; `--ask none` denies; `$ARX_STATE_DIR/choices.json` survives `--resume` (when `plugin-state` has landed); as a `--policy` layer (when `trust` has landed), editing `plugins:` does not remove it |

Add to `tests/cli.sh`: `--ask maybe` is a usage error; `arx ctl last answer`
without an option is a usage error.

## Docs to change

Each page follows `docs/WRITING.md`: lead with the answer, name the
mechanism and the numbers, short sentences, no em dashes.

- **`docs/plugins/hooks.md`** (guide):
  - "Where hooks run in a turn": step 4 becomes "`before_tool` runs for
    each call on its own"; step 6 says `after_tool` runs as each call ends,
    without holding the others.
  - "Contract": add `ARX_HOOK_RUN`, and a row for `run`.
  - New section "Long-lived hooks": when to use one (state, cost, a large
    Python import), `run: session`, the line protocol with the exchange and
    the counting hook, startup, shutdown, reload, and one file for several
    points.
  - New section "Ask a person": the `ask` output, the second run with
    `answer`, `--ask`, and a short example hook.
  - "More than one hook": the ordering rules across calls, and the one-copy
    rule.
  - "When a hook fails": the long-lived table.
  - "Common mistakes": a long-lived hook that does not flush; one that
    prints logs to stdout (a bad line restarts it); one that does not exit
    at end of input; one that reads `ARX_TURN`; a hook that changes keys
    without `changes: [keys]`.
  - Remove the "Planned" section.
- **`docs/plugins/tools.md`** (guide), "Keys": a call in its hooks holds its
  keys; `changes: [keys]` makes it hold `*`; an approval on `bash` still
  holds the later calls.
- **`docs/plugins/schedulers.md`** (guide): "How tool calls run" (steps 1
  to 3). The message tables come from the one protocol table in
  `async-calls.md`, which includes `waiting` and `ran`.
- **`docs/plugins/reference.md`** (reference): `run` under
  "Hook options"; `ARX_HOOK_RUN` under "Environment"; the events `hook`
  (`req`, `warning`), `hook.process`, `ask` and `ask.end`; the `[session]`
  mark in the `arx check` output.
- **`docs/cli.md`** (reference): `--ask` (and that subagents get `ctl` or
  `none` from their parent), `arx ctl ... answer`, and `arx hook ask` next
  to `arx tool bash|edit`.
- **`docs/plugins/concepts.md`** (concept), the Key section
  (`concepts.md:243`): calls in their hooks hold their keys.
- **`docs/plugins/planned.md`** (project): remove the row and the section
  "Long-lived and concurrent hooks".
- **`docs/roadmap.md`** (project): the `permissions: ask` line becomes the
  `ask` plugin and `--ask`.
- **`plugins/README.md`** and **`plugins/ask/README.md`**: the new plugin.

## Dependencies

| Slug | What we share | Order |
|---|---|---|
| `acp-tui` | The ask contract is the one way to ask a person, and `arx acp` is one of its handlers (Decisions item 1). `arx acp` starts each child with `--ask ctl` and the `ask` plugin as `--policy`, maps `ask` events to `session/request_permission`, answers into the inbox of the event's `session`, and keeps "always" choices for its ACP session. `session/cancel` is the Ctrl-C path, which closes open asks. The `arx acp ask` client and its socket are dropped. See "`arx acp` as an ask handler". | Mode `ask` in `arx acp` waits for this plan's part 3 (steps 5 and 6) and for `trust`; until then `arx acp` ships with mode `allow` only. This plan file supersedes the earlier note `long-lived-hooks-ask-contract.md`, which still lists an in-process handler API that is now dropped. |
| `plugin-state` | `ARX_STATE_DIR` for the `ask` plugin's memory and for any long-lived hook that must survive `--resume`. Both plans change `ToolEnv` and `HookEnv` (`tool_exec.c:60-73`, `hooks.c:73-85`); I add `ARX_HOOK_RUN`. The restart rule compares the whole environment, so their variables need no extra code here. | `plugin-state` first, as its plan proposes. Without it, the `ask` plugin keeps "always" in memory only. |
| `async-calls` | Three pieces. (1) Their `ProcKeep`, `ProcRelease` and `ProcStop` registry in `proc.c` holds long-lived hook processes. (2) Their call table on `Agent` and `CallsPoll` in `tool_calls.c` are where concurrent hooks go. (3) The inbox: `answer` joins their `cancel` and `result` lines in one dispatcher. A call that does not block still runs its `before_tool` chain first, and its `after_tool` chain on the real result can use the `HookTask` engine. The scheduler protocol has one table, in `async-calls.md`, which they own; this plan's `waiting` and `done.ran` go into it (Settled item 5). | Their steps 1 and 3 land before this plan's steps 1 and 3. |
| `mcp-client` | A long-lived child that speaks JSON lines. `LineSink`, `LinePop` and `ProcClose` (step 1) serve MCP servers too. MCP tools run through `before_tool` like any tool, so the `ask` plugin covers them. | Step 1 first, or whichever lands first owns the helpers. |
| `trust` | Their step 1 splits `hooks.c` (394 lines; the lint limit is 400) into `hooks.c` and `chain.c`, and exports `HookRunOne`; this plan's engine builds on that split. The `harness_edit` hook point runs through the same engine and can be long-lived. The `ask` plugin belongs in a policy folder (`--policy`) when the agent must not turn it off. The reload rule applies to policy layers too. | Their step 1 lands before this plan's step 2. |
| `sandboxes` | `ARX_SANDBOX` reaches long-lived hooks at start. A change restarts them at the next reload. | Independent. |
| `plugin-yaml-keys` | Both add keys to `fields.c` (`run` in `kHook`, their keys in `kPluginFields`). | Independent; a small merge. |
| `arx-plugin` | Lists the `ask` plugin in `index.yaml`. | After step 6. |
| `climb` | Runs headless, so asks are `none` there. Nothing shared. | Independent. |

## Size and risks

**Size: L.** It splits into three parts that land one after another:

| Part | Steps | Size |
|---|---|---|
| The engine and concurrent calls | 1, 2, 3 | M |
| Long-lived hooks | 4 | M |
| Ask and the `ask` plugin | 5, 6 | M |

Risks:

- **The engine rewrite touches every hook point.** All six points move onto
  `HookTask`. Mitigation: step 2 changes no behavior and must pass the
  existing `tests/hooks.sh` and `tests/runtime.sh` before step 3 starts.
- **A hook that relies on call order.** A hook that counts the calls of a
  reply, or reads files that an earlier call's tool writes, can see a
  different order. Mitigation: the one-copy rule keeps per-call hooks in
  arrival order; the docs say what changed.
- **Keys that a hook widens.** A hook that adds keys without
  `changes: [keys]` can let a later conflicting call start first. The
  warning event makes it visible, but does not prevent it.
- **Ctrl-C paths.** Calls can now be in five states when Ctrl-C comes. Each
  state needs a test; the runtime tests above cover them.
- **A long-lived hook with a leak or a hang.** A hang costs `timeout` on
  every request until the process exits. The crash budget covers exits, not
  hangs. Keep the default `timeout` at 10 seconds.
- **The terminal prompt** reads stdin during a turn. It must not take input
  meant for the next message in interactive mode. It reads only while an
  ask is open, one line for each answer.
- **Pipe buffers.** A long-lived hook that never reads stdin blocks arx's
  writes. `ProcWrite` queues and writes without blocking, so arx keeps
  going, but memory grows. A request that times out does not drain the
  queue.

## Open decisions

Decided on 2026-11-09 (release plan, "Decisions" and "Settled across
plans"):

- **Where the person's wait happens: the `ask` output.** The hook prints
  `ask`, and arx asks and runs the hook again with `answer`. It is the only
  way arx asks a person, and `arx acp` is one of its handlers. The
  askpass-style `ARX_ASK` program and the `arx acp ask` socket are dropped.
- **No `permissions:` spec key.** The agent can write the spec, so the mode
  comes from the `ask` plugin, `--policy`, `--ask` and the front-end.
- **Scheduler messages** go into the one table that `async-calls` owns.
- **`ARX_DATA_DIR` is `.arx/data/<name>/`.**

Still open, each with a recommendation that stands unless someone objects:

1. **Asks from a terminal parent's subagents.** **Recommend that the parent
   prompts for them** (the `ask` arrives through `EventForward`, the answer
   goes into the subagent's inbox). The other choice is `--ask none` for the
   subagents of a terminal run, which denies their asks. For `ctl` parents,
   such as `arx acp`, subagents always get `--ask ctl`.
2. **Concurrency by default.** **Recommend on for every hook, with no
   opt-out in 0.2.0.** The one-copy rule keeps existing per-call hooks safe.
   Add a `serial: true` option later if a real hook needs it.
3. **Parallel copies of a per-call hook.** **Recommend one copy at a
   time.** Parallel copies would break hooks that append to one file. A
   hook that wants parallel work becomes long-lived.
4. **Keys while in hooks.** Options: hold the current keys; always hold
   `*` (no gain); hold nothing (conflicting calls reorder). **Recommend the
   current keys, and `*` while a hook that declares `changes: [keys]` is
   still to run**, plus the warning event.
5. **`after_tool` on the same engine.** **Recommend yes.** It is the same
   code, and it stops one slow `after_tool` hook from stalling the other
   tools' pipes.
6. **A request that times out.** Options: fail it and keep the process;
   fail it and restart the process. **Recommend keeping the process.** A
   restart drops the state of the other open requests, and does not help a
   hook that hangs on every request.
7. **The crash budget.** **Recommend 3 crashes per session**, reset when a
   reload changes the file or the environment.
8. **When to start.** **Recommend at session start, without waiting**, so
   the startup overlaps the first model call. Starting at the first request
   saves an idle process in chat-only runs, but adds the startup to a call.
9. **One process for a shared file.** **Recommend yes**, keyed by real
   path, so a plugin can see `before_tool` and `after_tool` in one memory.
   It is a few lines.
10. **The option name.** **Recommend `run: call|session`.** It reads as a
    sentence and leaves room for other values. Others: `long_lived: true`,
    `lifetime: session`.
11. **stderr of a long-lived hook.** **Recommend the last 4 KB in the
    error, and nothing on disk.** `ARX_STATE_DIR` gives the hook a place for
    its own log.
12. **The 1 MB cap on per-call hooks.** **Recommend raising it to 64 MB in
    step 1**, since the same helper serves both modes.
13. **The `ask` plugin's code.** **Recommend a built-in hook
    (`arx hook ask`)**, as `shell` connects built-in `bash` and `edit`, so
    `arx acp` users need no python3. The other choice is a Python hook,
    which is shorter to write but adds a runtime to every editor install.
14. **The inbox read while an ask is open.** **Recommend every 20 ms.** A
    front-end that answers at once (mode `allow`, a remembered "always")
    then adds about 10 ms to a call. Watching the file with kqueue or
    inotify would be faster but adds code for each platform.
15. **The ask timeout.** **Recommend a `timeout` field in the `ask`
    object, with no limit by default.** The hook knows how long a person
    should get; Ctrl-C and `--cap wall=` bound the rest.
