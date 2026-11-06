# Roadmap

arx stays small: each item below is a new plugin contract or a separate
program, not more code in the core loop.

| | Item | Status |
|---|---|---|
| 1 | Plugin guide and example plugins | **done**: [plugin guide](plugins.md) |
| 2 | External commands | **done**: `arx foo` runs `arx-foo`; `setup`, `init`, `doctor`, `models`, `sessions` and `update` are built this way |
| 3 | Plugin folders and the marketplace | **done**: `plugin.yaml`, layers, `arx plugin`, [`plugins/`](../plugins). More of `arx plugin` is next. |
| 4 | `arx acp`: an Agent Client Protocol server | planned |
| 5 | A TUI plugin | planned |
| 6 | MCP client | planned |
| 7 | `arx climb`: a keep/revert driver | planned |

## More of `arx plugin`

- **`update`, `search` and `eject`.** `eject` copies a plugin into the spec
  folder, so the agent owns it and can change it.
- **Named marketplaces**, such as `@acme/lint`, next to the default one.
- **A `setup:` command** in `plugin.yaml` that runs once after an install.
- **MCP servers in `plugin.yaml`**, once the MCP client exists.

## `arx acp`

An [Agent Client Protocol](https://agentclientprotocol.com) server over stdio,
for editors and custom front-ends:

- `session/new` and `session/load` map to a new session and `--resume`;
- `session/prompt` runs the turn loop;
- `session/cancel` is the Ctrl-C path;
- events become `session/update` messages;
- `permissions: ask` sends `session/request_permission` before tool calls.

It shares one small JSON-RPC module with the MCP client.

## A TUI plugin

A terminal front-end built with [OpenTUI](https://opentui.com) that talks to
`arx acp`. It is a plugin, so it adds nothing to the binary.

## MCP client

MCP servers declared in the spec become tools. Only two built-in tools sit in
the prompt: `mcp_search` finds a tool, and `mcp_select` adds its full schema
on the next turn. Large tool catalogs then cost almost nothing until they are
used.

## `arx climb`

A driver that runs the official evaluation outside the agent's reach, and
keeps or reverts each change itself. Today the agent runs its own scorer, as
in autoresearch; `arx climb` removes the need to trust it.
