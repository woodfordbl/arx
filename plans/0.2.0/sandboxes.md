# Sandboxes: `sandbox:`, `ARX_SANDBOX` and the `sandbox-native` plugin

Slug: `sandboxes`. Plan for arx 0.2.0. Nothing here is built yet.

## Goal

Let a run's `bash` and `edit` work where they cannot change the harness,
read your secrets, or (by default) reach the network, while arx itself stays
the same small program.

- **One spec key, `sandbox:`**: arx validates it and gives it to every tool,
  hook, observer and compactor as `ARX_SANDBOX`. arx does not act on it.
- **One list, `ARX_HARNESS`**: the paths that make up the harness, so a
  sandbox knows what to keep out of the agent's reach.
- **One real plugin, `sandbox-native`**: its own `bash` and `edit`, with
  `replaces: [bash, edit]`. On macOS they run in Seatbelt (`sandbox-exec`),
  on Linux in bubblewrap (`bwrap`). Inside, they run the same
  `arx tool bash|edit` as the `shell` plugin, so results do not change.
- **Fail closed**: when a run has a sandbox and the `bash` or `edit` it got
  does not sandbox, the call fails with a message. It never runs on the host
  by mistake.

A sandbox that cannot change the harness files is what makes a policy
(slug `trust`) a boundary. Without one, a policy stops mistakes, not a
hostile agent.

### Why native first, not Docker

| | `sandbox-native` (Seatbelt, bubblewrap) | `sandbox-docker` |
|---|---|---|
| Start cost per call | about 5 to 20 ms (to measure in step 0) | `docker exec` 50 to 150 ms; `docker run` 0.3 to 1 s |
| State per session | none: each call is a new sandbox | a container per session, and a way to remove it |
| `edit` inside | the host's `arx tool edit`, unchanged | needs a Linux arx in the container; on macOS that is a second binary |
| Toolchain | the host's compilers, `node`, `python3` | an image you build and keep current |
| Shared work folder | same OS on both sides | Linux builds in a macOS folder (`node_modules`, `.venv`) break on the host |
| Needs | macOS: nothing; Linux: `bwrap` and user namespaces | Docker Desktop, OrbStack or colima, and a running daemon |
| Isolation | same kernel and user; path rules | a VM on macOS, namespaces on Linux |

