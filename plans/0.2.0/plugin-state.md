# Plugin state (slug `plugin-state`)

## Goal

Give every plugin two folders of its own, named by environment variables,
so that it can keep files between calls without inventing paths:

| Variable | Folder | For |
|---|---|---|
| `ARX_STATE_DIR` | `$ARX_SESSION_DIR/plugins/<name>/` | state for one session: a plan, a scheduler's counters, a long-lived hook's memory |
| `ARX_DATA_DIR` | `<working folder>/.arx/data/<name>/` | data across sessions: a search index, a cache |

arx's own commands keep their files in `.arx/<command>/`, such as
`.arx/climb/` (decision 9), so `.arx/data/` belongs to plugins only.

arx only names the folders. It adds no plugin.yaml key, no CLI flag, no hook
point and no event. The change is about 60 lines of C, two small edits to
commands, tests and docs.

## Current state

- **The plan**: `docs/plugins/planned.md:55-62` names the two variables and
  folders. Nothing else exists.
- **The environment for plugin programs**: `ToolEnv` sets nine variables
  (`src/harness/tool_exec.c:59-74`): `ARX_SESSION`, `ARX_SESSION_DIR`,
  `ARX_TURN`, `ARX_CWD`, `ARX_SPEC`, `ARX_SPEC_DIR`, `ARX_DEPTH`, `ARX_BIN`,
  and `ARX_PLUGIN_DIR` only when it is given a plugin folder. It takes the
  folder, not the plugin name (`src/harness/harness.h:309-312`).
- **Callers of `ToolEnv`**:
  - tool calls: `src/harness/tool_exec.c:209`, with `Tool.plugin_dir`;
  - hooks: `src/harness/hooks.c:71-85` (`HookEnv`, which adds
    `ARX_PLUGIN_SETTINGS`);
  - the scheduler plugin: `src/agent/scheduler.c:98`;
  - observers: `src/agent/run.c:67-73`, with no plugin. A plugin's observer
    gets `ARX_PLUGIN_DIR` from a shell wrapper,
    `export ARX_PLUGIN_DIR='...'; cmd`, built at load time
    (`src/harness/plugins.c:121-134`, `:189-198`);
  - compactors: `src/harness/compact.c:225-226`, with no plugin. A plugin's
    compactor path is made absolute (`src/harness/plugins.c:184-187`) and
    merged into the spec, so its plugin is not known, and it gets no
    `ARX_PLUGIN_DIR` (documented at `docs/plugins/compactors.md:69-70`).
- **Commands**: `src/cli/external.c:57-69` sets `ARX_PLUGIN_DIR` for a
  command in a user plugin (`<config>/plugins/<name>/commands/`), and
  `:104-105` sets `ARX_BIN` and `ARX_LIBEXEC`. No session variables.
- **Credentials and adapters** run with no `ARX_*` variables
  (`docs/plugins/credentials.md:105`).
- **Inherited values leak**: `EnvWith` adds or replaces variables in a copy
  of `environ`, but never removes one (`src/base/proc.c:28-46`). So when arx
  runs under a plugin command that runs `arx -p`, a spec-folder tool
  inherits the command's `ARX_PLUGIN_DIR`. New variables would leak the same
  way.
