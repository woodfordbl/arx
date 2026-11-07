# Hooks

A hook is an executable that arx runs at a fixed point of the run, the hook
point. It can add context, deny a tool call, add a note to a result, or keep
the agent working when it wants to stop.

**Status:** today. **Examples:** [`plugins/guard`](../../plugins/guard)
(`before_tool`), [`plugins/git-context`](../../plugins/git-context)
(`session_start`), [`plugins/fail-hint`](../../plugins/fail-hint)
(`after_tool`), and [`examples/plugins/hooks/stop`](../../examples/plugins/hooks/stop).

## Contract

A hook is the file `hooks/<point>` in any [layer](concepts.md#layer). The file
name is exactly the point name, with no extension.

- **Input (stdin):** one JSON object on one line. It has the fields of the
  point (table below), plus `point`, `session` (the session id) and `turn`.
- **Output (stdout):** nothing, which means "carry on", or one JSON object.
- **Errors and logs:** write them to stderr. arx keeps stderr apart from the
  answer, and shows it in the `hook` event when the hook fails.
- **Working directory:** the folder `arx` runs in.
- **Environment:** the [`ARX_*` variables](reference.md#environment). A hook
  in a plugin also gets `ARX_PLUGIN_DIR`.
- **Timeout:** 10 seconds by default.

| Point | When | Extra input | Output it may print |
|---|---|---|---|
| `session_start` | once, before the first model call of a new session | none (`turn` is 0) | `{"context": "..."}` |
| `before_tool` | before each tool call | `{"tool": {"name", "args"}}` | `{"decision": "deny", "reason": "..."}` |
| `after_tool` | after each tool call | `{"tool": {"name"}, "result": {"text", "error"}}` | `{"note": "..."}` |
| `stop` | when the model replies without calling a tool | `{"last_message": "..."}` | `{"decision": "continue", "message": "..."}` or `{"decision": "restart", "message": "..."}` |

**What each output does:**

- **`session_start` context** is added to the end of the first user message.
  The hook does not run again on `--resume`.
- **`before_tool` deny:** the tool does not run. The model gets
  `denied by the before_tool hook: <reason>` as the result. Any other output
  allows the call.
- **`after_tool` note** is added to the result as a new line,
  `[after_tool] <note>`, before the model sees it. `result.text` is cut at
  8 KB. `after_tool` also runs for a call that `before_tool` denied, and for
  an unknown tool.
- **`stop` continue:** arx sends `message` (default `Continue.`) to the agent
  as a user message, and the loop goes on. This is how "never stop" loops
  work.
- **`stop` restart:** arx clears the history and starts again from the system
  prompt, the first message and `message`. `session_start` does not run
  again. `last_message` is cut at 8 KB.
- **`stop` with no output,** or any other decision: the session ends.

**Options** for the hooks in the spec folder and the config folder go in the
spec. A plugin sets the options of its own hooks in its `plugin.yaml`, and
the spec's `hooks:` does not apply to them:

```yaml
hooks:
  before_tool: {timeout: 5s, fail: closed}
```

| Option | Default | Meaning |
|---|---|---|
| `timeout` | `10s` | At the timeout, arx stops the hook's process group, and the hook fails. |
| `fail` | `open` | `open` ignores a failed hook. `closed` makes a failed `before_tool` hook deny the call. At the other points, it only stops the later hooks for that point. |

**Failures:** a hook fails when it cannot start, exits non-zero, times out,
or prints something that is not a JSON object. arx writes a `hook` event with
an `error`, then ignores the hook (unless `fail: closed`). So a broken hook,
for example one the agent wrote, cannot stop the run.

## More than one hook

Each layer can have a hook for a point. They all run, in layer order: the
spec folder first, then project plugins, your config folder and user plugins.
Each hook gets the same input. The answers combine like this:

| Point | Rule |
|---|---|
| `session_start` | All contexts are joined, with a blank line between them. |
| `before_tool` | The first deny wins, and the later hooks do not run. |
| `after_tool` | All notes are joined, with a blank line between them. |
| `stop` | The first hook that prints a decision wins, and the later hooks do not run. |

`arx check` shows each point that has a hook, and the plugins it comes from:
`hooks: before_tool(guard) after_tool(fail-hint) stop`.

## Minimal example

```sh
#!/bin/sh
# hooks/before_tool: deny force pushes.
input=$(cat)
case "$input" in
  *'"name":"bash"'*'git push --force'*)
    echo '{"decision": "deny", "reason": "no force pushes; ask the operator"}' ;;
esac
```

```sh
chmod +x hooks/before_tool
echo '{"tool":{"name":"bash","args":{"command":"git push --force"}}}' | hooks/before_tool
arx check                                  # hooks: before_tool
```

A `stop` hook that keeps the agent working until a file exists:

```sh
#!/bin/sh
# hooks/stop
[ -f DONE ] && exit 0
echo '{"decision": "continue", "message": "Not done yet. When the task is complete, create the file DONE."}'
```

An `after_tool` hook in Python, reading the input with a JSON parser:

```python
#!/usr/bin/env python3
import json
import sys

event = json.load(sys.stdin)
if event["result"]["error"]:
    print(json.dumps({"note": "The tool failed. Read the full output first."}))
```

## Common mistakes

| Mistake | What happens | Fix |
|---|---|---|
| The file is not executable | arx does not run it, and gives no warning | `chmod +x`, then check that `arx check` lists the point |
| The file has an extension, such as `stop.sh` | arx does not run it | name the file exactly `stop` |
| The hook prints log lines to stdout | the output is not a JSON object, so the hook fails and is ignored | write logs to stderr |
| The hook prints an object with a typo, such as `"decison"` | it is a valid object with no decision, so the call is allowed | test the hook by hand with a sample input |
| The pattern expects spaces, such as `"name": "bash"` | arx sends compact JSON, `"name":"bash"`, so the pattern never matches | match the compact form, or parse the JSON |
| A plugin's hook options are in the spec | they apply only to hooks in the spec folder and the config folder | put them in the plugin's `plugin.yaml` under `hooks:` |
| A guard hook can fail open | if it crashes, every call goes through | set `fail: closed` for `before_tool` |
| The agent can turn off a plugin's guard | it can edit `plugins:` in `agent.yaml` | pin it from the command line: `--set 'plugins=["guard"]'` |
| A `stop` hook always continues | the run ends only at a cap | give the agent a clear way to finish, such as a `DONE` file |

## Planned

The redesign gives hooks the raw objects: `before_tool` can change the call or
give a result in place of the run, `after_tool` can change the result, and two
new points, `before_model` and `after_model`, wrap the model call. Hooks will
run in bands (`policy`, `normal`, `final`), and each hook gets the output of
the hook before it. Today's outputs keep working. See
[Planned changes](planned.md#hook-lifecycle).
