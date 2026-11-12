# Trust: policy folders and the `harness_edit` gate

Slug: `trust`. Plan for arx 0.2.0. Built: see
[Policies](../../docs/plugins/policies.md). The "Current state" section
describes the code before this plan.

## Goal

Give the person who starts a run a part of the harness that the agent
cannot remove, and a gate on the agent's harness edits.

- **`--policy DIR`**: a policy folder is a plugin folder that loads before
  the spec folder. No key in `agent.yaml`, `config.yaml` or a kit can remove
  it.
- **`harness_edit`**: a new hook point. Before arx loads a changed harness,
  the policy sees each harness file that changed, and accepts or rejects
  each change. "The agent may edit prompts, but not hooks" becomes one hook
  of a few lines.

### Threat model

arx and the agent run as the same user on the same disk. So, without a
sandbox (slug `sandboxes`):

- The agent's `bash` can change any file arx can read, including the policy
  folder, and it can run any command directly. No policy stops that.
- The policy is then a guard rail against mistakes and a record of every
  harness edit. It is not a security boundary.

A policy is a boundary only when all three of these are true:

1. The agent's `bash` and `edit` run in a sandbox that cannot write the
   policy folders.
2. The sandbox ends every process that a call starts when the call ends, so
   no process of the agent outlives its call.
3. The policy rejects every change that would let the agent run code on the
   host: new or changed hooks, tools, `scheduler` files, named programs
   (`compactors`, `credentials`, `adapters`), plugins and kits, and spec keys
   that name programs or hosts (`endpoint`, `hooks`, `observers`, and the
   MCP servers of `mcp-client`).

Point 3 is the core of the design. Hooks and tools from the spec folder run
on the host as the user, outside any sandbox. A file the agent writes to
`hooks/` is host code from the next time arx runs it. `harness_edit` is the
gate between "a file the agent wrote" and "code arx runs on the host".

What the gate does not cover, by design:

- Files that a hook or tool reads or runs itself: helper scripts, libraries,
  interpreters and `PATH`. arx does not know about them. Keep them in the
  policy folder, or out of the sandbox's reach.
- Observer commands. arx starts them once, at the start of the session.
- Who made a change. Every change during a run counts as the agent's,
  including your own edits in an editor.
- Changes made before the run starts. arx trusts the files on disk at start,
  also on `--resume`.

## Current state

What exists today, and the parts this plan changes:

| Part | Where | What it does today |
|---|---|---|
| Reload fingerprint | `src/harness/signature.c:63` | One FNV-1a hash over `stat()` of the spec, `config.yaml`, prompt files, `tools/*`, `hooks/*`, `skills/*/SKILL.md`, `plugins/*/plugin.yaml` and `kits/*/kit.yaml`. |
| What the fingerprint reads | `src/harness/signature.c:24`, `:43` | Path, mtime and size; the mode only for direct entries of `tools/` and `hooks/`. No ctime, no inode. It does not cover `scheduler` or named programs. |
| Reload | `src/agent/loop.c:44`, called at `:134` | Before each model call: if the hash changed, `SpecLoad` again. A bad spec keeps the old one in memory and notes the agent (`:51`). |
| Spec load | `src/harness/spec.c:231` | Merges `config.yaml`, the kit and the spec, applies `--set` (`:266`), builds the active list and the layers. |
| `--kit` and `--set` | `src/cli/options.c:48`, `:52` | `--kit NAME` is `--set kit=NAME`. Both are applied on every load, so a reload keeps them. |
| Active list | `src/harness/active.c:205` | Sources in order: `config.yaml`, `agent.yaml`, `--set`. A kit or `plugins:` replaces the list. |
| Layers | `src/harness/plugins.c:312` | The spec folder is always layer 0 (`:318`), then the active list or every installed plugin. A broken plugin is skipped (`:237`). |
| Plugin values | `src/harness/plugins.c:161`, `:202` | A plugin's `plugin.yaml` merges under the spec: the spec wins. |
| Layer and spec structs | `src/harness/harness.h:36`, `:46` | `Layer` has `dir`, `plugin`, `skills`, `hooks`, `settings`, `replaces`. |
| Tool precedence | `src/harness/tools.c:279` | The first layer with a tool of a name wins, so the spec folder's tool always wins. |
| Hook order | `src/harness/hooks.c:186`, `:366` | Policy band, then normal, then final; inside a band, layer order. |
| Hook files | `src/harness/hooks.c:140` | arx runs `hooks/<point>` from disk each time. Nothing checks that the file is the one that was loaded. |
| Final policy result | `src/harness/hooks.c:349`, `:383` | A `result` set by a `policy`-band hook is final for the later hooks. |
| Hook points | `src/harness/fields.c:9`, `src/harness/validate.c:240` | Six points. An unknown point in `hooks:` is a validation error. |
| Subagents | `src/harness/tool_exec.c:110` | `arx -p - --spec PATH` with `--cap` only. `--set` and `--kit` do not pass to a subagent. |
| Exit codes | `src/base/base.h:27` | 0, 1, 2, 3, 4 and 130. |
| `arx check` | `src/cli/check.c:37` | `LayerLabel` assumes `layers[0]` is the spec folder. |
| Prompt text | `src/agent/agent.c:125`, `:150` | `{{harness}}` says "Your harness is yours to change" and lists the plugins. |
| File size limit | `src/harness/hooks.c` | 394 lines; `make lint` allows 400. |