`sandbox-native` keeps arx small and fast, adds no daemon, and needs no
session lifecycle. Docker gives stronger isolation on macOS and the same
contract fits it, so it is the next plugin, not this release's
(see [Later: sandbox-docker](#later-sandbox-docker)).

### Threat model

The agent controls the model's tool calls, and any process those calls
start. It runs as your user. The sandbox must keep it from:

1. **Changing the harness**: any path in `ARX_HARNESS`, which arx runs or
   reads on the host (spec, prompts, tools, hooks, plugins, kits, programs,
   `.arx/`, the arx binary). A file the agent writes to `hooks/` is host code.
2. **Reaching arx**: signals, `ptrace`, the terminal (`TIOCSTI`), the
   session inbox.
3. **Reading secrets**: the API key in the environment, the keychain, saved
   credentials, `~/.ssh` and the like.
4. **Talking to the network**, unless `network: true`; and Unix sockets
   (ssh-agent, Docker, D-Bus) always.
5. **Escaping through the OS**: LaunchServices (`open`), Apple Events
   (`osascript`), launchd, nested sandboxes.

Out of scope: kernel exploits, resource exhaustion (fork bombs, a full
disk), and code the agent writes that you run later yourself. The docs say
so plainly.

## Current state

| Part | Where | Today |
|---|---|---|
| Tool environment | `src/harness/tool_exec.c:59-74` | `ToolEnv` builds 9 `ARX_*` variables. No sandbox. |
| Hook environment | `src/harness/hooks.c:71-85` | `ToolEnv` plus `ARX_PLUGIN_SETTINGS`. |
| Observer environment | `src/agent/run.c:67-72` | `ToolEnv(a, NULL)`. |
| How a child gets its env | `src/base/proc.c:28-46`, `:122` | `EnvWith` adds the extras to a copy of `environ`. Every tool gets arx's whole environment, `OPENROUTER_API_KEY` too. |
| Subagents | `src/harness/tool_exec.c:107-139` | `arx -p - --spec P --json --quiet --events fd:3` plus `--cap`; env is `ToolEnv` with `ARX_DEPTH` one higher. `--set` does not pass. |
| What arx reads from its own env | `src/agent/run.c:191-192` | `ARX_DEPTH`; also `ARX_CONFIG_DIR`, `ARX_CURL`, `ARX_DISABLE_KEYCHAIN`. |
| `bash` and `edit` | `src/cli/shell_tools.c:56-104`, `:106-144` | `edit` writes any path; `bash` runs `sh -c`. |
| The `shell` plugin | `plugins/shell/` | `tools/bash` is `exec "$ARX_BIN" tool bash "$@"`; schemas in `tools/*.json`. |
| Direct start | `src/harness/tools.c:43-46`, `:98`; `tool_exec.c:214-219` | A file of 512 bytes or less that only runs `exec "$ARX_BIN" tool NAME` starts as arx itself. |
| First tool wins | `src/harness/tools.c:276-300` | `AddLayers` keeps the first tool with a name, in layer order. `tools.c` is 391 lines; lint allows 400. |
| `replaces:` | `fields.c:105`, `plugins.c:180`, `src/cli/check.c:130-160` | Only silences the "hides the tool" warning. Changes no order. |
| Layer order | `src/harness/plugins.c:311-331` | Spec folder first, then the active list (or project plugins, config folder, user plugins). |
| Reload fingerprint | `src/harness/signature.c:62-93` | Spec, config, prompt files, `tools/`, `hooks/`, skills of each layer, `plugin.yaml` and `kit.yaml` files. Misses programs and the scheduler (trust adds them). |
| Spec fields | `src/harness/fields.c:66-95` | No `sandbox`. |
| Sessions | `src/io/session.c:14`, `:120`; `src/cli/commands.c:83-98` | `.arx/sessions/` under the working directory; `arx ctl` appends to the session's `inbox` file. |
| Saved keys | `src/model/auth.c:4`, `:59-62` | Keychain service `arx` on macOS, else `<config>/credentials`. The `chatgpt` plugin keeps `auth.json` in `<config>/chatgpt/`. |
| Default layout | `commands/arx-init:70-89` | `agent.yaml`, `prompts/`, `tools/`, `hooks/`, `skills/` in the work folder. So the spec folder is usually the work folder. |
| Docs | `docs/plugins/planned.md:45-53`, `docs/plugins/tools.md:199-205`, `:237-241`, `docs/concepts.md:200-201` | Sandboxes are "planned"; concepts says "No sandbox: run arx in a container or VM". |
| CI | `.github/workflows/ci.yml` | Tests run inside an Alpine container, where user namespaces do not work. `release.yml` runs on macOS and builds static Linux binaries. |

## Design

### The `sandbox` key

`sandbox:` is a map. arx validates it with the field table, makes its paths
absolute, and passes it on. It never acts on it.

```yaml
# agent.yaml
sandbox:
  type: native                 # required: which sandbox plugin acts
  network: false               # default false: localhost only
  write: [~/.cache/pip]        # more writable folders
  read_only: [eval/]           # readable, not writable, inside a writable folder
  hide: [~/.config/acme]       # neither readable nor writable
  env: [PIP_INDEX_URL]         # more environment variables to pass in
```

| Key | Type | Default | Meaning |
|---|---|---|---|
| `type` | string | **required** | The sandbox. A plugin named `sandbox-TYPE` acts on it. Letters, digits, `_`, `-`. |
| `network` | boolean | `false` | `false`: loopback only. `true`: any IP host. Unix sockets stay closed in both. |
| `write` | string list | `[]` | Folders the agent may write, besides the work folder and its private temp folder. |
| `read_only` | string list | `[]` | Paths inside a writable folder that the agent may read but not change, such as `eval/`. |
| `hide` | string list | `[]` | Paths the agent may neither read nor write, besides the default list. |
| `env` | string list | `[]` | Environment variable names to pass in, besides the default list. |
| `harness` | string | `read-only` | Step 10, with `trust`: `read-only` or `gated`. See [Harness files](#harness-files). |

Rules:

- **Paths**: a relative path is relative to the spec folder, as for every
  path in the spec. `~/` is your home folder. arx makes both absolute
  before it exports them.
- **Where it can be set**: `agent.yaml`, `config.yaml` and `--set`. Not
  `plugin.yaml` or `kit.yaml`: installing a plugin must not sandbox, or
  unsandbox, every run.
- **Pin it** with `--set 'sandbox={"type":"native"}'` (a JSON value sets the
  whole map). arx applies it on every reload, so an edit to `agent.yaml`
  cannot change it.
- **No `sandbox:`** means no sandbox. There is no `type: none`.

### `ARX_SANDBOX`

| Part | Contract |
|---|---|
| Value | The map as one line of compact JSON (`cJSON_PrintUnformatted`), keys in spec order, only the keys that are set, paths absolute. |
| Set for | Every tool call, hook, observer, compactor and scheduler, through `ToolEnv`. Not for `--schema` (no `ARX_*` variables, as today). |
| Unset | When the run has no sandbox. |
| Where it comes from | An `ARX_SANDBOX` in arx's own environment, when not empty. Else the spec's `sandbox:` after `--set`. |

```text
ARX_SANDBOX={"type":"native","network":false,"write":["/Users/ana/.cache/pip"],"read_only":["/Users/ana/tsp/eval"]}
```

**An inherited value wins.** arx never removes or changes an `ARX_SANDBOX` it
was started with. So a subagent, an `arx` that a tool starts, and the runs
of `arx climb` keep the sandbox of the run that started them. A subagent's
own `sandbox:` applies only when its parent has none: a sandbox can be added
down the tree, never removed or loosened. arx does not parse an inherited
value; the sandbox plugin checks it and fails closed.

### `ARX_HARNESS`

The paths a sandbox must keep from being changed, one per line:

```text
spec /Users/ana/tsp/agent.yaml
config /Users/ana/.config/arx/config.yaml
prompt /Users/ana/tsp/prompts/system.md
folder /Users/ana/tsp/tools/
folder /Users/ana/tsp/hooks/
folder /Users/ana/tsp/plugins/
folder /Users/ana/tsp/kits/
folder /Users/ana/tsp/skills/
plugin /Users/ana/.config/arx/plugins/sandbox-native/
plugin /Users/ana/.config/arx/plugins/shell/
session /Users/ana/tsp/.arx/
binary /usr/local/bin/arx
```

| Part | Contract |
|---|---|
| Line | `KIND PATH`, one space between. `read -r kind path` reads it in `sh`. |
| Path | Absolute, as arx uses it (symlinks not resolved). It need not exist. A folder ends with `/`. Each path once. |
| Set | For the same programs as `ARX_SANDBOX`, with or without a sandbox, so a policy can use it too. |
| Inherited | arx appends its own lines to an `ARX_HARNESS` it was started with. A subagent's sandbox then also protects its parent's harness, which shares the work folder. A launcher such as `arx climb` can add its own files the same way. |
| Size | About 20 to 60 lines; well under `ARG_MAX`. Computed at each load, kept with the spec. |

| Kind | What |
|---|---|
| `spec`, `config` | The spec file; `config.yaml` when in use. |
| `prompt` | A file named by `instructions`, `first_message` or `compaction.prompt`. |
| `program` | A path named by `compactors`, `credentials`, `adapters`, `compaction.strategy`, `endpoint.credential`, `endpoint.adapter` or `endpoint.curl`, and the first word of an `observers` command when it is a path (relative to the working directory). MCP server commands join here (slug `mcp-client`). |
| `folder` | `tools/`, `hooks/`, `plugins/`, `kits/` and the skills folder of the spec folder and the config folder. |
| `scheduler` | The `scheduler` file of the spec folder and the config folder. |
| `plugin` | Each plugin folder in the active list, whole. |
| `kit` | Each kit folder in use that is not under a `kits/` folder above. |
| `agent` | Each subagent spec (`tools.*.agent`). Its folder adds its own `folder`, `prompt` and `program` lines, once each, recursively. |
| `policy` | Each policy folder (slug `trust`). |
| `session` | `.arx/` in the working directory. |
| `binary` | The running arx binary and its `libexec/arx` folder. Subagents start this binary on the host. |

The list is the reload walk seen as roots: one function in
`src/harness/signature.c` feeds both, so a file that reload watches is
always under a protected root (a test checks this). Trust adds the walk
itself (`HarnessFiles`); this plan adds `HarnessRoots` next to it.

### `ARX_IN_SANDBOX`

A sandbox plugin sets `ARX_IN_SANDBOX=1` for every process in its sandbox.
arx never sets it. Two programs read it:

- **`arx tool bash|edit`** run when it is `1`, even with `ARX_SANDBOX` set.
- **A sandbox plugin's runner** runs the command directly when it is `1`:
  the process is already confined, and macOS cannot nest Seatbelt.

### The shell tools fail closed

`arx tool bash` and `arx tool edit` (`src/cli/shell_tools.c`) refuse when
`ARX_SANDBOX` is set and not empty, and `ARX_IN_SANDBOX` is not `1`:

```text
bash: this run has a sandbox (type native), but this bash does not run in
one. Enable the sandbox-native plugin, before shell in the plugin list.
```

The call ends with exit 1, so the model sees an error result. This catches
every way to get it wrong: the plugin is not installed, it comes after
`shell` in a list, or a subagent's `plugins:` list leaves it out. The type
in the message comes from a plain string search for `"type":"`, so the
refusal itself needs no JSON parser.

### `replaces:` wins the tool

Today `replaces: [bash]` only silences a warning. This plan makes it decide.
The rule, agreed for the whole release (README, "Settled across plans",
item 4) and written the same way in the trust plan:

1. **A policy layer's tool** (slug `trust`) wins.
2. **Else, a tool from a plugin that lists the name in `replaces:`** wins,
   wherever that plugin is in the active list. This also beats a tool of the
   same name in the spec folder.
3. **Else, the current rule**: the first tool with a name wins, in layer
   order.

Inside steps 1 and 2, the first layer in order wins. Two plugins that both
replace a name: the first in the list wins, and `arx check` warns. A tool
that a winner hides gets the existing note "tools/NAME is hidden by a tool
above it".

So `enable: [sandbox-native]`, which appends to the end of a kit's list,
works, and a `tools/bash` in the spec folder cannot hide the sandbox's
`bash`. Without this, the first case would hit the refusal above and need a
reordered `plugins:` list.

### `arx check`

| Output | When |
|---|---|
| `sandbox: native (agent.yaml)` | The run has a sandbox. The source is `agent.yaml`, `config.yaml`, `--set` or `the environment`. |
| `- sandbox native: bash runs \`arx tool bash\`, which refuses in a sandbox; enable the sandbox-native plugin` | in `problems:`, when the `bash` or `edit` that wins is a direct start of `arx tool` (`Tool.core` is set). |
| `arx check --harness` | Prints `ARX_HARNESS`, one line each. |
| `arx check --sandbox` | Prints `ARX_SANDBOX`, or nothing. |

`arx check` stays the place to ask "what will this run do". It does not
test the sandbox; `arx sandbox-native check` does.

### The `session.start` event

The event gets `"sandbox": {...}`, the value of `ARX_SANDBOX`, when the run
has one. Observers, `arx watch` and an ACP front-end (slug `acp-tui`) can
then show it.

### What every sandbox plugin must do

A sandbox plugin is any plugin that acts on `ARX_SANDBOX`. The contract,
for `sandbox-native` and any later one:

1. **Name**: `sandbox-TYPE`, acting only when `type` is `TYPE`.
2. **No sandbox, no change**: when `ARX_SANDBOX` is unset or empty, its
   `bash` and `edit` run `arx tool bash|edit` as the `shell` plugin does.
   Installing it changes nothing until a spec sets `sandbox:`.
3. **Another type**: refuse, exit 1, with a message that names both types.
4. **Every key or nothing**: apply every key, and refuse an unknown key or a
   value it cannot enforce.
5. **The harness**: no create, write, delete, rename or link on any
   `ARX_HARNESS` path, on a symlink's target, or on a folder that holds a
   protected file.
6. **arx out of reach**: no signals to or `ptrace` of processes outside the
   sandbox, no terminal, no Unix sockets.
7. **Environment**: pass only the default list, `env:` names and the
   `ARX_*` variables, with `ARX_IN_SANDBOX=1`.
8. **Processes**: end every process of the call when the call ends, where
   the OS allows it, and document the gap where it does not.
9. **Same tools**: `bash` and `edit` with the same schemas, keys and
   results as `shell`'s, and `replaces: [bash, edit]`.
10. **A runner command**: `arx sandbox-TYPE run -- CMD...` runs any command
    in the same sandbox, for other programs (climb's eval, MCP servers, your
    own tools). `arx sandbox-TYPE check` tests the backend on this machine.

### The `sandbox-native` plugin

```text
plugins/sandbox-native/
  plugin.yaml          # replaces: [bash, edit]; hooks: session_start
  README.md
  tools/bash           # exec "$ARX_PLUGIN_DIR/lib/run" "$ARX_BIN" tool bash
  tools/bash.json      # shell's schema; the description says "in a sandbox"
  tools/edit           # exec "$ARX_PLUGIN_DIR/lib/run" "$ARX_BIN" tool edit
  tools/edit.json      # shell's schema, keys ["file:{path}"]
  hooks/session_start  # tells the model what the sandbox allows
  commands/arx-sandbox-native   # run -- CMD | check | profile
  lib/run              # POSIX sh: read the value, pick the backend, exec
  lib/json.awk         # ARX_SANDBOX to shell-safe lines; fails on anything else
  lib/macos.sb         # the Seatbelt base profile: (deny default)
  lib/macos            # sh: writes the full profile for one run
  lib/linux            # sh: builds the bwrap arguments
```

```yaml
# plugins/sandbox-native/plugin.yaml
name: sandbox-native
version: 0.1.0
description: Runs bash and edit in the OS sandbox (Seatbelt on macOS, bubblewrap on Linux) when the spec sets sandbox.type native.
arx: ">=0.2"
replaces: [bash, edit]
hooks: {session_start: {timeout: 5s}}
```

No `requires:`: it differs by OS. `arx sandbox-native check` and the run
time errors say what is missing.

**One call, step by step** (`lib/run`):

1. `ARX_IN_SANDBOX=1`, or `ARX_SANDBOX` empty: `exec "$@"`.
2. Parse `ARX_SANDBOX` with `lib/json.awk`. A type other than `native`, an
   unknown key, a nested value or a string with a control character: exit 1
   with the reason.
3. Refuse a work folder of `/` or `$HOME`: the agent would get write access
   to everything.
4. Read `ARX_HARNESS`. Resolve each path and each symlink target with
   `cd -P`/`pwd -P` (both paths are protected). A path with a newline or a
   `"` is refused.
5. Make the private temp folder,
   `${TMPDIR:-/tmp}/arx-sandbox-$(id -u)/<session>/`, mode 0700.
6. Build the profile (macOS) or the argument list (Linux), from a cache
   keyed by the hash of `ARX_SANDBOX`, `ARX_HARNESS` and `ARX_CWD`. The
   cache is in `$ARX_STATE_DIR` (slug `plugin-state`), under `.arx/`, so the
   sandbox cannot change it.
7. Run the command with the call's stdin. Exit with its code.

**Workdir and mounts.** The work folder is `ARX_CWD`. Paths are the same
inside and outside the sandbox, so the paths in output, in `edit` calls and
in `.arx/sessions/<id>/tool-NNNN.out` all match.

| Area | macOS (Seatbelt) | Linux (bubblewrap) |
|---|---|---|
| Whole disk | readable | `--ro-bind / /` |
| Work folder | writable | `--bind CWD CWD` |
| Private temp folder | writable; `TMPDIR` points to it | bound at `/tmp`; `TMPDIR=/tmp` |
| `/tmp` | `/private/tmp` writable (tools hard-code it) | the private folder; the host's `/tmp` is not visible |
| `write:` folders | writable | `--bind` each |
| `ARX_HARNESS`, `read_only:` | `(deny file-write* ...)` for each path and its ancestors up to the work folder | `--ro-bind` each existing path. A missing `folder` is made empty on the host first, then bound. A missing file inside a writable folder: refuse, and name it. |
| `.git/hooks`, `.git/config` | read-only when `.git` is a folder at the start of the call | same |
| Hidden paths | `(deny file-read* file-write* ...)` | `--tmpfs` over a folder, `--ro-bind /dev/null` over a file |
| `/dev` | `/dev/null`, `/dev/zero`, `/dev/urandom`; no `/dev/tty*` | `--dev /dev` (no host terminal) |
| `/run`, `/var/run`, `$XDG_RUNTIME_DIR` | Unix sockets denied by the network rules | `--tmpfs` over each |

The default hidden list: `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.azure`,
`~/.config/gcloud`, `~/.kube`, `~/.docker`, `~/.netrc`, `~/.git-credentials`,
`~/.config/gh`, `~/.npmrc`, `~/.pypirc`, `~/.password-store`,
`~/Library/Keychains`, `<config>/credentials` and `<config>/chatgpt/`.

**Network.**

| `network` | macOS | Linux |
|---|---|---|
| `false` (default) | `network*` to and from `localhost` only | `--unshare-net`: a new namespace with only `lo` |
| `true` | IP in and out; `/private/var/run/mDNSResponder` for DNS | the host's network namespace |
| Unix sockets | denied either way, except mDNSResponder with `true` | the socket folders are covered by tmpfs |

A host allowlist (`network: [pypi.org]`) needs a proxy and is not in 0.2.0.

**Environment.** `--clearenv` on Linux and `env -i` on macOS, then only:
`PATH`, `HOME`, `USER`, `LOGNAME`, `SHELL`, `TERM`, `LANG`, `LC_*`, `TZ`,
every `ARX_*` variable, the names in `env:`, `TMPDIR` (the private folder)
and `ARX_IN_SANDBOX=1`. So the variable that `endpoint.api_key_env` names
does not reach the agent.

**Processes and reaching arx.**

| | macOS | Linux |
|---|---|---|
| Signals | `(allow signal (target same-sandbox))` only | `--unshare-pid`: arx is not visible |
| `ptrace` | denied by `(deny default)` | not possible across the pid namespace |
| Terminal | no `/dev/tty*`, so no `TIOCSTI` | `--new-session` |
| End of call | the runner ends the call's process group when the command exits; a process that calls `setsid` outlives the call, still confined | `--unshare-pid` with `--die-with-parent`: every process ends with the call |
| OS escapes | `(deny default)` blocks `mach-lookup` (LaunchServices, `securityd`, launchd) and `appleevent-send`, so `open`, `osascript` and `security` fail | none known; no Unix sockets |
| Session inbox | `.arx/` is read-only, so `arx ctl` from inside fails | same |

A background process (`npm run dev &`) ends with its call. The agent starts
a server and tests it in the same call, or uses a background call
(slug `async-calls`), whose sandbox lives as long as that call.

**Startup cost.** Each call is a new sandbox: no state per session, no
cleanup, nothing for long-lived hooks to keep. The estimates, to measure in
step 0 and hold in `tests/bench.sh`:

| | Today (`shell`, direct start) | `sandbox-native` |
|---|---|---|
| macOS | about 1 ms | `sh` + `awk` + `sandbox-exec` (profile from cache): 10 to 20 ms |
| Linux | about 1 ms | `sh` + `awk` + `bwrap` with new namespaces: 5 to 15 ms |
| Without `sandbox:` | | one `sh` more: about 2 ms |

Budget: p50 of a sandboxed `true` at most 30 ms on both. A model call takes
seconds, so this is not on the critical path. If it is over budget, the
first fix is a profile cache in the session (already planned), then a
small runner in C in the plugin, not in arx.

**The model learns about it** from `hooks/session_start`, which prints
nothing without `ARX_SANDBOX`, and with it, for example:

```text
Your bash and edit run in a sandbox. You can write in /Users/ana/tsp and
in $TMPDIR. The harness (agent.yaml, prompts/, tools/, hooks/, .arx/) is
read-only. The network is off; localhost works. Every process ends when
its call ends. "Operation not permitted" or "Read-only file system" means
the sandbox blocked the action: do not try to work around it.
```

A `plugin.yaml` `instructions` text (slug `plugin-yaml-keys`) is static and
would show without a sandbox too, so the hook fits better.

**The command.** `arx sandbox-native` gets `ARX_BIN` and, when a tool or
hook runs it, `ARX_SANDBOX` and `ARX_HARNESS`. From your shell, it reads
them with `arx check --sandbox` and `arx check --harness` (with `--spec`).

| Command | What it does |
|---|---|
| `arx sandbox-native run [--spec P] -- CMD...` | runs CMD in the run's sandbox, stdin and exit code passed through |
| `arx sandbox-native check` | checks the backend (macOS version, `bwrap`, user namespaces), then tries a write to the work folder, to `agent.yaml` and to `~`, and a connect to `192.0.2.1`; prints each result |
| `arx sandbox-native profile [--spec P]` | prints the Seatbelt profile or the `bwrap` arguments, to debug a denial |

### Harness files

**`harness: read-only`** (the default, and the only mode until step 10):
every `ARX_HARNESS` path is read-only in the sandbox. The agent can read its
harness, but not change it. A self-improving run that edits its own tools
and hooks (`docs/autoresearch.md`) cannot do that in a sandbox. The docs
say so, and point to `gated`.

**`harness: gated`** (step 10, needs `trust`): the sandbox leaves the
spec folder's and config folder's harness files writable, keeps `policy`,
`session` and `binary` paths read-only, and refuses to start unless
`ARX_POLICY` is set. Trust's `harness_edit` then sees each change before
arx loads it, and reverts what it rejects. Trust needs "no process outlives
its call" for this. Linux has it; on macOS a process that calls `setsid`
can still change a file between the check and the run. The docs name that
gap.

### Subagents and `arx climb`

| | How it inherits | What you set |
|---|---|---|
| Subagent | `ToolEnv` puts `ARX_SANDBOX` and `ARX_HARNESS` in the environment of `arx -p ... --spec`; the child keeps the first and appends to the second. | Its harness needs a sandbox plugin. With no `plugins:` list, your user plugins have it. With a list, add `sandbox-native`, or its calls fail with the refusal. |
| `arx` run by a tool | The same, inside the sandbox; the runner sees `ARX_IN_SANDBOX=1` and does not nest. | Nothing. |
| `arx climb` | climb runs the agent with the spec's `sandbox:` (or its own `--set`), and starts it with `ARX_HARNESS` that already lists climb's eval files. | Keep the eval out of the work folder, or in `sandbox.read_only`. |
| climb's eval | climb runs it on the host, outside the sandbox: it is trusted. Agent code that the eval runs can go through `arx sandbox-native run --`. | climb's plan decides. |
| climb's git | climb runs `git` on the host to keep or revert. `.git/hooks` and `.git/config` are read-only in the sandbox, so the agent cannot plant a git hook or `core.fsmonitor`. | Nothing. |

### Later: sandbox-docker

The same contract fits a Docker plugin. The sketch, for 0.3:

- **One container per session**, `arx-<session>`, started on the first call
  with `docker run -d --init --network none --user UID:GID -v CWD:CWD`
  and read-only `-v` for the harness, then `docker exec -i` for each call.
- **Removal**: a plugin observer gets end of file when arx exits and runs
  `docker rm -f` (works today), or a session-long hook (slug
  `long-lived-hooks`) owns the container.
- **`edit` inside**: the static Linux arx from the release, mounted at
  `/usr/local/bin/arx`. On macOS the plugin fetches the Linux build with
  `setup:` (slug `arx-plugin`).
- **Settings**: `image` goes in the plugin's settings in the active list,
  which needs `ARX_PLUGIN_SETTINGS` for tools, not only hooks.

## Implementation steps

Each step is one pull request that builds, lints and passes `make test`.

0. **Spike, no merge.** On macOS 15 and 26, and on Ubuntu 24.04 and
   Fedora: write the base profile and the `bwrap` line by hand, and prove
   each threat-model point with a shell script: hard links, a rename of a
   folder that holds a protected file, creating a missing protected path,
   symlink swaps, `open`, `osascript`, `security`, Unix sockets, `TIOCSTI`,
   `kill` of the parent. Measure the start cost. Output: `lib/macos.sb`,
   the `bwrap` arguments, and the numbers in the PR of step 7. Start from
   the published Seatbelt profiles of Codex CLI and Claude Code, and check
   their licenses before you copy a line.
1. **The `sandbox` key.** `src/harness/fields.c`: a `kSandbox` table
   (`type`, `network`, `write`, `read_only`, `hide`, `env`) and `sandbox`
   in `kTopFields`, type `kMap`. `src/harness/validate.c`: `type` is
   required and uses `kNameChars`. `src/harness/spec.c`: make the three path
   lists absolute after the merge and `--set` (relative to the spec folder;
   `~/` to `$HOME`). `arx schema` follows from the table.
2. **The harness roots.** `src/harness/signature.c`: `HarnessRoots(spec,
   fn, ctx)` next to trust's `HarnessFiles`, sharing its per-layer helpers.
   If trust has not landed, add the walk here and trust reuses it. Keep the
   joined text in `Spec` (`char* harness`), built at each load. Observer
   first words that are paths become `program` lines. If `signature.c`
   passes 400 lines, move the walk to `src/harness/walk.c`.
3. **The environment.** `src/harness/tool_exec.c` (`ToolEnv`): add
   `ARX_SANDBOX` and `ARX_HARNESS`, after plugin-state's change to the same
   array. `src/agent/run.c` (`AgentMain`, next to `ARX_DEPTH` at `:191`):
   read `ARX_SANDBOX` and an inherited `ARX_HARNESS` once into `Agent`; an
   inherited sandbox wins over the spec; append, don't replace, the harness
   lines. Add `sandbox` to the `session.start` event (`run.c:75`).
4. **Fail closed.** `src/cli/shell_tools.c`: the refusal in `arx tool bash`
   and `arx tool edit`, before any work. About 15 lines.
5. **Which tool wins.** The agreed rule, in `src/harness/tools.c`
   `AddLayers`: a policy layer's tool first, then a tool that `replaces:`
   the name, then the current rule that the first tool with a name wins.
   Build it as three passes over the layers (policy layers, then plugins
   whose `replaces:` lists the name, then every layer in order), each adding
   only names not yet taken. Move `AddLayers` and its helpers to
   `src/harness/tool_layers.c` first: `tools.c` is at 391 of 400 lines.
   `src/cli/check.c` `HiddenWarnings`: no warning for a hide that the rule
   explains, and a warning when two plugins replace one name. Land this
   with, or before, trust's change to the same function, so the rule is
   written once.
6. **`arx check`.** `src/cli/check.c`: the `sandbox:` line, the problem for
   a core `bash` or `edit`, and `--harness` and `--sandbox`.
   `src/cli/commands.c:228-231`: the usage line.
7. **The plugin.** `plugins/sandbox-native/` as in the tree in
   [Design](#the-sandbox-native-plugin): `plugin.yaml`, `tools/`, `lib/`,
   `hooks/session_start`, `commands/arx-sandbox-native`, `README.md`. Add
   it to `plugins/README.md`, so `arx plugin add sandbox-native` finds it.
8. **Tests and CI.** `tests/sandbox.sh`, the additions to `tests/shell.sh`,
   `tests/layers.sh` and `tests/cli.sh` (see [Tests](#tests)), and
   `tests/sandbox.sh` in the `test` target of the `Makefile`. In
   `.github/workflows/ci.yml`, a `sandbox` job on `ubuntu-24.04` outside the
   Alpine container: `apt-get install -y bubblewrap`,
   `sysctl -w kernel.apparmor_restrict_unprivileged_userns=0`, `make arx`,
   `SANDBOX_REQUIRED=1 tests/sandbox.sh`. In `release.yml`, the macOS jobs
   run it with `SANDBOX_REQUIRED=1`. `tests/bench.sh`: the start-cost
   budget.
9. **Docs.** See [Docs to change](#docs-to-change).
10. **`harness: gated`**, after `trust` lands. `fields.c`: the `harness`
    key. `lib/run`: leave non-policy harness files writable, refuse without
    `ARX_POLICY`. Tests in `tests/sandbox.sh` with a policy that rejects a
    hook edit. If trust slips to 0.3, this step moves with it.

## Tests

`tests/sandbox.sh`, in the style of `tests/shell.sh`. The core checks run
everywhere. The backend checks run when `arx sandbox-native check` passes,
and are skipped otherwise; with `SANDBOX_REQUIRED=1` a skip is a failure.
Each backend check uses a temporary `HOME`, so no real secret is touched.

**Core (every platform, about 20 checks):**

- `sandbox:` validates: `netwrok` gets "did you mean"; no `type` is an
  error; `arx schema` lists the keys.
- A test tool that prints its environment sees `ARX_SANDBOX` as compact
  JSON with absolute paths, and no `ARX_SANDBOX` without `sandbox:`.
- `--set 'sandbox={"type":"x"}'` overrides `agent.yaml`, also after an edit
  and a reload.
- `ARX_SANDBOX` in arx's environment wins over the spec, and `arx check`
  says `(the environment)`.
- A subagent's tool sees the parent's `ARX_SANDBOX` even when the
  subagent's spec has another, and sees the parent's `ARX_HARNESS` lines
  before its own.
- `ARX_HARNESS` has `spec`, `folder` (with `/`), `plugin`, `session` and
  `binary` lines, and `program` for a compactor and for `./log.sh` as an
  observer. Every path that the reload walk visits is under a root.
- `arx check --harness` prints the same lines as a tool sees.
- `arx tool bash` and `arx tool edit` refuse with `ARX_SANDBOX` set (exit 1,
  the message), and run with `ARX_IN_SANDBOX=1` too.
- `arx check` lists the refusal as a problem when `bash` comes from
  `shell`.
- `tests/layers.sh`: a plugin after `shell` with `replaces: [bash]` wins
  `bash`; it also wins over a spec folder `tools/bash`; a policy layer's
  `bash` wins over both; two replacers warn; without `replaces:`, the first
  tool with a name still wins.
- `tests/shell.sh`: the `shell` tools are unchanged without `ARX_SANDBOX`.
- `session.start` has `sandbox`.

**Backend (macOS and Linux, about 30 checks), each through a scripted
`bash` call in a real session and through `arx sandbox-native run`:**

- Writes in the work folder and `$TMPDIR` work; the private temp folder
  stays between two calls of one session.
- Writes fail to: `agent.yaml`, a new `tools/x`, a new `hooks/before_tool`
  in a missing `hooks/`, `plugins/`, `.arx/`, a prompt file, `~/x`, a
  `read_only:` path, `.git/hooks/pre-commit`, `.git/config`.
- Escapes fail: `mv prompts p2` (a folder that holds a prompt file), a hard
  link to `hooks/stop` then a write through it, a symlink to `agent.yaml`
  then a write through it, `rm agent.yaml`.
- `edit` on `agent.yaml` returns an error result; `edit` on a work file
  works, with the same result text as `shell`'s.
- Reads of `~/.ssh/id_test` and `<config>/credentials` fail; reads of
  `agent.yaml` work.
- `FOO_API_KEY` in arx's environment is not visible; with `env: [FOO]`,
  `FOO` is.
- `network: false`: a connect to `192.0.2.1:80` fails within 1 second; a
  listener on `127.0.0.1` answers. `network: true`: the connect is
  attempted (it times out, not denied).
- A Unix socket on the host (made with `python3 -c` or `nc -lU`) cannot be
  reached in either mode.
- `kill -0` of arx's pid fails.
- A `sleep 100 &` started by a call is gone after the call (Linux); on
  macOS, a background job in the process group is gone.
- A call with `timeout: 2s` running `sleep 100` ends at the timeout, and no
  `sleep` is left.
- macOS: `open -a TextEdit`, `osascript -e 'beep'` and
  `security find-generic-password -s arx` fail.
- An `arx tool bash` call inside the sandbox runs (no nesting error).
- A subagent with `plugins: [shell]` in a sandboxed parent gets the
  refusal; with `sandbox-native` its write to the parent's `agent.yaml`
  fails.
- A spec with `type: docker` gets "sandbox type docker" from
  `sandbox-native`'s `bash`.

**Bench (`tests/bench.sh`):** p50 and p95 of 50 sandboxed `true` calls,
against the 30 ms budget, reported apart from the core budgets.

## Docs to change

Each page follows `docs/WRITING.md`: the first sentence defines the
subject, no planned behavior in the present tense, at most two callouts.

- **New: `docs/plugins/sandboxes.md`** (guide). Opens with "A sandbox runs
  the agent's `bash` and `edit` where they cannot change the harness, read
  your secrets or, by default, use the network." Sections: Use
  `sandbox-native` (three steps: `arx plugin add sandbox-native`, set
  `sandbox: {type: native}`, `arx sandbox-native check`), What the sandbox
  allows (the area, network and environment tables), Harness files
  (read-only; why a self-improving run cannot edit its harness here),
  Subagents and climb, Write a sandbox plugin (the ten rules), Common
  mistakes (the refusal message, `bwrap` and user namespaces on Ubuntu
  24.04, a missing prompt file, a cache folder that needs `write:`),
  Related. One `[!WARNING]`: a sandbox is not a VM, and code the agent
  writes still runs when you run it. Add the page to `src/lib/nav.mjs` in
  arx-docs.
- **`docs/spec.md`**: `sandbox` row in Top-level keys, and a `### sandbox`
  table.
- **`docs/plugins/reference.md`**: `ARX_SANDBOX`, `ARX_HARNESS` and
  `ARX_IN_SANDBOX` in Environment; `replaces:` "wins the tool" in the
  `plugin.yaml` table; `sandbox` in the `session.start` event.
- **`docs/plugins/tools.md`**: in "bash and edit", the refusal and the new
  `replaces:` rule; replace the Planned paragraph (`:237-241`) with a link
  to the sandboxes page.
- **`docs/plugins/planned.md`**: remove the Sandboxes row and section.
- **`docs/plugins.md`** (`:74`): move sandboxes from planned to the list of
  plugin kinds.
- **`docs/concepts.md`** (`:200-201`): "No sandbox" becomes "No sandbox in
  the binary: a sandbox plugin runs `bash` and `edit` in the OS sandbox".
- **`docs/cli.md`**: `arx check --harness` and `--sandbox` next to
  `--hosts`.
- **`docs/plugins/subagents.md`**: "A subagent keeps its parent's sandbox"
  in "Its harness".
- **`docs/plugins/hooks.md`** (`:10`): link "not a sandbox" to the new page.
- **`docs/autoresearch.md`**: one paragraph: a sandboxed run cannot edit
  its harness, and what to do instead.
- **`docs/roadmap.md`**: a row for sandboxes, done.
- **`plugins/README.md`** and **`plugins/shell/README.md`**: name
  `sandbox-native` as the plugin that replaces `bash` and `edit`.

## Dependencies

| Slug | What it shares | Order |
|---|---|---|
| `trust` | The reload walk (`HarnessFiles` in `signature.c`); this plan adds `HarnessRoots`. Policy folders are `policy` lines. A sandbox makes a policy a boundary; `harness: gated` needs `harness_edit` and `ARX_POLICY`. Trust says the sandbox's `bash` and `edit` belong in a policy folder: `--policy` with the `sandbox-native` folder does that, and `replaces:` covers the common case without one. Trust writes the same rule for which tool wins (policy, then `replaces:`, then first wins); step 5 builds it once. | Either first for steps 1 to 9; step 10 after trust. |
| `plugin-state` | `ToolEnv` grows in both plans. `ARX_STATE_DIR` holds the profile cache. `AgentMain` unsets the plugin variables at start, but must keep `ARX_SANDBOX` and `ARX_IN_SANDBOX`. `.arx/` is read-only in the sandbox, which makes plugin state safe from the agent. | plugin-state first. |
| `plugin-yaml-keys` | `replaces:` changes meaning (step 5), by the agreed rule. `instructions` was the other way to tell the model; this plan uses a `session_start` hook instead. | Its docs of `replaces:` follow step 5. |
| `climb` | climb adds its eval files to `ARX_HARNESS` or uses `sandbox.read_only`; runs git and the eval on the host; can run agent code with `arx sandbox-native run`. `.git/hooks` and `.git/config` are read-only. | Independent; climb's docs link the sandboxes page. |
| `long-lived-hooks` | Not needed by `sandbox-native` (no state per session). A Docker plugin would use a session-long hook to own its container. | None. |
| `async-calls` | A background call's sandbox lives as long as the call. That is how a server outlives one `bash` call. | None. |
| `mcp-client` | stdio MCP servers are host programs; their commands join `ARX_HARNESS` as `program`, and they can start through `arx sandbox-TYPE run --` when the run has a sandbox. | None. |
| `acp-tui` | `sandbox` in `session.start` for a badge; a front-end can relax approval prompts when the run has a sandbox. | None. |
| `arx-plugin` | `arx plugin add sandbox-native`; `setup:` for a later Docker plugin. `arx plugin` runs on the host, outside any sandbox. | None. |

Shared files: `src/harness/tool_exec.c` (`ToolEnv`, with plugin-state and
long-lived-hooks), `src/harness/signature.c` (with trust),
`src/harness/fields.c` (with plugin-yaml-keys, arx-plugin, mcp-client),
`src/harness/tools.c` (with trust), `src/cli/check.c` (with trust and
plugin-yaml-keys), `src/agent/run.c`.

## Size and risks

**Size: M.** About 200 lines of C in seven files, one file split, a plugin
of about 350 lines of `sh`, `awk` and Seatbelt profile, about 50 test
checks, a CI job, one new doc page and ten edited ones. The security review
of the profiles is the larger part of the work.

Risks:

- **Path rules have holes.** Hard links, renames of a parent folder and
  missing paths are the known ways around path-based rules. Step 0 must
  prove each one closed on both OSes before any code merges. On Linux, a
  hard link cannot cross the read-only bind (`EXDEV`). On macOS this is the
  open question; if Seatbelt allows it, `lib/run` refuses to run while a
  protected file has a link count above 1.
- **The harness list must be complete.** A file that arx runs or loads and
  that is not in `ARX_HARNESS` is a way out. One walk feeds reload, trust
  and this list, and a test checks that reload's files are covered. Helper
  scripts that a hook sources from outside its plugin folder are not
  covered; the docs say to keep them inside it.
- **`sandbox-exec` is deprecated.** Apple still ships it, and Codex CLI,
  Claude Code, Bazel and Chromium depend on Seatbelt. If it goes, the
  contract stays and `sandbox-docker` covers macOS.
- **A strict profile breaks tools.** `(deny default)` can block a Mach
  service that a compiler or package manager needs. `arx sandbox-native
  profile` and `log stream --predicate 'sender == "Sandbox"'` find the rule;
  the tests run `cc`, `make`, `git`, `python3` and `node` inside.
- **User namespaces on Linux.** Ubuntu 23.10 and later restrict them with
  AppArmor; containers usually block them. The runner fails closed and
  names the fix.
- **Friction.** Network off and a read-only home break `pip install` and
  `npm install` until you set `network: true` and `write:` for the cache.
  The guide leads with this.
- **macOS processes can outlive a call** after `setsid`. They stay
  confined, so with `harness: read-only` they can change nothing that
  matters. With `harness: gated` this is trust's check-then-run gap.
- **Core reads one sandbox field.** The refusal searches `ARX_SANDBOX` for
  the type to name it in the message. It does not act on the value.
- **An inherited `ARX_SANDBOX` from your shell** applies to every run.
  `arx check` shows the source.

## Open decisions

1. **Backend for 0.2.0.** Recommend `sandbox-native` (Seatbelt and
   bubblewrap in one plugin, so one spec works on a team's Macs and Linux
   machines). Docker in 0.3, with the same contract.
2. **The shape of `sandbox:`.** Recommend a map that arx validates, with six
   generic keys every sandbox plugin must honor. Backend-only settings (a
   Docker `image`) go in the plugin's settings, once tools get
   `ARX_PLUGIN_SETTINGS`.
3. **`ARX_HARNESS` in core.** **Decided** (README, "Settled across plans",
   item 6): `ARX_HARNESS` goes in the core, fed by the same file walk as
   reload and trust. A sandbox cannot protect files it cannot name, and a
   guess from folder names misses prompts, programs and subagent specs.
4. **The shell tools fail closed.** Recommend yes. A sandbox that silently
   falls back to the host is worse than none.
5. **Which tool wins.** **Decided** (README, "Settled across plans",
   item 4): a policy layer's tool first, then a tool that `replaces:` the
   name, then the current rule that the first tool with a name wins. Trust
   writes the same rule; step 5 builds it once.
6. **An inherited sandbox wins, and `ARX_HARNESS` adds up.** Recommend yes:
   a subagent or a nested run can add a sandbox, never remove one, and its
   sandbox protects the parent's harness.
7. **Harness writability in a sandbox.** Recommend `read-only` only for
   steps 1 to 9, and `harness: gated` as step 10 once trust lands. Until
   then, a self-improving run that edits its own tools and hooks runs
   without a sandbox.
8. **Network.** Recommend `false` by default (localhost only), `true` for
   any IP host, and no host allowlist in 0.2.0. An allowlist needs a proxy;
   it could reuse the `hosts:` list later.
9. **Processes end with the call.** Recommend yes on both OSes. Long-running
   servers use a background call (slug `async-calls`).
10. **Environment.** Recommend an allowlist, plus `env:`. A denylist would
    miss the next secret's name.
11. **Defaults to protect and hide.** Recommend read-only `.git/hooks` and
    `.git/config` (not all of `.git`, so commit and reset work), and the
    hidden list in this plan. A credential plugin with its own secret
    folder adds it to `hide:` in its docs; a `plugin.yaml` key for that can
    come later.
12. **Who may set `sandbox:`.** Recommend the spec, `config.yaml` and
    `--set` only. A kit that sets a sandbox could come later.
13. **How the model learns about the sandbox.** Recommend the
    `session_start` hook (it knows the values) over static `instructions`.
14. **`/private/tmp` on macOS.** Recommend writable, with `TMPDIR` set to
    the private folder: many tools hard-code `/tmp`, and Unix sockets there
    stay closed by the network rules.
