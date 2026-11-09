# Compactors

A compactor is a program that shortens the history when the prompt gets too
large.

arx sends it the messages as JSON on stdin, and it prints a shorter list on
stdout. Write one when the built-in strategies drop the wrong things, for
example when your task needs its early messages kept word for word. For most
runs, keep the default, `mask`.

**Status:** today. **Example:** [`plugins/keep-last`](../../plugins/keep-last).

## Contract

### Choose a strategy

`compaction.strategy` in the spec chooses how arx compacts:

| Value | What arx runs | Use it when |
|---|---|---|
| `mask`, `summarize`, `hybrid`, `restart` | a built-in strategy; `mask` is the default ([agent.yaml reference](../spec.md#compaction)) | a built-in strategy keeps what your task needs |
| a name from `compactors:` | a compactor that the spec or a plugin names | a plugin ships the compactor |
| a path | an executable, relative to the spec folder | the compactor lives in your own harness |

A plugin names its compactors in `plugin.yaml`, with paths relative to the
plugin folder. The spec then chooses one by name:

```yaml
# plugin.yaml
compactors: {keep_last: compactors/keep_last.py}
```

```yaml
# agent.yaml
compaction: {strategy: keep_last, trigger: 0.7}
```

### When arx compacts

arx runs the strategy at two points:

- **Before a model call**: when the prompt is larger than
  `compaction.trigger × context_window`. The defaults are 0.7 and 128000
  tokens.
- **After a context error**: when the provider says the context is too long,
  and no `before_model` hook changed anything for that error. With the
  default `mask`, arx uses `hybrid` here. Then it retries the call once. See
  [Context overflow](hooks.md#context-overflow).

### Input and output

arx writes one JSON object to the compactor's stdin:

```json
{"messages": [...], "usage": {"prompt_tokens": 91234}, "context_window": 128000}
```

The compactor prints `{"messages": [...]}` on stdout. The list must not be
empty, and every message must have a `role`.

- **Message format**: OpenAI Chat Completions. Message 0 is the system
  prompt. An assistant message with `tool_calls` is followed by one `tool`
  message per call, with the same `tool_call_id`.
- **`_` fields**: fields such as `_out` (the path of a tool's full output)
  stay in arx and never go to the model. Keep them.
- **No change**: to say "nothing to compact", print the messages unchanged.
- **Failure**: a non-zero exit, a run longer than 120 seconds, or output that
  is not valid makes arx use `mask` instead and tell the agent why.
- **Environment**: the [`ARX_*` variables](reference.md#environment). A
  plugin's compactor also gets `ARX_PLUGIN_DIR` and its
  [state folders](concepts.md#plugin-state), `ARX_STATE_DIR` and
  `ARX_DATA_DIR`. The working directory is the folder `arx` runs in.

After a compaction, arx writes a `{"_reset":true}` line and then the new
history to `transcript.jsonl`, and sends a `compact` event.

> [!WARNING]
> arx reads a compactor's stderr together with its stdout. One debug line on
> stderr makes the JSON invalid, and arx falls back to `mask`.

## Write a compactor

This compactor keeps the system prompt, the first user message and about the
last 12 messages. It cuts only in front of an assistant message, so no tool
result loses the call it answers:

```python
#!/usr/bin/env python3
import json
import sys

KEEP = 12
messages = json.load(sys.stdin)["messages"]
head, rest = messages[:2], messages[2:]
cut = max(0, len(rest) - KEEP)
while cut < len(rest) and rest[cut]["role"] != "assistant":
    cut += 1
if 0 < cut < len(rest):
    note = {"role": "user", "content": f"[{cut} earlier messages were dropped]"}
    messages = head + [note] + rest[cut:]
print(json.dumps({"messages": messages}))
```

Save it in a plugin as `compactors/keep_last.py`, make it executable, and
name it in `plugin.yaml` as in [Choose a strategy](#choose-a-strategy). To
see it work, give the run a small window so that it compacts after a few
turns, then look for `compact` events:

```sh
arx -p "..." --set context_window=1500                    # compacts early
grep '"type":"compact"' .arx/sessions/last/events.jsonl   # one line each
```

Each `compact` event names the `strategy` and gives `tokens_before` and
`tokens_after`.

## Common mistakes

| Mistake | What happens | Fix |
|---|---|---|
| The cut separates a `tool` message from the assistant message that called it | the provider rejects the next request | cut only in front of an assistant message |
| The compactor drops message 0 | the agent loses its system prompt | keep the first message |
| The compactor writes to stderr | arx reads stderr with stdout, so the JSON is not valid, and arx uses `mask` | write nothing to stderr |
| A compactor in the spec folder reads `$ARX_PLUGIN_DIR` | only a plugin's compactor gets it | use `$ARX_SPEC_DIR`, or the script's own path, such as `os.path.dirname(__file__)` |
| The compactor removes `_out` fields | the agent loses the paths of full tool outputs | copy messages as they are, and change only what you must |
| `compaction.strategy` names a compactor from a plugin that is off | the spec is not valid: `not a built-in strategy, and ... is not executable` | turn the plugin on, or use a path |

## Compact from a before_model hook

A [`before_model` hook](hooks.md) can also compact: the messages it prints
replace the history. It runs before every model call, so it decides on its
own when to cut. It gets `"reason": "context_overflow"` when the provider
said the prompt is too long.

Use a compactor when the spec should choose the strategy with
`compaction.strategy`. Use a hook when the plugin should always act.

## Planned

**Planned:** the compactor kind and the built-in strategies will move to
plugins, as `before_model` hooks. See [Planned changes](planned.md).

## Related

- [Hooks](hooks.md): `before_model` hooks and what arx does on context
  overflow.
- [agent.yaml reference](../spec.md#compaction): every `compaction` key and
  its default.
- [Plugin reference](reference.md#events): the `compact` event and the rest
  of the event stream.
