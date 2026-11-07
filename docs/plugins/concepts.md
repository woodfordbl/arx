# Plugin concepts

This page gives one meaning for each term in the plugin guide, and explains
how arx finds and loads plugins. Each term is marked:

- **Today:** it works in the current arx.
- **Planned:** it is designed but not built. See [Planned changes](planned.md).

## Terms

| Term | Status | Meaning |
|---|---|---|
| [Kind](#kind) | Today | One of the nine contracts: tool, subagent, hook, scheduler, compactor, observer, driver, command, skill. |
| [Plugin](#plugin) | Today | A folder with a `plugin.yaml` that holds parts of one or more kinds. |
| [Layer](#layer) | Today | A folder that arx reads `tools/`, `hooks/` and `skills/` from. Layers have a fixed order. |
| [Hook point](#hook-point) | Today | A fixed place in the turn loop where hooks run. |
| [Marketplace](#marketplace) | Today | A Git repository with plugin folders in `plugins/<name>/`. |
| [Kit](#kit) | Today | A folder with a `kit.yaml` and no code, that chooses plugins, their order and their settings. |
| [Active list](#active-list) | Today | The ordered list of plugins that one run uses. |
| [Band](#band) | Today | The group a hook runs in at its point: `policy`, `normal` or `final`. |
| [Key](#key) | Today | A lock on a tool call: calls that share a key run one at a time. |

Three words from [How arx works](../concepts.md) also appear here:

- **Spec:** the `agent.yaml` file, chosen with `--spec`. The **spec folder**
  is the folder it is in.
- **Harness:** the spec and everything it loads: prompts, tools, hooks,
  skills and plugins.
- **Config folder:** your defaults from `arx setup`, in `~/.config/arx/`, or
  `$ARX_CONFIG_DIR` when it is set.

## Kind

**Today.** A kind is a contract between arx and an executable: what arx gives
it, when, and what it must print. There are nine kinds:

| Kind | arx gives it | It prints |
|---|---|---|
| [Tool](tools.md) | the call's arguments as JSON | the result, as text |
| [Subagent](subagents.md) | a task | its final answer (arx does this for it) |
| [Hook](hooks.md) | the raw request, reply, call or result; or JSON about the moment | the fields it changes, or a decision |
| [Scheduler](schedulers.md) | the queued tool calls, one JSON line each | which calls to start, one JSON line each |
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

**Today.** A layer is a folder that arx reads `tools/`, `hooks/`, skills and
a `scheduler` from. The spec folder is always the first layer. The rest
depend on whether the run has an [active list](#active-list):

| # | With a kit or a `plugins:` list | With neither |
|---|---|---|
| 1 | the spec folder | the spec folder |
| 2 | each plugin of the active list, in list order, from `<spec folder>/plugins/<name>/` or else `~/.config/arx/plugins/<name>/` | project plugins: `<spec folder>/plugins/<name>/`, in name order |
| 3 | — | your config folder: `~/.config/arx/` (`tools/`, `hooks/`, `skills/`) |
| 4 | — | user plugins: `~/.config/arx/plugins/<name>/`, in name order |

- In the spec folder, skills come from the folder that `skills:` names.
- The config folder and user plugins are left out when the spec folder is
  the config folder.
- A folder in `plugins/` without a `plugin.yaml` is not a plugin. arx passes
  over it.
- A project plugin hides a user plugin with the same name.
- `disable: [name]` takes a plugin out in both cases.

**How the order is used:**

| Part | Rule |
|---|---|
| Tools | The first layer with a working tool of a name wins. arx tells the agent about each tool that a higher layer hides. |
| Hooks | Every layer's hook for a point runs, by [band](#band), then in layer order. Around the model and tool calls, each hook gets the object as the hook before it left it. See [More than one hook](hooks.md#more-than-one-hook). |
| Scheduler | The first layer with an executable `scheduler` at its top wins. |
| Skills | `{{skills}}` lists the skills of every layer. When two layers have a skill folder with the same name, the first one wins. |
| Observers | All of them run. |
| Compactors | All names are available. When two places name the same compactor, the spec wins, then the first plugin. |
| Commands | Only user plugins add commands, whether or not they are in the active list. See [Commands](commands.md). |

So a tool that the agent writes in its spec folder always wins over a
plugin's tool with the same name.

**On and off:** without a kit or a list, every installed plugin is on. A
kit or a `plugins:` list names the only plugins to use, in order:

```yaml
kit: coding                # the coding kit's plugins, in its order
plugins: [guard, shell]    # only these two, in this order
plugins: []                # no plugins at all, so no bash and edit either
enable: [lint]             # add one to the kit or the list
disable: [notify]          # leave one out
```

`bash` and `edit` come from the `shell` plugin, so a list that leaves it out
leaves the agent without them. Use a kit or a list in experiment harnesses,
so that a plugin you install later cannot change a run. See
[The active list](kits.md#the-active-list).

**Pinning:** the agent can edit `agent.yaml`, so it can also edit `kit:` and
`plugins:`. A value you give on the command line stays in force after every
reload:

```sh
arx -p "..." --kit coding
arx -p "..." --set 'plugins=["guard","shell"]'
```

Write a `--set` list as JSON. `plugins=[guard]` is not valid.

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

Hooks at one point run by [band](#band) (`policy`, `normal`, `final`), then
in layer order.

## Marketplace

**Today.** A marketplace is a Git repository with plugin folders in
`plugins/<name>/`, and kits in `kits/<name>/`. The arx repository is the
default marketplace: its [`plugins/`](../../plugins) folder has one working
plugin of each kind, and [`kits/`](../../kits) has three kits. The release
ships both folders in `libexec/arx/`, next to the commands, so the shipped
plugins and kits install without a download.

```sh
arx plugin add guard                  # plugins/guard from the arx repo, at the tag of your arx
arx plugin add acme/tools/lint        # a plugin folder in any GitHub repo
arx plugin add guard@main             # at a branch, tag or commit
arx kit add coding                    # kits/coding and each plugin it names
```

See [`arx plugin`](reference.md#arx-plugin) and [`arx kit`](kits.md#commands)
for every command.

**Planned:** an `index.yaml` that lists each plugin and kit with its
versions, for `arx plugin search`.

## Kit

**Today.** A kit is a folder with a `kit.yaml`, prompts and project files,
and no executables. It chooses which plugins a run uses, in which order, with
which settings and which prompt. A kit makes one kind of agent, such as a
coding agent or a research agent. Use one with `kit: NAME` in `agent.yaml`,
or `arx --kit NAME`.

The rule: if something runs, it belongs in a plugin. If it only chooses or
configures, it belongs in a kit. See [Kits](kits.md).

## Active list

**Today.** The active list is the ordered list of plugins that one run uses.
Only plugins in the list load, and the position in the list is the priority.
arx builds it from four sources, each one changing the list from the source
before it: `config.yaml`, the kit, `agent.yaml`, then `--kit` and `--set`.
With no kit and no `plugins:` list in any source, every installed plugin is
on. `arx plugin list` shows the list and why each plugin is on or off. See
[The active list](kits.md#the-active-list).

## Band

**Today.** The hooks at one point run in three bands: `policy` first, then
`normal` (the default), then `final`. Inside a band they run in layer order.
A `result` that a `policy` hook sets is final. See [Bands](hooks.md#bands).

## Key

**Today.** Each tool call has a list of keys. Calls that share a key run one
at a time; a call with `*` runs alone; a call with `[]` runs with anything.
A tool declares its keys in its schema. See [Keys](tools.md#keys) and
[Schedulers](schedulers.md).
