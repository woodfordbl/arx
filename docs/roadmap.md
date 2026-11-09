# Roadmap

The roadmap lists what arx has shipped from its plan and what it plans to
add next. arx stays small: each item is a new plugin contract or a separate
program, not more code in the core loop.

| # | Item | Status |
|---|---|---|
| 1 | Plugin guide and example plugins | **done**: [plugin guide](plugins.md) |
| 2 | External commands | **done**: `arx foo` runs `arx-foo`; `setup`, `init`, `doctor`, `models`, `sessions` and `update` are built this way |
| 3 | Plugin folders and the marketplace | **done**: `plugin.yaml`, layers, `arx plugin`, [`plugins/`](../plugins). More of `arx plugin` is next. |
| 3a | Credential and adapter plugins | **done**: [credentials](plugins/credentials.md), [adapters](plugins/adapters.md), `hosts:` and `arx check --hosts`, and the [`chatgpt`](../plugins/chatgpt) plugin for ChatGPT plan usage |
| 4 | `arx acp`: an Agent Client Protocol server | planned |
| 5 | A TUI plugin | planned |
| 6 | MCP client | planned |
| 7 | `arx climb`: a keep/revert driver | **done**: [`arx climb`](climb.md) and the `climber` kit |
| 8 | Installer and settings menus | planned for 0.2.0 |

None of the planned items exist yet. The sections that follow describe each
design as it stands.

## More of `arx plugin`

The plan adds these to `arx plugin`:

- **`update`, `search` and `eject`**: `eject` will copy a plugin into the
  spec folder, so the agent owns it and can change it.
- **Named marketplaces**: more marketplaces next to the default one, with
  plugins named like `@acme/lint`.
- **A `setup:` command**: a command in `plugin.yaml` that will run once after
  an install.
- **MCP servers in `plugin.yaml`**: once the MCP client exists.

## `arx acp`

`arx acp` will be an [Agent Client Protocol](https://agentclientprotocol.com)
server over stdio, for editors and custom front-ends. The plan maps ACP to
arx like this:

- `session/new` and `session/load` will map to a new session and `--resume`.
- `session/prompt` will run the turn loop.
- `session/cancel` will take the Ctrl-C path.
- Events will become `session/update` messages.
- `permissions: ask` will send `session/request_permission` before tool
  calls.

It will share one small JSON-RPC module with the MCP client.

## A TUI plugin

The TUI plugin will be a terminal front-end built with
[OpenTUI](https://opentui.com) that will talk to `arx acp`. Because it is a
plugin, it will add nothing to the binary.

## MCP client

The MCP client will turn MCP servers declared in the spec into tools. Only
two built-in tools will sit in the prompt: `mcp_search` to find a tool, and
`mcp_select` to add its full schema on the next turn. Large tool catalogs
will then cost almost nothing until the agent uses them.

## Installer and settings menus

`install.sh` will go on into `arx setup` on a terminal, and `arx setup` will
become a menu you drive with the arrow keys: a short wizard the first time,
and a settings menu after that for the provider, key, model, kit, plugins,
updates and doctor. The menus will be drawn by `pick`, a small C program
next to the commands, so the core binary gains nothing and its startup does
not change. Every flag that works today will keep working with no prompt.