Two gaps today, which this plan closes:

- **A pin keeps the list, not the files.** `--kit coding` pins the kit's
  name, but the agent can edit `kits/coding/kit.yaml` and take `guard` out
  of it. The kit loads again with the agent's list.
- **A changed hook runs before the reload sees it.** If the agent's `bash`
  writes `hooks/after_tool`, the new hook runs as soon as that `bash` call
  ends, in the same turn.

## Design

### The policy folder

A policy folder is a plugin folder: a `plugin.yaml` and any of `tools/`,
`hooks/` and `skills/`. arx checks it with the same rules as any plugin
(`arx check --plugin DIR`). The differences are where it loads and who can
remove it.

**CLI:**

```text
--policy DIR          load a policy folder first; repeatable
```

- `DIR` is a path, relative to the working directory. arx resolves it with
  `realpath()` when the run starts.
- `--policy` is repeatable. The policy folders load in the order of the
  flags.
- **`ARX_POLICY`**: a colon-separated list of folders. arx reads it at start
  and puts its folders before the `--policy` folders. A folder in both loads
  once. So a wrapper or a driver can set a policy for every run, and a
  `--policy` flag can add to it but not remove it.
- A missing or broken policy folder stops the run before the session starts,
  with exit 2: `arx: policy DIR: <problem>`. A broken plugin is skipped; a
  broken policy is never skipped.
- A subagent gets the same policy: `StartSubagent` passes one `--policy DIR`
  for each policy folder, after the `--cap` arguments.
- No spec key, `config.yaml` key or `kit.yaml` key names a policy. The agent
  can write all three files.

**Layer order** becomes:

| # | Layer |
|---|---|
| 0..n-1 | the policy folders, in flag order |
| n | the spec folder |
| n+1.. | the active list, or the installed plugins, as today |

What "first" means for each part:

