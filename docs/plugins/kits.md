# Kits

A kit is a folder that makes one kind of agent, such as a coding agent or a
research agent, by choosing which plugins a run uses, in which order, with
which settings and which prompt. A kit has no code. If something runs, it
belongs in a plugin. If it only chooses or configures, it belongs in a kit.

Use a kit when a run must load the same plugins every time, such as in an
experiment harness, so that a plugin you install later cannot change it. arx
ships three:
[`kits/coding`](../../kits/coding), [`kits/explorer`](../../kits/explorer)
and [`kits/research`](../../kits/research).

| | Plugin | Kit |
|---|---|---|
| Contains | `plugin.yaml`, `tools/`, `hooks/`, `skills/`, `commands/` | `kit.yaml`, `prompts/`, `init/`; no executables |
| Answers | What can the agent do? | Which agent is this? |
| Examples | `guard`, `shell`, `never-stop` | `coding`, `explorer`, `research` |

## What a kit contains

A kit is a folder `kits/<name>/` with a `kit.yaml`:

```text
coding/
  kit.yaml           # required
  prompts/system.md  # the system prompt, if kit.yaml names it
  init/              # files that `arx init coding` copies into a project
```

The `kit.yaml` of a coding kit lists its plugins in order, with settings
where a plugin needs them:

```yaml
name: coding                       # must match the folder name
version: 0.1.0
description: A general coding agent.
plugins:                           # in order: the position is the priority
  - guard
  - shell
  - never-stop: {message: "Next experiment."}   # a plugin with settings
model_settings: {reasoning_effort: medium}
prompt: prompts/system.md          # relative to the kit folder
```

| Key | Meaning |
|---|---|
| `name` | The kit's name: letters, digits, `_` and `-`. It must match the folder name. |
| `version`, `description` | Shown by `arx kit add` and `arx kit list`. |
| `plugins` | The plugins, in order. Each entry is a name, or `{name: {settings}}`. Required, unless the kit has `extends`. |
| `model_settings` | Extra request fields, as in the spec. |
| `prompt` | The system prompt file, relative to the kit folder. It becomes the spec's `instructions`. |
| `extends` | Another kit that this one starts from. |
| `enable`, `disable` | Plugins to add to the end of the list it extends, or to take out of it. |

These rules decide where arx finds a kit and what it does with it:

- **No executables**: arx rejects a kit with an executable file anywhere in
  its folder. `arx check --kit-dir`, `arx kit add` and a run all refuse it.
- **Where arx finds a kit**: `kits/<name>/` next to the spec, else
  `kits/<name>/` in your config folder, where `arx kit add` puts it.
- **How you use a kit**: `kit: NAME` in `agent.yaml` or `config.yaml`, or
  `arx --kit NAME` for one run.
