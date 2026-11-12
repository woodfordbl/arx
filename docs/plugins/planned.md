# Planned changes

Planned changes are the parts of the plugin system that are designed but not
built yet. They are here so that plugin authors can plan for them, and the
contracts can still change.

> [!NOTE]
> Nothing on this page works in arx today. For what works now, see the other
> pages of the [plugin guide](../plugins.md). The [roadmap](../roadmap.md)
> covers plans beyond plugins.

Most of the plugin redesign is already built and documented: hooks on raw
objects ([Hooks](hooks.md)), the `shell` plugin
([Tools](tools.md#bash-and-edit)), keys and the tool runtime
([Keys](tools.md#keys), [Schedulers](schedulers.md)), and kits, the active
list and hook bands ([Kits](kits.md), [Bands](hooks.md#bands)). These parts
are not built:

| Part | What it would add | Section |
|---|---|---|
| Trust | a policy folder that the spec cannot remove, and a `harness_edit` hook point | [Trust](#trust) |
| Sandboxes | a `sandbox:` value that sandbox plugins read | [Sandboxes](#sandboxes) |
| Calls that do not block | a result now, the real result later | [Calls that do not block](#calls-that-do-not-block) |
| Long-lived and concurrent hooks | hooks that keep state, and `before_tool` hooks that run at the same time | [Long-lived and concurrent hooks](#long-lived-and-concurrent-hooks) |
| Front-ends | an ACP server and a terminal UI | [Front-ends](#front-ends) |
| The marketplace index | `index.yaml` and `arx plugin search` | [More of arx plugin](#more-of-arx-plugin) |

## Trust

The agent and arx run as the same user on the same disk, so today the
agent's `bash` can change plugin files and its own `agent.yaml`. A launcher
pin (`--kit`, `--set`) keeps the active list, but not the files.

The plan adds two parts:

- **`--policy DIR`** would name a policy folder that loads first, before the
  spec folder, and that the spec cannot remove.
- **A `harness_edit` hook point**: before a reload, the policy would see each
  harness file that the agent changed, and accept or reject the change. Then
  "the agent may edit prompts, but not hooks" would be one small hook.

## Sandboxes

The spec would get a `sandbox:` value. arx would not read it: it would give
it to each tool and hook as `ARX_SANDBOX`. A sandbox plugin, such as
`sandbox-docker`, would ship its own `bash` and `edit` that read this value,
in a layer above the `shell` plugin, with `replaces: [bash, edit]`. The rule
"the first tool with a name wins" would do the rest.

Only a sandbox that cannot reach the harness files would make a policy safe.

## Calls that do not block

A scheduler plugin would give the model the result `started as c7` at once,
and send the real result later as a note in the inbox. Then a subagent could
start without a wait, and the agent would go on working.

## Long-lived and concurrent hooks

Two changes would make hooks cheaper and let them wait:

- **Long-lived hooks**: a hook could start once for each session and read
  one JSON line for each call, so that it keeps state and starts no process
  for each call.
- **`before_tool` hooks that run at the same time**: today they run for each
  call in call order. Once they run at the same time, a hook could wait for a
  person's approval while the other calls go on.

## Front-ends

- **ACP server (`arx acp`)**: the Agent Client Protocol over stdio, for
  editors and other front-ends. `session/new` and `session/load` would map to
  a new session and `--resume`, `session/prompt` would run the turn loop,
  `session/cancel` would take the Ctrl-C path, and events would become
  `session/update` messages.
- **A terminal UI**: a plugin that talks to `arx acp`.

## More of arx plugin

- **An index**: `index.yaml` at the root of a marketplace would list each
  plugin and kit with its versions, and `arx plugin search` would read it.
- **More commands**: `update`, `eject` (copy a plugin into the spec folder so
  that the agent owns it), other marketplaces by name (`@acme/lint`), and a
  `setup:` command that would run once after an install.
