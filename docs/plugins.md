# Plugins

A plugin adds something to arx: a tool for the model, a hook in the turn loop,
a compaction program, an event reader, a command or a skill. Each part is an
executable file in any language. arx starts it, gives it JSON, and reads what
it prints. Nothing is linked into the arx binary.

You can write the parts yourself, install them as a plugin folder, or let the
agent write them. arx checks its files before every model call, so a change is
live on the next turn.

## Start here

1. **[Quickstart](plugins/quickstart.md):** write a tool and a hook, and see
   them run in a session, in about five minutes. No API key needed.
2. **[Concepts](plugins/concepts.md):** what a plugin, a layer and a hook
   point are, and how arx loads them.
3. **The page for your kind** (table below): the contract, a working example,
   and the common mistakes.
4. **[Reference](plugins/reference.md):** every `plugin.yaml` field, `ARX_*`
   variable, event, session file, `arx plugin` command and exit code.

## The kinds

| Kind | What it is | Where it lives | When it runs | Example in [`plugins/`](../plugins) |
|---|---|---|---|---|
| [Tool](plugins/tools.md) | an action the model can call | `tools/<name>` | when the model calls it | `word-count`, `clock` |
| [Subagent](plugins/subagents.md) | a tool that runs arx again, with its own spec | `tools: {name: {agent: spec.yaml}}` | when the model calls it | `reviewer` |
| [Hook](plugins/hooks.md) | a check or change at a fixed point of the loop | `hooks/<point>` | at its hook point | `guard`, `git-context`, `fail-hint` |
| [Compactor](plugins/compactors.md) | a program that shortens the history | `compactors: {name: path}` | when the prompt passes the trigger | `keep-last` |
| [Observer](plugins/observers.md) | a reader of the event stream | `observers: [command]` | for the whole session | `notify` |
| [Driver](plugins/drivers.md) | a program that runs arx | anywhere | when you run it | [`resume_on_cap.sh`](../examples/plugins/drivers/resume_on_cap.sh) |
| [Command](plugins/commands.md) | a new `arx <name>` subcommand | `commands/arx-<name>` | when you type `arx <name>` | [`commands/`](../commands) |
| [Skill](plugins/skills.md) | instructions the agent reads when it needs them | `skills/<name>/SKILL.md` | when the agent reads it | `plugin-authoring` |

Paths are relative to a [layer](plugins/concepts.md#layer): the spec folder,
a plugin folder, or your config folder.

## More

- **[Planned changes](plugins/planned.md):** hooks on the raw request and
  reply, a tool runtime that runs calls in parallel, the `shell` plugin, and
  kits. None of this is built yet.
- **[The marketplace](../plugins):** one working plugin of each kind.
  [`examples/plugins/`](../examples/plugins) is a harness that uses all of
  them, and `make test` runs it.
- **Commands to remember:**

  ```sh
  arx check                    # the spec, tools, hooks and plugins, with any problems
  arx tools                    # the tools as the model sees them
  arx check --plugin DIR       # one plugin folder, before you install it
  arx plugin add --link DIR    # use a plugin from where it is, while you work on it
  ```
