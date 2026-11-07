# Compactors

A compactor is a program that makes the history shorter when the prompt gets
too large. arx gives it the messages as JSON, and it prints a shorter list.

**Status:** today. **Example:** [`plugins/keep-last`](../../plugins/keep-last).

## Contract

`compaction.strategy` in the spec chooses how arx compacts:

| Value | Meaning |
|---|---|
| `mask`, `summarize`, `hybrid`, `restart` | a built-in strategy; `mask` is the default ([spec reference](../spec.md)) |
| a name from `compactors:` | a compactor that the spec or a plugin names |
| a path | an executable, relative to the spec folder |

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

**When it runs:**

- before a model call, when the prompt is larger than
  `compaction.trigger × context_window` (default 0.7 × 128000 tokens);
- when the provider says the context is too long. arx compacts once and
  retries the call.

**Input (stdin):**

```json
{"messages": [...], "usage": {"prompt_tokens": 91234}, "context_window": 128000}
```

**Output (stdout):** `{"messages": [...]}`. The list must not be empty, and
every message must have a `role`.

- **Message format:** OpenAI Chat Completions. Message 0 is the system prompt.
  An assistant message with `tool_calls` is followed by one `tool` message per
  call, with the same `tool_call_id`.
- **`_` fields,** such as `_out` (the path of a tool's full output), stay in
  arx and never go to the model. Keep them.
- **No change:** print the messages unchanged to say "nothing to compact".
- **Failure:** a non-zero exit, more than 120 seconds, or output that is not
  valid makes arx use `mask` instead, and tell the agent why.
- **Environment:** the [`ARX_*` variables](reference.md#environment), but not
  `ARX_PLUGIN_DIR`. The working directory is the folder `arx` runs in.

After a compaction, arx writes a `{"_reset":true}` line and then the new
history to `transcript.jsonl`, and sends a `compact` event.

## Minimal example

Keep the system prompt, the first user message and about the last 12
messages, and cut only in front of an assistant message:

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

Try it with a small window, so that it runs after a few turns:

```sh
arx -p "..." --set context_window=1500
grep '"type":"compact"' .arx/sessions/last/events.jsonl
```

## Common mistakes

| Mistake | What happens | Fix |
|---|---|---|
| The cut separates a `tool` message from the assistant message that called it | the provider rejects the next request | cut only in front of an assistant message |
| The compactor drops message 0 | the agent loses its system prompt | keep the first message |
| The compactor writes to stderr | arx reads stderr with stdout, so the JSON is not valid, and arx uses `mask` | write nothing to stderr |
| The compactor reads `$ARX_PLUGIN_DIR` | it is not set for compactors | find your files from the script's own path, such as `os.path.dirname(__file__)` |
| The compactor removes `_out` fields | the agent loses the paths of full tool outputs | copy messages as they are, and change only what you must |
| `compaction.strategy` names a compactor from a plugin that is off | the spec is not valid: `not a built-in strategy, and ... is not executable` | turn the plugin on, or use a path |

## Planned

Compaction becomes a `before_model` hook: the hook gets the request and
returns new messages, which replace the history. If the provider says the
context is too long, arx runs `before_model` again with
`"reason": "context_overflow"`. The compactor kind and the built-in strategies
then move to plugins. See [Planned changes](planned.md#hook-lifecycle).
