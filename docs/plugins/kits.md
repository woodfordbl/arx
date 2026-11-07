# Kits

A kit makes one kind of agent, such as a coding agent or a research agent. It
chooses which plugins a run uses, in which order, with which settings, and
with which prompt. A kit has no code: if something runs, it belongs in a
plugin; if it only chooses or configures, it belongs in a kit.

**Status:** today. **Examples:** [`kits/coding`](../../kits/coding),
[`kits/explorer`](../../kits/explorer) and
[`kits/research`](../../kits/research).

| | Plugin | Kit |
|---|---|---|
| Contains | `plugin.yaml`, `tools/`, `hooks/`, `skills/`, `commands/` | `kit.yaml`, `prompts/`, `init/`; no executables |
| Answers | What can the agent do? | Which agent is this? |
| Examples | `guard`, `shell`, `never-stop` | `coding`, `explorer`, `research` |

## Contract

A kit is a folder `kits/<name>/` with a `kit.yaml`:

```
coding/
  kit.yaml           # required
  prompts/system.md  # the system prompt, if kit.yaml names it
  init/              # files that `arx init coding` copies into a project
```

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

- **No executables:** a kit with an executable file anywhere in its folder
  is rejected: `arx check --kit-dir`, `arx kit add` and a run all refuse it.
- **Where arx finds a kit:** `kits/<name>/` next to the spec, else
  `kits/<name>/` in your config folder (where `arx kit add` puts it).
- **Using a kit:** `kit: NAME` in `agent.yaml` or `config.yaml`, or
  `arx --kit NAME` for one run.
- **What it sets:** the active list (below), the plugin settings, and, below
  the spec, `model_settings` and the prompt. The spec wins over the kit, and
  the kit wins over `config.yaml`.
- **A missing kit stops the run** with exit 2 and the message
  `kit NAME is not installed: run arx kit add NAME`. arx downloads nothing
  without a question.
- **Plugin names** are bare names (`guard`), `OWNER/REPO/PATH` for a plugin
  in another repo, and may end in `@REF` to pin a version. `arx kit add`
  uses the full reference; a run uses only the name.
- **`kit.lock`:** when a kit pins a version with `@REF`, arx writes
  `kit.lock` next to the spec, with the source and commit of the kit and each
  plugin it loads. Keep it with the project to repeat a run.

## The active list

