# Plugin concepts

This page gives one meaning for each term in the plugin guide, and explains
how arx finds and loads plugins. Each term is marked:

- **Today:** it works in the current arx.
- **Planned:** it is designed but not built. See [Planned changes](planned.md).

## Terms

| Term | Status | Meaning |
|---|---|---|
| [Kind](#kind) | Today | One of the eight contracts: tool, subagent, hook, compactor, observer, driver, command, skill. |
| [Plugin](#plugin) | Today | A folder with a `plugin.yaml` that holds parts of one or more kinds. |
| [Layer](#layer) | Today | A folder that arx reads `tools/`, `hooks/` and `skills/` from. Layers have a fixed order. |
| [Hook point](#hook-point) | Today | A fixed place in the turn loop where hooks run. |
| [Marketplace](#marketplace) | Today | A Git repository with plugin folders in `plugins/<name>/`. |
| [Kit](#kit) | Planned | A folder with a `kit.yaml` and no code, that chooses plugins, their order and their settings. |
| [Active list](#active-list) | Planned | The ordered list of plugins that one run uses. |

Three words from [How arx works](../concepts.md) also appear here:

- **Spec:** the `agent.yaml` file, chosen with `--spec`. The **spec folder**
  is the folder it is in.
- **Harness:** the spec and everything it loads: prompts, tools, hooks,
  skills and plugins.
- **Config folder:** your defaults from `arx setup`, in `~/.config/arx/`, or
  `$ARX_CONFIG_DIR` when it is set.

## Kind

**Today.** A kind is a contract between arx and an executable: what arx gives
it, when, and what it must print. There are eight kinds:

| Kind | arx gives it | It prints |
|---|---|---|
| [Tool](tools.md) | the call's arguments as JSON | the result, as text |
| [Subagent](subagents.md) | a task | its final answer (arx does this for it) |
| [Hook](hooks.md) | the raw request, reply, call or result; or JSON about the moment | the fields it changes, or a decision |
| [Compactor](compactors.md) | the history as JSON | a shorter history as JSON |
| [Observer](observers.md) | the event stream, one JSON line per event | nothing |
| [Driver](drivers.md) | nothing: it runs arx | anything |
| [Command](commands.md) | its command-line arguments | anything |
| [Skill](skills.md) | nothing: it is a Markdown file the agent reads | — |

A **part** is one file or entry of a kind, such as the tool `greet` or the
hook `hooks/before_tool`.

## Plugin

**Today.** A plugin is a folder with a `plugin.yaml`. It holds parts of one or
more kinds, and you install, link or remove it as one unit:

```
guard/
  plugin.yaml          # required: name, version, description, ...
  tools/               # executables, one per tool
  hooks/               # executables named after hook points
  skills/<name>/SKILL.md
  commands/arx-<name>  # works only in a user plugin
  ...                  # any other files that plugin.yaml names
```

- **The name** in `plugin.yaml` must match the folder name. It uses letters,
  digits, `_` and `-`.
- **Paths** in `plugin.yaml` are relative to the plugin folder.
- **Settings** in `plugin.yaml` (tool options, observers, compactors) merge
  under the spec. Where both set a value, the spec wins.
- **A broken plugin is skipped.** If `plugin.yaml` is not valid, or the plugin
  needs a newer arx, arx skips the whole plugin and tells the agent why. A
  broken plugin cannot stop a run.

Parts do not have to be in a plugin. The agent's own tools and hooks live in
the spec folder, next to `agent.yaml`, and work the same way. A plugin is the
unit you share and install. Every field is in the
[reference](reference.md#pluginyaml).

## Layer

**Today.** A layer is a folder that arx reads `tools/`, `hooks/` and skills
from. arx builds the layers in this order:

| # | Layer | Folder |
|---|---|---|
| 1 | the spec folder | the folder of `agent.yaml`; skills come from the folder that `skills:` names |
| 2 | project plugins | `<spec folder>/plugins/<name>/`, in name order |
| 3 | your config folder | `~/.config/arx/` (`tools/`, `hooks/`, `skills/`) |
| 4 | user plugins | `~/.config/arx/plugins/<name>/`, in name order |

- Layers 3 and 4 are left out when the spec folder is the config folder.
- A folder in `plugins/` without a `plugin.yaml` is not a plugin. arx passes
  over it.
- A project plugin hides a user plugin with the same name.

**How the order is used:**

| Part | Rule |
|---|---|
| Tools | The first layer with a working tool of a name wins. arx tells the agent about each tool that a higher layer hides. |
| Hooks | Every layer's hook for a point runs, in layer order. Around the model and tool calls, each hook gets the object as the hook before it left it. See [More than one hook](hooks.md#more-than-one-hook). |
| Skills | `{{skills}}` lists the skills of every layer. When two layers have a skill folder with the same name, the first one wins. |
| Observers | All of them run. |
| Compactors | All names are available. When two places name the same compactor, the spec wins, then the first plugin. |
| Commands | Only user plugins (layer 4) add commands. See [Commands](commands.md). |

So a tool that the agent writes in its spec folder always wins over a
plugin's tool with the same name.

**On and off:** every installed plugin is on. A `plugins:` list in the spec
names the only plugins to use:

```yaml
plugins: [shell, guard]    # only these two
plugins: []                # no plugins at all, so no bash and edit either
```

`bash` and `edit` come from the `shell` plugin, so a list that leaves it out
leaves the agent without them.

A list also leaves out layer 3, so the harness is exactly the spec folder and
the plugins it names. Use a list in experiment harnesses, so that a plugin you
install later cannot change a run.

**Pinning:** the agent can edit `agent.yaml`, so it can also edit
`plugins:`. A value you give on the command line stays in force after every
reload:

```sh
arx -p "..." --set 'plugins=["shell","guard"]'
```

Write the list as JSON. `plugins=[guard]` is not valid.

**Reload:** before every model call, arx checks the files of every layer,
each `plugin.yaml`, and the `plugins/` folders. When something changed, it
loads the harness again. A plugin you add or remove takes effect on the next
turn. If the new harness is not valid, arx keeps the old one and tells the
agent why. Observers are the exception: they start once, when the session
starts.

## Hook point

**Today.** A hook point is a fixed place in the run where arx runs hooks.
There are six:

| Point | When | The hook gets |
|---|---|---|
| `session_start` | once, before the first model call of a new session | the session |
| `before_model` | before each model call | the request: messages, tools, model, settings |
| `after_model` | after each model call | the reply |
| `before_tool` | before each tool call | the call: id, name, args |
| `after_tool` | after each tool call | the call and its result |
| `stop` | when the model replies without calling a tool | the last message |

A hook is the executable `hooks/<point>` in any layer. See [Hooks](hooks.md).

**Planned:** hook bands (`policy`, `normal`, `final`) that order the hooks at
one point. See [Hook bands](planned.md#hook-bands).

## Marketplace

**Today.** A marketplace is a Git repository with plugin folders in
`plugins/<name>/`. The arx repository is the default marketplace, and its
[`plugins/`](../../plugins) folder has one working plugin of each kind. The
arx release does not include these plugins: it is only the binary and its
commands.

```sh
arx plugin add guard                  # plugins/guard from the arx repo, at the tag of your arx
arx plugin add acme/tools/lint        # a plugin folder in any GitHub repo
arx plugin add guard@main             # at a branch, tag or commit
```

See [`arx plugin`](reference.md#arx-plugin) for every command.

**Planned:** a marketplace can also hold kits in `kits/<name>/`, and an
`index.yaml` that lists each plugin and kit with its versions.

## Kit

**Planned.** A kit is a folder with a `kit.yaml`, prompts and project files,
and no executables. It chooses which plugins a run uses, in which order, with
which settings and which prompt. A kit makes one kind of agent, such as a
coding agent or a research agent.

The rule: if something runs, it belongs in a plugin. If it only chooses or
configures, it belongs in a kit. See [Kits](planned.md#kits).

## Active list

**Planned.** The active list is the ordered list of plugins that one run
uses. Only plugins in the list load, and the position in the list is the
priority. arx builds it from four sources, each one changing the list from the
source before it: your config folder, the kit, `agent.yaml`, then `--kit` and
`--set`.

Today the closest thing is the `plugins:` list, which chooses plugins but not
their order. See [The active list](planned.md#the-active-list).