- **The plugin name**: `Layer.plugin` holds it (`src/harness/harness.h:36-43`);
  `Tool` holds only `plugin_dir` (`:253-263`, set at
  `src/harness/tools.c:259`). The folder is a `realpath`
  (`src/harness/plugins.c:228`), so for a linked plugin
  (`arx plugin add --link`, or `arx setup`'s link to `shell`) the basename of
  `plugin_dir` can differ from the name. The name is letters, digits, `_` and
  `-` (`src/harness/validate.c:360-366`) and must match the folder name in
  `plugins/` (`src/harness/plugins.c:231-235`), so it is one safe path
  segment.
- **One plugin per name in a run**: a project plugin hides a user plugin of
  the same name (`src/harness/plugins.c:267`), and the active list loads each
  name from the spec's `plugins/`, else the config folder's
  (`src/harness/plugins.c:285-309`).
- **Sessions**: `.arx/sessions/<id>/` in the working folder
  (`src/io/session.c:14`). `SessionNew` makes it and stores an absolute
  path (`src/io/session.c:33-58`). `SessionResume` reopens the same folder
  (`src/io/session.c:107-124`). `.arx/` goes into `.gitignore` with
  `arx init` (`commands/arx-init:66`, `:146`).
- **Subagents**: a subagent is a new `arx -p` process
  (`src/harness/tool_exec.c:107-139`) with its own session folder in the same
  working folder. Its events reach the parent's stream
  (`src/harness/tool_exec.c:82-93`).
- **No fork**: nothing in `src/`, `commands/` or `docs/` forks a session.
  `stop` with `restart` and compaction keep the same session folder.
- **Cleanup**: arx deletes no session (`commands/arx-sessions` only lists).
  `arx plugin remove` deletes the install folder only
  (`commands/arx-plugin:259-282`).
- **Plugins that keep state today**: only `chatgpt`. It keeps `auth.json`
  and `host-id` in `$ARX_CHATGPT_DIR`, else `<config folder>/chatgpt/`
  (`plugins/chatgpt/lib/chatgpt_auth.py:60-70`), with an `mkdir` lock
  (`:125-158`). The other twelve shipped plugins (`shell`, `clock`,
  `word-count`, `guard`, `fail-hint`, `git-context`, `never-stop`, `notify`,
  `keep-last`, `reviewer`, `op-key`, `plugin-authoring`) keep nothing.

## Design

### The variables

| Variable | Value | Always absolute |
|---|---|---|
| `ARX_STATE_DIR` | `<session folder>/plugins/<name>` | yes: the session folder is a `realpath` |
| `ARX_DATA_DIR` | `<getcwd()>/.arx/data/<name>` | yes |

`<name>` is the plugin's `name:`, which is its folder name in `plugins/`.
arx takes it from `Layer.plugin`, never from the basename of the resolved
folder, so a linked plugin gets the folder of its name.

### Which programs get them

The rule: a program gets both variables when it is a plugin's, and
`ARX_STATE_DIR` only when a session runs.

| Program | `ARX_STATE_DIR` | `ARX_DATA_DIR` |
|---|---|---|
| A plugin's tool, on each call | yes | yes |
| A tool's `--schema`, or `tools/<name>.json` | no | no |
| A plugin's hook | yes | yes |
| A plugin's scheduler | yes | yes |
| A plugin's observer | yes | yes |
| A plugin's compactor | yes (new, with `ARX_PLUGIN_DIR`; see open decision 5) | yes |
| A user plugin's command | no: no session runs | yes |
| arx's own commands, such as `arx climb` | no | no: they use `.arx/<command>/` |
| A credential or an adapter | no | no |
| A program in the spec folder or the config folder | no | no |

**arx removes inherited values.** When a run starts (`AgentMain`), arx
unsets `ARX_PLUGIN_DIR`, `ARX_PLUGIN_SETTINGS`, `ARX_STATE_DIR` and
`ARX_DATA_DIR` in its own environment. So a program that is not a plugin's
never sees another plugin's folders, also when a plugin command runs
`arx -p`. This also fixes the `ARX_PLUGIN_DIR` leak.

### When the folders are made

arx makes neither folder. A plugin makes its folder before it first writes:

```sh
mkdir -p "$ARX_STATE_DIR"
```

```python
os.makedirs(os.environ["ARX_STATE_DIR"], exist_ok=True)
```

Why: most plugins never write (`guard` runs before every call), so a folder
made for each one would fill `.arx/data/` with empty folders that last
forever. A plugin that makes its own folder also needs no extra system call
from arx for each process. The cost is one line in each plugin that writes,
which the docs and a "Common mistakes" row cover.

### How long they last

| Folder | Lasts | Survives |
|---|---|---|
| `ARX_STATE_DIR` | as long as the session folder | `--resume`, compaction, a `stop` hook's `restart`, hot reload, a crash |
| `ARX_DATA_DIR` | until you delete it | every session, a plugin update, `arx plugin remove` |

- **A plugin added mid-session** (hot reload) gets the variables from its
  next process.
- **A plugin removed or turned off** keeps its folders. arx never reads them.
- **An upgraded plugin** finds the files of its older version in both
  folders.

### Cleanup

arx deletes neither folder.

- **`ARX_STATE_DIR`** goes when its session folder goes
  (`rm -rf .arx/sessions/<id>`). A session prune command is out of scope.
- **`ARX_DATA_DIR`** stays until you delete it. `arx plugin remove NAME`
  keeps it, because the data may be the result of hours of work and
  the command can't see other working folders. When `./.arx/data/NAME/`
  exists in the current folder, it prints one more line:

  ```text
  Kept its data in .arx/data/NAME/ in this folder (delete it with rm -rf).
  ```

- **`arx doctor`** lists each folder in `./.arx/data/` whose name is in no
  row of `arx check --list`:

  ```text
    ! .arx/data/old-index/ holds data for old-index, which is not installed (rm -rf it if you don't need it)
  ```

- **A plugin** may prune its own files, such as the oldest cache entries.

### `--resume`

`--resume` reopens the same session folder, so each plugin finds its
`ARX_STATE_DIR` as it left it. arx does nothing more.

- `session_start` hooks do not run again on `--resume`
  (`docs/plugins/hooks.md`). A plugin must not make its state only in
  `session_start`: it reads the folder when it starts and makes what is
  missing.
- A long-lived hook or a scheduler is a new process after `--resume`. It
  must write what it needs to `ARX_STATE_DIR` as it goes, and read it back
  when it starts.
- A session from arx 0.1 has no `plugins/` folder. A plugin makes it.

### Session forks

arx has no fork today. When one arrives (ACP's fork method in `acp-tui`, or a
later `--fork ID` flag), it follows this contract:

1. The new session gets its own folder and id.
2. Before any program of the new session starts, arx copies the source
   session's `plugins/` folder into the new one, files and folders as they
   are (`cp -R`).
3. `ARX_DATA_DIR` is shared, so nothing is copied.

Why copy: plugin state usually describes the history (a plan, a to-do list),
and the fork copies the history. A plugin that wants fresh state after a fork
writes `$ARX_SESSION` into its state file, and starts over when the id it
reads back is not the current one. Large files belong in `ARX_DATA_DIR`, so
the copy stays small.

### Subagents

A subagent is its own session, so its plugins get their own
`ARX_STATE_DIR`, under the subagent's session folder. Parallel subagents never
share an `ARX_STATE_DIR`, and a subagent never changes its parent's.

`ARX_DATA_DIR` is the same for the parent and every subagent, because they
run in one working folder. arx adds no variable for the parent's session
folder in 0.2.0 (open decision 3).

### Many writers

Several processes can use one folder at the same time:

- `ARX_STATE_DIR`: calls of one tool with `[]` keys, the plugin's scheduler,
  its hooks, a long-lived hook.
- `ARX_DATA_DIR`: all of those, plus parallel subagents and two `arx` runs in
  one folder.

arx gives no lock. The docs give two rules: write a whole file to a
temporary name in the same folder and `rename` it, and guard a
read-modify-write with an `mkdir` lock, as `chatgpt` does.

### Plugin names that clash

- **In one run** two layers never share a name (see Current state), so two
  plugins never share a folder in one run.
- **Across runs in one working folder**, two different plugins with one name
  share `ARX_DATA_DIR`. Examples: a subagent spec with its own
  `plugins/notes/` while the parent loads your user plugin `notes`; a second
  spec run with `--spec` in the same folder; an old and a new version of one
  plugin. arx does not detect this.
- **The rule**: the folder belongs to the name, not to a copy of the plugin.
  Put a format version in your files, and skip files you don't know.
- **Spec-folder and config-folder programs** have no plugin name, so they get
  neither variable. They can use `$ARX_SESSION_DIR` and paths of their own.
- **Scoped names** from more marketplaces (`@acme/lint`, slug `arx-plugin`)
  must install to a folder whose name is one path segment. The state folders
  use that folder name.

### The agent can change these files

Both folders are in the working folder, so the agent's `bash` can read and
change them, as it can change `.arx/sessions/`. Plugin state is not
tamper-proof:

- Keep no secrets there. A sign-in belongs in the config folder, as
  `chatgpt` keeps it.
- Don't use it as evidence that the agent could forge. A sandbox that hides
  `.arx/` from the agent (slug `sandboxes`) fixes this.

### Existing plugins

None of the shipped plugins moves:

- Twelve keep no state.
- `chatgpt` keeps a sign-in for you, in every folder you work in. It stays in
  `<config folder>/chatgpt/`: moving it to `.arx/data/chatgpt/` would ask
  you to sign in once per project, and would put the tokens where the
  agent's `bash` can read them. Credentials get no `ARX_*` variables anyway.
- The `notify` observer, `never-stop` and the example drivers keep nothing.

No new shipped plugin is needed: the docs and the tests carry the example
(open decision 10).

## Implementation steps

1. **The plugin name on each tool.** In `src/harness/harness.h:253-263` add
   `char* plugin` to `Tool`, next to `plugin_dir`. Set it in
   `src/harness/tools.c:259` from `layer->plugin`, start it as `NULL` in
   `Add` (`:211`), and free it in `ToolsFree` (`:367`).
2. **`ToolEnv` with a name.** Change it to
   `char** ToolEnv(struct Agent* a, const char* plugin_dir, const char* plugin)`
   (`src/harness/tool_exec.c:59-74`, comment at
   `src/harness/harness.h:309-312`). Grow the array from 10 to 12 slots. When
   `plugin` is set, add
   `ARX_STATE_DIR=<a->session.dir>/plugins/<plugin>` and
   `ARX_DATA_DIR=<cwd>/.arx/data/<plugin>`, with the `cwd` the function
   already reads. Keep the `NULL` end marker after the last set slot.
3. **Update the callers.**
   - `src/harness/tool_exec.c:209`: `ToolEnv(a, t->plugin_dir, t->plugin)`.
     Subagent calls keep `NULL` (`StartSubagent` reuses this env and still
     sets `ARX_DEPTH`; the child arx unsets the plugin variables in step 6).
   - `src/harness/hooks.c:74` and `src/agent/scheduler.c:98`:
     `ToolEnv(a, layer->plugin ? layer->dir : NULL, layer->plugin)`.
   - `src/agent/run.c:69`: `ToolEnv(a, NULL, NULL)`.
4. **Observers.** Rename `WithPluginDir` to `WithPluginEnv` and give it the
   name (`src/harness/plugins.c:121-134`, called at `:195`). The wrapper
   becomes:

   ```sh
   export ARX_PLUGIN_DIR='<dir>' ARX_STATE_DIR="$ARX_SESSION_DIR/plugins/<name>" ARX_DATA_DIR="$ARX_CWD/.arx/data/<name>"; <command>
   ```

   The name needs no quoting: it is letters, digits, `_` and `-`. The
   observer's environment already has `ARX_SESSION_DIR` and `ARX_CWD`.
5. **Compactors** (open decision 5). In `External`
   (`src/harness/compact.c:212-252`), find the plugin layer whose `dir`
   followed by `/` starts the compactor's path, and pass its `dir` and
   `plugin` to `ToolEnv`. A spec compactor matches no plugin layer and keeps
   `NULL`. About ten lines.
6. **Remove inherited values.** At the start of `AgentMain`
   (`src/agent/run.c:189-192`), before `Start`, call `unsetenv` for
   `ARX_PLUGIN_DIR`, `ARX_PLUGIN_SETTINGS`, `ARX_STATE_DIR` and
   `ARX_DATA_DIR`. `arx tool bash` does not pass through `AgentMain`, so the
   agent's shell commands keep what the `shell` plugin's tool got.
7. **Commands.** In `SetPluginDir` (`src/cli/external.c:57-69`), when the
   command is a user plugin's, also set
   `ARX_DATA_DIR=<getcwd()>/.arx/data/<basename of the plugin folder>`.
   That folder is the unresolved `<config>/plugins/<name>`, so its basename is
   the name. Rename the function to `SetPluginEnv`.
8. **`arx plugin remove`.** In `cmd_remove` (`commands/arx-plugin:259-282`),
   after `Removed $name.`, print the "Kept its data" line when
   `.arx/data/$name` is a folder in the current folder.
9. **`arx doctor`.** In `commands/arx-doctor`, after the spec checks, read the
   names from `arx check --list` (column 2) and `warn` once for each folder in
   `.arx/data/` that is not among them. Print nothing when there is no
   `.arx/data/`.
10. **Docs and tests**, as below.

## Tests

Add `tests/state.sh` and a line for it in the `test:` target of the
`Makefile` (`:63-71`). Each case uses `begin`, `run` and `check` from
`tests/lib.sh`, with a small plugin under `$ARX_CONFIG_DIR/plugins/`:

| Case | How | Check |
|---|---|---|
| A tool gets both values | a plugin tool `where` prints `$ARX_STATE_DIR` and `$ARX_DATA_DIR` | `<ws>/.arx/sessions/<id>/plugins/st` and `<ws>/.arx/data/st` |
| arx makes no folder | after that run | neither `plugins/` in the session nor `.arx/data/` exists |
| Hooks, scheduler and observer get them | the plugin's `before_tool` hook, `scheduler` and observer append the values to a file in `$ARX_STATE_DIR` | three lines with the same two values as the tool |
| Spec-folder programs get none | `export ARX_STATE_DIR=/bad ARX_DATA_DIR=/bad ARX_PLUGIN_DIR=/bad`, then run a spec-folder tool that prints `${ARX_DATA_DIR-unset}` | `unset` three times |
| `--resume` keeps state | a tool appends a line to `$ARX_STATE_DIR/count`; run, then `--resume last` and call it again | two lines; a new session starts at one |
| Subagents get their own state folder | a subagent spec loads the plugin; the tool records its values in the parent and the subagent | the state folders differ and hold each session's id; the data folders match |
| A linked plugin uses its name | link `<ws>/dev-copy` as `$ARX_CONFIG_DIR/plugins/st` | `ARX_STATE_DIR` ends in `/plugins/st`, not `dev-copy` |
| A plugin compactor gets them | `compaction: {strategy: <the plugin's compactor>}`; the compactor writes `$ARX_PLUGIN_DIR` and `$ARX_STATE_DIR` to a file | both set (drop this case if open decision 5 goes the other way) |
| A command gets `ARX_DATA_DIR` only | a user plugin command `arx-st` prints `${ARX_DATA_DIR-unset} ${ARX_STATE_DIR-unset}` | `<ws>/.arx/data/st unset` |
| A command's `arx -p` leaks nothing | `arx-st` runs `"$ARX_BIN" -p` with a spec-folder tool that prints `${ARX_DATA_DIR-unset}` | `unset` |
| `arx plugin remove` keeps data | `mkdir -p .arx/data/st`, then `arx plugin remove st --yes` | the folder exists; the output has `Kept its data` |
| `arx doctor` lists orphans | `mkdir -p .arx/data/gone` | the output has `.arx/data/gone/` |

Run `make test`, which uses the ASan and UBSan build (`arx-debug`), and
`make lint`, as for every C change.

## Docs to change

Write each change to `docs/WRITING.md`: lead with the answer, exact paths and
names, a "Use it when" column for choices, and a "Common mistakes" row for
the `mkdir -p` slip.

| Page | Change |
|---|---|
| `docs/plugins/concepts.md` | A new `## Plugin state` section and a row in "Terms at a glance". It opens with "Plugin state is the files a plugin keeps between calls, in two folders that arx names for it." Then: the two-row table with a "Use it when" column, "arx makes no folder", how long each lasts, `--resume`, subagents, many writers, clashing names, and "the agent can change these files". |
| `docs/plugins/reference.md` | Environment (`:171-198`): two rows, and two columns in the table of kinds; the compactor row gets `ARX_PLUGIN_DIR`. Session files (`:255-268`): a `plugins/<name>/` row. A line that arx removes inherited plugin variables when a run starts. |
| `docs/plugins/tools.md` | "A call": the two variables. "Common mistakes": "The tool writes to `$ARX_STATE_DIR` before it exists: `No such file or directory`: `mkdir -p` first." |
| `docs/plugins/hooks.md` | The Environment row of the contract table. One sentence: keep state for `--resume` in `ARX_STATE_DIR`, because `session_start` does not run again. |
| `docs/plugins/schedulers.md` | The Environment bullet: keep counters in `ARX_STATE_DIR`, so a `--resume` keeps them. |
| `docs/plugins/observers.md` | The Environment bullet (`:39-40`). |
| `docs/plugins/compactors.md` | `:69-70` and the mistake row at `:122`: a plugin's compactor now gets `ARX_PLUGIN_DIR` and both state variables. |
| `docs/plugins/commands.md` | `:22-25`: a user plugin's command gets `ARX_DATA_DIR`, not `ARX_STATE_DIR`. |
| `docs/plugins/subagents.md` | The "Session" bullet: its plugins get their own `ARX_STATE_DIR`, and share `ARX_DATA_DIR` with the parent. |
| `docs/plugins/planned.md` | Remove the "Plugin state" row (`:23`) and section (`:55-62`). |
| `docs/plugins.md` | `:72-74`: drop "plugin state folders" from the planned list. |
| `docs/concepts.md` | Sessions (`:162-178`): a `plugins/<name>/` row, and one sentence on `.arx/data/` (plugins) and `.arx/<command>/` (arx's own commands). |
| `docs/cli.md` | `--resume` (`:45`): "Continues a session with its full history and its plugins' state." |
| `plugins/plugin-authoring/skills/plugin-authoring/SKILL.md` | One bullet: keep files in `$ARX_STATE_DIR` or `$ARX_DATA_DIR`, and `mkdir -p` first. |

## Dependencies

| Slug | What it shares with this item |
|---|---|
| `climb` | A core command, so it gets no `ARX_DATA_DIR` and keeps its files in `.arx/climb/` (decision 9). `.arx/data/climb/` stays free for a plugin named `climb`. Its inner `arx -p` runs start clean of plugin variables (step 6). The agent can change `.arx/`, so climb must not trust its own files there as proof of a score. |
| `long-lived-hooks` | The long-lived hook gets both variables when it starts, through the same `ToolEnv` call in `hooks.c`. It lives for one session process, so it must save to `ARX_STATE_DIR` to survive `--resume`. Land `plugin-state` first: both change `HookEnv`. |
| `async-calls` | A scheduler that answers `started as c7` can keep its pending calls in `ARX_STATE_DIR`. What a `--resume` does with a call that was still running is that plan's choice. |
| `sandboxes` | Adds `ARX_SANDBOX` to the same `ToolEnv` array: one of the two plans grows it, the other rebases. A sandbox that runs plugin programs in a container must mount both folders at the same absolute paths. A sandbox that hides `.arx/` from the agent's `bash` makes plugin state safe from the agent. |
| `trust` | `harness_edit` does not cover `.arx/`, so a policy plugin can't trust its own state unless a sandbox hides it. Nothing to build here. |
| `acp-tui` | `session/load` maps to `--resume`, so state carries over. If it adds a fork, it follows "Session forks" above: copy `plugins/` before the first program starts. The TUI plugin may keep its input history in `ARX_DATA_DIR`. |
| `arx-plugin` | `remove` prints the "Kept its data" line (step 8). `eject` keeps the plugin's name, so it keeps its data. `update` reuses the data. Scoped names must install to one path segment. |
| `mcp-client` | If it is a plugin, it may cache server catalogs in `ARX_DATA_DIR`. No shared code. |
| `plugin-yaml-keys` | None: this plan adds no `plugin.yaml` key. |

## Size and risks

**Size: S.** About 60 lines of C in six files, 15 lines of shell in two
commands, one test file with twelve cases, and fourteen doc edits.

| Risk | Effect | Mitigation |
|---|---|---|
| `ToolEnv` changes in three other plans | merge conflicts in `tool_exec.c` and `hooks.c` | land `plugin-state` first in 0.2.0; it is the smallest |
| A plugin writes before `mkdir -p` | `No such file or directory` | every doc example makes the folder; a "Common mistakes" row |
| Step 6 removes an inherited `ARX_PLUGIN_DIR` | a spec-folder program that read it under a plugin command loses it | it pointed at another plugin's folder, so it was a bug; one line in the release notes |
| Two plugins with one name share data | one reads the other's files | the "clashing names" rule: version files, skip unknown ones |
| The agent changes plugin files | state is not proof of anything | documented; `sandboxes` can hide `.arx/` |
| `.arx/` grows | disk use in the working folder | the `arx doctor` orphan check; a session prune command later |

## Open decisions

1. **Rename the data folder to `.arx/data/<name>/`.** **Decided
   (2026-11-09): `ARX_DATA_DIR` is `.arx/data/<name>/`**, so each variable
   matches its folder. The planned `.arx/state/<name>/` would have put
   `ARX_DATA_DIR`, not `ARX_STATE_DIR`, in `.arx/state/`. This plan uses
   `.arx/data/` throughout; `planned.md`, `climb.md` and
   `long-lived-hooks.md` change to match.
2. **Who makes the folders.** arx could make `ARX_STATE_DIR` for each active
   plugin at session start, and `ARX_DATA_DIR` on first use. **Recommendation:
   arx makes neither; the plugin runs `mkdir -p`.** No empty folders, no extra
   work per process, and one rule for both.
3. **Subagents: their own folder or the parent's.** **Recommendation: their
   own.** A subagent is a session, and parallel subagents must not share a
   plan. Add `ARX_PARENT_SESSION_DIR` later only if a plugin needs it: the
   child arx already inherits the parent's `ARX_SESSION_DIR`, so it is a
   two-line change.
4. **A fork copies plugin state or starts empty.** **Recommendation: copy
   `plugins/`**, because the state usually describes the history that the
   fork copies. A plugin can detect a fork by the session id it stored.
5. **Plugin compactors get `ARX_PLUGIN_DIR` and the state variables.**
   **Recommendation: yes, in this change.** It costs about ten lines and
   removes the one documented exception to "a plugin's programs get
   `ARX_PLUGIN_DIR`". It can be dropped without changing the rest.
6. **Spec-folder and config-folder programs.** They could get a reserved
   name such as `.spec`. **Recommendation: no variables.** They are the
   agent's own files, and `$ARX_SESSION_DIR` is there for them.
7. **A third folder for user-wide plugin data** (such as
   `<config folder>/state/<name>/`, for sign-ins). **Recommendation: not in
   0.2.0.** Only `chatgpt` needs it, and it already has a folder. Document its
   pattern.
8. **Cleanup commands** (`arx plugin remove --purge`, `arx sessions prune`).
   **Recommendation: neither in 0.2.0.** The "Kept its data" line and the
   `arx doctor` check are enough until users ask.
9. **Where a core command keeps data.** **Decided (2026-11-09): core
   commands keep their files in `.arx/<command>/`, so climb uses
   `.arx/climb/`.** `.arx/data/` stays the plugins' namespace, so a plugin
   named `climb` can't clash with arx's own command.
10. **An example plugin that keeps state.** A `todo` plugin with a plan tool
    would show `ARX_STATE_DIR`. **Recommendation: no new shipped plugin in
    this item**; the docs example and `tests/state.sh` cover the contract.
    Propose `todo` separately for the marketplace.
