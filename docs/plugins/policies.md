# Policies

A policy folder is a plugin folder that loads before the spec folder and
that the agent cannot remove. You name it with `--policy DIR` when you start
a run. Use one to keep a guard in every run, or to decide which harness
edits of the agent load.

> [!WARNING]
> A policy without a sandbox stops mistakes, not a hostile agent. arx and
> the agent run as the same user on the same disk, so the agent's `bash` can
> change any file arx reads, the policy folder too, and can run any command.
> A policy is then a guard rail and a record of every harness edit. It is
> not a security boundary.

## When to use a policy folder

| You want | Use |
|---|---|
| a fixed list of plugins for a run | `--kit NAME` or `--set 'plugins=[...]'` ([Pin the list](concepts.md#pin-the-list-from-the-command-line)) |
| a hard limit on turns, tokens, cost or time | `--cap` ([Command line](../cli.md#caps)) |
| a guard the agent's spec cannot turn off | a policy folder with a `before_tool` hook |
| a say over each harness edit before it loads | a policy folder with a `harness_edit` hook |

A pin keeps the name of a kit or the list of plugins. It does not keep the
files: under `--kit coding` the agent can still edit `kits/coding/kit.yaml`.
A policy folder is how you stop edits to the files.

## What a policy needs from a sandbox

A policy is a boundary only when all three of these are true:

1. The agent's `bash` and `edit` run in a sandbox that cannot write the
   policy folders.
2. The sandbox ends every process that a call starts when the call ends, so
   no process of the agent outlives its call.
3. The policy rejects every change that lets the agent run code on the
   host: new or changed hooks, tools, `scheduler` files, programs
   (`compactors`, `credentials`, `adapters`), plugins and kits, and the spec
   keys that name programs or hosts (`endpoint`, `hooks`, `observers`).

Point 3 matters most. Hooks and tools from the spec folder run on the host
as you. A file the agent writes to `hooks/` is host code from the next time
arx runs it. The `harness_edit` hook is the gate between a file the agent
wrote and code arx runs.

**Planned:** sandbox plugins. Until they ship, treat a policy as a guard
rail. See [Planned changes](planned.md#sandboxes).

The gate does not cover these, by design:

- **Files that a hook or tool reads or runs itself**: helper scripts,
  libraries, interpreters and `PATH`. arx does not know about them. Keep
  helpers in the policy folder.
- **Observer commands**: arx starts them once, when the session starts.
- **Who made a change**: every change during a run counts as the agent's.
  An edit you make in an editor goes through the gate too, and a rejected
  one is reverted.
- **Changes before the run**: arx trusts the files on disk at the start,
  also with `--resume`.

## `--policy` and `ARX_POLICY`

A policy folder is a plugin folder: a `plugin.yaml` and any of `tools/`,
`hooks/` and `skills/`. Check one with `arx check --plugin DIR`. Then name
it when you start a run:

```sh
arx --policy ~/policies/guard -p "fix the failing test"   # one policy folder
arx check --policy ~/policies/guard                       # the harness with it
```

- **`--policy DIR`** is repeatable. The folders load in the order of the
  flags. arx resolves each path when the run starts.
- **`ARX_POLICY`** is a colon-separated list of folders. Its folders load
  before the flags', and a folder in both loads once. A wrapper or driver
  can set it for every run, and a flag can add to it but not remove it.
- **A missing or broken policy folder stops the run** before a session
  starts, with exit code `2` and `arx: policy DIR: <problem>`. arx skips a
  broken plugin. It never skips a broken policy.
- **A subagent gets the same policy folders.**
- **No key names a policy.** The agent can write `agent.yaml`, `config.yaml`
  and `kit.yaml`, so none of them can add or remove one.

Keep a policy folder outside the working directory. `arx check` warns when
it is inside.

### What comes first

The policy folders are the first layers, in flag order. Then come the spec
folder and the plugins, as without a policy.

| Part | Rule with a policy |
|---|---|
| Tools | A policy's tool wins over every other tool with its name. See [Which part wins](concepts.md#which-part-wins). |
| Hooks | In each [band](hooks.md#bands), the policy folders run first. A `policy`-band hook in a policy folder runs before every other hook at its point, and its `result` is final. |
| Skills | The policy's skills come first in `{{skills}}`. |
| `instructions` | The policy's text comes first in the system prompt, before your instructions and outside `{{plugin_instructions}}`. No setting moves or drops it. |
| `model_settings` | A policy's field wins over `--set`, the spec, the kit and every plugin. With two policies, the first wins. `null` removes the field. |
| Other `plugin.yaml` values | They merge over the spec, so the policy wins. `observers` and `hosts` add, as for any plugin. |
| The active list | A plugin with the same name as a policy does not load again. `plugins: []`, `disable:` and a kit leave the policy on. |

The `{{harness}}` text tells the agent which policies are in force, by
name. It does not give their folders.

### Settings for a policy

A policy takes its [plugin settings](kits.md#the-active-list) from the two
sources you control: `config.yaml`, and `--set` over it. Settings for its
name in `agent.yaml` or a kit are ignored, and `arx check` warns about the
ones in `agent.yaml`. The policy's hooks get them as `ARX_PLUGIN_SETTINGS`,
or `{}` when there are none.

```sh
arx --policy ~/policies/guard --set 'enable=[{"guard": {"deny": ["rm"]}}]'
```

`config.yaml` is in your config folder, which the agent's `bash` can write
without a sandbox.

### A policy folder is not the `policy` band

The `policy` band is a place in the order of hooks at one point. Any layer
can use it, the agent's spec folder too. A policy folder is a layer that
the spec cannot remove.

A guard in a policy folder should still set `band: policy` and
`fail: closed`. arx keeps the defaults of every layer (`normal`, `open`),
and `arx check` warns when a policy's `before_tool` hook lacks either one.

The hooks after a policy guard can change `name` and `args`. So a policy
that guards tool calls should also reject hook edits with a `harness_edit`
hook.

## The `harness_edit` hook

`harness_edit` is a hook point that runs only in policy folders. arx runs
it before it loads a changed harness, once for all the changes of that
reload. It does not run when a session starts. `hooks/harness_edit` in any
other layer never runs, and `arx check` warns about it.

### Input

One JSON object on stdin:

```json
{"point": "harness_edit", "session": "20261109-101500-a1b2", "turn": 7,
 "changes": [
  {"path": "/w/hooks/before_tool", "rel": "hooks/before_tool",
   "layer": "spec", "kind": "hook", "change": "changed", "exec": true,
   "old": "/tmp/arx-gate.4711-1-0/0"},
  {"path": "/w/agent.yaml", "rel": "agent.yaml", "layer": "spec",
   "kind": "spec", "change": "changed", "exec": false,
   "old": "/tmp/arx-gate.4711-1-0/1",
   "keys": ["endpoint.base_url", "limits.max_turns"],
   "pinned": ["limits.max_turns"]}
 ]}
```

| Field | Value |
|---|---|
| `path` | The absolute path of the file. |
| `rel` | The path inside its folder. |
| `layer` | The folder the file is in: `spec`, `config`, `plugin:NAME` or `kit:NAME`. A plugin that is not loaded yet still gets `plugin:NAME`. |
| `kind` | `spec`, `config`, `prompt`, `tool`, `hook`, `scheduler`, `skill`, `plugin`, `kit` or `program`. A `program` is a path that `compactors`, `credentials`, `adapters`, `compaction.strategy` or `endpoint` names. |
| `change` | `added`, `changed` or `removed`. A `chmod` is `changed`. |
| `exec` | True when the file is executable now, so arx would run it. Not there for a removed file. |
| `old` | A copy of the accepted version, for a diff. Not there for an added file, or for a file over the copy limit. arx writes the copies to a new private folder outside the working directory and deletes it after the hooks ran. |
| `keys` | For `spec`, `config`, `plugin` and `kit`: the dotted path of each value that changed, was added or went away, down to the first scalar or list. Not there when the file does not parse. |
| `pinned` | For `spec` and `config`: the keys in `keys` that `--set` or `--kit` override, so the edit has no effect. |

arx covers the files that hot reload covers: the spec and `config.yaml`,
prompt files, every entry of `tools/` and `hooks/`, each `SKILL.md`, the
`scheduler` of each layer, named programs, and each `plugin.yaml` and
`kit.yaml`.

### Output

| The hook prints | Effect |
|---|---|
| nothing | Accept every change. |
| `{"reject": {"PATH": "REASON"}}` | Reject those changes. `PATH` is the `path` arx sent. arx ignores a path it did not send, and says so in the `hook` event. |
| `{"decision": "reject", "reason": "..."}` | Reject every change. |
| `{"decision": "stop", "reason": "..."}` | Reject every change and stop the run with exit code `5`. |

With more than one policy, each hook gets the same input, by band and then
in layer order. arx joins their rejects. The first `stop` ends the run, and
the later hooks do not run.

### Options

Set them in the policy's `plugin.yaml`:

```yaml
# plugin.yaml
hooks: {harness_edit: {timeout: 30s}}
```

| Option | Default for `harness_edit` |
|---|---|
| `timeout` | `10s` |
| `fail` | `closed`: a hook that fails rejects every change, with the reason `the harness_edit hook of NAME failed`. With `open`, arx ignores the failed hook. |
| `band` | `normal`. It only orders the policy folders' hooks. |

## What a reject does

arx writes the accepted version back to the file, with its mode. An added
file goes away, and a removed file comes back. Then the reload goes on with
the accepted changes, and the run goes on.

- **The copies are in memory.** When a policy has a `harness_edit` hook,
  arx keeps the bytes, mode and symlink target of every harness file outside
  the policy folders, after each accepted load. The limit is 4 MB in all.
- **The rejected version is kept** in
  `.arx/sessions/<id>/harness/rejected/<turn>-<rel>`, with each `/` in `rel`
  written as `__`. arx never reads it back.
- **arx writes through a temp file and `rename()`**, so a reader never sees
  half a file.
- **The agent gets a note** with your reason:

  ```text
  [harness]
  The policy rejected your change to hooks/before_tool (only prompts and
  skills may change in this run). arx restored the previous version. Your
  version is in .arx/sessions/20261109-101500-a1b2/harness/rejected/7-hooks__before_tool.
  ```

These cases stop the run with exit code `5` and the status `policy`:

- A file in a policy folder changed. arx checks every file in the folder
  at each reload, and the file it is about to run before it runs it.
- A hook printed `{"decision": "stop"}`.
- arx cannot revert a rejected file: the write failed, or the file was over
  the copy limit.

### The check before each run

The gate runs before each model call, but a tool call can change a hook
that runs in the same turn. So, when a policy has a `harness_edit` hook,
arx checks a file with `stat()` right before it runs it.

| arx is about to run | If the file changed since it was accepted |
|---|---|
| a hook outside the policy folders | The hook fails with `changed since the policy accepted it; the policy sees it before the next model call`. Its `fail` option applies. |
| a tool outside the policy folders | The call ends with that text as an error result. |
| the `scheduler` | arx uses the built-in scheduler until the next reload. |
| a compactor | The compaction fails, as when the program fails. |
| a policy folder's hook or tool | The run stops with exit code `5`. |

The check compares device, inode, size, mtime, ctime and mode. The agent
can set mtime with `touch -d`, but not ctime, so an edit that keeps the
size and the mtime still counts.

`credentials` and `adapters` programs are checked at reload only. A process
that rewrites a file in the microseconds between the check and the run can
still win. A sandbox that ends every process with its call closes both
gaps.

## Example: only prompts and skills may change

[`examples/policies/prompts-only/`](../../examples/policies/prompts-only)
is a policy folder with one hook. It needs `jq`.

```sh
#!/bin/sh
# hooks/harness_edit: accept prompts and skills; reject the rest
jq -c '{reject: [.changes[]
  | select(.kind != "prompt" and .kind != "skill"
      and (.kind != "spec" or (.keys - ["instructions", "first_message"] != [])))
  | {key: .path, value: "only prompts and skills may change in this run"}]
  | from_entries}'
```

Run it from a copy outside your project:

```sh
cp -R examples/policies/prompts-only ~/policies/   # out of the agent's way
arx --policy ~/policies/prompts-only -p "improve your system prompt"
```

For an evaluation run, where any other edit should end the run, print
`{"decision": "stop", "reason": "..."}` instead of a reject.

## `--kit` and `--set` with a policy

Use them together: `--kit` and `--set` decide what loads, `--cap` limits the
run, and the policy decides which edits load.

| Pin | What it keeps | With a policy |
|---|---|---|
| `--kit NAME` | the kit's name, on every reload | No kit removes the policy. The agent can still edit `kits/NAME/kit.yaml`, and `harness_edit` sees that as `kind: kit`. |
| `--set KEY=VALUE` | one spec value, on every reload | A spec edit to a pinned key shows in `pinned`, so a policy can accept it as harmless. |
| `--set 'plugins=[...]'` | the active list | The policy folders are not in the list, so `plugins: []` leaves them on. |
| `--cap` | hard limits | Not related. A policy has no limits of its own. |

## Common mistakes

| Mistake | What happens | Fix |
|---|---|---|
| Treating a policy as a sandbox | The agent's `bash` edits the policy folder, and the run stops with exit code `5`, after the command already ran. | Use a policy for mistakes. Wait for sandbox plugins for a boundary. |
| The policy folder is inside the working directory | `arx check` warns: the agent's `bash` can change it. | Keep it outside, for example in `~/policies/`. |
| A `before_tool` guard without `band: policy` and `fail: closed` | Hooks before it can change the call, and a broken guard lets calls through. | Set both in the policy's `plugin.yaml`. |
| `hooks/harness_edit` in the spec folder or a plugin | It never runs. | Put it in a policy folder. |
| A hook that reads `keys` of a file that does not parse | `keys` is missing, the hook fails, and `fail: closed` rejects the batch. | That is the safe result. Tell the agent in your reason to run `arx check`. |
| The agent writes the same rejected file every turn | It spends turns. | Say why in the reason, or print `{"decision": "stop"}`. |
| Trusted state in `ARX_STATE_DIR` or `ARX_DATA_DIR` | Both are in the working directory, which the agent can write. | Keep what the policy trusts in memory or outside the working directory. |
| You edit a harness file during a run | It goes through the gate like the agent's edits. | Stop the run first, or expect a revert. |

## Related

- [Hooks](hooks.md): hook points, bands and the `fail` option.
- [Kits](kits.md): choose the plugins of a run, and pin them.
- [Plugin concepts](concepts.md#which-part-wins): layers, and which tool
  wins.
- [Plugin reference](reference.md): the `harness.edit` event, `ARX_POLICY`
  and exit code `5`.
