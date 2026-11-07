# Tools

A tool is an action the model can call. It is an executable file in a
layer's `tools/` folder, and its file name is the tool name. Every tool comes
from a layer: `bash` and `edit` too, from the [`shell`](#bash-and-edit)
plugin.

**Status:** today. **Examples:** [`plugins/clock`](../../plugins/clock)
(shell), [`plugins/word-count`](../../plugins/word-count) (Python) and
[`plugins/shell`](../../plugins/shell) (a schema file and a direct start).

## Contract

| Step | What arx does | What the tool does |
|---|---|---|
| Describe | reads `tools/<name>.json`; if there is none, runs `<tool> --schema` with stdin empty and no `ARX_*` variables | `--schema` prints one JSON object, within 2 seconds, and exits 0 |
| Call | runs `<tool>` with no arguments, and the call's arguments as JSON on stdin | prints the result and exits |
| Result | reads stdout and stderr together | exits 0 for success, non-zero for an error |

**The schema** is the description the model sees:

```json
{"description": "What it does, for the model.",
 "parameters": {"type": "object", "properties": {...}, "required": [...]}}
```

- **Where it comes from:** a file `tools/<name>.json` next to the tool, or
  else the tool's `--schema` answer. With a schema file, arx starts no process
  to load the tool. A file that ends in `.json` is never a tool itself.
- **`parameters`** is a JSON Schema. If it is missing, arx uses an object with
  no properties.
- **Placeholders:** `{{timeout}}`, `{{tool_output.head}}` and
  `{{tool_output.tail}}` in the description become the spec's values for this
  tool, in seconds and bytes.
- **Cache:** arx keeps the schema until the tool or its schema file changes
  (modification time or size), so it is read once per change, not once per
  turn.

**A call:**

- **Working directory:** the folder `arx` runs in, not the tool's folder.
- **Environment:** the [`ARX_*` variables](reference.md#environment). A tool
  in a plugin also gets `ARX_PLUGIN_DIR`, the plugin's folder.
- **Errors:** a non-zero exit marks the result as an error, and the model
  sees `[exit code N]` after the output. An exit 0 with no output gives
  `(no output)`.
- **Timeout:** 120 seconds by default. At the timeout, arx stops the tool's
  whole process group (SIGTERM, then SIGKILL 3 seconds later), and the
  result says so.
- **Long output:** the model sees the first 2 KB and the last 6 KB, with a
  line that gives the path of the full output. arx saves all of it in
  `.arx/sessions/<id>/tool-NNNN.out`. `tool_output.head` and
  `tool_output.tail` in the spec change these sizes.

**Options** in the spec, or in the plugin's `plugin.yaml`:

```yaml
tools:
  word_count: {timeout: 10s}      # default 120s
  now: {enabled: false}           # hide the tool from the model
```

A plugin's options are defaults: the spec wins when both set a value.

## Minimal example

```sh
#!/bin/sh
# tools/now: the current date and time in UTC. It takes no arguments.
if [ "$1" = --schema ]; then
  echo '{"description": "The current date and time in UTC.", "parameters": {"type": "object", "properties": {}}}'
  exit 0
fi
date -u +%Y-%m-%dT%H:%M:%SZ
```

```sh
chmod +x tools/now
arx check                 # tools: now (and bash edit, with the shell plugin)
echo '{}' | tools/now     # try a call by hand
```

A tool that takes arguments reads them from stdin. In Python:

```python
#!/usr/bin/env python3
import json
import sys

if sys.argv[1:] == ["--schema"]:
    print(json.dumps({
        "description": "Count the words in a file.",
        "parameters": {
            "type": "object",
            "properties": {"path": {"type": "string"}},
            "required": ["path"],
        },
    }))
    sys.exit(0)

args = json.load(sys.stdin)
try:
    with open(args["path"]) as f:
        print(len(f.read().split()), "words")
except OSError as e:
    print(f"cannot read {args['path']}: {e.strerror}")
    sys.exit(1)
```

## bash and edit

`bash` and `edit` come from the [`shell`](../../plugins/shell) plugin. Their
code is in the arx binary, so they are fast and need no other programs. The
plugin only connects them:

```
plugins/shell/
  plugin.yaml
  tools/bash         # exec "$ARX_BIN" tool bash "$@"
  tools/bash.json    # the schema, with {{timeout}} and {{tool_output.*}}
  tools/edit         # exec "$ARX_BIN" tool edit "$@"
  tools/edit.json
```

- **`arx tool bash|edit`** runs a tool with the arguments as JSON on stdin,
  and `arx tool NAME --schema` prints its schema. `bash` runs `command` with
  `sh -c` and exits with its code. `edit` replaces one exact, unique string in
  a file, or creates a file when `old` is empty.
- **Direct start:** when a tool file only runs
  `exec "$ARX_BIN" tool NAME` (with an optional `"$@"`, a `#!` line and
  comments, in 512 bytes or less), arx starts `arx tool NAME` itself, without
  the shell. The result is the same.
- **Install:** `make install` and the release put a copy of the plugin in
  `libexec/arx/plugins/shell`, next to the commands. `arx setup` links that
  copy into your user plugins when you have no `shell` plugin yet, so it
  stays at the version of your arx after `arx update`. In a source checkout,
  it links the repo's `plugins/shell`.
- **No tools:** without the plugin, the agent has no tools and can only chat.
  `arx doctor` warns about this. A `plugins:` list that leaves out `shell`
  also leaves out `bash` and `edit`.
- **Settings:** `tools.bash.timeout`, `tools.edit.timeout` and
  `enabled: false` work as for any tool.
- **Replacing them:** put your own `bash` or `edit` in a higher layer, such
  as the spec folder or `./plugins/`. The first tool with a name wins, and
  `arx check` notes that the shell plugin's tool is hidden. Use this to run
  the tools somewhere else, such as in a sandbox.

## Names

- Letters, digits, `_` and `-` only. A file with any other name is skipped.
- When two layers have a tool with the same name, the first layer wins. See
  [Layers](concepts.md#layer).

## Common mistakes

| Mistake | What happens | Fix |
|---|---|---|
| The file is not executable | skipped: `tools/x is not executable (chmod +x it)` | `chmod +x tools/x` |
| A schema file, but no tool file | there is no tool: a `.json` file only describes the tool next to it | add the executable `tools/x` |
| The schema file is not valid JSON | skipped: `x.json must be a JSON object ...` | check it with `python3 -m json.tool tools/x.json` |
| `--schema` writes to stderr, for example a warning | arx reads stderr with stdout, so the JSON is not valid, and the tool is skipped | write nothing to stderr in `--schema`, or use a schema file |
| `--schema` is slow (it imports a large library) | skipped after 2 seconds | use a schema file, or answer `--schema` before you import anything slow |
| `--schema` reads `$ARX_PLUGIN_DIR` or another `ARX_*` variable | `--schema` runs without the `ARX_*` variables, so they are empty | make `--schema` print a fixed answer |
| The tool reads a path relative to its own file | it runs in the work folder, so the path is wrong | use `$ARX_PLUGIN_DIR` (in a plugin) or `$ARX_SPEC_DIR` |
| The tool prints a large file | the model sees only the head and tail | print a summary, and the path of the details |
| `tools.x` in the spec, but no `tools/x` file | `tools.x is configured but tools/x is missing` | add the file, or remove the entry |
| A `plugins:` list without `shell` | the agent has no `bash` or `edit` | add `shell` to the list |

arx tells the agent about each skipped tool in a "Tool problems" note, once.
`arx check` lists the same problems under `problems:`. It still exits 0, so
read that list.

## Planned

Tools will declare **keys** in their schema, so that calls that do not share
a key can run at the same time. A sandbox plugin will read a `sandbox:` value
from the spec. See [Planned changes](planned.md#tool-runtime).
