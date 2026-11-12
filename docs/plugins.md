# Plugins

A plugin adds a capability to arx: a tool for the model, a hook in the turn
loop, a compaction program, an event reader, a command, a skill, or a way to
reach a model endpoint. Each part is its own executable in any language,
except a skill, which is a Markdown file. arx starts the executable, gives it JSON, and reads what it prints.
Nothing is linked into the arx binary.

You can write the parts yourself, install them as a plugin folder, or let the
agent write them. arx checks the harness files before every model call, so a
change is live on the next turn.

## Start here

Follow this path the first time you extend arx:

1. **[Quickstart](plugins/quickstart.md)**: write a tool and a hook, and see
   them run in a session. It takes about five minutes and needs no API key.
2. **[Concepts](plugins/concepts.md)**: learn what a plugin, a layer and a
   hook point are, and how arx loads them.
3. **The page for your kind**: find it in the table on this page. Each one
   gives the contract, a working example, and the common mistakes.
4. **[Reference](plugins/reference.md)**: look up every `plugin.yaml` field,
   `ARX_*` variable, event, session file, `arx plugin` command and exit code.
5. **[Kits](plugins/kits.md)**: choose the plugins of a run, in order, to
   make one kind of agent.
6. **[Policies](plugins/policies.md)**: keep a guard in every run, and decide
   which harness edits of the agent load.

## The kinds

Each kind is a contract between arx and an executable. Pick the kind by what
you want to change:

| Kind | Use it to | Where it lives | When it runs | Example in [`plugins/`](../plugins) |
|---|---|---|---|---|
| [Tool](plugins/tools.md) | give the model an action it can call | `tools/<name>` | when the model calls it | `shell` (`bash`, `edit`), `word-count`, `clock` |
| [Subagent](plugins/subagents.md) | give the model a tool that runs arx again, with its own spec | `tools: {name: {agent: spec.yaml}}` | when the model calls it | `reviewer` |
| [Hook](plugins/hooks.md) | check or change the request, reply, call or result | `hooks/<point>` | at its hook point | `guard`, `git-context`, `fail-hint`, `never-stop` |
| [Scheduler](plugins/schedulers.md) | decide when tool calls run | `scheduler` at the top of a layer | for the whole session | none |
| [Compactor](plugins/compactors.md) | shorten the history | `compactors: {name: path}` | when the prompt passes the trigger | `keep-last` |
| [Observer](plugins/observers.md) | read the event stream | `observers: [command]` | for the whole session | `notify` |
| [Driver](plugins/drivers.md) | run arx from a program | anywhere | when you run it | [`resume_on_cap.sh`](../examples/plugins/drivers/resume_on_cap.sh) |
| [Command](plugins/commands.md) | add an `arx <name>` subcommand | `commands/arx-<name>` | when you type `arx <name>` | [`commands/`](../commands) |
| [Skill](plugins/skills.md) | give the agent instructions it reads when it needs them | `skills/<name>/SKILL.md` | when the agent reads it | `plugin-authoring` |
| [Credential](plugins/credentials.md) | get the key and base URL for model calls from a program | `credentials: {name: path}` | before model calls, when its value is missing or expires | `op-key`, `chatgpt` |
| [Adapter](plugins/adapters.md) | translate model calls for an endpoint that does not speak Chat Completions | `adapters: {name: path}` | around each call to the endpoint | `chatgpt` (`responses`) |

Paths are relative to a [layer](plugins/concepts.md#layer): the spec folder,
a plugin folder, or your config folder.

A plugin can also add text to the system prompt with `instructions`, and
fields to the model request with `model_settings`. These are keys in its
`plugin.yaml`, not executables, so the table has no row for them. See
[Prompt text and model settings](plugins/prompt.md).

A [kit](plugins/kits.md) is not a plugin, because it has no code. It chooses
the plugins of a run, their order and settings, and the prompt, so it makes
one kind of agent. arx ships three in [`kits/`](../kits): `coding`,
`explorer` and `research`.

## Check a plugin before you use it

These commands cover most plugin work:

```sh
arx check                    # the spec, tools, hooks and plugins, with any problems
arx tools                    # the tools as the model sees them
arx check --plugin DIR       # one plugin folder, before you install it
arx check --hosts            # the network hosts a run needs, one per line
arx plugin add --link DIR    # use a plugin from where it is, while you work on it
```

## Next steps

- [Plugin quickstart](plugins/quickstart.md): write your first tool and hook.
- [The marketplace](../plugins): browse one working plugin of each kind.
  [`examples/plugins/`](../examples/plugins) is a harness that uses all of
  them, and `make test` runs it.
- [Planned changes](plugins/planned.md): see what is designed but not built:
  sandboxes and a marketplace index.
