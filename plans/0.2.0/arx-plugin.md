# arx-plugin: the rest of `arx plugin` for 0.2.0

Slug: `arx-plugin`. Covers roadmap item 3 ("More of `arx plugin`") and the
"More of arx plugin" and "The marketplace index" rows of
`docs/plugins/planned.md`.

## Goal

`arx plugin` can install, update, find and take over plugins from more than
one marketplace, and a plugin can declare the one command it needs after an
install and the MCP servers it brings. At the end of 0.2.0:

- `arx plugin update` moves installed plugins to the newest version that
  works with the installed arx, and `--check` says whether one exists.
- `arx plugin search` lists what each marketplace offers, from its
  `index.yaml`.
- `arx plugin eject NAME` copies a plugin into the spec folder, so the agent
  owns it and can change it.
- Named marketplaces work: `arx plugin market add acme acme/arx-plugins`,
  then `arx plugin add @acme/lint`.
- A `setup:` command in `plugin.yaml` runs once after each install or
  update. The `tui` plugin (slug `acp-tui`) uses it for `bun install`.
- `mcp_servers:` in `plugin.yaml` adds MCP servers, with the shape that
  `mcp-client` defines for the spec.

What stays the same: arx stays small. All of this is shell in
`commands/arx-plugin` plus a few hundred lines of C for validation, the
version check and the load gate. A run still uses only plugin names. The
core install stays bare. `arx plugin add NAME` still fetches the tag of the
installed core. Installed plugins are still on by default. A plugin command
still cannot replace a built-in or core command.

## Current state

What exists today, at commit `c6a0908`:

