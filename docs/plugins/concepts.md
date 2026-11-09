# Plugin concepts

arx finds plugins in a fixed order of folders, called layers, and runs their
parts at fixed points in the turn loop. Each term on this page has one
meaning across the plugin guide, and the load rules decide which part wins
when two layers give the same name.

Everything here works in the current arx, except where a sentence starts
with **Planned:**. [Planned changes](planned.md) lists what is designed but
not built.

## Terms at a glance

| Term | Meaning |
|---|---|
| [Kind](#kind) | One of the nine contracts: tool, subagent, hook, scheduler, compactor, observer, driver, command, skill. |
| [Plugin](#plugin) | A folder with a `plugin.yaml` that holds parts of one or more kinds. |
| [Layer](#layer) | A folder that arx reads `tools/`, `hooks/` and `skills/` from. Layers have a fixed order. |
| [Hook point](#hook-point) | A fixed place in the turn loop where hooks run. |
| [Marketplace](#marketplace) | A Git repository with plugin folders in `plugins/<name>/`. |
| [Kit](#kit) | A folder with a `kit.yaml` and no code, that chooses plugins, their order and their settings. |
| [Active list](#active-list) | The ordered list of plugins that one run uses. |
| [Band](#band) | The group a hook runs in at its point: `policy`, `normal` or `final`. |
| [Key](#key) | A lock on a tool call: calls that share a key run one at a time. |

Three words from [How arx works](../concepts.md) also appear here:

- **Spec**: the `agent.yaml` file, chosen with `--spec`. The **spec folder**
  is the folder it is in.
- **Harness**: the spec and everything it loads: prompts, tools, hooks,
  skills and plugins.
- **Config folder**: your defaults from `arx setup`, in `~/.config/arx/`, or
  `$ARX_CONFIG_DIR` when it is set.

## Kind

A kind is a contract between arx and an executable: what arx gives it, when,
and what it must print. There are nine kinds:

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
| [Skill](skills.md) | nothing: it is a Markdown file the agent reads | nothing: the agent reads it |

A **part** is one file or entry of a kind, such as the tool `greet` or the
hook `hooks/before_tool`.

## Plugin

A plugin is a folder with a `plugin.yaml`. It holds parts of one or more
kinds, and you install, link or remove it as one unit:

```text
guard/
  plugin.yaml          # required: name, version, description, ...
  tools/               # executables, one per tool
  hooks/               # executables named after hook points
  skills/<name>/SKILL.md
  commands/arx-<name>  # works only in a user plugin
  ...                  # any other files that plugin.yaml names
```

These rules apply to every plugin:

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
unit you share and install. The [reference](reference.md#pluginyaml) lists
every field.

## Layer

A layer is a folder that arx reads `tools/`, `hooks/`, skills and a
`scheduler` from. The spec folder is always the first layer. The rest depend
on whether the run has an [active list](#active-list):

| # | With a kit or a `plugins:` list | With neither |
|---|---|---|
| 1 | the spec folder | the spec folder |
| 2 | each plugin of the active list, in list order, from `<spec folder>/plugins/<name>/` or else `~/.config/arx/plugins/<name>/` | project plugins: `<spec folder>/plugins/<name>/`, in name order |
| 3 | none | your config folder: `~/.config/arx/` (`tools/`, `hooks/`, `skills/`) |
| 4 | none | user plugins: `~/.config/arx/plugins/<name>/`, in name order |

A few details of the order:

- In the spec folder, skills come from the folder that `skills:` names.
- arx leaves out the config folder and user plugins when the spec folder is
  the config folder.
- A folder in `plugins/` without a `plugin.yaml` is not a plugin. arx passes
  over it.
- A project plugin hides a user plugin with the same name.
- `disable: [name]` takes a plugin out in both cases.

### Which part wins

Each kind uses the layer order in its own way:

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

### Turn plugins on and off

Without a kit or a list, every installed plugin is on. A kit or a `plugins:`
list names the only plugins to use, in order:

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

### Pin the list from the command line

The agent can edit `agent.yaml`, so it can also edit `kit:` and `plugins:`.
A value you give on the command line stays in force after every reload:

```sh
arx -p "..." --kit coding
arx -p "..." --set 'plugins=["guard","shell"]'
```

Write a `--set` list as JSON. `plugins=[guard]` is not valid.

### Reload

Before every model call, arx checks the files of every layer, each
`plugin.yaml`, and the `plugins/` folders. When something changed, it loads
the harness again, so a plugin you add or remove takes effect on the next
turn. If the new harness is not valid, arx keeps the old one and tells the
agent why.

> [!NOTE]
> Observers are the exception to reload. They start once, when the session
> starts.

## Hook point

A hook point is a fixed place in the run where arx runs hooks. There are
six:

| Point | When | The hook gets |
|---|---|---|
| `session_start` | once, before the first model call of a new session | the session |
| `before_model` | before each model call | the request: messages, tools, model, settings |
| `after_model` | after each model call | the reply |
| `before_tool` | before each tool call | the call: id, name, args |
| `after_tool` | after each tool call | the call and its result |
| `stop` | when the model replies without calling a tool | the last message |

A hook is the executable `hooks/<point>` in any layer. Hooks at one point run
by [band](#band) (`policy`, `normal`, `final`), then in layer order. See
[Hooks](hooks.md).

## Marketplace

A marketplace is a Git repository with plugin folders in `plugins/<name>/`,
and kits in `kits/<name>/`. The arx repository is the default marketplace:
its [`plugins/`](../../plugins) folder has one working plugin of each kind,
and [`kits/`](../../kits) has three kits. The release ships both folders in
`libexec/arx/`, next to the commands, so the shipped plugins and kits install
without a download.

```sh
arx plugin add guard                  # plugins/guard from the arx repo, at the tag of your arx
arx plugin add acme/tools/lint        # a plugin folder in any GitHub repo
arx plugin add guard@main             # at a branch, tag or commit
arx kit add coding                    # kits/coding and each plugin it names
```

[`arx plugin`](reference.md#arx-plugin) and [`arx kit`](kits.md#commands)
list every command.

**Planned:** an `index.yaml` will list each plugin and kit with its
versions, for `arx plugin search`.

## Kit

A kit is a folder with a `kit.yaml`, prompts and project files, and no
executables. It chooses which plugins a run uses, in which order, with which
settings and which prompt. A kit makes one kind of agent, such as a coding
agent or a research agent. Use one with `kit: NAME` in `agent.yaml`, or
`arx --kit NAME`.

The rule: if something runs, it belongs in a plugin. If it only chooses or
configures, it belongs in a kit. See [Kits](kits.md).

## Active list

The active list is the ordered list of plugins that one run uses. Only
plugins in the list load, and the position in the list is the priority.

arx builds it from four sources, each one changing the list from the source
before it: `config.yaml`, the kit, `agent.yaml`, then `--kit` and `--set`.
With no kit and no `plugins:` list in any source, every installed plugin is
on. `arx plugin list` shows the list and why each plugin is on or off. See
[The active list](kits.md#the-active-list).

## Band

A band is the group a hook runs in at its point. There are three: `policy`
first, then `normal` (the default), then `final`. Inside a band, hooks run
in layer order. A `result` that a `policy` hook sets is final. See
[Bands](hooks.md#bands).

## Key

A key is a lock on a tool call. Each call has a list of keys, and calls that
share a key run one at a time. A call with `*` runs alone, and a call with
`[]` runs with anything. A tool declares its keys in its schema. See
[Keys](tools.md#keys) and [Schedulers](schedulers.md).

## Next steps

- [Plugin quickstart](quickstart.md): write a tool and a hook, and watch the
  layers load them.
- [Hooks](hooks.md): learn what each hook point gets and what it can change.
- [Kits](kits.md): build an active list and pin it for a run.
- [Plugin reference](reference.md): look up every `plugin.yaml` field and
  `arx plugin` command.
