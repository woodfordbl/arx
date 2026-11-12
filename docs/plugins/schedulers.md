# Schedulers

A scheduler decides when each tool call runs, and which calls run in the
background.

arx has a built-in scheduler that starts calls by their
[keys](tools.md#keys). For most harnesses, keep it: keys already run edits
to one file one at a time, and each `bash` call alone. Replace it with a
scheduler plugin when you need rate limits, priorities, fairness, a limit
that many agents share, or
[calls in the background](#run-calls-in-the-background).
For background calls alone, install the
[`background` plugin](../../plugins/background) and write nothing.

**Status:** today.

## How tool calls run

Hooks decide if a call may run. The scheduler decides when.

1. arx runs the `before_tool` hooks for every call of the reply, in call
   order. A hook can change the call and its keys, or give a result in place
   of the run.
2. The allowed calls wait in a queue.
3. The scheduler starts them. Many calls can run at the same time.
4. As each call ends, its `after_tool` hooks run.
5. The results go into the history in call order, whatever order the calls
   ended in. A [background call](#run-calls-in-the-background) gets a
   placeholder there, and its real result comes later.

**The built-in scheduler** starts each queued call, in call order, whose
keys conflict with no running call and no call queued before it. Two calls
conflict when they share a key, or when either has the key `*`. So calls
that conflict run in the order the model gave them.

## Contract

A scheduler plugin is an executable file named `scheduler` at the top of a
[layer](concepts.md#layer): next to `agent.yaml`, or at the top of a plugin
folder. The first one in layer order wins.

- **How it runs**: one process for the whole session, started before the
  first tool calls. It keeps running between replies. arx reads what it
  prints while tools run, at the start of each turn, and while it waits for
  a background call.
- **Protocol**: one JSON object per line, on its stdin and stdout. Flush
  stdout after each line.
- **Environment**: the [`ARX_*` variables](reference.md#environment), and
  for a plugin's scheduler `ARX_PLUGIN_DIR`, `ARX_STATE_DIR`,
  `ARX_DATA_DIR`, and its [settings](kits.md#the-active-list) as JSON in
  `ARX_PLUGIN_SETTINGS`. Keep counters in `ARX_STATE_DIR`, so a `--resume`
  keeps them: a scheduler is a new process after a resume. arx drops its
  stderr.
- **Ctrl-C**: does not stop it. arx stops it when the session ends.

### Messages from arx

| Message | Meaning |
|---|---|
| `{"ready": {"id", "name", "keys", "kind", "args"}}` | A call is in the queue. `kind` is `"tool"`, or `"agent"` for a subagent. `args` holds the arguments after the `before_tool` hooks, as an object. |
| `{"done": {"id", "secs", "is_error", "backoff", "ran"}}` | A call ended. `backoff` is what an `after_tool` hook printed, or `null`. `ran` is `false` for a queued call that was cancelled or stopped before its process started: then `secs` is 0 and `is_error` is true. For a background call, `done` comes when the call ends, which can be turns later. |
| `{"tick": <unix secs>}` | The time the scheduler asked for with `wake_at` has come. |

### Messages from the scheduler

| Message | Meaning |
|---|---|
| `{"start": ["call_4", "call_5"]}` | Start these queued calls now. This works for any queued call of the session, so a background call that you held can start turns later. |
| `{"wake_at": <unix secs>}` | Send a `tick` at this time. |
| `{"result": {"id", "text"}}` | End a queued call without a run, with this text as an error result, such as "budget used up". For a queued background call, the text arrives as a note with the status `error`. |
| `{"detach": ["call_4"]}` | Move these calls to the [background](#run-calls-in-the-background). A queued call stays queued until a later `start`. A running call keeps running. |
| `{"cancel": ["call_4", "c7"]}` | [Cancel](#cancel-a-call) these calls. |

These rules cover both tables:

- **Ids**: every message uses the model's call id (`call_4`). Only `cancel`
  also takes the short id of a background call (`c7`).
- **One `done` for each `ready`**, except for a call that the scheduler
  itself ended with `result`. So a scheduler can count what is in flight.
- **One line can hold several keys**: `{"start": ["x"], "detach": ["x"]}`
  starts a call and moves it to the background at once.
- **Ignore what you do not know.** arx can add messages and fields. A
  scheduler written for arx 0.1 still works, because it ignores them.

### Backoff, unknown ids and failure

- **Backoff**: an `after_tool` hook prints
  `{"backoff": {"key": "host:api.github.com", "secs": 30}}`, for example
  after an HTTP 429. arx passes it to the scheduler in `done`. The built-in
  scheduler ignores it.
- **Unknown ids**: arx ignores them in every message. It also ignores a
  `detach` for a call that ended or is already in the background.
- **Bad values**: a `start`, `detach` or `cancel` value that is not a list
  of strings is a bad line, and counts as a failure.
- **A call that ends with `result`**: gets no `after_tool` hooks.
- **Failure**: if the process cannot start, exits, or prints a line that is
  not one of the messages on this page, arx writes an `error` event
  (`scheduler PATH: ...; using the built-in scheduler`) and uses the
  built-in scheduler for the rest of the session. It does not start that
  scheduler again. Background calls that run go on. The built-in scheduler
  starts the queued ones by their keys, with no limit on how many.

## Write a scheduler

This scheduler runs at most two calls at a time, in the order they come,
whatever their keys.

> [!WARNING]
> This example ignores keys, so it can run two `edit` calls to one file, or
> two `bash` calls, at the same time. Use it to learn the protocol, then
> respect keys in a real scheduler.

1. Save it as `scheduler`, next to `agent.yaml` or at the top of a plugin
   folder:

   ```python
   #!/usr/bin/env python3
   # scheduler: runs at most two tool calls at a time, in the order they come.
   import json
   import sys

   LIMIT = 2
   queue, running = [], set()

   for line in sys.stdin:
       message = json.loads(line)
       if "ready" in message:
           queue.append(message["ready"]["id"])
       if "done" in message:
           running.discard(message["done"]["id"])
       start = []
       while queue and len(running) < LIMIT:
           call = queue.pop(0)
           running.add(call)
           start.append(call)
       if start:
           print(json.dumps({"start": start}), flush=True)
   ```

2. Make it executable:

   ```sh
   chmod +x scheduler        # next to agent.yaml, or at the top of a plugin folder
   ```

With three calls of one second each, the first two run together, and the
third starts when one of them ends.

## Run calls in the background

A scheduler moves a call to the background with `detach`. The model gets a
placeholder result at once and goes on working, and the call's real result
reaches it later as a `[harness]` note. Use it for work the model can do
other things beside, such as a subagent or a long build.

The built-in scheduler never moves a call to the background. Without a
scheduler plugin that sends `detach`, every call blocks until it ends.

### The placeholder result

When a call moves to the background, arx gives it a short id (`c1`, `c2`,
and so on) and ends its slot in the reply with this result:

```text
started as c7 in the background. Its result comes later in a [harness] note.
Output so far: /work/.arx/sessions/20261030-221403-a1b2/tool-0007.out
```

- **`queued as c7`** takes the place of `started` when the scheduler holds
  the call. The `Output so far` line is missing then, and for a subagent.
- **Short ids never repeat in a session**, across `--resume` too. The
  counter is `call_seq` in `meta.json`.
- **Tell the model how to wait.** The placeholder is short on purpose. The
  `background` plugin explains background calls in its `instructions`. If
  you write your own scheduler, add
  [`instructions`](prompt.md) to your plugin that say: keep working, and
  reply without a tool call when there is nothing else to do.
- **A call that cannot start** when it moves to the background ends at
  once. The model gets the error as the normal result, not a placeholder.

### Keys of a background call

A background call holds only its named keys. The key `*` does not count
against it, on either side:

- A background `edit` of `a.c` (`file:a.c`) makes a later `edit` of `a.c`
  wait, in this reply or a later one.
- A background `bash` call does not make later calls wait, and a later
  `bash` call does not wait for a background call. The model was told that
  the call runs on, so it owns that conflict.

arx drops `*` from the call's keys when it moves to the background. The
built-in scheduler follows this rule after a fallback. A scheduler plugin
should follow it too.

### When the model sees a result

When a background call ends, arx runs its `after_tool` hooks on the real
result, sends `done`, and appends a `result` line to the session's
[inbox](reference.md#inbox-lines). Before its next model call, the agent
gets each new result as one paragraph of a `[harness]` note:

```text
[harness]
c7 (reviewer: Review src/a.c) finished after 42s:
1. The loop in parse() never ends on an empty line.
```

| Status | When | The note says |
|---|---|---|
| `ok` | exit code 0 | `finished after 42s` |
| `error` | a non-zero exit, a timeout, no start, or a scheduler `result` | `failed after 3s` |
| `cancelled` | a cancel from the scheduler, `arx ctl` or a tool | `was cancelled after 10s` |
| `stopped` | Ctrl-C, or the session ended | `was stopped after 10s` |

The text is what a foreground call gives: the head and tail of the output
with the path of the full output, or a subagent's answer, plus the
`[exit code N]`, `[timed out ...]`, `[cancelled]` or `[interrupted]` line.

A reply without tool calls does not end the run while a call is in flight.
arx skips the `stop` hook and waits for the first of: a result, an operator
`note` or `stop`, Ctrl-C, or the `wall` cap. Then it runs the next turn.

- **The `stop` hook runs only when nothing is in flight.** So "done" means
  that the agent's own work is done.
- **A wait costs one turn for each batch of results**, not one for each
  call. Results that end in the same poll share one note.
- **The wait is bounded.** Each call has its tool timeout (120 seconds, or
  30 minutes for a subagent), and the `wall` cap applies while arx waits.
- **In interactive mode** the turn waits too. arx stops the calls that are
  still in flight before the prompt comes back.

### Cancel a call

Three ways cancel a call, by its short id or the model's id:

| From | How |
|---|---|
| The scheduler | `{"cancel": ["c7"]}` |
| A person or a front-end | `arx ctl ID\|last cancel c7` |
| The model | a tool that runs `"$ARX_BIN" ctl "$ARX_SESSION_DIR" cancel c7`, such as `cancel_call` in the `background` plugin |

- **A running call** gets SIGTERM on its process group, and SIGKILL 3
  seconds later. arx does not wait for it. Its result is the output so far
  plus `[cancelled]`, and its `after_tool` hooks run.
- **A queued call** ends at once with `[cancelled before it started]`. The
  scheduler gets `done` with `ran: false`.
- **An unknown id or a call that ended** is ignored. `arx ctl` checks first
  and exits 2 with `no call c9 in flight (in flight: c7, c8)`.
- arx applies a cancel from `arx ctl` at the start of the next turn, and
  while it waits.

### Session end, Ctrl-C and --resume

No background call outlives its session.

- **Session end** (a cap, an error, `arx ctl stop`, end of input): arx stops
  every call in flight, as a cancel does, before `session.end`. Each one
  gets its `after_tool` hooks and a `result` line with the status
  `stopped`.
- **Ctrl-C** stops background calls as it stops foreground calls.
- **`--resume`**: for each call that the agent had not seen the result of,
  arx adds a note before the first model call: the `stopped` result, or
  `c7 (reviewer: ...) did not finish` when arx itself was killed. arx does
  not start the call again.

## Common mistakes

| Mistake | What happens | Fix |
|---|---|---|
| The scheduler does not flush stdout | arx never sees `start`, so the calls wait | flush after each line (`flush=True`, `fflush`) |
| The scheduler never starts a call | the turn waits until you press Ctrl-C | start every call, or end it with `result` |
| It holds a background call and never starts it | the run waits until Ctrl-C or the `wall` cap | start a held call when a slot frees, or end it with `result` |
| It moves a call to the background that the model needs at once | the model gets the placeholder, and waiting costs one more turn | detach only work the model can do other things beside |
| It ignores keys, as the example does | two `edit` calls to one file, or two `bash` calls, can run at the same time | start calls with conflicting keys one at a time, unless you mean otherwise |
| It writes logs to stdout | the line is not a message, so arx falls back to the built-in scheduler | log to stderr (arx drops it) or to a file |
| The file is in `tools/` or `hooks/` | it is not found | put it at the top of the layer, named `scheduler` |
| You expect `arx check` to list it | it does not | check the `error` events of a session |

## Related

- [Tools](tools.md#keys): the keys the built-in scheduler starts calls by.
- [Hooks](hooks.md): `before_tool` decides if a call runs, and `after_tool`
  can print a `backoff`.
- [Subagents](subagents.md): calls with no keys, which run side by side,
  and how to run them in the background.
- [Plugin reference](reference.md#events): the `error` event a failed
  scheduler writes.
