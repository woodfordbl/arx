# Schedulers

A scheduler decides when the tool calls of one reply run.

arx has a built-in scheduler that starts calls by their
[keys](tools.md#keys). For most harnesses, keep it: keys already run edits
to one file one at a time, and each `bash` call alone. Replace it with a
scheduler plugin when you need rate limits, priorities, fairness, or a limit
that many agents share.

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
   ended in.

**The built-in scheduler** starts each queued call, in call order, whose
keys conflict with no running call and no call queued before it. Two calls
conflict when they share a key, or when either has the key `*`. So calls
that conflict run in the order the model gave them.

## Contract

A scheduler plugin is an executable file named `scheduler` at the top of a
[layer](concepts.md#layer): next to `agent.yaml`, or at the top of a plugin
folder. The first one in layer order wins.

- **How it runs**: one process for the whole session, started before the
  first tool calls. It keeps running between replies.
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
| `{"ready": {"id", "name", "keys"}}` | A call is in the queue. |
| `{"done": {"id", "secs", "is_error", "backoff"}}` | A call ended. `backoff` is what an `after_tool` hook printed, or `null`. |
| `{"tick": <unix secs>}` | The time the scheduler asked for with `wake_at` has come. |

### Messages from the scheduler

| Message | Meaning |
|---|---|
| `{"start": ["c4", "c5"]}` | Start these calls now. |
| `{"wake_at": <unix secs>}` | Send a `tick` at this time. |
| `{"result": {"id", "text"}}` | End a call without a run, with this text as an error result, such as "budget used up". |

### Backoff, unknown ids and failure

- **Backoff**: an `after_tool` hook prints
  `{"backoff": {"key": "host:api.github.com", "secs": 30}}`, for example
  after an HTTP 429. arx passes it to the scheduler in `done`. The built-in
  scheduler ignores it.
- **Unknown ids**: arx ignores them in `start` or `result`.
- **A call that ends with `result`**: gets no `after_tool` hooks.
- **Failure**: if the process cannot start, exits, or prints a line that is
  not one of the messages on this page, arx writes an `error` event
  (`scheduler PATH: ...; using the built-in scheduler`) and uses the
  built-in scheduler for the rest of the session. It does not start that
  scheduler again.

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

## Common mistakes

| Mistake | What happens | Fix |
|---|---|---|
| The scheduler does not flush stdout | arx never sees `start`, so the calls wait | flush after each line (`flush=True`, `fflush`) |
| The scheduler never starts a call | the turn waits until you press Ctrl-C | start every call, or end it with `result` |
| It ignores keys, as the example does | two `edit` calls to one file, or two `bash` calls, can run at the same time | start calls with conflicting keys one at a time, unless you mean otherwise |
| It writes logs to stdout | the line is not a message, so arx falls back to the built-in scheduler | log to stderr (arx drops it) or to a file |
| The file is in `tools/` or `hooks/` | it is not found | put it at the top of the layer, named `scheduler` |
| You expect `arx check` to list it | it does not | check the `error` events of a session |

## Planned

**Planned:** calls that do not block. A scheduler will give the model the
result `started as c7` at once, and send the real result later. See
[Planned changes](planned.md#calls-that-do-not-block).

## Related

- [Tools](tools.md#keys): the keys the built-in scheduler starts calls by.
- [Hooks](hooks.md): `before_tool` decides if a call runs, and `after_tool`
  can print a `backoff`.
- [Subagents](subagents.md): calls with no keys, which run side by side.
- [Plugin reference](reference.md#events): the `error` event a failed
  scheduler writes.
