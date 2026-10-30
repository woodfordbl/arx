---
name: plugin-authoring
description: How to add a tool, hook or observer to your own harness, and how to check it.
---

# Adding to your harness

Everything here lives next to your spec and takes effect on your next turn.

- **Tool**: write an executable at `tools/<name>`, then `chmod +x` it. Running
  `tools/<name> --schema` must print
  `{"description": "...", "parameters": {<JSON Schema>}}`. A call gets the
  arguments as JSON on stdin; print the result, and exit non-zero on error.
- **Hook**: write an executable at `hooks/<point>` for `session_start`,
  `before_tool`, `after_tool` or `stop`. It gets JSON on stdin and may print a
  JSON decision.
- **Observer**: add a shell command to `observers:` in the spec. It reads
  one JSON event per line on stdin.

Check your work before relying on it:

    "$ARX_BIN" check --spec "$ARX_SPEC"     # spec, tools and hooks
    "$ARX_BIN" tools --spec "$ARX_SPEC"     # the tools as you will see them
    tools/<name> --schema                    # one tool's description

If a tool is skipped, a "Tool problems" note says why on your next turn.