| Part | Where | What it does now |
|---|---|---|
| Usage and verbs | `commands/arx-plugin:14-37`, `:370-383` | `add`, `remove`, `list`, `enable`, `disable`, `new`, `fetch` (internal, for `arx kit`) |
| Default marketplace | `commands/arx-plugin:40` | `ARX_PLUGIN_REPO`, default `woodfordbl/arx` |
| Core tag | `commands/arx-plugin:96-105` (`core_ref`) | `v<version>` for a release, `main` for any other build |
| Download | `commands/arx-plugin:111-123` (`fetch`) | the arx repo from `$ARX_DOWNLOAD_URL/archive/<ref>.tar.gz`; other repos from GitHub (`gh api` or codeload); `ARX_PLUGIN_MIRROR` replaces both in tests |
| Reference grammar | `commands/arx-plugin:128-162` (`resolve`) | `NAME[@REF]`, `OWNER/REPO/PATH[@REF]` (HEAD by default), `./PATH`, `FILE.tar.gz`; `OWNER/NAME` with two parts is an error |
| Install | `commands/arx-plugin:164-211` (`cmd_add`) | `arx check --plugin`, a summary, one confirmation, copy to `.<name>.new`, write `.arx-source`, swap; `--link` makes a symlink |
| Source record | `commands/arx-plugin:204-205` | `.arx-source` has `source=`, `commit=` (the tarball's top folder), `installed=` |
| Keep it on | `commands/arx-plugin:226-233` (`turn_on`) | adds the plugin to `enable:` when a kit or list leaves it out |
| Plugin facts for scripts | `src/harness/describe.c:77-114` | `arx check --plugin DIR` prints `name= version= description= arx= requires= missing= tools= hooks= skills= commands= credentials= adapters= hosts=` |
| `plugin.yaml` keys | `src/harness/fields.c:97-111` | `name`, `version`, `description`, `arx`, `requires`, `tools`, `hooks`, `replaces`, `observers`, `compactors`, `credentials`, `adapters`, `hosts` |
| Keys not merged into the spec | `src/harness/plugins.c:18-20` (`kOwnKeys`) | the descriptive keys plus `hooks`, `observers`, `replaces`, `hosts` |
| Version gate | `src/harness/plugins.c:89-119` | `arx:` accepts only `">=X.Y.Z"`; a build that is not a release accepts any plugin |
| Load | `src/harness/plugins.c:224-248` (`LoadPlugin`) | a plugin that fails `PluginRead` becomes a `broken` row and is skipped |
| Merge | `src/harness/plugins.c:161-203` (`Adopt`) | makes program paths absolute, appends hosts and observers, merges the rest under the spec |
| Reload | `src/harness/signature.c:80-90` | hashes `plugins/<name>/plugin.yaml` and `kits/<name>/kit.yaml`; names that start with `.` are skipped, so staging folders do not trigger a reload |
| Run-time names | `src/harness/active.c:50-63` (`EntryName`) | `acme/tools/lint@v1` and `lint: {...}` are both `lint` |
| Plugin list entries | `src/harness/validate.c:73-77` | any non-empty string, or `{name: {settings}}` |
| `kit.lock` | `src/harness/kits.c:223-281` | one line per plugin from its `.arx-source` (`source`, `commit`) |
| Kits | `commands/arx-kit:72-113`, `:157-163` | shipped kits and their plugins are linked from `libexec/arx`; other plugins go through `arx plugin add --yes --no-enable` |
| Config edits | `commands/arx-config:84-91` | `add` and `remove` edit one top-level list; `put_list` writes items as given, unquoted |
| Core update | `commands/arx-update:59-104` | replaces `bin/arx` and `libexec/arx`; `--check` exits 10 when a release is newer |
| Installer | `install.sh:47-53` | installs the core, and a kit only with `--kit` |
| Commands | `src/cli/external.c:26-55` | arx's own commands first, then `~/.config/arx/commands`, then user plugins, then `PATH` |
| YAML errors | `src/harness/spec.c:108-113` | prints libyaml's message with line and column |
| Tests | `tests/cli.sh:156-195` | add, `--yes`, `--force`, `--link`, `--project`, the mirror, `.arx-source` |

Not built: `update`, `search`, `eject`, named marketplaces, `index.yaml`,
`setup:`, and `mcp_servers:` in `plugin.yaml`.

One fact shapes the design: libyaml rejects a plain scalar that starts with
`@`. `enable: [@acme/lint]` fails with `found character that cannot start
any token`, and `enable: ["@acme/lint"]` works. I checked this with
`./arx check` on a scratch spec.

## Design

### 1. Plugin references

`arx plugin add`, `update`, `eject`, `arx kit add` and kit plugin lists
accept these forms:

| Form | Example | Source and version |
|---|---|---|
| `NAME[@REF]` | `guard`, `guard@main` | the default marketplace, at the core tag, or at REF |
| `@MARKET/NAME[@REF]` | `@acme/lint`, `@acme/lint@v0.4.1` | the marketplace MARKET: the newest version in its index that works with this arx, or REF |
| `OWNER/REPO/PATH[@REF]` | `acme/tools/plugins/lint` | unchanged: that repo at REF, else its default branch |
| `./PATH`, `DIR/PATH`, `/PATH` | `./lint` | unchanged: a folder on this machine |
| `FILE.tar.gz`, `FILE.tgz` | `lint.tar.gz` | unchanged: a tarball with one plugin folder |

Rules:

- **MARKET** uses letters, digits, `_` and `-`. `@arx` is reserved: it is
  the default marketplace, so `@arx/guard` is `guard`.
- **`resolve` checks `@*` first**, before the `*/*` folder test, so a
  folder named `@acme` in the working directory never shadows a marketplace.
- **The installed folder is `NAME`**, as today. `plugin.yaml` `name` must
  still match it, and a run still uses only the name: `EntryName("@acme/lint@v1")`
  is already `lint` (`src/harness/active.c:56-58`). So `lint` and
  `@acme/lint` cannot both be installed in one scope. Adding one over the
  other needs `--force`, and the message names the other source.
- **In YAML, quote a name that starts with `@`**: `enable: ["@acme/lint"]`,
  `- "@acme/lint": {strict: true}`. arx adds a hint to the libyaml error (step
  8), and `arx config add` quotes such items itself (step 10).

### 2. Named marketplaces

A marketplace is a source with `plugins/<name>/`, `kits/<name>/` and,
optionally, `index.yaml` at its root. A new list key names them:

```yaml
# config.yaml (yours), agent.yaml (this project), or kit.yaml (while `arx kit add` installs the kit)
marketplaces:
  - acme: acme/arx-plugins            # a GitHub repo; its index at the default branch
  - beta: acme/arx-plugins@next       # the same repo, its index at the branch next
  - local: ./vendor/arx-market        # a folder, relative to the file it is in
```

| Source | Index read from | Plugins fetched from |
|---|---|---|
| `OWNER/REPO` | `index.yaml` at `HEAD` | the version's `ref` in the index, else `HEAD` |
| `OWNER/REPO@REF` | `index.yaml` at REF | the version's `ref`, else REF |
| `./DIR`, `/DIR` | `DIR/index.yaml` | `DIR/plugins/<name>` as it is now; `ref` is ignored |

- **The key**: `marketplaces`, a list of one-key maps `{NAME: SOURCE}`. It
  is a list, not a map, so `arx config add` and `remove` edit it with no
  change (`item_name` already reads `acme: ...` as `acme`), and its order is
  the order `search` prints.
- **Where it lives**: `config.yaml` and `agent.yaml`, where an `agent.yaml`
  entry wins for its name. A run ignores the key; only `arx plugin` and
  `arx kit` read it. `arx check` validates its shape.
- **In `kit.yaml`**: the kit's marketplaces apply only while `arx kit add`
  installs that kit. The summary shows each one, and the one confirmation
  covers them. arx does not write them to `config.yaml`.
- **Commands**:

  ```text
  arx plugin market add NAME SOURCE [--project]   # config.yaml, or ./agent.yaml with --project
  arx plugin market remove NAME [--project]
  arx plugin market list                          # NAME, SOURCE, FROM (file), INDEX (plugins/kits count, or "none")
  ```

  `market add` reads the source's `index.yaml` once and prints
  `acme: 4 plugins, 1 kit`, or `acme has no index.yaml: search cannot list
  it, but arx plugin add @acme/NAME works`. It changes nothing on a source
  it cannot reach (exit 1).

### 3. `index.yaml`

`index.yaml` at the root of a marketplace lists each plugin and kit with
its versions:

```yaml
# index.yaml: what this marketplace offers, for `arx plugin search`.
# `arx plugin index` writes it; descriptions and tags may be edited by hand.
index: 1
plugins:
  lint:
    description: Runs the linter after each edit and adds its errors.
    tags: [lint, python]
    versions:
      - version: 0.5.0
        ref: v0.5.0
        arx: ">=0.3.0"
      - version: 0.4.1
        ref: v0.4.1
        arx: ">=0.2.0 <0.3.0"
        setup: uv sync --frozen
      - {version: 0.4.0, ref: v0.4.0, yanked: true}
kits:
  web:
    description: A coding agent for web apps.
    versions:
      - {version: 0.1.0, ref: v0.1.0, arx: ">=0.2.0"}
```

| Key | Type | Meaning |
|---|---|---|
| `index` | integer | Required. The format, `1`. arx refuses a higher number with `index.yaml is format N; update arx`. |
| `plugins`, `kits` | map | Name to entry. Names use letters, digits, `_` and `-`. |
| `<entry>.description` | string | One line. `search` matches it. |
| `<entry>.tags` | string list | Words `search` matches. |
| `<entry>.versions` | list | Required, at least one. Order does not matter: arx sorts by version. |
| `version` | string | Required. `X.Y.Z`, or `X.Y.Z-SUFFIX` for a pre-release. |
| `ref` | string | A tag, branch or commit. Without it, the version is the one in the same commit as `index.yaml`, and a name has at most one such version. |
| `path` | string | Default `plugins/<name>` or `kits/<name>`. |
| `arx` | string | The arx versions it works with, the same grammar as `plugin.yaml` `arx`. Without it, any arx. |
| `setup` | string | A copy of the plugin's `setup:`, so `arx kit add` can show it before a download. Display only. |
| `yanked` | boolean | `true` hides the version from resolution and `search`. `@REF` still installs it. |

The index is a guide, not the source of truth. After a download, arx checks
the downloaded `plugin.yaml` as today, and warns when its `version` differs
from the index entry.

**`arx check --index FILE`** validates the file with the same validator as
`agent.yaml` (errors with line numbers, exit 2), and prints one tab-separated
row per version, newest first within a name:

```text
kind	name	version	ref	path	arx	status	setup	description	tags
plugin	lint	0.5.0	v0.5.0	plugins/lint	>=0.3.0	needs arx >=0.3.0		Runs the linter...	lint python
plugin	lint	0.4.1	v0.4.1	plugins/lint	>=0.2.0 <0.3.0	ok	uv sync --frozen	Runs the linter...	lint python
plugin	lint	0.4.0	v0.4.0	plugins/lint		yanked		Runs the linter...	lint python
```

`status` is `ok`, `needs arx <constraint>`, `yanked` or `pre-release`,
computed in C with the same check that `plugin.yaml` `arx:` uses. The shell
never compares versions.

**`arx plugin index [DIR] [--ref REF] [--check]`** writes `DIR/index.yaml`
(default `.`) for marketplace authors:

- It reads every `DIR/plugins/*/plugin.yaml` and `DIR/kits/*/kit.yaml`
  through `arx check --plugin` and `--kit-dir`.
- With `--ref REF`, it adds each current version with `ref: REF`, and keeps
  the versions already in the file. Use this at a release tag.
- Without `--ref`, it writes each current version with no `ref`, and drops
  the other versions without a `ref` for that name. The arx repo uses this
  form, so each tag's index describes that tag.
- It keeps hand-written `description` and `tags`, and fills a missing
  `description` from `plugin.yaml`. It keeps entries whose folder is gone,
  so old versions stay installable.
- `--check` exits 1 when the file is not current, and changes nothing. CI
  runs `./arx plugin index --check .` on the arx repo.

**Where arx reads an index**:

| Marketplace | URL |
|---|---|
| the default (`woodfordbl/arx`) | `$ARX_DOWNLOAD_URL/index/<ref>.yaml`, a new route on the arx site that serves `index.yaml` of the repo at `<ref>` |
| another GitHub repo | `https://raw.githubusercontent.com/OWNER/REPO/<ref>/index.yaml` |
| a folder | `DIR/index.yaml` |
| tests (`ARX_PLUGIN_MIRROR`) | `$ARX_PLUGIN_MIRROR/OWNER/REPO/<ref>/index.yaml`, next to the existing `<ref>.tar.gz` |

There is no cache. `search` makes one small request per marketplace.

The arx site is `arx-documentation.vercel.app`, and that is its final
domain. The `index` route and the downloads stay there, and it stays the
default of `ARX_DOWNLOAD_URL`.

### 4. How versions are resolved against the core tag

Let C be the installed core version from `arx version`. C is a release when
it matches `X.Y.Z`; anything else (`0.2.0-4-gabc1234`) is a dev build.

| Reference | Ref fetched | Version check |
|---|---|---|
| any form with `@REF` | REF, exactly | the downloaded `plugin.yaml` `arx:` must accept C (today's check) |
| `NAME`, default marketplace | `v<C>`; `main` for a dev build (today's rule) | the same; at `v<C>` it always passes, since CI tested that tag |
| `@MARKET/NAME` with an index | the `ref` of the highest version whose status is `ok` | the index's `arx`, then the downloaded `plugin.yaml` |
| `@MARKET/NAME` without an index | the marketplace's ref (`HEAD` unless the source names one), with a note | the downloaded `plugin.yaml` |
| `OWNER/REPO/PATH` | `HEAD` (today's rule) | the downloaded `plugin.yaml` |

Rules:

- **Highest version**: compare `X.Y.Z` as numbers. Pre-releases
  (`X.Y.Z-rc1`) and yanked versions are skipped unless `@REF` names them.
- **A dev build** accepts any `arx:` constraint, as `VersionProblem` does
  today (`src/harness/plugins.c:113`). So a dev build gets the highest
  version.
- **No version fits**: exit 1 with `no version of @acme/lint works with arx
  0.2.0 (0.5.0 needs >=0.3.0): run arx update, or name a version with
  @acme/lint@REF`.
- **The default marketplace has no such plugin at `v<C>`**: exit 1 with
  `arx 0.2.0 has no plugin tui. It may be in a newer arx: run arx update,
  or try tui@main`. arx does not fall back to `main` on its own.
- **Constraint grammar**: `arx:` (in `plugin.yaml` and the index) becomes a
  space-separated list of comparisons, all of which must hold: `>=`, `>`,
  `<=`, `<`, `=`, each followed by `X.Y.Z` or `X.Y`. `">=0.2.0 <0.3.0"`
  works. Today's `">=0.2.0"` keeps its meaning. Before 1.0, a minor release
  may change a contract, so the docs tell authors to bound the minor.

### 5. `.arx-source`

A copied plugin's `.arx-source` gets more lines. The three existing lines
keep their meaning, so `kit.lock` (`src/harness/kits.c:223`) and `list` need
no change:

```text
source=acme/arx-plugins/plugins/lint@v0.4.1   # as today: shown by list, read by kit.lock
commit=acme-arx-plugins-1a2b3c4               # as today: the tarball's top folder
installed=2026-11-09T12:00:00Z                # as today
market=acme                                    # new: arx, a market name, or empty
repo=acme/arx-plugins                          # new: empty for a folder or a tarball
path=plugins/lint                              # new
ref=v0.4.1                                     # new: the ref fetched
pin=                                           # new: the @REF you gave, or empty when arx chose
version=0.4.1                                  # new: plugin.yaml version at install
ejected=                                       # new: the old source line, after eject
```

A file without the new lines is a plugin from 0.1.x. `update` treats it as
`market=arx` when `source` starts with `$ARX_PLUGIN_REPO/plugins/`, and as
`OWNER/REPO/PATH` otherwise, with `pin` taken from `@REF` in `source` only
when that ref is not `v<C>`.

### 6. The `setup:` command

```yaml
# plugin.yaml
name: tui
version: 0.1.0
requires: [bun]
setup: bun install --frozen-lockfile    # runs once after each install or update
```

`setup` is a string: one shell command. It is the only code that arx runs
outside a run, and these rules make it safe:

**When it runs**:

- After `arx plugin add`, `arx plugin update`, and `eject` copy the plugin
  into place, and after `arx kit add` installs a plugin that has one.
- When you run `arx plugin setup NAME` (to retry after a failure, or after a
  `--link` add of a plugin you are writing).
- Never when a run loads the plugin, never on reload, never on `arx update`
  of the core.
- `--no-setup` on `add` and `update` skips it. The plugin is then off (see
  the load gate) until `arx plugin setup NAME`.

**Before it runs**:

- `arx plugin add` shows `setup    bun install --frozen-lockfile` in its
  summary, next to `tools`, `hooks` and `network`, before the one
  confirmation. The confirmation, or `--yes`, covers it. `update` shows it
  when it is new or changed.
- When a program in `requires` is missing and the plugin has `setup`, `add`
  stops before it changes anything: `tui needs bun, which is not on
  PATH: install it, then run arx plugin add tui again`. Exit 1.

**How it runs**:

- `sh -c "$setup"` in the plugin's final folder. It runs in place, not in
  the staging folder, because some setup output records absolute paths (a
  Python virtualenv does).
- stdin is `/dev/null`, so a prompt fails instead of hanging.
- Its own process group. At `ARX_SETUP_TIMEOUT` (default `10m`), or on
  Ctrl-C, the group gets SIGTERM, then SIGKILL 3 seconds later: the rule
  tools follow. The script uses `set -m` for the group, so it needs no
  `setsid` (macOS has none).
- Environment: your environment, plus `ARX_PLUGIN_DIR` (the absolute
  folder), `ARX_PLUGIN_NAME`, `ARX_PLUGIN_VERSION`, `ARX_SETUP_REASON`
  (`add`, `update`, `eject` or `manual`), `ARX_SETUP_PREVIOUS` (the version
  before an update, else empty), `ARX_BIN` and `ARX_LIBEXEC`. No session
  variables, no `ARX_PLUGIN_SETTINGS`, and none of `plugin-state`'s
  `ARX_STATE_DIR` or `ARX_DATA_DIR`: no run exists, and `ARX_DATA_DIR`
  depends on the working directory, which setup does not have.
- It should write only inside `ARX_PLUGIN_DIR`, and must be safe to run
  twice. The docs say so; arx does not enforce it.

**Output**:

- stdout and stderr go together to `.arx-setup.log` in the plugin folder,
  replaced on each run.
- When stderr is a terminal, they also stream to stderr with a `  | `
  prefix. Without a terminal (CI, or `arx kit add`, which sends `add`'s
  stdout to `/dev/null`), only the log gets them.
- At the end arx prints `Setup done in 12s.`, or on a failure the last 20
  lines of the log on stderr and the log's path.

**The stamp and the load gate**:

- On exit 0, arx writes `.arx-setup` in the plugin folder:

  ```text
  setup=bun install --frozen-lockfile
  exit=0
  ran=2026-11-09T12:00:00Z
  secs=12
  ```

- `LoadPlugin` (`src/harness/plugins.c:224`) loads a plugin that has
  `setup:` only when `.arx-setup` has `exit=0` and a `setup=` line equal to
  the current `setup:` value. Otherwise the plugin is `broken`, with the why
  `setup has not run: run arx plugin setup NAME`. So a plugin whose setup
  failed, was skipped, or changed never runs half-installed. This costs one
  small file read per plugin with `setup:`, at load only.
- `SpecSignature` (`src/harness/signature.c:80-90`) also hashes
  `plugins/<name>/.arx-setup`, so a setup that finishes during a session
  takes effect on the next turn.

**Failures**:

| Case | What arx does | Exit |
|---|---|---|
| `add`, setup fails or times out | removes the new folder, and its `enable:` entry if `add` wrote one: nothing is installed | 1 |
| `add --force` over an installed plugin, setup fails | puts the old folder back | 1 |
| `update`, setup fails | puts the old version back, with its stamp | 1, after the other plugins finish |
| `arx plugin setup NAME` fails | writes no stamp, so the plugin stays off | 1 |
| `eject`, setup fails | keeps the copy, off, and says to run `arx plugin setup NAME` | 1 |

To put the old folder back, the install path changes from "copy, then swap"
to: copy to `.<name>.new`, move the old folder to `.<name>.old`, move
`.<name>.new` into place, run setup, then delete `.<name>.old` on success or
move it back on failure. Both staging names start with `.`, so a reload
ignores them. While setup runs, a session that reloads sees the new folder
without a stamp, so the plugin is off for that time and no longer.

**Re-runs on `update`**: `update` replaces the whole folder, so whatever
setup made (`node_modules/`) is gone, and setup always runs again after an
update. A stamp from the old folder never carries over.

**Links and shipped plugins**:

- `add --link` runs setup in your linked folder, with the same summary and
  confirmation. The stamp and log land there, so `arx plugin new` writes a
  `.gitignore` with `.arx-setup` and `.arx-setup.log`.
- A plugin from `libexec/arx/plugins/` (shipped with arx) that has
  `setup:` is copied, not linked: by `arx kit add` and by `arx setup`.
  `arx update` replaces `libexec/arx`, which would delete its setup output,
  and `libexec` may not be writable. Shipped plugins without `setup:` stay
  linked, as today.

**Kits**: a kit holds no code, so `kit.yaml` has no `setup`. `arx kit add`
shows `plugin tui from ... (setup: bun install --frozen-lockfile)` when
the index or the shipped folder tells it, and `(may run setup)` when
neither does, before its one confirmation. It passes `--yes` to each
`arx plugin add`, as today.

### 7. `arx plugin update`

```text
arx plugin update [NAME...] [--project] [--check] [--yes] [--no-setup]
```

- **Scope**: user plugins, or `./plugins/` with `--project`, as `add` and
  `remove` do. With no NAME, every copied plugin in the scope.
- **Skipped**, with one line each: links (`a link: update its folder
  yourself`), plugins without `.arx-source` (`copied by hand`), tarball
  sources, ejected plugins (`ejected: this harness owns it`), and plugins
  pinned to a tag or commit (`pinned at v0.1.0: add NAME@REF --force to
  change it`). A pin is a tag when it matches `v<digits>`, and a commit when
  it is 7 to 40 hex digits.
- **A folder source** is skipped with no NAME, and copied again from the
  same folder when you name it.
- **What it fetches**: for each plugin, the ref that section 4 gives for
  its `market`, `repo` and `path`, or its `pin` when the pin is a branch. A
  named marketplace's current `marketplaces:` entry wins over the `repo` in
  `.arx-source`, so a moved marketplace keeps working; without an entry,
  `repo` is used.
- **Up to date** when the fetched `commit` equals `.arx-source` `commit`.
- **The summary** lists each change before one confirmation:

  ```text
  Updates for arx 0.2.1:
    guard     0.2.0 -> 0.2.1   arx (v0.2.1)
    lint      0.4.1 -> 0.4.2   @acme (v0.4.2)
              setup  uv sync --frozen (changed)
              network  +pypi.org
  Plugins run with your permissions. Update 2 plugins?
  ```

  It shows a `setup`, `hosts`, `commands`, `tools`, `hooks`, `mcp`, `prompt`
  or `settings` line when that part differs between `arx check --plugin` of
  the old and the new folder (`mcp` is `mcp-client`'s `mcp_servers=`;
  `prompt` and `settings` are the `plugin-yaml-keys` lines `instructions=`
  and `model_settings=`).
- **Install**: the same path as `add` (section 6), with `ARX_SETUP_REASON=update`.
  `pin`, `market` and `enable:` entries stay as they were. One plugin's
  failure does not stop the others; the exit code is 1 if any failed.
- **`--check`**: prints the list and changes nothing. Exit 10 when an update
  exists, 0 when none does, 1 on an error: the codes of `arx update --check`.
- **`kit.lock`**: the next run writes it again from the new `.arx-source`,
  so a pinned kit's lock shows the change in `git diff`.

`arx update` (the core) does not update plugins. After it installs a new
core, it runs `arx plugin update --check` and prints `2 plugins have updates
for arx 0.2.1: run arx plugin update`. Shipped plugins are linked from
`libexec`, so they follow the core with no step.

### 8. `arx plugin search`

```text
arx plugin search [TERM] [--market NAME] [--kits] [--versions] [--tsv]
```

- Reads the index of the default marketplace at the ref section 4 uses (the
  core tag), then each named marketplace in `marketplaces:` order.
- Matches TERM, case-insensitive, against the name, `description` and
  `tags`. No TERM lists everything.
- Prints a table. NAME is `guard` for the default marketplace and
  `@acme/lint` for a named one. VERSION is the version `add` would install,
  or `-` when none fits, and then DESCRIPTION starts with the reason, such as
  `(needs arx >=0.3.0)`. INSTALLED is the installed version, or `-`:

  ```text
  NAME          VERSION  KIND    INSTALLED  DESCRIPTION
  guard         0.2.0    plugin  0.2.0      A before_tool hook that denies a few destructive shell commands.
  @acme/lint    0.4.1    plugin  -          Runs the linter after each edit and adds its errors.
  @acme/web     0.1.0    kit     -          A coding agent for web apps.
  ```

- `--kits` lists only kits. `--market NAME` reads one marketplace.
  `--versions` adds one row per version, with its status.
- `--tsv` prints the same rows tab-separated with no header, in the columns
  name, version, kind, installed, description. The installer's "Find more
  plugins" menu reads this form (`installer-notes.md` in the shared notes).
- A marketplace with no index, or one it cannot reach, gets one line on
  stderr, and the others still print.
- Exit 0 when something matches, 1 when nothing does.

### 9. `arx plugin eject`

```text
arx plugin eject NAME [--force] [--yes] [--no-setup]
```

`eject` copies the plugin that loads here into `./plugins/NAME/`, next to
`./agent.yaml`, so the harness owns it:

- **Which copy**: the folder that `arx check --list` names for NAME, with
  links followed. A plugin that is not installed is an error.
- **Already here**: a project plugin that is a folder is an error
  (`NAME is already in ./plugins`). A project link is replaced by a copy.
  `--force` replaces an existing `./plugins/NAME`.
- **What it copies**: everything except `.arx-source`, `.arx-setup` and
  `.arx-setup.log`, through `.NAME.new`, then a rename.
- **Its record**: a new `.arx-source` with `source=ejected`,
  `ejected=<the old source line>` and `installed=`, and no `repo` or
  `market`, so `update` skips it.
- **Setup**: a plugin with `setup:` runs it in the new folder, after the
  summary and confirmation, with `ARX_SETUP_REASON=eject`.
- **Settings**: unchanged. The active list uses names, so the same
  settings, position, `enable:` and `disable:` apply.
- **What changes**: a project plugin hides a user plugin with the same name
  (`docs/plugins/concepts.md:108`). With no kit and no `plugins:` list,
  project plugins load before user plugins, so the ejected plugin's tools
  now win over other user plugins' tools. The summary says so.
- **Guards**: when the plugin has a hook with `band: policy` or
  `fail: closed`, the summary warns: `guard has a policy hook. In ./plugins
  the agent can change it.` Until `trust` lands, that is the only check.
- The user plugin stays installed for other harnesses.

Then `arx plugin list` shows `project` and the source `ejected from
@acme/lint 0.4.1`. The `plugin-authoring` skill tells the agent to eject a
plugin before it changes it, instead of editing `~/.config/arx/plugins/`.

### 10. `arx plugin setup`

```text
arx plugin setup NAME [--project] [--yes]
```

Runs NAME's `setup:` in its installed folder (a copy or a link), with
`ARX_SETUP_REASON=manual`. It shows the command and asks first; without a
terminal it needs `--yes`. A plugin without `setup:` prints `NAME has no
setup` and exits 0.

### 11. MCP servers in `plugin.yaml`

`mcp-client` owns the key and builds it in C (its step 4): the field table in
both `kTopFields` and `kPluginFields`, `Adopt`, and the `mcp_servers=` line
of `arx check --plugin`. `mcp-client` confirmed this shape (its plan,
sections 2 and 3, and `mcp-client.md` in the shared notes):

```yaml
# plugin.yaml
requires: [npx]
mcp_servers:
  github:                                  # the server's name
    command: npx                           # a program on PATH, or a path relative to the plugin folder
    args: [-y, "@modelcontextprotocol/server-github"]
    env: {GITHUB_PERSONAL_ACCESS_TOKEN: "${GITHUB_TOKEN}"}
  docs:
    url: https://mcp.example.com/mcp       # a remote server
hosts: [api.github.com]
```

| Point | Detail |
|---|---|
| Key name | `mcp_servers`, the same in `agent.yaml`, `config.yaml` and `plugin.yaml`, with one field table |
| Entry keys | `type`, `command`, `args`, `env`, `cwd`, `url`, `headers`, `credential`, `api_key_env`, `description`, `include`, `exclude`, `preload`, `keys`, `timeout`, `startup_timeout`, `enabled` |
| Merge | server by server and key by key (`SpecMergeUnder`): the spec wins, then the first plugin in the active list. So the spec can set `mcp_servers: {github: {enabled: false}}`, or one `env` value, on a plugin's server |
| Settings | the plugin's settings from the active list may change its `mcp_servers`, as they change `tools` and `hooks` in `Adopt` |
| Expansion | `${NAME}` and `${NAME:-default}` in `args`, `env`, `url` and `headers` values, from arx's environment, when the server starts. The example's `"${GITHUB_TOKEN}"` works |
| Paths | a `command` that contains `/` is relative to the plugin folder, and `Adopt` makes it absolute. A bare `command` is looked up on `PATH` |
| Environment | the server process gets `ARX_PLUGIN_DIR`, as observers do |
| Hosts | `Adopt` adds a `url` server's host to the hosts; a `command` server's hosts go in the plugin's `hosts:` |
| Dependencies | a server that needs packages uses `setup:` (`npm ci`) and `requires:`. This is the one part this plan owns |
| Off plugins | only plugins in the active list add servers; this falls out of `Adopt` |
| Shown by | `arx check --plugin` prints `mcp_servers=github docs` (`mcp-client`); `arx plugin add` and `update` show `mcp       github docs` (this plan, step 15) |

Server lifecycle, tool naming (`<server>__<tool>`), `mcp_search` and
`mcp_select` are `mcp-client`'s.

### 12. Commands, options, files and variables in one place

```text
usage: arx plugin add REF [--project] [--link] [--force] [--yes] [--no-enable] [--no-setup]
       arx plugin update [NAME...] [--project] [--check] [--yes] [--no-setup]
       arx plugin remove NAME [--project] [--yes]
       arx plugin search [TERM] [--market NAME] [--kits] [--versions] [--tsv]
       arx plugin eject NAME [--force] [--yes] [--no-setup]
       arx plugin setup NAME [--project] [--yes]
       arx plugin market add NAME SOURCE [--project] | remove NAME [--project] | list
       arx plugin index [DIR] [--ref REF] [--check]
       arx plugin enable|disable NAME [--global]
       arx plugin list
       arx plugin new NAME [DIR]
       arx plugin fetch [--kits] REF DIR
```

| Item | Kind | Status |
|---|---|---|
| `setup` | `plugin.yaml` key, string | new |
| `mcp_servers` | `plugin.yaml` key, map | new, built by `mcp-client` |
| `marketplaces` | `config.yaml`, `agent.yaml`, `kit.yaml` key: list of `{NAME: SOURCE}` | new |
| `arx` | `plugin.yaml` key | grammar grows: `<`, `<=`, `>`, `=` and several comparisons |
| `index.yaml` | marketplace file | new, format 1 |
| `.arx-source` | plugin file | new lines (section 5) |
| `.arx-setup`, `.arx-setup.log` | plugin files | new |
| `arx check --index FILE` | built-in | new: TSV rows, exit 2 when not valid |
| `arx check --plugin DIR` | built-in | prints `setup=` too (`mcp_servers=` comes from `mcp-client`) |
| `ARX_SETUP_TIMEOUT` | variable | new, default `10m` |
| `ARX_PLUGIN_DIR`, `ARX_PLUGIN_NAME`, `ARX_PLUGIN_VERSION`, `ARX_SETUP_REASON`, `ARX_SETUP_PREVIOUS` | set for `setup` | new |
| `ARX_PLUGIN_MARKETS` | variable, internal | `arx kit add` passes the kit's `marketplaces` to `arx plugin add` as `NAME=SOURCE` lines |
| `ARX_DOWNLOAD_URL` | variable | also serves `/index/<ref>.yaml`; the default stays `https://arx-documentation.vercel.app` |
| `ARX_PLUGIN_MIRROR` | variable, tests | also holds `OWNER/REPO/<ref>/index.yaml` |
| exit 10 | `arx plugin update --check` | new: an update exists |

No new hook points, events or run-time behavior beyond the load gate.

## Implementation steps

In order. Steps 1 to 9 are C and land first, in one PR, because the shell
needs `arx check --index` and the load gate. Step 15 waits for `mcp-client`
step 4.

1. **`src/harness/version.c` (new)**: move `VersionNumber` and
   `VersionProblem` out of `src/harness/plugins.c:89-119`. Add the
   comparison list grammar (section 4), pre-release detection, and
   `int VersionCompare(const char*, const char*)`. Declare them in
   `src/harness/harness.h`. Add the file to the `Makefile` sources.
2. **`src/harness/fields.c`**: add `setup` (`kString`) to `kPluginFields`;
   add `marketplaces` (a new type `kMarketList`) to `kTopFields` and
   `kKitFields`; add `kIndexFields` and its nested tables for the entry and
   the version.
3. **`src/harness/validate.c`**: check `kMarketList` (one-key maps, names in
   `kNameChars`, not `arx`, string sources); add `IndexValidate`, which also
   checks `index: 1`, each `version`, each `arx` constraint, and at most one
   version without `ref` per name.
4. **`src/harness/plugins.c`**: add `setup` to `kOwnKeys`; in `LoadPlugin`,
   the setup gate (section 6) before `Adopt`, with the why `setup has not
   run: run arx plugin setup NAME`.
5. **`src/harness/signature.c`**: hash `plugins/<name>/.arx-setup` in both
   parents, next to `plugin.yaml`.
6. **`src/harness/describe.c`**: print `setup=` after `hosts=` and after
   the `instructions=` and `model_settings=` lines that `plugin-yaml-keys`
   adds there, so the line order is fixed; add
   `IndexDescribe(path, out, err)` for the TSV rows, sorted with
   `VersionCompare`, with `status` from `VersionProblem`.
7. **`src/cli/check.c`**: accept `arx check --index FILE` in `CheckFolder`
   (`:238-247`) and `CheckOrTools` (`:249-254`).
8. **`src/harness/spec.c`**: when libyaml reports `found character that
   cannot start any token` at a `@`, append `(quote a name that starts with
   @, as in "@acme/lint")`.
9. **`src/harness/harness.h`**: the declarations, and `kMarketList` in the
   field types.
10. **`commands/arx-config`**: `put_list` and `set` quote an item that
    starts with `@`.
11. **`commands/arx-plugin`**, in this order, each with its tests:
    1. `resolve`: the `@MARKET/NAME[@REF]` branch first; `market_source`
       (reads `marketplaces` from `./agent.yaml`, then `config.yaml`, then
       `ARX_PLUGIN_MARKETS`, with `arx config get`); `fetch_index`;
       `pick_version` over `arx check --index` rows; a better error when the
       default marketplace has no such plugin.
    2. `install_folder`: the shared stage, swap, setup and roll-back path
       (section 6), used by `add`, `update` and `eject`; `.arx-source` with
       the new lines; `run_setup` with the process group, timeout, log,
       stream and stamp.
    3. `cmd_add`: `setup` and `market` lines in the summary, the `requires`
       stop, `--no-setup`, roll-back of `enable:` on failure.
    4. `cmd_setup`, `cmd_market`, `cmd_index`, `cmd_search`, `cmd_update`,
       `cmd_eject`, the usage text and the dispatcher (`:370-383`).
    5. `cmd_new`: write `.gitignore` with `.arx-setup` and `.arx-setup.log`.

    Keep it to bash 3.2, which macOS ships: no associative arrays, no
    `mapfile`, no `${var,,}`.
12. **`commands/arx-kit`**: `plugin_ref` (`:104-113`) passes `@MARKET/NAME`
    through; read the kit's `marketplaces` and pass them in
    `ARX_PLUGIN_MARKETS`; show `setup` per plugin; copy, not link, a
    shipped plugin with `setup:` (`:157-160`).
13. **`commands/arx-setup`** (`:178-185`) and **`commands/arx-update`**
    (`:104`): arx setup copies a shipped plugin with `setup:` instead of
    linking it (none does today); arx update prints the
    `arx plugin update --check` summary after an install.
14. **`index.yaml`** at the repo root, from `./arx plugin index .`;
    `scripts/lint.sh` runs `./arx plugin index --check .`;
    `plugins/README.md` adds the step to its checklist;
    `plugins/plugin-authoring/skills/plugin-authoring/SKILL.md` says to
    eject a plugin before changing it.
15. **After `mcp-client` step 4** (the key in both field tables, `Adopt`
    and `describe.c`): in `commands/arx-plugin`, read `mcp_servers=` in
    `describe` (`:79-92`), show the `mcp` line in `cmd_add`'s summary, and
    diff it in `update`'s summary. No C in this step.
16. **The arx site (woodfordbl/arx-docs, outside this repo)**: add
    `/index/<ref>.yaml`, serving `index.yaml` of woodfordbl/arx at a tag,
    `main` or a commit, as `/archive/<ref>.tar.gz` does. Merge it before
    the release, as for `d275cfc`. Until then, `fetch_index` falls back to
    raw.githubusercontent.com for the default marketplace. The route lives
    on `arx-documentation.vercel.app`, the site's final domain, next to the
    downloads.

## Tests

A new `tests/market.sh`, added to `make test` (`Makefile:63-72`). It uses
local marketplace folders and `ARX_PLUGIN_MIRROR`, never the network:

- **References**: `@acme/lint` installs `plugins/lint` from a folder
  marketplace and from the mirror; `@arx/guard` equals `guard`; an unknown
  market names `arx plugin market add`; `@acme/lint` over an installed
  `lint` needs `--force` and names the other source.
- **Markets**: `market add`, `list` and `remove` edit `config.yaml`, or
  `agent.yaml` with `--project`; `agent.yaml` wins for a name; `@arx` and
  bad names are refused; `market add` of a source without an index says so.
- **Index**: `arx check --index` accepts the example from section 3;
  rejects `index: 2`, a missing `versions`, a bad `arx`, two versions
  without `ref`; sorts `0.10.0` above `0.9.0`; marks `needs arx`, `yanked`
  and `pre-release`. `arx plugin index` writes a file that
  `arx check --index` accepts; `--ref` adds and keeps versions;
  `--check` exits 1 on a stale file.
- **Resolution**: the highest `ok` version wins; a pinned `@REF` wins over
  the index; a yanked version installs only by `@REF`; no version fits
  gives the message and exit 1; a market without an index uses `HEAD` with
  a note; `arx:` with an upper bound skips the plugin at load in a release
  build. The release cases build a test binary with a fixed `VERSION`, as
  `tests/cli.sh` does for `arx update`.
- **Setup**: runs after `add` in the final folder with each variable set
  and stdin empty; writes `.arx-setup` and `.arx-setup.log`; a failing setup
  leaves nothing installed and no `enable:` entry; `add --force` with a
  failing setup keeps the old folder; a `sleep 30` setup with
  `ARX_SETUP_TIMEOUT=1s` is killed with its children; a missing `requires`
  stops `add` first; `--no-setup` installs it off; `arx plugin setup` turns
  it on.
- **Update**: up to date when the commit is the same; moves to the new
  version and runs setup; puts the old version back when setup fails and
  still updates the others; skips links, pins, tarballs and ejected
  plugins; `--check` exits 10 and changes nothing; keeps `pin`, `market` and
  `enable:`; a 0.1.x `.arx-source` without the new lines updates.
- **Search**: matches name, description and tags; marks installed
  versions; `--kits`, `--market`, `--versions`; `--tsv` prints five
  tab-separated columns and no header; a missing index is one line
  on stderr; no match exits 1.
- **Eject**: copies to `./plugins/NAME` without `.arx-*` files; `list`
  shows `project` and `ejected from`; the project copy hides the user
  plugin; `update` skips it; a `band: policy` hook gives the warning;
  setup runs in the new folder.

Changes to existing files:

- **`tests/layers.sh`**: the load gate: no stamp, a stamp with another
  `setup=`, and `exit=1` each give `broken` with the why; a good stamp
  loads; writing the stamp mid-session loads the plugin on the next turn.
- **`tests/kits.sh`**: a kit with `- "@acme/lint"` and `marketplaces:`
  installs it; an unquoted `@acme/lint` gives the hint; a shipped plugin
  with `setup:` is copied, not linked.
- **`tests/cli.sh`**: `arx config add enable @acme/lint` writes a quoted
  item; `arx check --plugin` prints `setup=`; `arx update` prints the plugin
  summary (with `ARX_UPDATE_DIR`).
- **`tests/plugins.sh`**: `arx plugin index --check .` passes, so the
  repo's `index.yaml` matches `plugins/` and `kits/`.

## Docs to change

Written to `docs/WRITING.md`: "you", present tense, the default named,
sentences of 8 to 20 words, no em dashes, at most two callouts a page.

- **`docs/plugins/reference.md`** (reference): a row for `setup` in the
  `plugin.yaml` table and the full example (`mcp-client` adds the
  `mcp_servers` row; this plan adds the `mcp` line of the `add` summary and
  that a server's packages come from `setup:`); the new
  `arx:` grammar; a `### setup` contract section (when, environment, output,
  stamp, failures); the `arx plugin` command and option tables with
  `update`, `search`, `eject`, `setup`, `market`, `index`, `--no-setup`,
  `--check`; the `.arx-source` lines; `## index.yaml`; `marketplaces` under
  "Spec keys for plugins"; `arx check --index`; `ARX_SETUP_TIMEOUT`; exit 10
  in the exit code table.
- **`docs/plugins/marketplaces.md`** (new guide): "A marketplace is a repo
  or folder that offers plugins and kits." Lay out a marketplace, write and
  check `index.yaml`, release with `arx plugin index --ref vX.Y.Z`, bound
  `arx:`, write a safe `setup:` (lockfile, no prompts, idempotent, only
  `ARX_PLUGIN_DIR`), and how users add it. Ends with `## Related`. Link it
  from `docs/plugins.md` and `docs/plugins/concepts.md`.
- **`docs/plugins/concepts.md`** (concept): the Marketplace section gets
  named marketplaces, `@acme/lint` and `index.yaml`; remove the
  **Planned:** line at `:208-209`.
- **`docs/plugins/kits.md`** (guide): `@MARKET/NAME` in plugin lists,
  quoted; `marketplaces` in the `kit.yaml` table; a Common mistakes row for
  an unquoted `@acme/lint`; remove the **Planned:** line at `:237-238`.
- **`docs/plugins/planned.md`** (project): remove the "The marketplace
  index" row and the "More of arx plugin" section. Keep "MCP client" until
  `mcp-client` ships.
- **`docs/roadmap.md`** (project): item 3 becomes done without "More of
  `arx plugin` is next"; remove the "More of `arx plugin`" section.
- **`docs/spec.md`** (reference): the `marketplaces` key.
- **`docs/cli.md`** (reference): the `arx plugin` line at `:15` lists the
  new verbs; `ARX_SETUP_TIMEOUT` joins the variable table at `:175`.
- **`docs/plugins/commands.md`** (guide): one line that a command which
  needs packages gets them from its plugin's `setup:`.
- **`README.md`**: add `arx plugin search` and `arx plugin update` to the
  example at `:161-164`.
- **`plugins/README.md`**: the `index.yaml` step in the checklist.

## Dependencies

| Slug | What it shares with this plan |
|---|---|
| `mcp-client` | Owns and builds `mcp_servers` (section 11): its step 4 adds the key to both field tables, `Adopt` and `describe.c`. This plan's step 15 is only the `arx plugin` summary lines and docs, after that step. Both plans edit `kPluginFields` and `Adopt` (for `setup`), so they land one after the other. Confirmed in `mcp-client.md` in the shared notes. |
| `acp-tui` | Its plugin is `tui`, with the command `arx-tui` and `ui: tui`. It needs `setup:` (`bun install --frozen-lockfile`), `requires: [bun]`, and to be a user plugin for `commands/arx-tui`. Steps 1 to 11 land before it can be installed. If it ships in `plugins/`, the release also ships it in `libexec`, and the copy-not-link rule (step 12, 13) applies. The core install stays bare, so you run `arx plugin add tui`. |
| `plugin-yaml-keys` | Edits the same lines: `kPluginFields`, `kOwnKeys`, `Adopt`, `describe.c` and the reference table. Its note fixes `instructions=` and `model_settings=` right after `hosts=` in `arx check --plugin`, and `prompt` and `settings` lines in the `add` summary; `setup=` goes after them (step 6), and `update` diffs them too (section 7). Land in sequence, or in one PR for all new `plugin.yaml` keys. |
| `trust` | `eject` moves code into the folder the agent can edit, so a policy hook there is weaker (section 9). `harness_edit` would see the agent's edits to an ejected plugin. Trust replaces the fingerprint with one harness-file walk: `.arx-setup` (step 5) belongs in that walk, not in a separate hash. An `update` or `eject` during a run changes harness files, so a policy sees them as changes; a change in a policy folder stops the run, so update policy plugins between runs. Trust takes exit 5; this plan uses only 10, as `arx update --check` does. If `--policy DIR` gets its own `plugins/`, `add`, `update` and `setup` need a `--policy` scope next to `--project`. |
| `sandboxes` | `setup` runs on the host, outside any `sandbox:`. A sandbox plugin can use `setup:` to pull its image. |
| `plugin-state` | `setup` writes only in `ARX_PLUGIN_DIR`, which `update` replaces. Durable data belongs in `ARX_DATA_DIR` (`<cwd>/.arx/data/<name>/`), which `update` and `eject` never touch. `setup` gets neither `ARX_STATE_DIR` nor `ARX_DATA_DIR` (section 6). If `plugin-state` adds a per-user data folder, `setup` should get its variable. |
| `long-lived-hooks` | `update` replaces a folder under a hook process that keeps running. Long-lived hooks must restart when their plugin's `plugin.yaml` changes, which the reload signature already sees. |
| `climb` | None, unless `arx climb` ships as a plugin command; then `arx plugin add` installs it. |
| `async-calls` | None. |
| `installer` | Its "Find more plugins" menu runs `arx plugin search --tsv` (section 8). It turns `confirm()` in `commands/arx-plugin` and `commands/arx-kit` into a shared `ui_confirm` and adds a picker, ordered after this plan's changes to those files. Sourced shell lives in `libexec/arx/lib/`. |

## Size and risks

**Size: L.** About 300 lines of C (version grammar, index validation and
rows, the load gate, the YAML hint), about 450 lines of shell in
`commands/arx-plugin` plus small edits to `arx-kit`, `arx-config`,
`arx-setup` and `arx-update`, a new test file of about 250 lines, one new
docs page and nine edited ones, and one route on the arx site.

Risks:

- **`@acme/lint` needs quotes in YAML.** Readers will write it bare and get
  a libyaml error. The hint, the quoting in `arx config`, and a Common
  mistakes row soften it.
- **`commands/arx-plugin` grows to about 850 lines of bash 3.2.** Keep each
  verb a function, and share `resolve` and `install_folder`. If it passes
  900 lines, split the verbs into files in `libexec/arx/lib/`, the folder
  the `installer` plan uses for sourced shell (no `arx-` prefix, so they
  don't show up as commands).
- **`setup` runs third-party code at install time**, and `bun install` runs
  package scripts. The summary shows the command, the docs ask for a
  lockfile, and the `tui` plugin (slug `acp-tui`) should use `--frozen-lockfile`.
- **Timeouts in bash**: `set -m` with a watchdog is the only portable way
  to kill a process group on both macOS and Linux. Test it on both in CI.
- **A plugin is off while its update's setup runs.** For a TUI or MCP
  plugin this is seconds. For a guard it is a gap: the docs say to update
  between runs.
- **One folder per name**: a team that uses `lint` from two marketplaces
  cannot have both. That is the rule a run already follows by name.
- **Index drift**: an index can list a version that its `ref` does not
  hold. arx trusts the downloaded `plugin.yaml` and warns.
- **The site route** is a change in another repo, with its own review.

## Open decisions

1. **`@acme/lint` in YAML.** Keep the `@` form the roadmap names, require
   quotes in YAML, and add the parse hint. *Recommended.* The other choice,
   a form YAML accepts bare (`acme:lint`), breaks the `acme: source` style of
   one-key maps and differs from the roadmap.
2. **Where `eject` puts the plugin.** `./plugins/NAME/` as a project plugin.
   *Recommended*: it keeps `plugin.yaml` (bands, `fail`, settings,
   compactors), and a project plugin already hides a user plugin. Copying
   the parts into the spec folder's own `tools/` and `hooks/` would lose
   those options and the settings in `ARX_PLUGIN_SETTINGS`.
3. **A failed `setup`.** Roll back: `add` installs nothing, `update` keeps
   the old version. *Recommended*: the install is all or nothing, as the
   copy-then-swap already is. Keeping a half-installed plugin off is the
   other choice.
4. **The load gate.** A plugin with `setup:` and no good `.arx-setup` does
   not load. *Recommended*: no run sees a plugin without its packages. It
   costs one file read per such plugin.
5. **`setup` as a string only.** *Recommended* for 0.2.0. A map
   (`{run, timeout}`) can come later, and the string stays valid.
   `ARX_SETUP_TIMEOUT` covers a slow setup until then.
6. **An upper bound in `arx:`.** Add `<`, `<=`, `>`, `=` and several
   comparisons. *Recommended*: before 1.0 a minor release can break a
   plugin, and without a bound, resolution picks a version that the next
   minor breaks.
7. **Where named marketplaces live.** A `marketplaces:` list key in
   `config.yaml`, `agent.yaml` and `kit.yaml`. *Recommended*: `arx config`
   edits it with no change, `arx check` validates it, and a project or kit
   can name the marketplaces it needs. A separate file would need its own
   parser and editor.
8. **The default marketplace lacks a plugin at the core tag.** Fail, and
   suggest `arx update` or `@main`. *Recommended*: it follows the decision
   that `add` fetches the core tag, and a plugin from `main` may need a
   newer core.
9. **Fetching an index.** A site route for the arx repo, raw GitHub for
   other repos, and no cache. *Recommended*: one small request per
   marketplace, and the site keeps the arx repo on one host, as `d275cfc`
   chose. That host is `arx-documentation.vercel.app`, the final domain.
10. **Marketplaces at a plain URL** (not GitHub, not a folder). Defer past
    0.2.0. *Recommended*: a folder covers mirrors and air-gapped machines.
11. **`arx kit update`.** Defer. *Recommended*: shipped kits follow
    `arx update` as links, and `arx kit add NAME --force` covers the rest.
12. **`arx update` and plugins.** Print the `arx plugin update --check`
    summary, and update nothing. *Recommended*: each plugin update shows a
    summary and asks.
13. **Pre-releases.** Skip them unless `@REF` names one. *Recommended.* A
    `--pre` flag can come later.
14. **The `mcp_servers` key.** Settled with `mcp-client`: `mcp_servers`,
    merged key by key, with `${NAME}` expansion (section 11).
15. **`market` or `marketplace` as the verb.** `arx plugin market`.
    *Recommended*: shorter, and nothing else in `arx plugin` uses the word.
