# Observers

An observer is a command that reads the event stream of a session while it
runs. Use it for notifications, logs, dashboards and metrics. It cannot
change the run.

**Status:** today. **Example:** [`plugins/notify`](../../plugins/notify).

## Contract

`observers:` in the spec, or in a plugin's `plugin.yaml`, is a list of shell
commands:

```yaml
observers: ["$ARX_SPEC_DIR/observers/notify.sh", "cat >> all-events.jsonl"]
```

- **How it runs:** each entry runs with `sh -c`, once for the whole session,
  from the folder `arx` runs in.
- **Input (stdin):** the [event stream](reference.md#events), one JSON
  object per line.
- **Output:** arx does not read it. The observer shares arx's own stdout and
  stderr.
- **Limit:** at most 8 observers per session. arx does not start the rest.
- **It cannot slow the run:** the pipe never blocks arx. An observer that
  falls behind loses events.
- **At the end:** the observer gets end of file when the session ends. arx
  waits up to one second for it to exit.
- **Environment:** the [`ARX_*` variables](reference.md#environment). An
  observer from a plugin also gets `ARX_PLUGIN_DIR`.
- **Plugins:** a plugin's observers are added to the spec's list. They do
  not replace it.

To read events without `observers:`, read `.arx/sessions/<id>/events.jsonl`,
or run `arx watch --json` from another terminal.

## Minimal example

```yaml
# plugin.yaml
name: notify
version: 0.1.0
description: Reports when a session ends.
observers: ['"$ARX_PLUGIN_DIR/observers/notify.sh"']
```

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