Each run uses one **active list**: the plugins that load, in order. The
position in the list is the priority: the first plugin's tool wins over a
later plugin's tool with the same name, and its hooks run first in their
[band](hooks.md#bands).

Four sources build the list. Each one changes the list that the sources
before it built:

1. **`config.yaml`:** your defaults, such as a default kit
   (`arx kit add NAME --default`) or a list.
2. **The kit:** the last `kit:` that a source names gives its plugins, in its
   order.
3. **`agent.yaml`:** the project.
4. **The launcher:** `--kit NAME` and `--set`.

In each source:

| Key | Effect |
|---|---|
| `kit: NAME` | replaces the list with the kit's plugins |
| `plugins: [...]` | replaces the list with these plugins |
| `enable: [...]` | adds these plugins at the end |
| `disable: [...]` | takes these plugins out |

When no source names a kit or a `plugins:` list, every installed plugin is
on, minus the ones that `disable:` takes out. With a list, only the plugins
in it load, each from `./plugins/<name>/` or else from your user plugins, and
the loose files in your config folder (`tools/`, `hooks/`, `skills/`) are
left out. The agent's own tools and hooks in the spec folder always come
first. See [Layers](concepts.md#layer).

**Settings** for a plugin are the object after its name in any list:
`- never-stop: {message: "..."}`. They merge in the order `config.yaml`, the
kit, `agent.yaml`, `--set`, and the later value wins.

- `tools` and `hooks` in the settings change the plugin's own tool and hook
  options, such as `shell: {tools: {edit: {enabled: false}}}`.
- The plugin's hooks get all of its settings as JSON in
  `ARX_PLUGIN_SETTINGS`.

**Pinned:** `--kit` is the same as `--set kit=NAME`, so it stays in force
after every reload. The agent can edit `agent.yaml`, but it cannot change the
kit of a run that started with `--kit`.

`arx plugin list` shows the active list here, with the position, the state
(`on`, `off`, `broken`, `missing`) and the reason for each plugin:

```
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
| `arx kit add NAME` | installs a kit and each plugin it names; a bare name comes from the kits that came with arx, else from the arx repo at the tag of your arx |
| `arx kit add OWNER/REPO/PATH[@REF]` | a kit folder in any GitHub repo |
| `arx kit add ./PATH` | a kit folder on this machine; when it is in `<marketplace>/kits/`, its plugins come from `<marketplace>/plugins/` |
| `arx kit list` | the installed kits, their versions, the default, and their sources |
| `arx kit remove NAME` | deletes the kit; its plugins stay |
| `arx plugin enable NAME` | adds the plugin to `enable:` in `./agent.yaml` (and takes it out of `disable:`) |
| `arx plugin disable NAME` | adds the plugin to `disable:` in `./agent.yaml` |
| `arx init NAME` | copies the kit's `init/` files into this folder, with an `agent.yaml` that has `kit: NAME` |
| `arx config get\|set\|unset\|add\|remove KEY ...` | reads or changes one top-level key of `agent.yaml` (or `config.yaml` with `--global`) |
| `sh install.sh --kit NAME` | installs arx, then runs `arx kit add NAME --default --yes` |

- `arx kit add` options: `--default` (also writes `kit: NAME` to
  `config.yaml`), `--link` (use local folders where they are), `--force`,
  `--yes`. It asks first and shows each plugin it will install; without a
  terminal it needs `--yes`. A kit that `extends` another adds that one too.
- `--global` makes `arx plugin enable` and `disable` write `config.yaml`.
- `arx plugin add` keeps a new plugin on: when your kit or list would leave
  it out, it adds the plugin to `enable:` (`--no-enable` skips this).
- `make install` and the release put this repo's `plugins/` and `kits/` in
  `libexec/arx/`, next to the commands, so `arx kit add coding` needs no
  download. It links the shipped kit and plugins, so they stay at the version
  of your arx after `arx update`.

## The kits that ship with arx

| Kit | Plugins | Purpose |
|---|---|---|
| `coding` | `guard`, `shell`, `git-context`, `fail-hint`, `reviewer`, `plugin-authoring`, `keep-last`, `word-count`, `clock`, `notify` | a general coding agent |
| `explorer` | `guard`, `shell` with `edit` off, `git-context`, `word-count`, `clock` | reads and answers; `bash` can still change files |
| `research` | `shell`, `never-stop` with a message, `git-context` | an experiment loop that never stops; `arx init research` gives the files of `arx init autoresearch` |

## Minimal example

A kit for a reviewer that reads and reports, and never edits:

```
kits/review/
  kit.yaml
  prompts/system.md
```

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

```sh
arx check --kit-dir kits/review    # checks the folder, prints key=value lines
arx check --kit review             # the harness with this kit: tools, hooks, plugins
arx --kit review -p "Review the last commit"
```

A variant starts from another kit and changes its list:

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
| A script in the kit, such as `init/setup.sh` with `chmod +x` | the kit is rejected: it holds no code | move the script into a plugin, or `chmod -x` it |
| The kit leaves out `shell` | the agent has no `bash` and `edit` | list `shell` |
| A plugin in the list is not installed | `arx check` lists it as `missing` with `run arx plugin add NAME`; the run goes on without it | `arx kit add` the kit again, or add the plugin |
| You expect `kit:` in `agent.yaml` to add to your default kit | a kit replaces the list | use `enable:` and `disable:` to change a kit |
| The agent turns off a guard by editing `agent.yaml` | without a launcher pin it can | start the run with `--kit NAME` |
| Settings for a plugin that is not in the list | they do nothing | add the plugin with `enable:` and its settings |
| A kit that `extends` another gives settings in `enable:` for a plugin the other kit already lists | the plugin is already in the list, so that entry and its settings are skipped | list the plugins in full with `plugins:`, or give the settings in `agent.yaml` |
| A guard that must win runs in list order | a later hook can change its result | put its hook in the `policy` band (see [Bands](hooks.md#bands)) |

## Planned

A marketplace `index.yaml` that lists each plugin and kit with its versions,
for `arx plugin search`. See [Planned changes](planned.md).
