# Tools

A tool is an executable in a layer's `tools/` folder that the model can
call by name.

Write a tool for an action you want the model to call with typed arguments,
and with a description it reads before every call. The file name is the
tool name. Every tool comes from a layer, `bash` and `edit` too: they come
from the [`shell`](#bash-and-edit) plugin.

**Status:** today. **Examples:** [`plugins/clock`](../../plugins/clock)
(shell), [`plugins/word-count`](../../plugins/word-count) (Python) and
[`plugins/shell`](../../plugins/shell) (a schema file and a direct start).

## Contract

arx runs a tool in two ways: once to read its schema, and once for each
call.

| Step | What arx does | What the tool does |
|---|---|---|
| Describe | reads `tools/<name>.json`; if there is none, runs `<tool> --schema` with stdin empty and no `ARX_*` variables | `--schema` prints one JSON object, within 2 seconds, and exits 0 |
| Call | runs `<tool>` with no arguments, and the call's arguments as JSON on stdin | prints the result and exits |
| Result | reads stdout and stderr together | exits 0 for success, non-zero for an error |

### The schema

The schema is the description the model sees:

```json
{"description": "What it does, for the model.",
 "parameters": {"type": "object", "properties": {...}, "required": [...]}}
```

- **Where it comes from**: a file `tools/<name>.json` next to the tool, or
  else the tool's `--schema` answer. With a schema file, arx starts no
  process to load the tool. A file that ends in `.json` is never a tool
  itself.
- **`parameters`**: a JSON Schema. If it is missing, arx uses an object with
  no properties.
- **Placeholders**: `{{timeout}}`, `{{tool_output.head}}` and
  `{{tool_output.tail}}` in the description become the spec's values for
  this tool, in seconds and bytes.
- **Cache**: arx keeps the schema until the tool or its schema file changes
  (modification time or size). So it reads the schema once per change, not
  once per turn.

### A call

- **Working directory**: the folder `arx` runs in, not the tool's folder.
- **Environment**: the [`ARX_*` variables](reference.md#environment). A
  tool in a plugin also gets `ARX_PLUGIN_DIR`, the plugin's folder, and its
  [state folders](concepts.md#plugin-state): `ARX_STATE_DIR` for this
  session and `ARX_DATA_DIR` across sessions.
- **Errors**: a non-zero exit marks the result as an error, and the model
  sees `[exit code N]` after the output. An exit 0 with no output gives
  `(no output)`.
- **Timeout**: 120 seconds by default. At the timeout, arx stops the tool's
  whole process group (SIGTERM, then SIGKILL 3 seconds later), and the
  result says so.
- **Long output**: the model sees the first 2 KB and the last 6 KB, with a
  line that gives the path of the full output. arx saves all of it in
  `.arx/sessions/<id>/tool-NNNN.out`. `tool_output.head` and
  `tool_output.tail` in the spec change these sizes.

### Options

Set a tool's options in the spec, or in the plugin's `plugin.yaml`:

```yaml
tools:
  word_count: {timeout: 10s}      # default 120s
  now: {enabled: false}           # hide the tool from the model
```

A plugin's options are defaults: the spec wins when both set a value.

## Write a tool

This tool takes no arguments and prints the time. Save it as `tools/now`:

```sh
#!/bin/sh
# tools/now: the current date and time in UTC. It takes no arguments.
if [ "$1" = --schema ]; then
  echo '{"description": "The current date and time in UTC.", "parameters": {"type": "object", "properties": {}}}'
  exit 0
fi
date -u +%Y-%m-%dT%H:%M:%SZ
```

Make it executable, check that arx finds it, and try a call by hand:

```sh
chmod +x tools/now
arx check                 # tools: now (and bash edit, with the shell plugin)
echo '{}' | tools/now     # try a call by hand
```

`arx check` lists `now` under `tools:`, and the call prints the time.

### Take arguments

A tool that takes arguments reads them as JSON from stdin. This Python tool
counts the words in a file, and exits 1 when it can't read it:

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

## Keys

Keys decide which calls of one reply can run at the same time. Each call
has a list of **keys**, and a key works as a lock:

| Keys | Effect | Use it when |
|---|---|---|
| `["*"]` | the call runs alone; this is the default for a tool that declares no keys | the tool can change anything, as a shell can |
| `[]` | the call runs with any other call; this is the default for a subagent, `mcp_search` and `mcp_select` | the tool only reads, such as a search |
| `["file:{path}"]` | calls with the same key run one at a time; calls with different keys run together | the tool writes one thing that an argument names |

Declare them in the schema (the schema file or `--schema`):

```json
{"description": "...", "parameters": {...}, "keys": ["file:{path}"]}
```

- **`{arg}`**: puts in the value of the top-level argument `arg`. A string
  goes in as it is, any other value as JSON, and nothing when it is missing.
- **`host:`**: at the start of a key, keeps only the host of each value: no
  scheme, user, port or path, in lower case. `["host:{url}"]` gives one
  request to each host at a time.
- **A key list must be a list of strings.** If not, arx skips the tool.
- **Examples**: `edit` declares `["file:{path}"]`, so edits to different
  files run together. `bash` declares none, so it runs alone, because a
  shell can change anything. A read-only search tool can declare `[]`.
- **A `before_tool` hook** sees the keys in the call and can print new ones,
  for example `[]` for `git status`, or one key for `./a.py` and `a.py`. If
  a hook changes the name or the arguments but not the keys, arx computes
  the keys again for the new call.
- **The results** go to the model in call order, so the transcript is the
  same as when the calls run one at a time.

The [built-in scheduler](schedulers.md) starts calls by their keys. A
scheduler plugin can replace it.

An MCP tool takes its keys from its server's entry: `keys` in
[`mcp_servers`](../spec.md#mcp_servers), and `["*"]` without it. arx ignores
a server's `readOnlyHint`, since a server can claim anything.

## bash and edit

`bash` and `edit` come from the [`shell`](../../plugins/shell) plugin. Their
code is in the arx binary, so they are fast and need no other programs. The
plugin only connects them:

```text
plugins/shell/
  plugin.yaml
  tools/bash         # exec "$ARX_BIN" tool bash "$@"
  tools/bash.json    # the schema, with {{timeout}} and {{tool_output.*}}
  tools/edit         # exec "$ARX_BIN" tool edit "$@"
  tools/edit.json
```

- **What they do**: `bash` runs `command` with `sh -c` and exits with its
  code. `edit` replaces one exact, unique string in a file, or creates a
  file when `old` is empty.
- **`arx tool bash|edit`**: runs a tool with the arguments as JSON on
  stdin. `arx tool NAME --schema` prints its schema.
- **Direct start**: when a tool file only runs `exec "$ARX_BIN" tool NAME`
  (with an optional `"$@"`, a `#!` line and comments, in 512 bytes or less),
  arx starts `arx tool NAME` itself, without the shell. The result is the
  same.
- **Install**: `make install` and the release put a copy of the plugin in
  `libexec/arx/plugins/shell`, next to the commands. `arx setup` links that
  copy into your user plugins when you have no `shell` plugin yet, so it
  stays at the version of your arx after `arx update`. In a source checkout,
  it links the repo's `plugins/shell`.
- **Without the plugin**: the agent has no tools and can only chat.
  `arx doctor` warns about this. A `plugins:` list that leaves out `shell`
  also leaves out `bash` and `edit`.
- **Settings**: `tools.bash.timeout`, `tools.edit.timeout` and
  `enabled: false` work as for any tool.

To run the tools somewhere else, such as in a sandbox, replace them. Put
your own `bash` or `edit` in a higher layer, such as the spec folder or a
plugin before `shell` in the active list. The first tool with a name wins.
When a plugin hides another plugin's tool, `arx check` warns, unless the
plugin says so with `replaces: [bash]` in its `plugin.yaml`.

## Tool names

- A name uses letters, digits, `_` and `-` only. arx skips a file with any
  other name.
- When two layers have a tool with the same name, the first layer wins. See
  [Layers](concepts.md#layer).
- A tool of an [MCP server](../mcp.md) is named `<server>__<tool>`, such as
  `github__create_issue`. Other characters in the server's name for it
  become `_`. A name over 64 characters, or one that two tools share, keeps
  its first 55 characters and ends in `_` and 6 hex digits.
- A tool file with the name of an MCP tool wins. A file named `mcp_search`
  or `mcp_select` replaces that tool.

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
| The tool writes to `$ARX_STATE_DIR` before it exists | `No such file or directory`: arx makes neither state folder | `mkdir -p "$ARX_STATE_DIR"` first |
| The tool prints a large file | the model sees only the head and tail | print a summary, and the path of the details |
| `tools.x` in the spec, but no `tools/x` file | `tools.x is configured but tools/x is missing` | add the file, or remove the entry |
| A `plugins:` list or a kit without `shell` | the agent has no `bash` or `edit` | add `shell` to the list |
| A tool that writes files declares `[]` | two calls can write the same file at the same time | declare a key per file, such as `["file:{path}"]`, or none |

arx tells the agent about each skipped tool in a "Tool problems" note, once.
`arx check` lists the same problems under `problems:`.

> [!NOTE]
> `arx check` still exits 0 when it lists problems, so read the
> `problems:` list rather than trusting the exit code.

## Planned

**Planned:** a `sandbox:` value in the spec, which arx gives to each tool as
`ARX_SANDBOX`, so that a sandbox plugin's `bash` and `edit` know where to
run. See [Planned changes](planned.md).

## Related

- [Hooks](hooks.md): guard, change or log each call with `before_tool` and
  `after_tool`.
- [Schedulers](schedulers.md): decide when calls run, beyond their keys.
- [Subagents](subagents.md): a tool that runs a whole agent with its own
  spec.
- [Plugin reference](reference.md#environment): every `ARX_*` variable a
  tool gets.
