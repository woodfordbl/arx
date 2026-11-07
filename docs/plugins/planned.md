# Planned changes

**Nothing on this page is built yet.** It describes the redesign of the plugin
system, so that plugin authors can plan for it. The contracts can still
change. For what works today, see the other pages of the
[plugin guide](../plugins.md).

Two parts of the redesign are built and documented on the other pages:
hooks on raw objects, with `before_model` and `after_model` ([Hooks](hooks.md)),
and `bash` and `edit` in the `shell` plugin, with schema files
([Tools](tools.md#bash-and-edit)). These parts are not built:

| Part | What it adds | Section |
|---|---|---|
| Tool runtime | keys on each call, calls that run at the same time, scheduler plugins | [Tool runtime](#tool-runtime) |
| Kits | a kind with `kit.yaml` and no code, that makes one kind of agent | [Kits](#kits) |
| The active list | one ordered list of plugins for each run | [The active list](#the-active-list) |
| Hook bands | `policy`, `normal` and `final`: the order of hooks at one point | [Hook bands](#hook-bands) |
| Hooks, more | long-lived hooks, and a pinned plugin that runs first | [More for hooks](#more-for-hooks) |
| Trust and sandboxes | a policy folder, a `harness_edit` hook point, and `sandbox:` | [Other plans](#other-plans) |

## Tool runtime

A queue, keys on each call, and a scheduler that a plugin can replace. It
replaces the loop that runs the calls of a reply one at a time.

### Keys

Each call has a list of keys. A key works as a lock: the runtime starts a call
only when no running call holds one of its keys.

- **Same key:** calls that share a key run one at a time.
- **No keys (`[]`):** the call runs in parallel with all other calls.
- **`*`:** the call runs alone. A tool that declares no keys gets `["*"]`, so
  the tools of today still run one at a time.
- **More than one key:** the runtime gives all the keys of a call together, or
  none of them. Two calls cannot each hold one key and wait for the other.

A tool declares its keys in its schema (`tools/<name>.json` or `--schema`).
`{name}` puts in the value of the top-level argument `name`:

```json
{"description": "...", "parameters": {...}, "keys": ["file:{path}"]}
```

| Tool | `keys` | Result |
|---|---|---|
| `read`, `grep`, `glob` | `[]` | they run in parallel |
| `edit` | `["file:{path}"]` | edits to one file run one at a time; edits to different files run in parallel |
| `bash` | not set, so `["*"]` | it runs alone, because a shell can change anything |
| `web_fetch` | `["host:{url}"]` | one request to each host at a time (`{url}` gives the host in a `host:` key) |
| a subagent | `[]` | subagents run in parallel |

- **Keys from a hook:** `keys` becomes a field of the raw call that
  `before_tool` gets today (`{"id", "name", "args", "keys"}`), so a hook can
  calculate it and print it. For example, it can make `./a.py` and `a.py`
  the same key, or give `git status` no keys so that it runs in parallel.
- **Keys and results:** a call's keys must be known before it starts, so they
  cannot come from its own result. A result can slow later calls:
  `after_tool` prints a `backoff` (`{"backoff": {"key", "secs"}}`, for
  example after an HTTP 429), and a
  scheduler plugin waits that long before it starts a call with that key.
  The built-in scheduler ignores `backoff`.

### Scheduler plugins

A plugin can replace the built-in scheduler with one long-lived process for
each session (`scheduler: <path>` in its `plugin.yaml`). arx and the process
exchange one JSON object per line:

| Direction | Message | Meaning |
|---|---|---|
| arx → plugin | `{"ready": {"id", "name", "keys"}}` | a call is in the queue |
| arx → plugin | `{"done": {"id", "secs", "is_error", "backoff"}}` | a call ended |
| arx → plugin | `{"tick": <unix secs>}` | a time it asked for with `wake_at` |
| plugin → arx | `{"start": ["c4", "c5"]}` | start these calls now |
| plugin → arx | `{"wake_at": <unix secs>}` | send a `tick` at this time |
| plugin → arx | `{"result": {"id", "text"}}` | end a call without a run, for example "budget used up" |

- **Uses:** rate limits, more than one call for each key, priority and
  fairness. For a swarm, the process can talk to one shared service, so that
  one limit applies to all agents.
- **Failure:** if the process exits or prints bad output, arx writes an
  `error` event and goes back to the built-in scheduler.
- **Later:** a scheduler can give the model the result `started as c7` at
  once and send the real result later through the inbox, so that a subagent
  starts without a wait.

## More for hooks

The [hook lifecycle](hooks.md) is built. These additions are not:

- **Long-lived hooks:** a hook can start once for each session and read one
  JSON line for each call, so that it keeps state and starts no process for
  each call.
- **A pinned plugin runs first:** the hooks of a plugin that the launcher
  pins run before all others at each point.
- **Approval without a wait for others:** when the tool runtime runs calls at
  the same time, the `before_tool` hooks of different calls also run at the
  same time. A hook may then wait for a person, and the other calls do not
  wait for it.
- **Replacing a tool on purpose:** a plugin declares `replaces: [bash]`, so
  `arx check` does not warn that it hides the shell plugin's `bash`.

## Kits

A kit is a separate kind, not a plugin. It has a `kit.yaml`, `prompts/` and
`init/`, and no executables. It chooses which plugins to use, in which order,
with which settings and with which prompt. If something runs, it belongs in a
plugin. If it only chooses or configures, it belongs in a kit.

| | Plugin | Kit |
|---|---|---|
| Contains | `plugin.yaml`, `tools/`, `hooks/`, `skills/`, `commands/` | `kit.yaml`, `prompts/`, `init/`; no executables |
| Answers | What can the agent do? | Which agent is this? |
| Examples | `guard`, `shell`, `file-search` | `coding`, `explorer`, `research` |

```yaml
# kits/coding/kit.yaml
name: coding
version: 0.3.0
description: A general coding agent
plugins:                  # the order is the priority
  - guard
  - shell
  - file-search
  - plan
  - approve: {timeout: 10m}
  - compact-hybrid
  - cache-breakpoints
model_settings: {reasoning_effort: medium}
prompt: prompts/system.md
```

```sh
arx kit add coding                                    # the kit and each plugin it names
arx --kit coding
arx -p "Find the slow test" --kit explorer --cap usd=1
arx init coding                                       # copies the kit's init/ files into the project
sh install.sh --kit coding                            # install arx and a kit in one step
```

- **Settings** merge in this order: `config.yaml`, the kit, `agent.yaml`, then
  `--set`. The later value wins.
- **Pinned:** `--kit` stays in force after reloads. An edit to `agent.yaml`
  cannot change the kit of the run.
- **A missing kit:** arx stops and names the `arx kit add` command. It does
  not download anything without a question.
- **Names in a kit:** a bare name, such as `guard`, comes from the kit's own
  marketplace. `acme/tools/lint` comes from another repo. `@0.2.1` pins a
  version.
- **Repeatable runs:** for a climb, arx writes `kit.lock` in the project, with
  the exact commit of each part.
- **Variants:** `extends: coding` with `enable` and `disable` makes a new kit,
  such as `coding-strict`.
- **Marketplaces** also hold `kits/<name>/kit.yaml`, and an `index.yaml` that
  lists each plugin and kit with its versions.

The first three kits:

| Kit | Includes | Purpose |
|---|---|---|
| `coding` | `shell`, file search, plan, `guard`, tool approval | a general coding agent |
| `explorer` | `shell` without `edit`, file search, web fetch | reads and answers |
| `research` | `shell`, the experiment prompt, the never-stop hook, restart compaction | hill climbs; today this is `arx init autoresearch` |

## The active list

Installed plugins become a library. Each run uses one **active list**, in
order, and the position in the list is the priority. Only the plugins in the
list load. Four sources build the list, and each one changes the list from
the source before it:

1. **Default:** `~/.config/arx/config.yaml` names a default kit or a list.
   `arx plugin add` adds the new plugin to this list, so a new plugin is still
   on by default.
2. **Kit:** a kit gives a full list in its order, with settings for each
   plugin.
3. **Project:** `agent.yaml` can name a kit with `kit: coding`, then change it
   with `enable: [lint]` and `disable: [guard]`.
4. **Launcher:** `--kit` and `--set` change the list last, and stay in force
   after reloads.

The agent's own tools and hooks in the spec folder stay first in the order,
as today. A pinned policy comes before them. `arx plugin enable NAME` and
`arx plugin disable NAME` write to `agent.yaml`, or to `config.yaml` with
`--global`. `arx plugin list` shows the result and the reason for each line:

```
 #  plugin        version  from        state  why
 1  guard         0.2.0    arx         on     kit coding, policy band
 2  shell         0.1.0    arx         on     kit coding
 3  file-search   0.1.0    acme/tools  on     kit coding
 4  lint          0.4.1    ./plugins   on     agent.yaml enable
 -  notify        0.1.0    arx         off    not in kit coding
```

## Hook bands

Today the hooks at one point run as a chain in layer order. A chain is a
pipeline, so its order is important: for example, compaction must run before
cache breakpoints, and redaction must run last. List order alone breaks
easily, so each hook point will have three bands:

| Band | Runs | Examples |
|---|---|---|
| `policy` | first; a result that it sets is final, and later hooks cannot clear it | `guard`, approval |
| `normal` | in list order; the default | rewrites, compaction, keys |
| `final` | last, just before the model or the tool gets the object | cache breakpoints, redaction, logs |

A plugin declares the band of each hook in `plugin.yaml`. Inside a band, the
list order decides. There are no priority numbers.

```yaml
hooks:
  before_model: {band: final, changes: [messages]}
```

- **Each hook declares what it changes,** such as `changes: [messages]` or
  `changes: [args, keys]`.
- **`arx check` warns about overlaps:** if two active plugins change the same
  field at one point, it shows them and their order.
- **Each `hook` event lists the fields that the hook changed.** This part is
  built: see `changed` in the [hook event](reference.md#events).

## Other plans

- **Sandboxes:** a `sandbox:` value in the spec. arx does not read it: it
  gives it to each tool and hook as `ARX_SANDBOX`. A sandbox plugin, such as
  `sandbox-docker`, ships its own `bash` and `edit` that read this value, in a
  layer above the `shell` plugin.
- **New variables:** `ARX_SANDBOX` (the spec's `sandbox:` value),
  `ARX_STATE_DIR` (`$ARX_SESSION_DIR/plugins/<name>/`, state for one session)
  and `ARX_DATA_DIR` (`.arx/state/<name>/`, data across sessions).
- **Trust:** `--policy DIR` names a policy folder that loads first and that
  the spec cannot remove. A `harness_edit` hook point lets the policy accept
  or reject each harness file that the agent changes.
- **`plugin.yaml` keys:** `instructions` and `model_settings`, so a plugin can
  add to the prompt and the request.
- **ACP server (`arx acp`):** the Agent Client Protocol over stdio, for
  editors and other front-ends. `session/new` and `session/load` map to a new
  session and `--resume`, `session/prompt` runs the turn loop,
  `session/cancel` is the Ctrl-C path, and events become `session/update`
  messages.
- **A terminal UI** as a plugin that talks to `arx acp`.
- **MCP client:** MCP servers that the spec names become tools. Only two
  built-in tools sit in the prompt: `mcp_search` finds a tool, and
  `mcp_select` adds its full schema on the next turn.

### More of arx plugin

`update`, `search`, `eject` (copy a plugin into the spec folder so that the
agent owns it), other marketplaces by name (`@acme/lint`), and a `setup:`
command that runs once after an install.

See also the [roadmap](../roadmap.md).
