# Hooks

A hook is an executable that arx runs at a fixed point of the run, called a
hook point.

Use a hook to guard, rewrite or log what passes between the model and the
tools, to add context when a session starts, or to keep the agent working
when it wants to stop. Around the model call and the tool calls, a hook gets
the raw object (the request, the reply, the call or the result) and can
change it. A `before_tool` hook is a guard, not a sandbox: it sees each call
before it runs, but it can't limit what the tool does once it runs.

**Status:** today. **Examples:** [`plugins/guard`](../../plugins/guard)
(`before_tool`), [`plugins/git-context`](../../plugins/git-context)
(`session_start`), [`plugins/fail-hint`](../../plugins/fail-hint)
(`after_tool`), and [`examples/plugins/hooks/stop`](../../examples/plugins/hooks/stop).

## Where hooks run in a turn

There are six hook points. Four of them run inside each turn:

1. **`before_model`** gets the request. What it leaves is what the model
   gets.
2. **The model** replies, with or without tool calls.
3. **`after_model`** gets the reply. It can change the reply or remove tool
   calls.
4. **`before_tool`** runs for each call, in call order. It can let the call
   run, change the call and its keys, or give a result in place of the run.
5. **The tool runtime** starts the allowed calls by their
   [keys](tools.md#keys), or as a [scheduler plugin](schedulers.md) says.
   Many calls can run at the same time.
6. **`after_tool`** runs as each call ends. It can change the call's result.
7. **The results** go to the model in the order of the calls.

The other two run around the turns: `session_start` runs once, before the
first turn, and `stop` runs when the model replies without calling a tool.

## Contract

A hook is the file `hooks/<point>` in any [layer](concepts.md#layer). The
file name is exactly the point name, with no extension. arx starts the hook
each time the run reaches its point:

| Part | Contract |
|---|---|
| Input (stdin) | One JSON object on one line: the fields of the point (in the tables on this page), plus `point`, `session` (the session id) and `turn`. |
| Output (stdout) | Nothing, which keeps everything as it is, or one JSON object. |
| Errors and logs | Write them to stderr. arx keeps stderr apart from the answer, and shows it in the `hook` event when the hook fails. |
| Working directory | The folder `arx` runs in. |
| Environment | The [`ARX_*` variables](reference.md#environment). A hook in a plugin also gets `ARX_PLUGIN_DIR`, its [settings](kits.md#the-active-list) as JSON in `ARX_PLUGIN_SETTINGS` (`{}` when it has none), and its [state folders](concepts.md#plugin-state) `ARX_STATE_DIR` and `ARX_DATA_DIR`. |
| Timeout | 10 seconds by default. |

The points come in two kinds. The four points around the model call and the
tool calls pass a raw object, and the hook prints the fields it changes. The
two points around the turns ask for context or a decision.

### Points with a raw object

At these four points, the hook prints only the fields it changes. A printed
field replaces the field of the same name. arx ignores any field that is not
in the "May print" column.

| Point | Input (stdin) | May print |
|---|---|---|
| `before_model` | `{"messages", "tools", "model", "settings", "reason"}` | any of `messages`, `tools`, `model`, `settings` |
| `after_model` | `{"reply", "usage", "finish"}` | `reply` |
| `before_tool` | `{"id", "name", "args", "keys"}` | any of `name`, `args`, `keys`; or `result` to skip the tool |
| `after_tool` | `{"call": {"id", "name", "args"}, "result", "is_error"}` | `result`, `backoff` |

#### `before_model`

| Field | What it holds | If the hook prints it |
|---|---|---|
| `messages` | The history, in OpenAI Chat Completions format (see [Compactors](compactors.md)). | It replaces the history, for this call and every later one. |
| `tools` | The `tools` array of the request. | It applies to this call only. |
| `model` | The model id. | It applies to this call only. |
| `settings` | `model_settings` from the spec. | It applies to this call only. A `null` setting removes the field from the request. |
| `reason` | `turn`, or `context_overflow` when the provider said the prompt is too long (see [Context overflow](#context-overflow)). | Ignored. |

> [!WARNING]
> Messages you print replace the history. arx writes a `{"_reset":true}`
> line and then the new messages to `transcript.jsonl`, so the transcript
> shows what the model got. Keep message 0, or the agent loses its prompt.

#### `after_model`

| Field | What it holds | If the hook prints it |
|---|---|---|
| `reply` | The assistant message, with `tool_calls` when there are any. | It goes into the history, so you can remove or change tool calls before they run. |
| `usage` | `prompt_tokens`, `completion_tokens` and `cost`. | Ignored. |
| `finish` | `stop` or `tool_calls`. | Ignored. |

#### `before_tool`

| Field | What it holds | If the hook prints it |
|---|---|---|
| `id` | The call id. | Ignored. |
| `name` | The tool name. | arx runs the call with this name. |
| `args` | The arguments as an object, or as a string when the model wrote JSON that is not valid. | arx runs the call with these arguments. |
| `keys` | The call's [keys](tools.md#keys), from the tool's schema. | A list of strings that replaces them. |
| `result` | Not in the input. | A string that becomes the tool result. The tool does not run. |

- **A changed call**: when `name` or `args` changed, arx adds a line such as
  `[ran as: git push]` to the result, so the model knows what ran. When the
  name changed, the line starts with the new name.
- **A printed `result`** ends the call there. The tool does not run,
  `after_tool` does not run, and the later `before_tool` hooks do not run.

#### `after_tool`

| Field | What it holds | If the hook prints it |
|---|---|---|
| `call` | The call: `id`, `name` and `args`. | Ignored. |
| `result` | The text the model will see, after the head and tail cut of long output. | It replaces the result. |
| `is_error` | True after a non-zero exit, a timeout or an unknown tool. | Ignored. |
| `backoff` | Not in the input. | An object such as `{"key": "host:api.github.com", "secs": 30}` that goes to a [scheduler plugin](schedulers.md), which can wait before it starts another call with that key. |

`after_tool` runs for every call that `before_tool` let through, also after
an error, a timeout or Ctrl-C.

#### Older outputs

These outputs come from before the raw objects. They still work:

| Point | Output | Becomes |
|---|---|---|
| `before_tool` | `{"decision": "deny", "reason": "..."}` | the result `denied: <reason>`, marked as an error; the tool does not run |
| `after_tool` | `{"note": "..."}` | a line `[after_tool] <note>` added to the result |

### Points with a decision

| Point | When | Extra input | May print |
|---|---|---|---|
| `session_start` | once, before the first model call of a new session | none (`turn` is 0) | `{"context": "..."}` |
| `stop` | when the model replies without calling a tool | `{"last_message": "..."}` | `{"decision": "continue", "message": "..."}` or `{"decision": "restart", "message": "..."}` |

- **`session_start` context**: arx adds it to the end of the first user
  message. The hook does not run again on `--resume`, so keep what a
  resumed session needs in `ARX_STATE_DIR`, not only in memory.
- **`stop` continue**: arx sends `message` (default `Continue.`) to the
  agent as a user message, and the loop goes on. This is how "never stop"
  loops work.
- **`stop` restart**: arx clears the history and starts again from the
  system prompt, the first message and `message`. `session_start` does not
  run again.
- **`stop` with no output,** or any other decision: the session ends.

arx cuts `last_message` at 8 KB.

### Options

Where a hook's options go depends on where the hook is:

| The hook is in | Its options go in |
|---|---|
| the spec folder or the config folder | `hooks:` in the spec |
| a plugin | `hooks:` in the plugin's `plugin.yaml`; the spec's `hooks:` does not apply |

```yaml
# agent.yaml
hooks:
  before_tool: {timeout: 5s, fail: closed}
```

| Option | Default | Meaning |
|---|---|---|
| `timeout` | `10s` | At the timeout, arx stops the hook's process group, and the hook fails. |
| `band` | `normal` | `policy`, `normal` or `final`. See [Bands](#bands). |
| `changes` | none | The fields this hook changes, such as `[result]`, for the `arx check` warnings. |
| `fail` | `open` | `open` ignores a failed hook. `closed` stops the hooks after it at that point, and a failed `before_tool` hook then denies the call with `denied: the before_tool hook failed (fail: closed)`. |

### When a hook fails

A hook fails when it:

- cannot start;
- exits non-zero;
- times out;
- prints something that is not a JSON object;
- prints a field of the wrong type, such as `messages` that is not a list
  of messages.

arx then writes a `hook` event with an `error`, ignores everything the hook
printed, and goes on with the next hook, unless the hook has
`fail: closed`. So a broken hook, such as one the agent wrote, cannot stop
the run.

## More than one hook

Each layer can have a hook for a point, so one point can have many hooks.
arx runs them in this order:

1. By [band](#bands): every `policy` hook, then every `normal` hook, then
   every `final` hook.
2. Inside a band, in layer order: the spec folder first, then the plugins in
   the order of the active list. Without a kit or a list, that is the
   project plugins, your config folder and your user plugins.

What each hook gets depends on the point:

| Point | Rule |
|---|---|
| `before_model`, `after_model`, `before_tool`, `after_tool` | A chain: each hook gets the object as the hook before it left it. A `before_tool` hook that prints `result` (or a deny) ends the chain. |
| `session_start` | Each hook gets the same input. arx joins all the contexts, with a blank line between them. |
| `stop` | Each hook gets the same input. The first hook that prints a decision wins, and the later hooks do not run. |

Each `hook` event lists the fields that hook changed, such as
`"changed":["args"]`, so you can see which plugin changed what.

## Bands

A band is the group a hook runs in at its point. The hooks at one point
form a pipeline, so their order matters: a guard must decide first, and
redaction must run last. Set the band with `band:` in the hook's options:

| Band | Runs | Use it for |
|---|---|---|
| `policy` | first | guards and approval: a `result` it sets is final |
| `normal` | after `policy`; the default | rewrites, compaction, keys |
| `final` | last, right before the model or the tool gets the object | cache breakpoints, redaction, logs |

A guard sets all three of its options in its `plugin.yaml`:

```yaml
# plugin.yaml of a guard
hooks: {before_tool: {band: policy, fail: closed, changes: [result]}}
```

> [!WARNING]
> Give every guard `band: policy` and `fail: closed`. In the `normal` band,
> a later hook can change its result. With `fail: open`, a guard that
> crashes lets every call through.

The rules:

- **Inside a band,** hooks run in layer order, which is the order of the
  active list. There are no priority numbers.
- **A policy result is final**: when a `policy` hook sets `result`, arx
  drops a later hook's `result`, `note` or deny. The later hook's `hook`
  event says
  `"ignored":"result: a policy hook set it, so it is final"`.
- **`changes:`** says which fields a hook changes. When two hooks at one
  point say they change the same field, `arx check` warns and shows the
  order they run in. For two plugins, `redact` and `trim`, that both set
  `changes: [result]` at `after_tool`:
  `- after_tool: 2 hooks change result; they run in this order: plugin redact (policy), plugin trim (normal)`.
- **The `hook` event** of a hook outside the `normal` band has `"band"`.

`arx check` shows each point that has a hook, and the plugins it comes from:
`hooks: before_tool(guard) after_tool(fail-hint) stop`.

## Context overflow

When the provider says the prompt is too long, arx:

1. runs the `before_model` hooks again, with `"reason": "context_overflow"`;
2. if no hook changed anything, runs the spec's `compaction.strategy` (with
   `hybrid` in place of the default `mask`);
3. retries the call once.

So a `before_model` hook can do the compaction itself. Before each model
call, arx also still runs `compaction.strategy` when the prompt passes
`compaction.trigger`.

## Examples

Each example is a complete hook. Save it as `hooks/<point>` in the spec
folder and make it executable.

### Deny force pushes

This `before_tool` hook uses the older deny output:

```sh
#!/bin/sh
# hooks/before_tool
input=$(cat)
case "$input" in
  *'"name":"bash"'*'git push --force'*)
    echo '{"decision": "deny", "reason": "no force pushes; ask the operator"}' ;;
esac
```

Test it by hand with a sample call, then check that arx finds it:

```sh
chmod +x hooks/before_tool
echo '{"id":"c1","name":"bash","args":{"command":"git push --force"}}' | hooks/before_tool
arx check                                  # hooks: before_tool
```

The hook prints the deny, and `arx check` lists `before_tool` under
`hooks:`.

### Change a call

This `before_tool` hook makes every `pytest` run quiet. The result then ends
with `[ran as: pytest -q]`:

```python
#!/usr/bin/env python3
# hooks/before_tool
import json
import sys

call = json.load(sys.stdin)
command = call["args"].get("command", "") if isinstance(call["args"], dict) else ""
if call["name"] == "bash" and command == "pytest":
    print(json.dumps({"args": {"command": "pytest -q"}}))
```

### Add a hint to failed results

This `after_tool` hook adds a line to every error result:

```python
#!/usr/bin/env python3
# hooks/after_tool
import json
import sys

event = json.load(sys.stdin)
if event["is_error"]:
    print(json.dumps({"result": event["result"] + "\nRead the full output first."}))
```

### Keep the last 40 messages

This `before_model` hook keeps the first two messages and the last 40, and
never starts the kept part with a tool result. It replaces the history:

```python
#!/usr/bin/env python3
# hooks/before_model
import json
import sys

request = json.load(sys.stdin)
messages = request["messages"]
if len(messages) > 42:
    rest = messages[-40:]
    while rest and rest[0]["role"] != "assistant":   # never start with a tool result
        rest = rest[1:]
    print(json.dumps({"messages": messages[:2] + rest}))
```

### Keep the agent working until a file exists

This `stop` hook sends the agent back to work until it creates `DONE`:

```sh
#!/bin/sh
# hooks/stop
[ -f DONE ] && exit 0
echo '{"decision": "continue", "message": "Not done yet. When the task is complete, create the file DONE."}'
```

## Common mistakes

| Mistake | What happens | Fix |
|---|---|---|
| The file is not executable | arx does not run it, and gives no warning | `chmod +x`, then check that `arx check` lists the point |
| The file has an extension, such as `stop.sh` | arx does not run it | name the file exactly `stop` |
| The hook prints log lines to stdout | the output is not a JSON object, so the hook fails and is ignored | write logs to stderr |
| The hook prints the whole input back | fields it may not print are ignored, and unchanged fields are not listed as changed, so this works, but it is slow for a large history | print only the fields you change |
| An `after_tool` hook reads `result.text` or `tool.name` | those were the fields before the raw objects; the hook fails | read `result`, `is_error` and `call.name` |
| A `before_tool` hook reads `tool.args` | the call is at the top level now | read `name` and `args` |
| A `before_model` hook drops message 0, or cuts a `tool` message from the call it answers | the agent loses its prompt, or the provider rejects the request | keep message 0, and cut only in front of an assistant message |
| The hook prints an object with a typo, such as `"resutl"` | the field is ignored, so nothing changes | test the hook by hand with a sample input |
| The pattern expects spaces, such as `"name": "bash"` | arx sends compact JSON, `"name":"bash"`, so the pattern never matches | match the compact form, or parse the JSON |
| A plugin's hook options are in the spec | they apply only to hooks in the spec folder and the config folder | put them in the plugin's `plugin.yaml` under `hooks:` |
| A guard hook can fail open | if it crashes, every call goes through | set `fail: closed` for `before_tool` |
| The agent can turn off a plugin's guard | it can edit `plugins:` or `kit:` in `agent.yaml` | pin it from the command line: `--kit NAME`, or `--set 'plugins=["guard","shell"]'` |
| A guard runs in the `normal` band | a hook after it can change its result | set `band: policy` for the guard's hook |
| A `stop` hook always continues | the run ends only at a cap | give the agent a clear way to finish, such as a `DONE` file |

## Planned

**Planned:** a hook will be able to start once per session and read one JSON
line per call. The `before_tool` hooks of different calls will run at the
same time, so a hook that waits for a person does not hold up the other
calls. See [Planned changes](planned.md).

## Related

- [Plugin concepts](concepts.md#layer): layers, the active list and the
  order hooks run in.
- [Tools](tools.md#keys): the keys a `before_tool` hook can read and change.
- [Schedulers](schedulers.md): what a scheduler does with the `backoff` that
  an `after_tool` hook prints.
- [Compactors](compactors.md): shrink the history without writing a
  `before_model` hook.
- [Plugin reference](reference.md#events): the fields of the `hook` event.