| Part | Rule with a policy |
|---|---|
| Tools | A policy's tool wins over every other tool with its name. See [Which tool wins](#which-tool-wins). |
| Hooks | Inside each band, policy folders run first. A `policy`-band hook in a policy folder runs before every other hook at its point, and its `result` is final. |
| Skills | The policy's skills come first in `{{skills}}`. |
| `plugin.yaml` values | A policy's values merge **over** the spec: the policy wins. Observers and `hosts` add, as for any plugin. |
| `instructions`, `model_settings` | Rank 0: the policy's text comes first in the prompt, and its settings win over `--set`. See [A policy's rank](#a-policys-rank). |
| Settings | Only from the launcher's sources: `config.yaml` and `--set`. See [A policy's settings](#a-policys-settings). |
| Active list | A plugin with the same name as a policy is not loaded again from the active list. `arx check --list` shows it with the state `policy`. `disable:` cannot turn it off. |
| Reload | arx does not reload a policy folder. A change to any file in a policy folder stops the run (see [What reject does](#what-reject-does)). |

arx sets no new variable for a policy's hooks and tools. They get the same
`ARX_*` variables as any plugin, with `ARX_PLUGIN_DIR` set to the policy
folder. Tools and hooks inherit `ARX_POLICY` from arx's own environment, as
any variable, so an `arx` that a tool starts gets the same policy.

The `{{harness}}` text gets one more line when a policy is in force:

```text
- Policy: guard, prompts-only. They come before your harness and you cannot
  remove them; their text comes before your instructions, and their tools
  win over yours. Each harness edit goes to the policy before it loads; a
  rejected edit is restored, and your version is kept in
  .arx/sessions/<id>/harness/rejected/.
```

It names the policies, not their folders.

### Which tool wins

One rule for the whole release (README, "Settled across plans", item 4).
The sandboxes plan writes the same rule in its step 5:

1. **A policy layer's tool** wins.
2. **Else, a tool from a plugin that lists the name in `replaces:`** wins,
   wherever that plugin is in the active list. This also beats a tool of the
   same name in the spec folder.
3. **Else, the current rule**: the first tool with a name wins, in layer
   order.

Inside steps 1 and 2, the first layer in order wins: with two policies, the
first `--policy` folder's tool wins. A tool that a winner hides gets the
existing note "tools/NAME is hidden by a tool above it". A policy's own
`replaces:` changes nothing, because step 1 already puts its tools first.

So "a tool in the spec folder always wins" stops being true in two cases: a
policy has a tool with that name, or a plugin replaces it. The code is
written once, as three passes in `AddLayers` (see step 5 of the
implementation steps).

### A policy's rank

A policy has rank 0 for the prompt and the request fields: it comes before
every other source. The plugin-yaml-keys plan adds `instructions` and
`model_settings` to `plugin.yaml`, and leaves rank 0 free for a policy.

**The system prompt** is built in this order:

1. The `instructions` of each policy folder, in `--policy` order, each
   rendered on its own, joined by one blank line.
2. One blank line, then the base and the plugin text, as the
   plugin-yaml-keys plan builds them: the base from `--set`, `agent.yaml`,
   the kit or `config.yaml`, and the plugin text at
   `{{plugin_instructions}}` or after the base.

A policy's text never goes into `{{plugin_instructions}}`, and no source
can move or drop it: the active-list setting `instructions: null` does not
apply to a policy. The `{{harness}}` line about the policy says the policy
adds text before the agent's instructions, so the agent knows it can't
change that text.

**Model settings:** the first source in this order that sets a field wins:

| # | Source |
|---|---|
| 0 | each policy folder, in `--policy` order: the first policy wins |
| 1 | `--set model_settings.<field>=...` |
| 2 | `agent.yaml` |
| 3 | the kit, with the kits it extends |
| 4 | `config.yaml` |
| 5 | each plugin, in layer order: the first plugin wins |
| each call | `before_model` hooks, by band, can change `settings` for that call |

A policy's `null` removes the field, and `--set` cannot put it back. A
`before_model` hook after the policy's can still change `settings` for one
call. That is safe only when the policy rejects hook edits, as for guards
(see [Policy folders and the `policy` band](#policy-folders-and-the-policy-band)).

Rank 0 does not depend on the band of any hook, and it applies to these two
keys only. For the other `plugin.yaml` keys, a policy merges over the spec
(the layer-order table).

### A policy's settings

The spec cannot change a policy, so a policy's settings come only from the
two sources that the launcher controls:

| Source | Applies to a policy |
|---|---|
| `config.yaml` (`plugins:` or `enable:` entries with the policy's name) | yes |
| `--set` (the same entries) | yes, over `config.yaml` |
| the kit | no |
| `agent.yaml` | no; `arx check` warns: `settings for policy NAME in agent.yaml are ignored` |

A policy hook gets them as `ARX_PLUGIN_SETTINGS`, as any plugin hook does,
or `{}` when there are none. An entry with the policy's name adds nothing
to the active list, because a policy is never loaded twice.

This is what lets the long-lived-hooks `ask` plugin run as a policy and
still read its `tools`, `allow` and `timeout` settings.

`config.yaml` is in the config folder, which the agent's `bash` can write
without a sandbox. With a sandbox that does not mount the config folder, it
is out of the agent's reach.

### Policy folders and the `policy` band

They are two different things:

- **The `policy` band** is a slot in the order of hooks at one point. Any
  layer can use it, also the agent's spec folder.
- **A policy folder** is a layer that the spec cannot remove, and that comes
  first in every band.

A policy folder's guard should still set `band: policy` and
`fail: closed`. arx keeps the same defaults for every layer (`normal`,
`open`), and `arx check` warns when a policy folder's `before_tool` hook
lacks either one. `harness_edit` is the exception: it defaults to
`fail: closed`.

A policy guard sees the call before the hooks that run after it, and those
hooks can change `name` and `args`. That is safe only when every later hook
is one you trust. So a policy that guards tool calls must also reject hook
edits. Once the agent can write a hook, the hook runs as you on the host,
and no guard limits it.

### The `harness_edit` hook point

`harness_edit` is a decision point, like `session_start` and `stop`. It runs
only from policy folders. A `hooks/harness_edit` in any other layer never
runs, and `arx check` warns about it.

**When it runs:** in `MaybeReload`, when the fingerprint changed, before
`SpecLoad`. It runs once for all the changes of that reload. It does not run
at the start of a session.

**Input (stdin), one line:**

```json
{"point":"harness_edit","session":"20261109-101500-a1b2","turn":7,
 "changes":[
  {"path":"/w/hooks/before_tool","rel":"hooks/before_tool","layer":"spec",
   "kind":"hook","change":"changed","exec":true,
   "old":"/tmp/arx-gate.Xy12/0"},
  {"path":"/w/agent.yaml","rel":"agent.yaml","layer":"spec","kind":"spec",
   "change":"changed","old":"/tmp/arx-gate.Xy12/1",
   "keys":["endpoint.base_url","limits.max_turns"],
   "pinned":["limits.max_turns"]},
  {"path":"/w/plugins/lint/plugin.yaml","rel":"plugin.yaml",
   "layer":"plugin:lint","kind":"plugin","change":"added","keys":["name",
   "version","description","hooks"]}
 ]}
```

| Field | Value |
|---|---|
| `path` | The absolute path of the file. |
| `rel` | The path inside its layer, kit or spec folder. |
| `layer` | `spec`, `config`, `plugin:NAME` or `kit:NAME`: the folder the file is in. A plugin that is not loaded yet still gets `plugin:NAME`. |
| `kind` | `spec`, `config`, `prompt`, `tool`, `hook`, `scheduler`, `skill`, `plugin`, `kit` or `program`. `program` is a path that `compactors`, `credentials` or `adapters` name. |
| `change` | `added`, `changed` or `removed`. A `chmod` is `changed`. |
| `exec` | True when the new file is executable, so arx would run it. |
| `old` | A copy of the accepted version, for a diff. Not there for `added`, or when the file was over the copy limit. arx writes the copies to a new private folder from `mkdtemp()` for each call, outside the working directory, and deletes it after. |
| `keys` | For `spec`, `config`, `plugin` and `kit`: the dotted path of each value that changed, added or went away, down to the first scalar or list. `endpoint.base_url`, `plugins`, `hooks.before_tool.fail`. |
| `pinned` | For `spec` and `config`: the keys in `keys` that `--set` or `--kit` override, so the edit has no effect. |

**Output (stdout):**

| Output | Effect |
|---|---|
| nothing | Accept every change. |
| `{"reject": {"PATH": "REASON", ...}}` | Reject those changes. `PATH` is the `path` arx sent. Unknown paths are ignored, with an `ignored` field in the `hook` event. |
| `{"decision": "reject", "reason": "..."}` | Reject every change. |
| `{"decision": "stop", "reason": "..."}` | Reject every change and stop the run with exit 5. |

**More than one policy:** each `harness_edit` hook gets the same input, by
band and then in layer order. arx joins the rejects of all of them. The
first `stop` ends the run, and the later hooks do not run.

**Options**, in the policy's `plugin.yaml`:

```yaml
hooks: {harness_edit: {timeout: 30s}}
```

| Option | Default for `harness_edit` |
|---|---|
| `timeout` | `10s` |
| `fail` | `closed`: a failed hook rejects every change, with the reason `the harness_edit hook of POLICY failed`. With `open`, arx ignores the failed hook. |
| `band` | `normal`. It only orders the policy folders' hooks. |

**Example:** the agent may edit prompts and skills, but nothing else. With
`requires: [jq]` in the policy's `plugin.yaml`:

```sh
#!/bin/sh
# hooks/harness_edit: accept prompts and skills; reject the rest
jq -c '{reject: [.changes[]
  | select(.kind != "prompt" and .kind != "skill"
      and (.kind != "spec" or (.keys - ["instructions", "first_message"] != [])))
  | {key: .path, value: "only prompts and skills may change in this run"}]
  | from_entries}'
```

### What reject does

There are three options. This plan picks the first one.

| Option | What happens | Verdict |
|---|---|---|
| **Revert** | arx writes the accepted version back to the file, with its mode. An added file goes away; a removed file comes back. The run goes on, and the agent gets a note. | **Chosen.** Disk and the loaded harness agree again, so arx can go on running hooks and tools from disk. |
| Keep the old copy loaded | arx keeps the previous harness in memory and leaves the file as the agent wrote it. | Works today for the spec and prompts, which arx reads into memory. It cannot work for hooks and tools: arx runs them from disk, so the rejected file would run. It would need arx to run copies, which breaks `$0`-relative helper paths and the "load in place" rule. |
| Stop the run | arx stops with exit 5. | Kept as the hook's choice: `{"decision": "stop"}`. Right for evaluation runs, where any forbidden edit should end the run. |

How revert works:

- **Copies in memory.** When a policy has a `harness_edit` hook, arx keeps
  the bytes, mode and symlink target of every harness file outside the
  policy folders, after each accepted load. The copies are in memory, not in
  the session folder, because the agent can write the session folder. The
  limit is 4 MB in all. A file over the limit is not copied. Its `old` field
  is missing, and a reject of a change to it stops the run.
- **The rejected version is kept** for you in
  `.arx/sessions/<id>/harness/rejected/<turn>-<rel with / as __>`. arx never
  reads it back.
- **arx writes atomically**: a temp file in the same folder, then
  `rename()`. Then it takes the file's new `stat()` as the accepted one.
- **The agent gets a note:**

  ```text
  [harness]
  The policy rejected your change to hooks/before_tool (only prompts and
  skills may change in this run). arx restored the previous version. Your
  version is in .arx/sessions/20261109-101500-a1b2/harness/rejected/7-hooks__before_tool.
  ```

- **Then the reload goes on** with the accepted changes. If they do not
  validate without the rejected ones, the existing path applies: the old
  spec stays in memory, and the agent gets the validation note.

These cases stop the run with exit 5, status `policy`:

- A file in a policy folder changed. arx checks this at reload, and before
  it runs any policy folder's hook or tool, so the changed file never runs.
- A hook printed `{"decision": "stop"}`.
- arx cannot revert a file: the write failed, or the file was over the copy
  limit.

### The check before each run

The gate runs before each model call, but an agent's call can change a
hook that runs in the same turn. So, when a policy has a `harness_edit`
hook, arx checks a file's `stat()` against the accepted list right before it
runs it:

| arx is about to run | If the file changed since it was accepted |
|---|---|
| a hook outside the policy folders | The hook fails with `changed since the policy accepted it; the policy sees it before the next model call`. Its `fail:` option applies. |
| a tool outside the policy folders | The call ends with that text as an error result. |
| the `scheduler` | arx uses the built-in scheduler until the next reload. |
| a compactor program | The compaction fails, as when the program fails today. |
| a policy folder's hook or tool | The run stops with exit 5. |

The check compares device, inode, size, mtime, ctime and mode. The agent can
set mtime with `touch -d`, but not ctime, so a same-size edit with an old
mtime is still a change. It is one `stat()` per run, about 1 µs.

`credentials` and `adapters` programs run in `model/`, which does not know
the harness. They are checked at reload only; see Risks.

### The accepted list

One function walks the harness files, and both the fingerprint and the
accepted list use it, so the gate covers exactly what reload covers. The
walk adds two things the fingerprint misses today: the `scheduler` file at
the top of each layer, and the paths that `compactors`, `credentials` and
`adapters` name. Without a policy, arx keeps only the hash, as today.

### `--kit` and `--set` with a policy

| Pin | What it keeps | With a policy |
|---|---|---|
| `--kit NAME` | the kit's name, on every reload | The policy is not in the list, so no kit removes it. The agent can still edit `kits/NAME/kit.yaml`; `harness_edit` sees it as `kind: kit`. |
| `--set KEY=VALUE` | one spec value, on every reload | Applied as today. A spec edit to a pinned key shows in `pinned`, so a policy can accept it as harmless. |
| `--set 'plugins=[...]'` | the active list | The policy folders are not part of the list, so `plugins: []` leaves them on. |
| `--cap` | hard limits | Not related. Use it for limits; a policy has no limits of its own. |

Use them together: `--kit` and `--set` decide what loads, `--cap` limits
the run, and the policy decides which edits load.

### Events, exit code and `arx check`

- **Exit code 5**, `kExitPolicy`, status `policy` in `--json` and
  `session.end`.
- **`harness.edit`** event, one per change: `path`, `layer`, `kind`,
  `change`, `decision` (`accept`, `reject` or `stop`), and `reason` and
  `policy` (the plugin name) for a reject.
- **`harness.reload`** gets `rejected`, a count, when the gate rejected
  something.
- **`hook`** events of a policy folder get `"policy": true`.
- **`session.start`** gets `policy`: the list of policy names.
- **`arx check --policy DIR`** loads the harness with the policy, and
  prints `policy: guard prompts-only` before `plugins:`. The hooks line
  marks policy hooks: `hooks: harness_edit(prompts-only) before_tool(guard*)`
  (a `*` for a policy).
- **`arx check --list`** prints a row with the state `policy` for each
  policy folder, before the plugins.
- **New `arx check` warnings:**
  - `hooks/harness_edit runs only in a policy folder (--policy)`, for one in
    any other layer.
  - `policy DIR is inside the working directory, so the agent's bash can
    change it`.
  - `policy NAME: before_tool hook without band: policy and fail: closed`.

## Implementation steps

In order. Each step leaves `make test` and `make lint` green.

1. **Split `src/harness/hooks.c`** (394 lines) into `hooks.c` (running one
   hook, options, bands, the decision points) and a new
   `src/harness/chain.c` (the raw-object chain: `Legacy`, `Merge`,
   `AddNames`, `Apply`, `KeepResult`, `HookChain`). Export `HookRunOne`
   (today's `RunOne`) and `HookPath` in `harness.h`. No behavior change.
   `long-lived-hooks` also changes this file: land this split once, first.
2. **Exit code**: `kExitPolicy = 5` in `src/base/base.h`; `policy` in
   `StatusName` in `src/agent/run.c`; the exit codes line in `PrintOptions`.
3. **The file walk**: in `src/harness/signature.c`, add
   `HarnessFiles(const Spec*, HarnessFileFn, void* ctx)`, which calls back
   with path, kind, layer label and rel for each harness file, including
   `scheduler` and named programs. `SpecSignature` hashes through it.
4. **`--policy` and `ARX_POLICY`**: `cJSON* policy` (absolute folders) in
   `Agent` (`src/agent/agent.h`) and in `Spec` (`src/harness/harness.h`);
   parse the flag in `src/cli/options.c`; read the variable and resolve the
   folders in `Start` (`src/agent/run.c`). `SpecLoad` takes the list:
   `SpecLoad(path, sets, policy, spec, err)`; update the three callers
   (`run.c`, `loop.c`, `src/cli/check.c`).
5. **Policy layers**: `int policy` in `Layer`. In `src/harness/plugins.c`,
   `PolicyLoad(spec, err)` adds the policy layers before the spec folder; a
   problem goes to `err`, so `SpecLoad` fails. `Adopt` gets a flag to merge
   a policy's values over the spec (`JsonMergeOver`). `LoadActive` and
   `LoadPlugins` skip names that a policy has, with the row state `policy`.
   Fix the "layer 0 is the spec folder" assumptions: `LayerLabel` in
   `src/cli/check.c:37` and `LayerName` in `src/harness/tools.c`.
   - **Which tool wins**: the three passes in `AddLayers` (policy layers,
     then plugins whose `replaces:` lists the name, then every layer in
     order), in `src/harness/tool_layers.c`. Sandboxes step 5 moves
     `AddLayers` there, because `tools.c` is at 391 of 400 lines. Whichever
     plan lands first writes the three passes; the other only adds its
     tests. `HiddenWarnings` in `src/cli/check.c` gives no warning for a
     hide the rule explains.
   - **Settings**: `ActiveBuild` in `src/harness/active.c` keeps the
     settings of a policy's name from the `config.yaml` and `--set` sources
     only, and `check.c` warns about the `agent.yaml` ones.
   - **Rank 0**: after the plugin-yaml-keys steps land, `PluginText()` in
     `src/agent/agent.c` puts the policy layers' `instructions` before the
     base, outside `{{plugin_instructions}}`, and ignores
     `instructions: null` for them. The `model_settings` merge applies the
     policy layers last, after `--set` (`src/harness/spec.c:266`), so they
     win. If trust lands first, these two lines wait for plugin-yaml-keys.
6. **Subagents**: `StartSubagent` in `src/harness/tool_exec.c` passes the
   `--policy` arguments, so a subagent gets the flag's folders as well as
   the inherited `ARX_POLICY`.
7. **Hook point**: `harness_edit` in `kHookPoints` (`src/harness/fields.c`)
   and in the message at `src/harness/validate.c:243`. `HookRun` and
   `HookChain` skip it; only the gate runs it.
8. **The accepted list**: a new `src/harness/manifest.c`: build the list
   with full `stat()` and in-memory copies, diff two lists, keep the 4 MB
   copy limit, revert a file, and move a rejected version aside. Declared in
   `harness.h`.
9. **The gate**: a new `src/harness/gate.c`: `GateOpen(a)` after the first
   load; `GateReload(a)` before `SpecLoad`, which builds the input (with
   `keys` and `pinned` from a YAML diff through `SpecParse`), runs each
   policy folder's `harness_edit` through `HookRunOne`, joins the answers,
   reverts, sends `harness.edit` events and queues notes;
   `GateAllows(a, layer, path)` for the check before each run; `GateFree`.
   Both new files stay under 400 lines.
10. **Wire it in**: `MaybeReload` in `src/agent/loop.c` calls `GateReload`
    and returns `kExitPolicy` to `RunTurns` on a stop. `HookRunOne`, the
    tool start in `tool_exec.c`, `SchedOpen` in `src/agent/scheduler.c` and
    the compactor run in `src/harness/compact.c` call `GateAllows`.
11. **Prompt and check**: the policy line in `PluginsText`
    (`src/agent/agent.c`); the `policy:` line, the hook marks, the `--list`
    rows and the three warnings in `src/cli/check.c`; `--policy` in
    `PrintOptions`.
12. **Commands**: `commands/arx-plugin` shows the `policy` rows in
    `arx plugin list`, with the scope `policy`. `commands/arx-doctor` warns
    when a folder in `ARX_POLICY` is missing.
13. **Example**: `examples/policies/prompts-only/` with `plugin.yaml`
    (`requires: [jq]`) and `hooks/harness_edit` from the Design section. It
    is in `examples/`, not `plugins/`, because every installed plugin is on
    by default, and this one only makes sense as a policy.

## Tests

A new suite, `tests/trust.sh`, with its own config folder per test like
`tests/kits.sh`. Add it to the `test` target in `Makefile:63` and to the
suite lists in `.github/workflows/ci.yml:34` and `release.yml:57`.

Policy folders:

- `arx check --policy p` prints `policy: p`, and the policy's hooks come
  first in each band (order of `hook` events).
- `plugins: []`, `disable: [p]`, and a kit without `p` all leave the
  policy's hooks running.
- A plugin in the active list with the policy's name loads once.
- Which tool wins: a policy's `tools/bash` hides the spec folder's
  `tools/bash` and a replacing plugin's `bash`; with two policies, the first
  `--policy` folder's tool wins.
- A policy's `plugin.yaml` tool option wins over the spec's.
- Rank 0: a policy's `instructions` come before the spec's, also when the
  spec has `{{plugin_instructions}}`; `instructions: null` for the policy's
  name in `agent.yaml` leaves the text. A policy's
  `model_settings: {temperature: 0}` wins over
  `--set model_settings.temperature=1` (`fake/req-01.json`).
- Settings: `--set` and `config.yaml` entries for the policy's name reach
  its hook as `ARX_PLUGIN_SETTINGS`; an `agent.yaml` entry does not, and
  `arx check` warns.
- The `ask` plugin as a policy (once long-lived-hooks has landed): with
  `--policy plugins/ask`, `plugins: []` in the spec still asks, and the
  plugin loads once when the active list also names it.
- A missing policy folder, and one with a bad `plugin.yaml`, exit 2 before a
  session folder exists.
- `ARX_POLICY=a` and `--policy b` load `a` then `b`; the same folder twice
  loads once.
- A subagent's events show the policy hook at depth 1.

The gate:

- An edit to `prompts/system.md` is accepted: a `harness.edit` event with
  `accept`, and the hook's input has `kind: prompt` and an `old` file with
  the old text.
- A new `hooks/before_tool` is rejected: the file is gone, its copy is in
  `harness/rejected/`, the note is in the transcript, and the hook never
  runs.
- A changed tool is rejected: the old bytes and mode are back.
- A removed hook is rejected: it comes back.
- A same-turn race: the agent's `bash` writes `hooks/after_tool`, which
  touches a marker file. The marker does not exist after the call.
- A tool changed and called in the same reply gets the "changed since the
  policy accepted it" error.
- `touch -d` back to the old mtime with the same size still counts as a
  change.
- An `agent.yaml` edit gives `keys: ["endpoint.base_url"]`; with
  `--set limits.max_turns=5` and an edit to `limits.max_turns`, `pinned`
  lists it.
- An edit to `kits/k/kit.yaml` under `--kit k` reaches the hook as
  `kind: kit`.
- `{"decision": "stop"}` exits 5, with `"status":"policy"` in `--json` and
  in `session.end`.
- A `harness_edit` hook that exits 1 rejects the batch; with `fail: open`
  the batch is accepted.
- Two policies: their rejects join; the first `stop` wins.
- A change to a file in the policy folder stops the run before that file
  runs.
- A file over the copy limit, rejected, stops the run with exit 5.
- `hooks/harness_edit` in the spec folder: `arx check` warns, and it never
  runs.
- Without `--policy`, the existing reload tests in `tests/run.sh:77` and
  `:93` and `tests/kits.sh:105` pass as they are.

Bench: `tests/bench.sh` keeps its reload budget without a policy, and adds
an informational line for a reload through a `harness_edit` hook.

## Docs to change

Written to `docs/WRITING.md`: "policy folder" is the one name for the
concept, the threat model goes in one `[!WARNING]`, and nothing is described
before it ships.

- **New guide `docs/plugins/policies.md`** ("Policies"): opens with "A
  policy folder is a plugin folder that loads before the spec folder and
  that the agent cannot remove." Sections: when to use one, the threat model
  and what a policy needs from a sandbox, `--policy` and `ARX_POLICY`, the
  `harness_edit` contract (input, output, options), what a reject does, the
  prompts-only example, `--kit` and `--set` with a policy, common mistakes.
  Ends with Related. Add it to `src/lib/nav.mjs` in arx-docs and to
  `docs/plugins.md`.
- **`docs/plugins/planned.md`**: remove the Trust row and section; in
  Sandboxes, link the new page.
- **`docs/plugins/hooks.md`**: seven points; `harness_edit` in "Points with
  a decision" and in the "More than one hook" rule table; in Bands, one
  paragraph on policy folders versus the `policy` band; replace the
  common-mistake row "The agent can turn off a plugin's guard" with a pin
  plus `--policy`.
- **`docs/plugins/concepts.md`**: "Policy folder" in the terms table; the
  policy row in the layer table; the three-step tool rule in "Which part
  wins" (one edit, shared with sandboxes); the policy's rank 0 for
  `instructions` and `model_settings`; seven points in the hook point
  table; a `--policy` line in "Pin the list from the command line"; the
  gate in "Reload".
- **`docs/plugins/policies.md`** also covers a policy's settings, and runs
  the `ask` plugin as the example of a policy that needs them.
- **`docs/plugins/kits.md`**: in the TIP and common mistakes, say that
  `--kit` pins the kit's name, not its `kit.yaml`, and link Policies.
- **`docs/plugins/reference.md`**: `ARX_POLICY` in Environment; the
  `harness.edit` event and `rejected` in `harness.reload`; the `policy`
  state in `arx check`; `harness_edit` in Hook points; exit code 5.
- **`docs/cli.md`**: `--policy DIR` in the options table; exit code 5;
  `ARX_POLICY` in Environment; `arx check --policy`.
- **`docs/spec.md`**: in `hooks`, that `harness_edit` runs only in a policy
  folder; in Overrides, one sentence that a policy is how to stop edits to
  the files, which `--set` cannot.
- **`docs/concepts.md`**: a policy paragraph in "The harness edits itself";
  in "What arx does not do", say a policy is a gate on harness edits, still
  not a sandbox.
- **`docs/architecture.md`**: a design-decision row for the gate; `gate.c`,
  `manifest.c` and `chain.c` in the source table; the new test suite and
  count.
- **`README.md`**: one line on `--policy` where it shows `guard`.

## Dependencies

None of these must land first. Trust works alone, as a guard rail. It is a
boundary only together with `sandboxes`.

| Slug | What we share |
|---|---|
| `sandboxes` | The other half of the boundary. Both plans write the same [tool rule](#which-tool-wins); sandboxes step 5 moves `AddLayers` to `tool_layers.c`, and whichever lands first writes the three passes. Under that rule a sandbox plugin's `replaces: [bash, edit]` already beats the spec folder's `tools/bash`; in a policy folder it also can't be turned off. The `sandbox:` key must be pinned with `--set sandbox=...` or rejected by the policy, or the agent sets `sandbox: none`. The sandbox must not mount the policy folders, and should end every process of a call when the call ends. |
| `long-lived-hooks` | Both change `hooks.c`: land the split (step 1) once. A long-lived hook outside the policy starts again only after the gate accepts its change; a long-lived policy hook whose file changes stops the run. |
| `long-lived-hooks`, the `ask` plugin | `arx acp` passes the `ask` plugin with `--policy` (release Decision 1), so the agent can't turn it off, and mode `ask` in `arx acp` waits for this plan. What `ask` needs from trust: `--policy` repeatable and passed to subagents; policy hooks first in the `policy` band, with `fail: closed` honored; settings from `config.yaml` and `--set` ([A policy's settings](#a-policys-settings)), so `tools`, `allow` and `timeout` still work; one load when the active list also names `ask`. Its `run: session` process follows the long-lived rule in the row above: a change to its file stops the run. One caution for the `ask` plan: as a policy, it must not read approvals back from `$ARX_STATE_DIR/allowed.json`, because that folder is in the working directory and the agent can write "always allow bash" there. Keep "always" in memory, or store it outside the working directory. |
| `async-calls` | A call that runs on across turns can change harness files at any time, which is why the check before each run exists. A subagent started in the background gets `--policy` too. |
| `plugin-state` | `ARX_STATE_DIR` and `ARX_DATA_DIR` are in the working directory, which the agent can write. A policy must not keep trusted state there. Storage outside the working directory would also let the gate check changes on `--resume`. |
| `arx-plugin` | `arx plugin list` shows `policy` rows. `eject` copies a plugin into the spec folder, so its files go through the gate. `arx plugin add` run by the agent shows up as `kind: plugin`, `change: added`. |
| `plugin-yaml-keys` | It adds `instructions` and `model_settings` to `plugin.yaml` and leaves rank 0 free. Trust takes rank 0: a policy's text comes first in the prompt, outside `{{plugin_instructions}}`, and its settings win over `--set` ([A policy's rank](#a-policys-rank)). Trust's rank-0 lines in `PluginText()` and the settings merge land after that plan's steps. |
| `mcp-client` | MCP server commands are host programs. Their spec key name goes in the docs' list of keys to reject, and paths they name go in the file walk as `kind: program`. |
| `climb` | The driver can start runs with `--policy`, and should treat exit 5 as "revert and go on". Climb reverts the workspace; the gate reverts harness files from memory. They do not share code. |
| `acp-tui` | Mode `ask` in `arx acp` depends on this plan, through the `ask` plugin row above; until trust lands, `arx acp` ships with mode `allow` only. `arx acp` makes each `--policy` path absolute before it passes it to a child. Exit 5 maps to an ACP stop reason, and `harness.edit` events become `session/update` messages. |

## Size and risks

**Size: L.** New flag and variable, a new layer kind, a refactor of the
fingerprint, two new source files, one split file, changes in loop, tools,
hooks, scheduler and compaction, one test suite of about 30 checks, and
eleven doc pages.

Risks:

- **Overclaiming.** The docs must say plainly that a policy without a
  sandbox stops mistakes, not a hostile agent.
- **The gap between check and run.** arx checks a file's `stat()` and then
  runs it. A process that rewrites the file in those microseconds wins.
  macOS has no `fexecve()`, so arx cannot close this itself. The sandbox's
  "end every process with its call" closes it.
- **Credentials and adapters** are checked only at reload, so a process
  that outlives its call can change them between the reload and the model
  call. Same fix as the previous risk.
- **Files the gate does not see**: helper scripts, interpreters, observer
  commands. Say so in the docs, and keep helpers in the policy folder.
- **Revert loops.** An agent that writes the same rejected file every turn
  spends turns. The note says why, and the policy can `stop` instead.
- **Your own edits get reverted.** An edit you make in an editor during a
  run goes through the gate like the agent's. Say so in the guide.
- **Rule change for tools.** "A tool in the spec folder always wins"
  becomes "except a policy's, or a plugin's that `replaces:` the name".
  Update every page that says it, once, with sandboxes.
- **Reload budget.** Without a policy, nothing changes. With one, each
  reload with changes starts a hook process (a few ms), outside the 10 ms
  budget; the bench reports it separately.
- **Memory.** The copies cost up to 4 MB, within the 16 MB budget.
- **File length.** `hooks.c` is at 394 of 400 lines; step 1 makes room.

## Open decisions

Each with a recommendation. None blocks the plan's shape.

1. **What a reject does.** Recommend **revert from in-memory copies**, with
   `{"decision": "stop"}` for the hook that wants to end the run. Keeping
   the old copy loaded cannot work for hooks and tools, which arx runs from
   disk.
2. **The shape of a policy folder.** Recommend one plugin folder per
   `--policy`, repeatable, rather than a folder of plugins or a new
   `policy.yaml`. It reuses `plugin.yaml`, `arx check --plugin` and the hook
   options.
3. **Where `harness_edit` runs.** Recommend policy folders only, with a
   warning elsewhere. A gate the agent can edit judges its own edits.
4. **Band and `fail` defaults for policy hooks.** Recommend the same
   defaults as every layer, plus an `arx check` warning, and `fail: closed`
   for `harness_edit` only.
5. **Policy hooks in the `final` band.** Recommend first, as in the other
   bands, for 0.2.0: one rule. If a policy needs to redact last, revisit
   with "policy folders run last in `final`".
6. **`ARX_POLICY`.** Recommend reading it, and joining it with `--policy`
   (the variable's folders first), so a nested run cannot drop a policy
   with a flag.
7. **A `policy:` key in `config.yaml`.** Recommend no. The agent can write
   the config folder.
8. **Pins inside a policy** (a `set:` map in its `plugin.yaml`). Recommend
   no for 0.2.0: use `--set`, or reject the key in `harness_edit`. The
   policy's `plugin.yaml` values already win over the spec.
9. **`--resume`.** Recommend trusting the files on disk at start, as for a
   new session. The session folder is in the working directory, so a saved
   list there is not trustworthy. Revisit with `plugin-state`.
10. **Which runs get the check before each run.** Recommend hooks, tools,
    the scheduler and compactors. Credentials and adapters are checked at
    reload only, because `model/` does not depend on `harness/`.
11. **Exit code.** Recommend `5`, status `policy`.
12. **Copy limit.** Recommend 4 MB in all. A rejected change to a file over
    it stops the run.
13. **Settings for a policy.** Changed after the release plan: recommend
    settings from `config.yaml` and `--set` only, not from the kit or
    `agent.yaml`. The first draft gave a policy `{}`, which would leave the
    `ask` plugin, which `arx acp` passes with `--policy`, without its
    `tools`, `allow` and `timeout` settings.

Settled by the release plan (README, "Settled across plans"), not open:

- **Rank** (item 3): a policy's `instructions` come first, and its
  `model_settings` rank above `--set`.
- **Which tool wins** (item 4): a policy layer's tool, then a tool that
  `replaces:` the name, then the first tool with a name.
- **Exit code** (item 8): 5 means `policy`.