- **What it sets**: the [active list](#the-active-list), the plugin settings,
  and, below the spec, `model_settings` and the prompt. The spec wins over
  the kit, and the kit wins over `config.yaml`. Plugins rank below
  `config.yaml`: their `model_settings` fill only the fields that no other
  source sets, and their `instructions` add to the kit's prompt.
- **A missing kit stops the run** with exit 2 and the message
  `kit NAME is not installed: run arx kit add NAME`. arx downloads nothing
  without asking.
- **Plugin names** are bare names (`guard`) or `OWNER/REPO/PATH` for a plugin
  in another repo, and may end in `@REF` to pin a version. `arx kit add`
  uses the full reference; a run uses only the name.
- **`kit.lock`**: when a kit pins a version with `@REF`, arx writes
  `kit.lock` next to the spec, with the source and commit of the kit and each
  plugin it loads. Keep it with the project to repeat a run.

## The active list

The active list is the ordered list of plugins that one run loads. The
position in the list is the priority: the first plugin's tool wins over a
later plugin's tool with the same name, and its hooks run first in their
[band](hooks.md#bands).

Four sources build the list. Each one changes the list that the sources
before it built:

1. **`config.yaml`**: your defaults, such as a default kit
   (`arx kit add NAME --default`) or a list.
2. **The kit**: the last `kit:` that a source names gives its plugins, in its
   order.
3. **`agent.yaml`**: the project.
4. **The launcher**: `--kit NAME` and `--set`.

Each source can use these keys:

| Key | Effect |
|---|---|
| `kit: NAME` | Replaces the list with the kit's plugins. |
| `plugins: [...]` | Replaces the list with these plugins. |
| `enable: [...]` | Adds these plugins at the end. |
| `disable: [...]` | Takes these plugins out. |

When no source names a kit or a `plugins:` list, every installed plugin is
on, minus the ones that `disable:` takes out. With a list, only the plugins
in it load, each from `./plugins/<name>/` or else from your user plugins, and
arx leaves out the loose files in your config folder (`tools/`, `hooks/`,
`skills/`). The agent's own tools and hooks in the spec folder always come
first. See [Layers](concepts.md#layer).

**Settings** for a plugin are the object after its name in any list:
`- never-stop: {message: "..."}`. They merge in the order `config.yaml`, the
kit, `agent.yaml`, `--set`, and the later value wins. arx applies the
settings in two ways:

- `tools` and `hooks` in the settings change the plugin's own tool and hook
  options, such as `shell: {tools: {edit: {enabled: false}}}`.
- `instructions` and `model_settings` in the settings change the plugin's
  prompt text and request fields, such as `reviewer: {instructions: null}`,
  which drops its text. See
  [Prompt text and model settings](prompt.md#change-one-plugins-text-and-settings).
- The plugin's hooks get all of its settings as JSON in
  `ARX_PLUGIN_SETTINGS`.

> [!TIP]
> Start a run with `--kit NAME` when the agent must not change its plugins.
> `--kit` is the same as `--set kit=NAME`, so it stays in force after every
> reload. The agent can edit `agent.yaml`, but it cannot change the kit of a
> run that started with `--kit`.

`arx plugin list` shows the active list for the current folder, with the
position, the state (`on`, `off`, `broken`, `missing`) and the reason for
each plugin:

```text
PLUGIN             VERSION   SCOPE    #   STATE    WHY                          SOURCE
guard              0.1.0     user     1   on       kit coding                   link to ...
shell              0.1.0     user     2   on       kit coding                   link to ...
lint               0.4.1     project  3   on       enable in agent.yaml         ...
notify             0.1.0     user     -   off      disable in agent.yaml        ...
Using kit coding (from agent.yaml).
```

## Commands

| Command | What it does |
|---|---|
| `arx kit add NAME` | Installs a kit and each plugin it names. A bare name comes from the kits that came with arx, else from the arx repo at the tag of your arx. |
| `arx kit add OWNER/REPO/PATH[@REF]` | Installs a kit folder from any GitHub repo. |
| `arx kit add ./PATH` | Installs a kit folder on this machine. When it is in `<marketplace>/kits/`, its plugins come from `<marketplace>/plugins/`. |
| `arx kit list` | Lists the installed kits, their versions, the default, and their sources. |
| `arx kit remove NAME` | Deletes the kit. Its plugins stay. |
| `arx plugin enable NAME` | Adds the plugin to `enable:` in `./agent.yaml`, and takes it out of `disable:`. |
| `arx plugin disable NAME` | Adds the plugin to `disable:` in `./agent.yaml`. |
| `arx init NAME` | Copies the kit's `init/` files into this folder, with an `agent.yaml` that has `kit: NAME`. |
| `arx config get\|set\|unset\|add\|remove KEY ...` | Reads or changes one top-level key of `agent.yaml`, or of `config.yaml` with `--global`. |
| `sh install.sh --kit NAME` | Installs arx, then runs `arx kit add NAME --default --yes`. |

These options and defaults apply to the commands in the table:

- **`arx kit add` options**: `--default` (also writes `kit: NAME` to
  `config.yaml`), `--link` (use local folders where they are), `--force`,
  `--yes`. It asks first and shows each plugin it will install; without a
  terminal it needs `--yes`. A kit that `extends` another adds that one too.
- **`--global`**: makes `arx plugin enable` and `disable` write
  `config.yaml`.
- **`arx plugin add`**: keeps a new plugin on. When your kit or list would
  leave it out, it adds the plugin to `enable:`. `--no-enable` skips this.
- **Shipped kits**: `make install` and the release put this repo's
  `plugins/` and `kits/` in `libexec/arx/`, next to the commands, so
  `arx kit add coding` needs no download. It links the shipped kit and
  plugins, so they stay at the version of your arx after `arx update`.

## The kits that ship with arx

Start from `coding` for most work. Use `explorer` for an agent that reads
and answers, and `research` for an experiment loop.

| Kit | Plugins | Use it when |
|---|---|---|
| `coding` | `guard`, `shell`, `git-context`, `fail-hint`, `reviewer`, `plugin-authoring`, `keep-last`, `word-count`, `clock`, `notify` | you want a general coding agent |
| `explorer` | `guard`, `shell` with `edit` off, `git-context`, `word-count`, `clock` | the agent should read and answer; `bash` can still change files |
| `research` | `shell`, `never-stop` with a message, `git-context` | you run an experiment loop that never stops; `arx init research` gives the files of `arx init autoresearch` |

## Write a kit

This kit makes a reviewer that reads a change and reports problems, and
never edits. It has two files:

```text
kits/review/
  kit.yaml
  prompts/system.md
```

The `kit.yaml` turns off the `edit` tool of the `shell` plugin:

```yaml
name: review
version: 0.1.0
description: Reads a change and reports problems; never edits.
plugins:
  - guard
  - shell: {tools: {edit: {enabled: false}}}
  - git-context
  - reviewer
prompt: prompts/system.md
```

Check the folder, check the harness with the kit, then run it:

```sh
arx check --kit-dir kits/review    # checks the folder, prints key=value lines
arx check --kit review             # the harness with this kit: tools, hooks, plugins
arx --kit review -p "Review the last commit"
```

To make a variant, start from another kit with `extends` and change its
list:

```yaml
name: coding-quiet
version: 0.1.0
description: The coding kit without notifications.
extends: coding
disable: [notify]
```

## Common mistakes

| Mistake | What happens | Fix |
|---|---|---|
| A script in the kit, such as `init/setup.sh` with `chmod +x` | arx rejects the kit, because a kit holds no code | move the script into a plugin, or `chmod -x` it |
| The kit leaves out `shell` | the agent has no `bash` and `edit` | list `shell` |
| A plugin in the list is not installed | `arx check` lists it as `missing` with `run arx plugin add NAME`; the run goes on without it | `arx kit add` the kit again, or add the plugin |
| You expect `kit:` in `agent.yaml` to add to your default kit | a kit replaces the list | use `enable:` and `disable:` to change a kit |
| The agent turns off a guard by editing `agent.yaml` | without a launcher pin it can | start the run with `--kit NAME` |
| Settings for a plugin that is not in the list | they do nothing | add the plugin with `enable:` and its settings |
| A kit that `extends` another gives settings in `enable:` for a plugin the other kit already lists | the plugin is already in the list, so arx skips that entry and its settings | list the plugins in full with `plugins:`, or give the settings in `agent.yaml` |
| A guard that must win runs in list order | a later hook can change its result | put its hook in the `policy` band (see [Bands](hooks.md#bands)) |
| A kit's `temperature` hides a plugin's | the kit's value wins, by design: plugins rank below the kit | set the field in `agent.yaml` to change it for the run; settings for the plugin change only its own value, at its rank |

**Planned:** a marketplace `index.yaml` will list each plugin and kit with
its versions, for `arx plugin search`. See [Planned changes](planned.md).

## Related

- [Plugin concepts](concepts.md#layer): how layers and the active list decide
  which part wins.
- [Hooks](hooks.md#bands): the `policy`, `normal` and `final` bands.
- [Plugin reference](reference.md#arx-plugin): every `arx plugin` command
  and option.
