# Schedulers

A scheduler decides when the tool calls of a reply run. arx has a built-in
scheduler that uses the [keys](tools.md#keys) of each call. A scheduler
plugin replaces it, for rate limits, priorities, fairness, or a limit that
many agents share.

**Status:** today.

## How tool calls run

Hooks decide **if** a call may run; the scheduler decides **when**.

1. arx runs the `before_tool` hooks for every call of the reply, in call
   order. A hook can change the call and its keys, or give a result in place
   of the run.
2. The allowed calls wait in a queue.
3. The scheduler starts them. Many calls can run at the same time.
4. As each call ends, its `after_tool` hooks run.
5. The results go into the history in call order, whatever order the calls
   ended in.

**The built-in scheduler** starts each queued call, in call order, whose keys
conflict with no running call and no call queued before it. Two calls
conflict when they share a key, or when either has the key `*`. So calls
that conflict run in the order the model gave them. See
[Keys](tools.md#keys).

## Contract

A scheduler plugin is an executable file named `scheduler` at the top of a
[layer](concepts.md#layer): next to `agent.yaml`, or at the top of a plugin
folder. The first one in layer order wins.

- **How it runs:** one process for the whole session, started before the
  first tool calls. It keeps running between replies.
- **Protocol:** one JSON object per line, on its stdin and stdout. Flush
  stdout after each line.
- **Environment:** the [`ARX_*` variables](reference.md#environment), and
  `ARX_PLUGIN_DIR` for a plugin's scheduler. arx drops its stderr.
- **Ctrl-C** does not stop it; arx stops it when the session ends.

| Direction | Message | Meaning |
|---|---|---|
| arx → scheduler | `{"ready": {"id", "name", "keys"}}` | a call is in the queue |
| arx → scheduler | `{"done": {"id", "secs", "is_error", "backoff"}}` | a call ended; `backoff` is what an `after_tool` hook printed, or `null` |
| arx → scheduler | `{"tick": <unix secs>}` | the time it asked for with `wake_at` has come |
| scheduler → arx | `{"start": ["c4", "c5"]}` | start these calls now |
| scheduler → arx | `{"wake_at": <unix secs>}` | send a `tick` at this time |
| scheduler → arx | `{"result": {"id", "text"}}` | end a call without a run, with this text as an error result, such as "budget used up" |

- **Backoff:** an `after_tool` hook prints
  `{"backoff": {"key": "host:api.github.com", "secs": 30}}`, for example
  after an HTTP 429. arx passes it to the scheduler in `done`. The built-in
  scheduler ignores it.
- **Unknown ids** in `start` or `result` are ignored.
- **A call that ends with `result`** gets no `after_tool` hooks.
- **Failure:** if the process cannot start, exits, or prints a line that is
  not one of the messages above, arx writes an `error` event (`scheduler
  PATH: ...; using the built-in scheduler`) and uses the built-in scheduler
  for the rest of the session. It does not start that scheduler again.

## Minimal example

Run at most two calls at a time, in the order they come, whatever their
keys:

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

```sh
chmod +x scheduler        # next to agent.yaml, or at the top of a plugin folder
```

With three calls of one second each, the first two run together and the
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

Calls that do not block: a scheduler gives the model the result
`started as c7` at once, and sends the real result later. See
[Planned changes](planned.md).
