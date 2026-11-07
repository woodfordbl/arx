# Hooks

A hook is an executable that arx runs at a fixed point of the run, the hook
point. Around the model call and the tool calls, a hook gets the raw object
(the request, the reply, the call or the result) and can change it. At the
start and the end of a run, a hook can add context or keep the agent working.

**Status:** today. **Examples:** [`plugins/guard`](../../plugins/guard)
(`before_tool`), [`plugins/git-context`](../../plugins/git-context)
(`session_start`), [`plugins/fail-hint`](../../plugins/fail-hint)
(`after_tool`), and [`examples/plugins/hooks/stop`](../../examples/plugins/hooks/stop).

## One turn

1. **`before_model`** gets the request. What it leaves is what the model
   gets.
2. **The model** replies, with or without tool calls.
3. **`after_model`** gets the reply, and can change it or remove tool calls.
4. For each tool call, one at a time:
   1. **`before_tool`** gets the call. It can let it run, change it, or give
      a result in place of the run.
   2. **The tool** runs.
   3. **`after_tool`** gets the result, and can change it.
5. **The results** go to the model in the order of the calls.

`session_start` runs once before the first turn, and `stop` runs when the
model replies without calling a tool.

## Contract

A hook is the file `hooks/<point>` in any [layer](concepts.md#layer). The file
name is exactly the point name, with no extension.

- **Input (stdin):** one JSON object on one line. It has the fields of the
  point (tables below), plus `point`, `session` (the session id) and `turn`.
- **Output (stdout):** nothing, which means "keep everything as it is", or one
  JSON object.
- **Errors and logs:** write them to stderr. arx keeps stderr apart from the
  answer, and shows it in the `hook` event when the hook fails.
- **Working directory:** the folder `arx` runs in.
- **Environment:** the [`ARX_*` variables](reference.md#environment). A hook
  in a plugin also gets `ARX_PLUGIN_DIR`.
- **Timeout:** 10 seconds by default.

### Points with a raw object

At these four points, the hook prints only the fields it changes. A printed
field replaces the field of the same name. Fields not in the "may print"
column are ignored.

| Point | Input (stdin) | May print |
|---|---|---|
| `before_model` | `{"messages", "tools", "model", "settings", "reason"}` | any of `messages`, `tools`, `model`, `settings` |
| `after_model` | `{"reply", "usage", "finish"}` | `reply` |
| `before_tool` | `{"id", "name", "args"}` | any of `name`, `args`; or `result` to skip the tool |
| `after_tool` | `{"call": {"id", "name", "args"}, "result", "is_error"}` | `result` |

- **`before_model`:**
  - `messages` is the history, in OpenAI Chat Completions format (see
    [Compactors](compactors.md)). Messages you print **replace the
    history**: arx writes a `{"_reset":true}` line and then the new messages
    to `transcript.jsonl`, so the transcript shows what the model got.
  - `tools` is the `tools` array of the request. `model` is the model id.
    `settings` is `model_settings` from the spec; a `null` setting removes the
    field from the request. Changes to these three apply to this call only.
  - `reason` is `turn`, or `context_overflow` when the provider said the
    prompt is too long (see [Context overflow](#context-overflow)).
- **`after_model`:** `reply` is the assistant message, with `tool_calls` when
  there are any. `usage` has `prompt_tokens`, `completion_tokens` and `cost`.
  `finish` is `stop` or `tool_calls`. The reply you print goes into the
  history, so you can remove or change tool calls before they run.
- **`before_tool`:** `args` is the arguments as an object, or as a string
  when the model wrote JSON that is not valid.
  - A changed `name` or `args` makes arx run that call. arx then adds a line
    such as `[ran as: git push]` to the result, so the model knows what ran.
    When the name changed, the line starts with the new name.
  - A printed `result` (a string) is the tool result. The tool does not run,
    `after_tool` does not run, and the later `before_tool` hooks do not run.
- **`after_tool`:** `result` is the text the model will see (after the head
  and tail cut of long output). `is_error` is true after a non-zero exit, a
  timeout or an unknown tool. `after_tool` runs for every call that
  `before_tool` let through, also after an error, a timeout or Ctrl-C.

**Older outputs still work:**

| Point | Output | Becomes |
|---|---|---|
| `before_tool` | `{"decision": "deny", "reason": "..."}` | the result `denied: <reason>`, marked as an error; the tool does not run |
| `after_tool` | `{"note": "..."}` | a line `[after_tool] <note>` added to the result |

### Points with a decision

| Point | When | Extra input | May print |
|---|---|---|---|
| `session_start` | once, before the first model call of a new session | none (`turn` is 0) | `{"context": "..."}` |
| `stop` | when the model replies without calling a tool | `{"last_message": "..."}` | `{"decision": "continue", "message": "..."}` or `{"decision": "restart", "message": "..."}` |

- **`session_start` context** is added to the end of the first user message.
  The hook does not run again on `--resume`.
- **`stop` continue:** arx sends `message` (default `Continue.`) to the agent
  as a user message, and the loop goes on. This is how "never stop" loops
  work.
- **`stop` restart:** arx clears the history and starts again from the system
  prompt, the first message and `message`. `session_start` does not run
  again. `last_message` is cut at 8 KB.
- **`stop` with no output,** or any other decision: the session ends.

### Options

Options for the hooks in the spec folder and the config folder go in the
spec. A plugin sets the options of its own hooks in its `plugin.yaml`, and
the spec's `hooks:` does not apply to them:

```yaml
hooks:
  before_tool: {timeout: 5s, fail: closed}
```

| Option | Default | Meaning |
|---|---|---|
| `timeout` | `10s` | At the timeout, arx stops the hook's process group, and the hook fails. |
| `fail` | `open` | `open` ignores a failed hook. `closed` stops the hooks after it at that point, and a failed `before_tool` hook then denies the call with `denied: the before_tool hook failed (fail: closed)`. |

**Failures:** a hook fails when it cannot start, exits non-zero, times out,
prints something that is not a JSON object, or prints a field of the wrong
type (such as `messages` that is not a list of messages). arx writes a `hook`
event with an `error`, ignores everything the hook printed, and goes on with
the next hook (unless `fail: closed`). So a broken hook, for example one the
agent wrote, cannot stop the run.

## More than one hook

Each layer can have a hook for a point. They run in layer order: the spec
folder first, then project plugins, your config folder and user plugins.

| Point | Rule |
|---|---|
| `before_model`, `after_model`, `before_tool`, `after_tool` | A chain: each hook gets the object as the hook before it left it. A `before_tool` hook that prints `result` (or a deny) ends the chain. |
| `session_start` | Each hook gets the same input. All contexts are joined, with a blank line between them. |
| `stop` | Each hook gets the same input. The first hook that prints a decision wins, and the later hooks do not run. |

Each `hook` event lists the fields that hook changed, such as
`"changed":["args"]`, so you can see which plugin changed what.
`arx check` shows each point that has a hook, and the plugins it comes from:
`hooks: before_tool(guard) after_tool(fail-hint) stop`.

## Context overflow

When the provider says the prompt is too long, arx:

1. runs the `before_model` hooks again, with `"reason": "context_overflow"`;
2. if no hook changed anything, runs the spec's `compaction.strategy` (with
   `hybrid` in place of the default `mask`);
3. retries the call once.

So a `before_model` hook can do the compaction itself. Before each model call,
arx also still runs `compaction.strategy` when the prompt passes
`compaction.trigger`.

## Minimal examples

Deny force pushes (`before_tool`, with the older deny output):

```sh
#!/bin/sh
# hooks/before_tool
input=$(cat)
case "$input" in
  *'"name":"bash"'*'git push --force'*)
    echo '{"decision": "deny", "reason": "no force pushes; ask the operator"}' ;;
esac
```

```sh
chmod +x hooks/before_tool
echo '{"id":"c1","name":"bash","args":{"command":"git push --force"}}' | hooks/before_tool
arx check                                  # hooks: before_tool
```

Change a call (`before_tool`): make every `pytest` run quiet. The result then
ends with `[ran as: pytest -q]`:

```python
#!/usr/bin/env python3
import json
import sys

call = json.load(sys.stdin)
command = call["args"].get("command", "") if isinstance(call["args"], dict) else ""
if call["name"] == "bash" and command == "pytest":
    print(json.dumps({"args": {"command": "pytest -q"}}))
```

Add a hint to failed results (`after_tool`):

```python
#!/usr/bin/env python3
import json
import sys

event = json.load(sys.stdin)
if event["is_error"]:
    print(json.dumps({"result": event["result"] + "\nRead the full output first."}))
```

Keep only the last 40 messages in each request (`before_model`). This also
replaces the history:

```python
#!/usr/bin/env python3
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

Keep the agent working until a file exists (`stop`):

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
| The agent can turn off a plugin's guard | it can edit `plugins:` in `agent.yaml` | pin it from the command line: `--set 'plugins=["shell","guard"]'` |
| A `stop` hook always continues | the run ends only at a cap | give the agent a clear way to finish, such as a `DONE` file |

## Planned

Hooks will run in bands (`policy`, `normal`, `final`) and then in the order of
the active list. `before_tool` will get and set the call's `keys` for the tool
runtime, and `after_tool` will be able to print a `backoff`. A hook will be
able to start once per session and read one JSON line per call. See
[Planned changes](planned.md).
