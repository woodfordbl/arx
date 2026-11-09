# Observers

An observer is a shell command that reads a session's event stream while the
session runs.

Use one for notifications, logs, dashboards and metrics. An observer sees
every event but cannot change the run: to change what the agent does, write a
[hook](hooks.md).

**Status:** today. **Example:** [`plugins/notify`](../../plugins/notify).

## Contract

### Add an observer

`observers:` in the spec, or in a plugin's `plugin.yaml`, is a list of shell
commands:

```yaml
# agent.yaml
observers: ["$ARX_SPEC_DIR/observers/notify.sh", "cat >> all-events.jsonl"]
```

A plugin's observers are added to the spec's list. They do not replace it.

### How observers run

- **Start**: arx runs each entry with `sh -c`, once for the whole session,
  from the folder `arx` runs in.
- **Input (stdin)**: the [event stream](reference.md#events), one JSON object
  per line.
- **Output**: arx does not read it. The observer shares arx's own stdout and
  stderr.
- **Limit**: at most 8 observers per session. arx does not start the rest.
- **Speed**: the pipe never blocks arx, so an observer cannot slow the run.
  An observer that falls behind loses events.
- **End**: the observer gets end of file when the session ends. arx waits up
  to one second for it to exit.
- **Environment**: the [`ARX_*` variables](reference.md#environment). An
  observer from a plugin also gets `ARX_PLUGIN_DIR`.

> [!NOTE]
> Observers start once, when the session starts. A reload does not restart
> them, so an edit to an observer takes effect in the next session.

You don't need `observers:` to read events. Read
`.arx/sessions/<id>/events.jsonl`, or run `arx watch --json` from another
terminal.

## Write an observer

This plugin reports when the top-level session ends. Its `plugin.yaml` names
the script by `$ARX_PLUGIN_DIR`, because observers run from the work folder:

```yaml
# plugin.yaml
name: notify
version: 0.1.0
description: Reports when a session ends.
observers: ['"$ARX_PLUGIN_DIR/observers/notify.sh"']
```

The script reads one event per line and acts only on `session.end` at depth
0:

```sh
#!/bin/sh
# observers/notify.sh: reports when the top-level session ends.
while IFS= read -r line; do
  case "$line" in
    *'"depth":0,'*'"type":"session.end"'*)
      echo "arx session $ARX_SESSION ended" >&2 ;;
  esac
done
```

## Common mistakes

| Mistake | What happens | Fix |
|---|---|---|
| A path in `observers:` is relative to the plugin or spec folder | the command runs in the work folder, so the path is wrong | use `"$ARX_PLUGIN_DIR/..."` or `"$ARX_SPEC_DIR/..."` |
| The path has no quotes inside the YAML string | a folder with spaces breaks the command | quote the variable: `'"$ARX_PLUGIN_DIR/x.sh"'` |
| The observer reacts to subagent events | a subagent's events are in the same stream, with a higher `depth` | check `"depth":0` |
| The observer is slow, such as one HTTP call per event | it falls behind and loses events | filter first, then act on the few events you need |
| You edit the observer during a run | the change has no effect until the next session | restart the session |
| The observer prints to stdout | the text mixes with the terminal view and with `--json` output | write to stderr or to a file |

## Planned

No change is planned for observers.

## Related

- [Plugin reference](reference.md#events): every event type and its fields.
- [Hooks](hooks.md): change the run at a fixed point in the turn loop.
- [Drivers](drivers.md): run arx from another program and read its result.
