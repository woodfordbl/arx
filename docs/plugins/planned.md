# Planned changes

**Nothing on this page is built yet.** It describes what is planned for the
plugin system, so that plugin authors can plan for it. The contracts can still
change. For what works today, see the other pages of the
[plugin guide](../plugins.md).

Most of the plugin redesign is built and documented on the other pages:
hooks on raw objects ([Hooks](hooks.md)), the `shell` plugin
([Tools](tools.md#bash-and-edit)), keys and the tool runtime
([Keys](tools.md#keys), [Schedulers](schedulers.md)), and kits, the active
list and hook bands ([Kits](kits.md), [Bands](hooks.md#bands)). These parts
are not built:

| Part | What it adds | Section |
|---|---|---|
| Trust | a policy folder that the spec cannot remove, and a `harness_edit` hook point | [Trust](#trust) |
| Sandboxes | a `sandbox:` value that sandbox plugins read | [Sandboxes](#sandboxes) |
| Plugin state | `ARX_STATE_DIR` and `ARX_DATA_DIR` | [Plugin state](#plugin-state) |
| Calls that do not block | a result now, the real result later | [Calls that do not block](#calls-that-do-not-block) |
| More for hooks | long-lived hooks, and `before_tool` hooks that run at the same time | [More for hooks](#more-for-hooks) |
| The marketplace index | `index.yaml` and `arx plugin search` | [More of arx plugin](#more-of-arx-plugin) |

## Trust

The agent and arx run as the same user on the same disk, so the agent's
`bash` can change plugin files and its own `agent.yaml`. A launcher pin
(`--kit`, `--set`) keeps the active list, but not the files.

- **`--policy DIR`** names a policy folder that loads first, before the spec
  folder, and that the spec cannot remove.
- **A `harness_edit` hook point:** before a reload, the policy sees each
  harness file that the agent changed, and accepts or rejects the change.
  Then "the agent may edit prompts, but not hooks" is one small hook.

## Sandboxes

A `sandbox:` value in the spec. arx does not read it: it gives it to each tool
and hook as `ARX_SANDBOX`. A sandbox plugin, such as `sandbox-docker`, ships
its own `bash` and `edit` that read this value, in a layer above the `shell`
plugin, with `replaces: [bash, edit]`. The rule "the first tool with a name
wins" does the rest. Only a sandbox that cannot reach the harness files makes
a policy safe.

## Plugin state

Two folders for a plugin's own files:

| Variable | Folder | For |
|---|---|---|
| `ARX_STATE_DIR` | `$ARX_SESSION_DIR/plugins/<name>/` | state for one session, such as a plan or a scheduler's counters |
| `ARX_DATA_DIR` | `.arx/state/<name>/` | data across sessions, such as a search index or climb results |

## Calls that do not block

A scheduler plugin gives the model the result `started as c7` at once, and
sends the real result later as a note in the inbox. Then a subagent can start
without a wait, and the agent goes on working.

## More for hooks

- **Long-lived hooks:** a hook can start once for each session and read one
  JSON line for each call, so that it keeps state and starts no process for
  each call.
- **`before_tool` hooks that run at the same time:** today they run for each
  call in call order. When they run at the same time, a hook may wait for a
  person (approval), and the other calls do not wait for it.

## Other plans

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

- **An index:** `index.yaml` at the root of a marketplace lists each plugin
  and kit with its versions, and `arx plugin search` reads it.
- `update`, `eject` (copy a plugin into the spec folder so that the agent owns
  it), other marketplaces by name (`@acme/lint`), and a `setup:` command that
  runs once after an install.

See also the [roadmap](../roadmap.md).
