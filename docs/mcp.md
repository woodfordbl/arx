# MCP servers

arx runs the MCP servers your spec names and gives the agent their tools
through two tools, `mcp_search` and `mcp_select`.

Use a server when the tools you need already exist as one: an issue tracker,
a database, a browser. Only the two tools sit in the prompt, so a run with
500 MCP tools pays for two schemas until the agent picks the ones it needs.
A spec with no `mcp_servers` costs nothing: no process and no prompt token.

> [!WARNING]
> A stdio server is a program that runs as you, outside any sandbox, with
> your files and your network. The descriptions of its tools reach the
> prompt. Add only servers you trust, and keep tools you don't want out
> with `exclude`.

## Add a stdio server

A stdio server is a program on your machine. arx starts it and talks to it
over its stdin and stdout.

1. Add the server to `agent.yaml`. The keys match the `mcpServers` entries
   of other MCP hosts, so an entry from a server's README pastes in:

   ```yaml
   mcp_servers:
     github:
       command: npx
       args: [-y, "@modelcontextprotocol/server-github"]
       env:
         GITHUB_PERSONAL_ACCESS_TOKEN: "${GITHUB_TOKEN}"
   ```

2. Check the spec:

   ```bash
   arx check
   ```

   ```text
   mcp: github (stdio, not listed)
   ```

3. Start the server once and list its tools:

   ```bash
   arx mcp list --refresh
   ```

   ```text
   github	stdio	41 tools	modern	listed 0 min ago
   ```

`${NAME}` and `${NAME:-default}` in `args`, `env`, `url` and `headers`
expand from arx's environment when the server starts. This keeps tokens out
of `agent.yaml`, which the agent can read. An unset variable with no default
stops the start with an error that names it.

A `command` with a `/` is a path relative to the spec folder. A bare name
is looked up on `PATH`.

## Add an HTTP server

An HTTP server is a URL. arx talks to it through a bridge process, `arx mcp
http`, so HTTP and tokens stay out of the agent process.

```yaml
mcp_servers:
  linear:
    url: https://mcp.linear.app/mcp
    credential: mcp-oauth
    description: Linear issues and projects
```

arx speaks streamable HTTP. It doesn't speak the older HTTP+SSE transport:
`type: sse` is an error. Use the server's streamable HTTP URL, or run a
stdio bridge such as `mcp-remote` as the server's `command`.

The host of each `url` joins `arx check --hosts`, with no `hosts:` entry.

## Sign in to an HTTP server

An HTTP server gets its token from a [credential
program](plugins/credentials.md), the same contract that model calls use.
For OAuth, use the [`mcp-oauth`](../plugins/mcp-oauth) plugin:

```bash
arx plugin add mcp-oauth
arx mcp-oauth login linear
```

Your browser opens the server's sign-in page. After that, the program
refreshes the token by itself. When a call fails with `not signed in`, the
message names the command to run.

A stdio server gets its key from its environment instead. Name a credential
program and the variable that takes its `api_key`:

```yaml
mcp_servers:
  github:
    command: npx
    args: [-y, "@modelcontextprotocol/server-github"]
    credential: op-key
    api_key_env: GITHUB_PERSONAL_ACCESS_TOKEN
```

## How the agent finds tools

The agent searches, selects, then calls:

1. **`mcp_search`** takes words for the action, such as `create issue`, and
   prints the best tools, one per line:

   ```text
   2 of 68 tools match "create issue":
   github__create_issue: Create a new issue in a GitHub repository. (owner, repo, title, body?)
   linear__create_issue: Create an issue in Linear. (title, teamId, description?)
   Call mcp_select with the names you want.
   ```

2. **`mcp_select`** adds tools by name. Their full schemas are in the
   request from the agent's next turn. `drop` removes tools.
3. The agent calls a selected tool like any other tool.

A tool's name is `<server>__<tool>`. Characters outside letters, digits,
`_` and `-` become `_`.

The search is lexical: BM25F over the tools' names, titles, descriptions
and argument names, with no model and no network. Write a `description` for
each server, since it's searched and it names the server in `mcp_search`'s
own description.

