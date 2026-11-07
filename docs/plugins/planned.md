# Planned changes

**Nothing on this page is built yet.** It describes the redesign of the plugin
system, so that plugin authors can plan for it. The contracts can still
change. For what works today, see the other pages of the
[plugin guide](../plugins.md).

The redesign has six parts:

| Part | What it adds | Section |
|---|---|---|
| Hook lifecycle | hooks on the raw request, reply, call and result; `before_model` and `after_model` | [Hook lifecycle](#hook-lifecycle) |
| Tool runtime | keys on each call, calls that run at the same time, scheduler plugins | [Tool runtime](#tool-runtime) |
| The `shell` plugin | `bash` and `edit` move out of the core | [The shell plugin](#the-shell-plugin) |
| Kits | a kind with `kit.yaml` and no code, that makes one kind of agent | [Kits](#kits) |
| The active list | one ordered list of plugins for each run | [The active list](#the-active-list) |
| Hook bands | `policy`, `normal` and `final`: the order of hooks at one point | [Hook bands](#hook-bands) |

## Hook lifecycle

This contract replaces the hook outputs of today for `before_tool` and
`after_tool`, and adds two hook points around the model call. Approval,
compaction, rate limits and concurrency are then hooks and plugins, so the
spec needs no settings for them.

### One turn

1. **`before_model`** gets the request. Its output is what the model gets.
2. **The model** replies, with or without tool calls.
3. **`after_model`** gets the reply, and can change or remove tool calls.
4. **`before_tool`** runs once for each call. It allows the call, changes it,
   or gives a result in place of the run. It also sets the call's keys.
5. **The tool runtime** puts each allowed call in a queue. The scheduler
   starts calls when their keys are free, and many calls can run at the same
   time.
6. **`after_tool`** runs when a call ends, and can change its result.
7. **The results** go to the model in the order of the calls, so the
   transcript is the same as when the calls run one at a time. Then the next
   turn starts at step 1.

### Hook points

Each hook gets the raw object as JSON on stdin, with `point`, `session` and
`turn` added. It prints the fields it changes, or nothing to keep the object
as it is. A printed field replaces the field of the same name.

| Point | Input (stdin) | Output it may print |
|---|---|---|
| `before_model` | `{"messages", "tools", "model", "settings", "reason"}` | any of `messages`, `tools`, `model`, `settings` |
| `after_model` | `{"reply", "usage", "finish"}` | `{"reply": ...}` |
| `before_tool` | `{"id", "name", "args", "keys"}` | any of `name`, `args`, `keys`; or `{"result": "..."}` to skip the tool |
| `after_tool` | `{"call", "result", "is_error"}` | `{"result": "..."}`, and `{"backoff": {"key", "secs"}}` |

`reason` is `turn`, or `context_overflow` when the provider said the context
is too long. Messages use the format in [Compactors](compactors.md), with the
`_` fields.

- **Order:** the hooks at one point run by [band](#hook-bands), then in the
  order of the [active list](#the-active-list). Each hook gets the output of
  the hook before it. A plugin that the launcher pins runs first.
- **Each call apart:** the `before_tool` hooks of different calls run at the
  same time. A hook may wait for a person (approval), and the other calls do
  not wait for it. A hook never waits for a free slot: that is the job of the
  runtime.
- **`after_tool` always runs** for a call that `before_tool` let through, also
  after an error, a timeout or Ctrl-C.
- **Changed calls:** if a hook changed `name` or `args`, arx adds one line to
  the result, such as `[ran as: git push]`, so the model knows what ran.
- **The history:** messages that `before_model` returns replace the history.
  arx writes them to `transcript.jsonl` after a `{"_reset":true}` line, as
  compaction does today. The transcript then shows exactly what the model
  got.
- **Compaction:** a compaction plugin is a `before_model` hook. If the
  provider says the context is too long, arx runs `before_model` again with
  `"reason": "context_overflow"`, then retries once. The compactor kind and the
  built-in strategies then move to plugins.
- **Long-lived hooks:** a hook can start once for each session and read one
  JSON line for each call, so that it keeps state and starts no process for
  each call.
- **Hooks of today keep working:** `{"decision": "deny", "reason": "..."}`
  from `before_tool` becomes the result `denied: <reason>`, and
  `{"note": "..."}` from `after_tool` is added to the result. `session_start`
  and `stop` do not change.

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

A tool declares its keys in its `--schema` answer. `{name}` puts in the value
of the top-level argument `name`:

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

- **Keys from a hook:** `keys` is a field of the call, so a `before_tool` hook
  can calculate it and print it. For example, it can make `./a.py` and `a.py`
  the same key, or give `git status` no keys so that it runs in parallel.
- **Keys and results:** a call's keys must be known before it starts, so they
  cannot come from its own result. A result can slow later calls:
  `after_tool` prints a `backoff` (for example after an HTTP 429), and a
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

## The shell plugin

Today `bash` and `edit` are built into the core, and no plugin can replace
them. The plan moves them into a plugin:

1. **The code stays in the binary.** `arx tool bash` and `arx tool edit` run
   the C code of today, so the tools stay fast and need no other programs.
2. **A `shell` plugin** has `tools/bash` and `tools/edit`. Each file is one
   line, such as `exec "$ARX_BIN" tool edit`.
3. **A schema file:** a file such as `tools/bash.json` gives the schema, so
   arx starts no process to load the tool. `--schema` stays as the fallback.
4. **No special cases:** every tool comes from a layer, and
   `tools.<name>.timeout` works the same for all tools.
5. **A `sandbox:` value** in the spec. arx does not read it: it gives it to
   each tool and hook as `ARX_SANDBOX`. A sandbox plugin, such as
   `sandbox-docker`, ships its own `bash` and `edit` that read this value. The
   rule "the first tool with a name wins" does the rest.

Without a plugin that gives tools, an agent can only chat, and `arx doctor`
warns about it. A plugin that replaces a tool on purpose declares
`replaces: [bash]`, so `arx check` does not warn about it.

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

The hooks at one point are a pipeline, so their order is important. For
example, compaction must run before cache breakpoints, and redaction must run
last. List order alone breaks easily, so each hook point has three bands:

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
- **Each `hook` event lists the fields that the hook changed,** so you can see
  which plugin changed what.

## Other plans

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