At most 32 tools are selected at once. The selection lives in the session
folder, so `--resume` keeps it.

To put tools in the prompt from the first turn, use `preload`:

```yaml
mcp_servers:
  notes:
    command: ./servers/notes.py
    preload: [append_note]   # or true, for every tool of the server
```

Try a search yourself with `arx mcp search "create issue"`. It prints what
the agent would see.

## When servers start

Nothing starts when a session starts. A server starts the first time the
agent needs it: a search or a select when its tool list is not cached, a
call to one of its tools, or a `preload`.

arx caches each server's tool list in `.arx/mcp/<server>.json`. The cache is
fresh for 24 hours, or for the time the server states. A second session
searches the cache and starts nothing.

A server lives as long as the arx process and stops with it. Ctrl-C cancels
the calls that run and keeps the servers. After a crash, the next call
restarts the server. Three exits in 5 minutes make it fail until you change
its entry, and arx tells the agent once.

When you edit an entry, arx restarts that server on its next use. The other
servers keep running.

## Keep tools out

`include` and `exclude` are glob patterns on the server's own tool names.
An excluded tool does not exist: it's not listed, searched or called.

```yaml
mcp_servers:
  github:
    command: npx
    args: [-y, "@modelcontextprotocol/server-github"]
    exclude: ["delete_*"]
```

For one tool, `tools.<server>__<tool>.enabled: false` does the same, and
`tools.<server>__<tool>.timeout` sets its timeout.

A `before_tool` hook gets `server` for an MCP call, so a guard can deny by
server. See [Hooks](plugins/hooks.md).

## Keys

Every call to a server has the keys `["*"]` by default, so its calls run
one at a time and nothing runs beside them. This matches the default of any
tool. For a server whose calls are safe to run together, set `keys`:

```yaml
mcp_servers:
  linear:
    url: https://mcp.linear.app/mcp
    keys: []                  # its calls run in parallel
```

`{arg}` and `host:` work as in a tool schema. arx does not use a server's
`readOnlyHint`, since a server can claim anything. See
[Keys](plugins/tools.md#keys).

## Servers in a plugin

A plugin adds servers with the same key in its `plugin.yaml`:

```yaml
# plugins/github-mcp/plugin.yaml
name: github-mcp
requires: [npx]
mcp_servers:
  github:
    command: npx
    args: [-y, "@modelcontextprotocol/server-github"]
```

- A `command` with a `/`, and `cwd`, are relative to the plugin folder.
- The server gets `ARX_PLUGIN_DIR` in its environment.
- The spec wins key by key: `mcp_servers: {github: {enabled: false}}`
  turns a plugin's server off.
- The plugin's settings in the active list can change its servers:
  `enable: [{github-mcp: {mcp_servers: {github: {args: [...]}}}}]`.

## Common mistakes

| Symptom | Cause | Fix |
|---|---|---|
| `it did not list its tools within startup_timeout` | `npx` or `uvx` downloads the package on the first start. | Raise `startup_timeout` (default `60s`), or install the package first. |
| The server's log has `not JSON-RPC` lines | The server prints to stdout. Only JSON-RPC may go there. | Make the server log to stderr. |
| A token sits in `agent.yaml` | The agent can read its spec. | Use `${NAME}` or a credential program. |
| `the HTTP+SSE transport is not supported` | The entry has `type: sse`. | Use the server's streamable HTTP URL. |
| The model's provider rejects a selected tool | The tool's schema uses a keyword the provider does not take, such as `$defs`. | Rewrite the schema in a `before_model` hook, or `exclude` the tool. |
| `the environment variable X is not set` | `${X}` has no value and no default. | Set it, or write `${X:-default}`. |

Each server's stderr goes to `mcp/<server>.log` in the session folder. An
error result names the file.

## Related

- [`mcp_servers` in agent.yaml](spec.md#mcp_servers): every key.
- [`arx mcp`](cli.md#arx-mcp): list, search and call from the shell.
- [Credentials](plugins/credentials.md): the programs that give servers
  their tokens.
- [Plugin reference](plugins/reference.md): the `mcp.server` and
  `tool.progress` events, and the files arx writes.
