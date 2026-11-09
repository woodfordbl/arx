# mcp-client: MCP servers as tools for 0.2.0

Slug: `mcp-client`. Covers roadmap item 6 ("MCP client"), the "MCP client"
row of `docs/plugins/planned.md`, and the "MCP servers in `plugin.yaml`"
bullet of the roadmap's "More of `arx plugin`" list (the `plugin.yaml` side
is built by `arx-plugin`, with the shape this plan defines).

## Goal

arx connects to the MCP servers that the spec names and gives the model
their tools. Only two tools sit in the prompt, `mcp_search` and
`mcp_select`, so a run with 500 MCP tools pays for two tool schemas until
the agent picks the ones it needs. At the end of 0.2.0:

- `mcp_servers:` in `agent.yaml`, `config.yaml` and `plugin.yaml` declares
  stdio and HTTP servers, in the shape other MCP hosts use, so a server
  entry from a server's README pastes in as it is.
- arx speaks the current MCP revision, `2026-07-28` (stateless, no
  handshake, `server/discover`), and falls back to the `initialize`
  handshake of `2025-11-25` and earlier, which most servers still use.
- A server starts the first time the agent needs it, lives as long as the
  arx process, restarts after a crash, and stops when arx stops.
- An MCP call goes through the same runtime as any tool: `before_tool` and
  `after_tool` hooks, keys, timeouts, Ctrl-C, head and tail output, and
  `tool.start` and `tool.end` events.
- HTTP servers and their sign-in stay out of the agent process: arx runs
  `arx mcp http` as a bridge for each `url:` server, and credential programs
  give the tokens. A new `mcp-oauth` plugin does the OAuth sign-in.
- One JSON-RPC module, `src/base/rpc.c`, serves this client and `arx acp`.

What stays the same: a spec with no `mcp_servers` costs nothing, not one
process and not one prompt token. arx stays one C binary with no runtime:
the client works in the static musl build without Node or Python. The loop
in `src/agent/loop.c` gets two calls, not a new phase.

Out of scope for 0.2.0: resources, prompts, sampling, elicitation and the
other `input_required` requests, roots, the Tasks extension, the deprecated
HTTP+SSE transport of `2024-11-05`, and sharing one server between a parent
and its subagents.

## Current state

- **No MCP code and no JSON-RPC code exist.** The only mentions are in the
  docs: `docs/roadmap.md:15` (item 6, planned), `:31` (servers in
  `plugin.yaml`), `:46` (the shared JSON-RPC module) and `:54-59`;
  `docs/plugins/planned.md:28` and `:95-99`.
- **Tools are files.** `ToolsBuild` (`src/harness/tools.c:340`) builds the
  tool set from `tools/` in every layer, plus subagents (`AddConfigured`,
  `tools.c:309`). `ToolKind` has two kinds, exec and agent
  (`src/harness/harness.h:247-250`). A `tools.<name>` entry with no file is
  reported as "configured but tools/x is missing" (`tools.c:333`).
- **Every call is a process.** `ToolStart` (`src/harness/tool_exec.c:263`)
  starts a child; an unknown name ends at once with "unknown tool"
  (`tool_exec.c:274`). The runtime collects each running call's child and
  polls them (`src/agent/tool_calls.c:298-310`: `ToolChild`, `ProcPoll`,
  `ProcDone`), and leaves the loop when no child runs (`tool_calls.c:301`).
  An MCP call is a request on a shared connection, with no child of its own.
- **Keys**: a tool that declares none gets `["*"]` (`src/harness/keys.c:86-87`);
  an unknown tool gets `[]`.
- **The request's tools** are `ToolsJson(&a->tools)`
  (`src/agent/model_call.c:32`), rebuilt only on a reload (`loop.c:63`,
  `run.c:74`, `check.c:264`). Nothing adds a tool between reloads.
- **A long-lived child per session exists**: the scheduler plugin
  (`src/agent/scheduler.c:85-111`), with `open_in`, `keep_on_interrupt` and
  its stdout lines parsed in `SchedPoll` (`scheduler.c:187`). Its pipes are
  served only by the runtime's `ProcPoll`; during a model call nothing
  drains them. `async-calls` plans a registry of session-lived children
  that every `ProcPoll` round serves (`plans/0.2.0/async-calls.md`, step 1).
- **`Proc`** (`src/base/base.h:154-168`) has no working-folder field and no
  way to close a running child's stdin. `BufferSink` stops at 1 MB
  (`base.h:61`).
- **Credentials**: one cached value per process
  (`src/model/credential.c:26-28`). The program gets `{reason, model, base_url}` (`credential.c:116-120`). The
  value reaches curl in a 0600 header file (`src/model/llm.c:66-80`).
- **`plugin.yaml`**: `kPluginFields` (`src/harness/fields.c:97-111`).
  `Adopt` merges a plugin under the spec, makes program paths absolute
  (`src/harness/plugins.c:184-187`), adds hosts (`plugins.c:145`), and lets
  settings override `tools` and `hooks` (`plugins.c:167`). Validation runs
  after the merge (`src/harness/spec.c:270-272`), so a plugin's values meet
  the spec's field table.
- **`before_model` may print `tools`** (`src/harness/hooks.c:27`). That is
  the only way a plugin could add a tool between reloads today.
- **Line limits**: `harness.h` is at 400 lines, the lint maximum;
  `tool_calls.c` is at 345.

## Design

### 1. Where the client lives

The client is a module of the binary, `src/mcp/`, outside the turn loop. It
plugs into the tool runtime at three points (the tool set, `ToolStart` and
the runtime's poll) and into the loop at two (a pump before each model call,
and a sync after each reload). HTTP and sign-in are not in the agent
process: HTTP is a separate program, `arx mcp http`, in the binary the way
`arx tool bash` is, and tokens come from credential programs in plugins.

| Option | Why not |
|---|---|
| A plugin: one gateway process in Node or Python with an official SDK | It needs two core contracts that don't exist (a long-lived tool process, and tools that appear between reloads), a language runtime on every machine, and a daemon that can outlive arx. The calls would still have to come back through the core. |
| A plugin made of hooks: `before_model` adds the selected schemas, `before_tool` renames each call to a bridge tool | Every MCP call shows `[ran as: mcp_call ...]`, starts two processes, loses its keys, and the bridge tool still needs a long-lived server holder. |
| Everything in the agent process, HTTP included | The agent would run credential programs (up to 60 seconds, blocking every parallel call), hold legacy HTTP sessions, and parse a second SSE dialect. A bug there stops the agent. |
| **Chosen**: stdio client in the binary, HTTP as a bridge program, auth in plugins | The agent process speaks one transport, newline-delimited JSON-RPC over pipes, which `arx acp` needs too. Server processes are arx's children, so they share its process groups, its Ctrl-C path and its exit. |

Cost: about 2,400 lines of C in new files and 350 lines of edits, and about
35 KB of binary (183 KB today; the macOS budget is 400 KB).

### 2. The spec key: `mcp_servers`

`mcp_servers` is a map from a server name to a server. It is valid in
`agent.yaml`, `config.yaml` and `plugin.yaml`, with one field table. The
keys match the `mcpServers` entries of other hosts (`command`, `args`,
`env`, `url`, `headers`, `type`), so a pasted entry validates:

```yaml
# agent.yaml
mcp_servers:
  github:
    command: npx
    args: [-y, "@modelcontextprotocol/server-github"]
    credential: op-key                       # its api_key goes in the variable below
    api_key_env: GITHUB_PERSONAL_ACCESS_TOKEN
    exclude: ["delete_*"]
  linear:
    url: https://mcp.linear.app/mcp
    credential: mcp-oauth                    # from the mcp-oauth plugin
    description: Linear issues and projects
    keys: []                                 # its calls may run in parallel
  notes:
    command: ./servers/notes.py              # a path relative to the spec folder
    preload: [append_note]                   # in the prompt from the first turn
```

| Key | Type | Default | Description |
|---|---|---|---|
| `type` | string | from `command` or `url` | `stdio` or `http`. Optional; for pasted entries. `sse` is an error that says to use the server's streamable HTTP URL. |
| `command` | string | | stdio: the program. A bare name is looked up on `PATH`; a name with `/` is relative to the spec folder, or to the plugin folder in `plugin.yaml`. |
| `args` | string list | `[]` | stdio: its arguments. |
| `env` | map of strings | | stdio: variables added to its environment. |
| `cwd` | string | the folder arx runs in | stdio: its working folder, relative to the spec folder. |
| `url` | string | | http: the MCP endpoint. |
| `headers` | map of strings | | http: headers sent on every request. |
| `credential` | string | | A name from `credentials:` or a program path, as for `endpoint.credential`. |
| `api_key_env` | string | | stdio: the variable that gets the credential's `api_key`. |
| `description` | string | the first sentence of the server's `instructions` | One line in `mcp_search`'s description. |
| `include` | string list | every tool | Glob patterns on the server's own tool names. Only matching tools exist. |
| `exclude` | string list | | Glob patterns. Matching tools never exist: they are not listed, searched or called. |
| `preload` | boolean or string list | `false` | Tools selected from the first turn. `true` selects all of the server's tools. |
| `keys` | string list | `["*"]` | The keys of every call to this server. `{arg}` and `host:` work as in a tool schema. |
| `timeout` | duration | `120s` | Longest call. `tools.<server>__<tool>.timeout` wins for one tool. |
| `startup_timeout` | duration | `60s` | Longest time from start to the first tool list. `npx` downloads count. |
| `enabled` | boolean | `true` | `false` turns the server off. |

- **`${NAME}`** and **`${NAME:-default}`** in `args`, `env`, `url` and
  `headers` values expand from arx's environment when the server starts.
  An unset variable with no default stops the start with an error that
  names it. `arx check` prints the values unexpanded. This keeps tokens out
  of `agent.yaml`, which the agent can read.
- **Validation** (`src/harness/validate.c`): a server name uses `kNameChars`,
  1 to 32 characters, and no `__`. Exactly one of `command` and `url`.
  `type` must agree with them. `url` is `http` or `https`; `arx check` warns
  about `http` to a host that is not loopback. `api_key_env` needs
  `command` and `credential`. `credential` must resolve. Every `env` and
  `headers` value is a string. Unknown keys get the "did you mean" hint.
- **Merge**: `config.yaml`, then plugins, then the spec, server by server
  and key by key, as `SpecMergeUnder` merges any map. So the spec can change
  one key of a plugin's server: `mcp_servers: {github: {enabled: false}}`,
  or one `env` value.
- **Hosts**: the host of each `url` joins `arx check --hosts` with no
  `hosts:` entry. A stdio server's hosts go in `hosts:`.

### 3. `mcp_servers` in `plugin.yaml`

The same key and field table. What differs from the spec:

- A `command` or `cwd` that contains `/` is relative to the plugin folder.
  `Adopt` makes it absolute, as it does for `compactors`.
- `Adopt` adds `ARX_PLUGIN_DIR` to the server's `env`, so a script can find
  its files.
- The plugin's settings in the active list may override its servers, as
  they override `tools` and `hooks`: `enable: [github-mcp: {mcp_servers:
  {github: {args: [...]}}}]`.
- Only plugins in the active list add servers.
- A server that needs packages declares the runtime in `requires:`
  (`[npx]`, `[uvx]`) and installs them with `setup:` (`arx-plugin`).
- `arx check --plugin DIR` prints `mcp_servers=github linear`.

`arx-plugin` assumed this shape in its section 11, with two differences
this plan settles: the merge is key by key, not only name by name, and
`${NAME}` expansion is part of the contract.

### 4. Tool names

The model sees an MCP tool as `<server>__<tool>`, such as
`github__create_issue`. arx maps the name back to the server's own name for
each call.

- Characters outside letters, digits, `_` and `-` (MCP allows `.`) become
  `_`.
- When the result is longer than 64 characters, or two tools of a server
  map to one name, arx keeps the first 55 characters and adds `_` and 6 hex
  digits of a hash of the server's tool name.
- A layer's tool file with the same name wins, as the first tool with a
  name always does; `arx check` reports the hidden MCP tool.
- `tools.<server>__<tool>` options (`timeout`, `enabled: false`) apply to
  MCP tools. `AddConfigured` no longer reports such an entry as a missing
  file when `<server>` is a configured server.

### 5. `mcp_search` and `mcp_select`

With at least one enabled server, arx adds two tools after `ToolsBuild`,
unless a layer has a tool of the same name. Both have `keys: []`.

`mcp_search` finds tools and prints their names:

```json
{"description": "Search the tools of these MCP servers: github (GitHub issues, pull requests and repositories), linear (Linear issues and projects). Then call mcp_select with the names you need; their full schemas are in your tools from the next turn. An empty query lists the servers.",
 "parameters": {"type": "object", "properties": {
   "query": {"type": "string", "description": "Words for the action, such as \"create issue\"."},
   "server": {"type": "string", "description": "Search only this server."},
   "limit": {"type": "integer", "description": "Most results: default 8, at most 25."}},
  "required": ["query"]}}
```

```text
4 of 68 tools match "create issue":
github__create_issue: Create a new issue in a GitHub repository. (owner, repo, title, body?, labels?)
linear__create_issue: Create an issue in Linear. (title, teamId, description?) [selected]
github__create_pull_request: Create a new pull request. (owner, repo, title, head, base, body?)
linear__create_comment: Add a comment to an issue. (issueId, body)
Call mcp_select with the names you want.
```

Each line has the name, the first sentence of the description (at most 160
bytes) and the arguments, with `?` for optional ones (at most 6, then `…`).
An empty query prints each server with its description, its tool count, or
"not listed yet".

`mcp_select` adds tools to the prompt:

```json
{"description": "Add MCP tools by the names mcp_search prints. Their full schemas are in your tools from your next turn, and you call them like any tool. drop removes tools you no longer need.",
 "parameters": {"type": "object", "properties": {
   "names": {"type": "array", "items": {"type": "string"}},
   "drop": {"type": "array", "items": {"type": "string"}}}}}
```

- The result says what it added and dropped:
  `Selected github__create_issue. 3 MCP tools are selected.`
- An unknown name is an error result with the 3 closest names from the
  ranking in section 6.
- At most 32 tools are selected at once. Over that, the result is an error
  that lists the selection and asks for `drop`.
- The selection lives in `$ARX_SESSION_DIR/mcp/selected.json`, a JSON list
  of names, so `--resume` keeps it. arx reads it again when its modification
  time changes, before each model call.
- The selected tools follow the other tools in the request, in selection
  order, so earlier selections keep their place.
- arx sends the server's `inputSchema` without `$schema` and without
  `x-mcp-header` keys, and the full `description`.
- A call to a catalog tool that is not selected runs, and arx selects it,
  so the history never holds a call to a tool the request does not list.
  A name of the form `<server>__<tool>` for a configured server whose tools
  are not listed yet is accepted the same way: the server starts and lists
  before the call.

To replace either tool, put a tool file of the same name in a layer. The
files in section 11 are the interface: a replacement `mcp_search` reads
`.arx/mcp/<server>.json`, and a replacement `mcp_select` writes
`selected.json`.

### 6. How `mcp_search` ranks

A lexical BM25F score over the catalog, computed on each search with no
index. 2,000 tools take about 1 ms.

1. **Documents**: one per tool, with weighted fields: the tool's own name
   ×3, `title` ×2, the server's name ×2, the server's `description` ×1, the
   tool's `description` ×1, argument names ×1 and argument descriptions
   ×0.5.
2. **Tokens**: lower case; split on anything that is not a letter or digit,
   and on camelCase and digit boundaries (`createIssue` and `HTTPServer` give
   `create issue` and `http server`); drop a short stopword list (`a`,
   `an`, `the`, `to`, `of`, `for`, `in`, `on`, `and`, `or`, `with`, `by`,
   `from`, `is`, `it`); strip `ies` to `y`, then `es`, `s`, `ing` and `ed`
   from words longer than 4 letters.
3. **Score**: for each query token t,
   `idf(t) × tf'(k1 + 1) / (tf' + k1(1 − b + b × len'/avglen'))`, where
   `tf'` and `len'` are the weighted sums over the fields, `k1 = 1.2`,
   `b = 0.75` and `idf(t) = ln(1 + (N − n + 0.5)/(n + 0.5))`.
4. **Prefixes**: a query token of 3 or more letters that is not in the
   document, but starts one of its tokens, counts at half weight (`repo`
   finds `repository`).
5. **Coverage**: the score is multiplied by `1 + matched/total` query
   tokens, so a tool that matches every word ranks above one that repeats
   one word.
6. **Exact names**: a query equal to a tool's name, either form, ignoring
   case, ranks that tool first.
7. **Order**: score, then the server's order in `mcp_servers`, then the
   server's own list order. A score of 0 is not shown.

`arx mcp search QUERY` runs the same function, for tests and for tuning
descriptions. A semantic search can replace `mcp_search` as a layer tool;
the plan does not build one.

### 7. Server lifecycle

Nothing starts when a session starts. A server starts when the agent first
needs it:

| Need | What starts |
|---|---|
| `mcp_search` or `mcp_select` | each server whose cached list is missing, stale or from another config |
| a call to one of its tools | that server |
| `preload: true` or a preloaded name not in the cache | that server, before the first model call |

A cached list is fresh while its config hash matches and its age is under
the server's `ttlMs`, or 24 hours when the server gave none. Each start
lists the tools again and rewrites the cache.

```text
          start                ready                  exit
  idle ─────────▶ starting ──────────▶ ready ──────────────▶ exited
                     │                   ▲                     │
                     │ fails             └─── next need ───────┘
                     ▼                                         │ 3 exits in 5 min
                  failed ◀─────────────────────────────────────┘
```

- **Reuse**: a server lives as long as the arx process, across turns and
  across the messages of an interactive session. `--resume` is a new
  process with new servers; it keeps the cache, the era and the selection.
- **Subagents** are their own arx processes, so they start their own
  servers. Lazy starts keep that cheap.
- **Hot reload**: after a reload, `McpSync` hashes each entry. A changed
  server stops and starts again on the next need; a removed one stops; an
  unchanged one keeps running. A server with calls in flight changes when
  they end.
- **Crash**: when a server exits, each call in flight on it ends with an
  error result that gives the exit code, the last 5 lines of its log and the
  log's path. arx does not repeat a `tools/call`, since it may have had an
  effect. A `tools/list` in flight is sent again after the restart. The next
  need restarts the server, after 0, 2 and then 8 seconds. Three exits in 5
  minutes, or a start that fails (cannot spawn, `startup_timeout`, or both
  handshakes fail), make the server `failed`: its calls end at once with the
  reason, and a `[harness]` note tells the agent once. A changed entry or a
  new arx process clears it.
- **Stop**: at the end of the session, after a reload that changes or
  removes the server, and after a failure. arx closes every server's stdin
  (`ProcClose`), waits up to 2 seconds for all of them, then stops the rest with SIGTERM to
  the process group and SIGKILL 3 seconds later. A server runs in its own
  process group, so `npx` and its `node` child stop together.
- **Ctrl-C** cancels the calls in flight (section 10) and keeps the servers:
  they start with `keep_on_interrupt`, so an interactive session goes on
  with them.
- **Credentials that expire**: when a stdio server's credential gave
  `expires_at`, arx restarts the server before the next call after that
  time, with a fresh value.

### 8. stdio transport

A server is a child started with `ProcStart`: `argv` is `command` and
`args`, `open_in` and `keep_on_interrupt` are set, its working folder is
`cwd`, and its environment is arx's plus the `ARX_*` variables of tools,
`ARX_PLUGIN_DIR` for a plugin's server, and `env`. Its stderr goes to
`$ARX_SESSION_DIR/mcp/<server>.log`. The child joins the session-lived
registry (`ProcKeep`), so its pipes drain while arx waits for the model.
Its stdout goes to a `LineSink`, and `McpPump` takes each line with
`LinePop` and feeds it to the JSON-RPC module. No MCP code runs inside
`ProcPoll`.

Before the start, when the entry has `credential`, arx runs the credential
program with `{"reason": "start", "server": "github"}` and puts its
`api_key` in the `api_key_env` variable.

**Which era the server speaks**: the cache in `.arx/mcp/<server>.json`
records it per config hash, so only the first start probes:

1. Send `server/discover` with arx's `_meta`, and wait up to 5 seconds (or
   `startup_timeout` when the cache says modern).
2. A `DiscoverResult`: the server is modern. Use `2026-07-28` if it is in
   `supportedVersions`, else stop with an error that lists them.
3. An `UnsupportedProtocolVersion` error (`-32022`): the server is modern
   but does not speak `2026-07-28`. Stop with an error that lists its
   `supported` versions.
4. Any other error, or no answer: the server is legacy. Send `initialize`
   with `{"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo":
   {"name": "arx", "version": ARX_VERSION}}` and the rest of the startup
   time. Accept a result version of `2025-11-25`, `2025-06-18`,
   `2025-03-26` or `2024-11-05`, then send `notifications/initialized`.

The fallback never depends on one error code, as the spec requires.

**Every modern request** carries:

```json
"_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
          "io.modelcontextprotocol/clientInfo": {"name": "arx", "version": "0.2.0"},
          "io.modelcontextprotocol/clientCapabilities": {}}
```

arx declares no client capabilities: no sampling, elicitation or roots.

**After the era is known**:

1. If the server's capabilities have `tools.listChanged`: a modern server
   gets `subscriptions/listen` with `{"notifications": {"toolsListChanged":
   true}}`, which stays in flight for the server's life; a legacy server
   sends `notifications/tools/list_changed` unasked.
2. `tools/list`, following `nextCursor` for up to 50 pages. arx applies
   `include` and `exclude`, writes the cache and sends `mcp.server` with
   `state: "ready"`.
3. The calls that waited for the server go out.

**From the server**:

| Message | What arx does |
|---|---|
| a response | ends the matching request |
| `notifications/tools/list_changed` | lists again; selected tools take their new schemas from the next model call; a selected tool that is gone stays in the prompt, and its calls fail with "the server no longer has this tool" |
| `notifications/progress` | a `tool.progress` event for the call |
| `notifications/message` | a line in the server's log |
| `notifications/subscriptions/acknowledged` | ignored |
| legacy `ping` request | answered with `{}` |
| any other request | answered with error `-32601` |
| a line that is not JSON-RPC | a line in the log |

### 9. HTTP transport: `arx mcp http`

For a `url:` server, arx starts `arx mcp http` as the server's command.
The bridge speaks modern MCP over stdio to arx, so the agent process has one
transport. The entry, after `${NAME}` expansion, is in `ARX_MCP_SERVER` as
JSON: not on the command line, because `headers` can hold a token and
`ps` shows arguments.

The bridge is built on `HttpStart` and `HttpFinish`, the platform layer of
wasm phase A (`plans/0.2.0/wasm.md`, "The platform layer"), which lands in
wave 1, before this work. Each request from arx becomes one `HttpStart`
with `method` `POST`, the headers below as lines, the JSON-RPC message as
`body`, `timeout` from the entry (0 for `subscriptions/listen`), `adapter`
NULL, and `tmp_dir` `$ARX_SESSION_DIR/mcp/`. `on_body` gets the reply as it
streams. The returned `ProcChild` goes into the bridge's `ProcPoll` loop
with its stdin, so requests run in parallel. Natively that is one curl
child per request, and `HttpStart` writes and deletes the 0600 header file,
so the bridge never handles a token file. In the browser build (phase B)
the same code becomes a `fetch`, so a remote server that allows CORS can
work there.

| Header | Value |
|---|---|
| `Content-Type` | `application/json` |
| `Accept` | `application/json, text/event-stream` |
| `MCP-Protocol-Version` | `2026-07-28`, or the legacy version |
| `Mcp-Method` | the method |
| `Mcp-Name` | `params.name` for `tools/call`; `=?base64?...?=` when it is not plain ASCII |
| `Mcp-Param-{Name}` | each argument that the tool's schema marks with `x-mcp-header`, encoded by the spec's rules |
| `Authorization` | from the credential program |
| your `headers` | from the entry |

- **Replies**: `application/json` is one message. `text/event-stream` is a
  series of events; each `data:` event is one message, and the bridge
  writes each one as a line as soon as it arrives in `on_body`, so
  `notifications/progress` reaches arx during the call. `202` ends a
  notification. The bridge reads `Content-Type` from the response headers
  (see "What the bridge needs from `HttpStart`" in this section).
- **`x-mcp-header`**: the bridge reads each `tools/list` result it forwards,
  drops tools whose `x-mcp-header` breaks the spec's rules (with a log
  line), and keeps each tool's header paths for its calls.
- **Cancel**: arx's `notifications/cancelled` makes the bridge call
  `HttpFinish` on that request while it runs, which stops it and closes the
  stream: the HTTP way to cancel.
- **Legacy servers**: when the first request gets `400`, `404` or `405`
  without a modern JSON-RPC error in the body, the bridge sends
  `initialize`, keeps the `Mcp-Session-Id`, sends
  `notifications/initialized`, and answers arx's `server/discover` with a
  `DiscoverResult` built from the `InitializeResult`. Later requests carry
  the session id and the legacy version. A `404` on a request with a
  session id starts a new session and repeats the request once. At exit the
  bridge sends `DELETE` for the session, with a 2-second limit, once
  `HttpStart` takes that method (see the table at the end of this section).
  The bridge
  opens no `GET` stream, so a legacy HTTP server's list changes show at the
  next start.
- **Retries**: `server/discover`, `tools/list` and `initialize` are retried
  3 times, after 1, 4 and 16 seconds, when `HttpResult.net_error` is 6, 7,
  28, 35, 52 or 56, and on HTTP 429, 502, 503 and 504 (`retry_after` wins
  when the server sends it). `tools/call` is not retried.
- **Errors** reach arx as JSON-RPC errors with code `-32000` and a message
  the model and you can act on, such as `401 from mcp.linear.app: sign in
  with arx mcp-oauth login linear`.
- **Files**: the bridge's own log lines go to the server's log.

**What the bridge needs from `HttpStart`.** The wasm plan's interface gives
three of the five things the bridge needs:

| Need | In `HttpStart` as planned | What to add |
|---|---|---|
| A streamed body, for SSE | yes: `on_body` | |
| Cancel a request in flight | yes: `HttpFinish` stops it | |
| Response headers: `Content-Type`, `Mcp-Session-Id` (legacy), `WWW-Authenticate` (for the credential's `challenge`) | no: `HttpResult` has only `status` and `retry_after` | `Buffer headers` in `HttpResult`, the raw header lines of the last response. Better still, an `on_headers` callback with the status and the lines before the first body byte, so the bridge knows JSON from SSE before it parses. Without the callback, the bridge reads the first body byte: `{` is JSON, anything else is SSE |
| `DELETE`, to end a legacy session | no: `method` is `GET` or `POST` | any method string. Without it, the bridge skips the `DELETE`; the spec makes it optional, and the server's session expires |
| Which curl runs, with no spec | not said: `llm.c` takes it from `endpoint.curl` | `HttpStart` falls back to `$ARX_CURL`, then `curl`, when the request names none. The bridge has no spec root, and the tests point `$ARX_CURL` at `tests/fake-curl` |

Any other stdio bridge works in its place: `command: npx, args:
[mcp-remote, URL]` is a stdio server to arx.

### 10. Calls

**Start**: `ToolStart` sees a `kToolMcp` tool and calls `McpCallStart`. If
the server is not ready, the call waits in the server's queue (its timeout
already runs). The request is `tools/call` with the server's own tool name,
the arguments, and a `progressToken` equal to the request id.

**Result for the model**:

| In the result | What the model sees |
|---|---|
| `text` items | the text, items joined by newlines |
| `image` or `audio` | `[image/png, 34 KB: .arx/sessions/<id>/tool-0007-1.png]`, with the data saved to that file |
| `resource_link` | `[resource: URI (name, mimeType)]` |
| embedded `resource` | its `text`, or its `blob` saved to a file as for images |
| only `structuredContent` | its JSON, unformatted |
| `isError: true` | the text, and the call is an error |
| `resultType: "input_required"` | an error: `the server asked for input arx cannot give (elicitation/create): <message>` |
| a JSON-RPC error | an error: `MCP error <code>: <message>` |

The text then gets the same head and tail cut as any tool, with the full
text in `tool-NNNN.out` (the cut moves from `CaptureText` to a shared
function in `tool_exec.c`).

**Timeout**: at `timeout`, arx sends `notifications/cancelled` with the
request id and `"reason": "timeout"`, forgets the request, and the result
is `[timed out after 120s; arx cancelled the call]`. The server keeps
running.

**Ctrl-C**: the same, with `[interrupted]`.

### 11. Hooks, keys, events and files

- **`before_tool`** gets `{id, name, args, keys, server}` for an MCP call:
  `server` is new and input only. A guard can deny every write to one
  server by name prefix or by `server`. A hook may rename a call to or from
  an MCP tool; arx runs the final name.
- **`after_tool`** works as for any tool.
- **Keys**: `KeysFor` gives an MCP tool its server's `keys`, `["*"]` by
  default. arx does not trust `readOnlyHint` for keys, since annotations
  are untrusted; a server you trust gets `keys: []` in its entry.
- **Events**:

  | Event | Fields |
  |---|---|
  | `mcp.server` | `server`, `state` (`start`, `ready`, `exit`, `failed`, `stop`), `era`, `version`, `tools`, `secs`, `code`, `error` |
  | `tool.start`, `tool.end` | gain `server` for an MCP call |
  | `tool.progress` (new) | `id`, `name`, `server`, `progress`, `total`, `message` |

- **Files**:

  | Path | Holds |
  |---|---|
  | `.arx/mcp/<server>.json` | the cache: config hash, era, version, `instructions`, list time, `ttlMs`, and the tools as listed. A core command's files live in `.arx/<command>/`, as the release plan settles, not in `.arx/data/`, so `plugin-state`'s check for orphaned plugin folders does not see it |
  | `$ARX_SESSION_DIR/mcp/selected.json` | the selection |
  | `$ARX_SESSION_DIR/mcp/<server>.log` | the server's stderr, its log messages and lines that were not JSON-RPC |

### 12. Auth

MCP's own rule is the split: a stdio server gets credentials from its
environment, and an HTTP server gets OAuth bearer tokens. Both come from the
credential programs that model calls use.

**The credential contract** (`docs/plugins/credentials.md`) gains input
fields. Output and exit codes stay the same:

```json
{"reason": "rejected", "server": "linear", "url": "https://mcp.linear.app/mcp",
 "base_url": "https://mcp.linear.app/mcp", "status": 401,
 "challenge": "Bearer resource_metadata=\"https://mcp.linear.app/.well-known/oauth-protected-resource\", scope=\"read write\""}
```

| Field | When |
|---|---|
| `server` | always, for an MCP server |
| `url` | HTTP servers; `base_url` holds the same value for programs written for model calls |
| `status`, `challenge` | `reason: rejected`: the HTTP status (401 or 403) and the `WWW-Authenticate` value |

- **stdio**: the program runs before each start. Its `api_key` goes in
  `api_key_env`; `headers` are ignored.
- **HTTP**: the bridge runs the program before its first request, when less
  than 60 seconds are left before `expires_at`, and after a 401 or 403,
  then repeats the request once. A second 401 or 403 ends the request with
  an error. Each bridge serves one server, so the one-value cache in
  `credential.c` fits as it is.
- **Exit 75** retries later, as for model calls; any other failure ends the
  request with the program's stderr, which tells the model and you what to
  run.

**The `mcp-oauth` plugin** does the OAuth 2.1 sign-in. It is Python, like
`chatgpt`:

```text
plugins/mcp-oauth/
  plugin.yaml                # credentials: {mcp-oauth: credentials/mcp-oauth}; requires: [python3, curl]
  credentials/mcp-oauth      # prints {"headers": {"Authorization": "Bearer ..."}, "expires_at": N}
  commands/arx-mcp-oauth     # arx mcp-oauth login SERVER [--scope S] [--no-browser] | logout SERVER | status
  lib/mcp_oauth.py
  tests/test_mcp_oauth.py
```

- **`login`** finds the server's `url` with `arx mcp list --json`, sends a
  request with no token, reads `resource_metadata` and `scope` from the 401,
  fetches the protected resource metadata (RFC 9728), then the
  authorization server's metadata (RFC 8414, then OpenID Connect discovery).
  It gets a client id in the spec's order: a pre-registered id from the
  plugin's settings, the Client ID Metadata Document at
  `https://arx-documentation.vercel.app/oauth/mcp-client.json`, or dynamic
  registration
  with `application_type: native`. It runs PKCE with S256 and the
  `resource` parameter, listens on `http://127.0.0.1:<port>/callback`,
  opens the browser (or prints the URL with `--no-browser`), checks `state`
  and `iss` (RFC 9207), and stores the tokens keyed by issuer and resource
  in `$ARX_CONFIG_DIR/mcp-oauth/`, mode 0600.
- **The credential program** never opens a browser. It refreshes under a
  lock when less than 5 minutes are left, since providers rotate refresh
  tokens. With no token, or a 403 with `insufficient_scope`, it exits 1 and
  prints the `arx mcp-oauth login` line to run, with the scopes to add. A
  network failure exits 75.

### 13. Commands

`arx mcp` is a built-in command, since it needs the C client:

```text
usage: arx mcp list [--refresh] [--json]   # servers, transport, cached tools, era, age
       arx mcp search QUERY [--server S]   # mcp_search's ranking, as the model sees it
       arx mcp call SERVER TOOL            # one call; JSON arguments on stdin
       arx mcp http                        # the HTTP bridge; arx starts it
```

- `arx check` prints `mcp: github (stdio, 41 tools cached) linear (http, not
  listed)`, starts nothing, and lists entry problems under `problems:`.
- `arx check --hosts` adds each `url` host.
- `arx tools` shows `mcp_search`, `mcp_select` and the preloaded tools.
- `arx doctor` runs `arx mcp list --refresh` when the spec has servers, and
  warns about each one that fails, with its log path.

### 14. The JSON-RPC module (`src/base/rpc.c`)

One peer object speaks JSON-RPC 2.0 as newline-delimited JSON, in either
role, with no I/O of its own: its owner feeds it the bytes it reads and
gives it a function that writes. So it fits arx's single-threaded
`ProcPoll` design. For an MCP server the writer is `ProcWrite` and the
bytes come from the server's stdout; for `arx acp` the writer is fd 1 and
the bytes come from fd 0. The interface this plan needs, as a section of
`base.h`:

```c
// ---- rpc.c ----
typedef struct RpcPeer RpcPeer;
typedef enum RpcStatus { kRpcOk, kRpcError, kRpcTimeout, kRpcClosed } RpcStatus;

typedef struct RpcHandlers {
  void (*write)(void* ctx, const char* data, size_t n);  // one whole line
  // An incoming request; answer now or later with RpcReply or RpcReplyError.
  // NULL: every request gets -32601.
  void (*request)(void* ctx, RpcPeer* p, cJSON* id, const char* method,
                  cJSON* params);
  void (*notify)(void* ctx, const char* method, cJSON* params);  // or NULL
  void (*bad_line)(void* ctx, const char* line, const char* why);  // or NULL
  void* ctx;
} RpcHandlers;

// Called once per call: `value` is the result (kRpcOk) or the error object
// (kRpcError), borrowed; NULL for kRpcTimeout and kRpcClosed.
typedef void (*RpcDoneFn)(void* ctx, RpcStatus status, cJSON* value);

RpcPeer* RpcNew(const RpcHandlers* h, size_t max_line);  // 0: 64 MB
void RpcFeed(void* peer, const char* data, size_t n);   // a DataFn
int64_t RpcCall(RpcPeer* p, const char* method, cJSON* params,  // consumed
                double timeout, RpcDoneFn done, void* ctx);       // 0: no deadline
void RpcNotify(RpcPeer* p, const char* method, cJSON* params);    // consumed
void RpcReply(RpcPeer* p, cJSON* id, cJSON* result);              // consumed
void RpcReplyError(RpcPeer* p, cJSON* id, int code, const char* message,
                   cJSON* data);                                  // data consumed
void RpcForget(RpcPeer* p, int64_t id);   // drop a pending call; done never runs
double RpcTick(RpcPeer* p, double now);   // fires timeouts; seconds to the next, or -1
void RpcClose(RpcPeer* p, const char* why);  // every pending call: kRpcClosed
int RpcPending(const RpcPeer* p);
void RpcFree(RpcPeer* p);
```

What the module must do:

- **Ids** are integers from 1 per peer, and `RpcCall` returns the id. MCP
  uses them as subscription ids, and arx needs them to cancel. An incoming
  id (string, number or null) goes back as it came.
- **Borrowed values**: the `id`, `params` and `value` a handler or callback
  gets belong to the module and are freed when it returns. An owner that
  answers later, such as `arx acp` for `session/prompt`, keeps
  `cJSON_Duplicate(id, 1)` and passes that copy to `RpcReply`.
- **Timeouts**: `timeout` 0 means no deadline. `arx acp` uses it for
  `session/request_permission`, which waits for a person; MCP's
  `subscriptions/listen` uses it too.
- **Framing**: one message per line; output never holds a raw newline,
  since cJSON escapes them. A line longer than `max_line` is skipped up to
  its newline and reported to `bad_line`. A batch array is a bad line: MCP
  and ACP send none.
- **Server role**: with a `request` handler, a line that is not JSON gets
  `-32700` with a null id, and a message that is not a valid request gets
  `-32600`.
- **Re-entry**: a callback may call `RpcCall`, `RpcNotify`, `RpcReply` and
  `RpcForget`; `RpcFree` waits until the callback returns.
- **No fds, threads or timers**: deadlines fire only in `RpcTick`, which
  the owner calls from its poll loop.
- **Size**: about 260 lines; no MCP or ACP names in it.

## Implementation steps

In order. Each step leaves `make test` green.

1. **JSON-RPC module** (`src/base/rpc.c`, `src/base/base.h`): the interface
   in section 14. It lands in wave 1 step 5, in its own PR with step 2,
   so `acp-tui` can build on it.
2. **Processes** (`src/base/proc.c`, `src/base/base.h`), in the same wave 1
   PR as step 1: `dir` in `Proc` (chdir in the child), and the line helpers
   of `long-lived-hooks` step 1: `ProcClose(child)`, which closes a child's
   stdin and lets it exit, and `LineSink` (a `DataFn` up to 64 MB) with
   `LinePop`. Earlier drafts of this plan called `ProcClose`
   `ProcCloseInput`; they are one function. `arx acp` uses `dir` and
   `ProcClose` too. The session-lived registry (`ProcKeep`, `ProcRelease`,
   `ProcStop`) comes from `async-calls` steps 1 to 3, which land before
   this PR in wave 1. `src/base/proc_host.c` (wasm step 4) stubs the new
   functions.
3. **Credentials** (`src/model/credential.c`, `src/model/model.h`): split
   the program run out of `CredentialEnsure` as `CredentialRun(path, input,
   &value, err)`, so a caller passes its own input fields. Keep the
   one-value cache and its behavior for model calls.
4. **The spec key** (`src/harness/fields.c`, `validate.c`, `plugins.c`,
   `describe.c`, `src/cli/check.c`): `mcp_servers` as a `kDict` of the
   server table, in `kTopFields` and `kPluginFields`; the rules of section
   2; `Adopt` makes paths absolute, adds `ARX_PLUGIN_DIR` to `env`, lets
   settings override `mcp_servers`, and adds `url` hosts; `arx check`
   prints the `mcp:` line and `--hosts` the `url` hosts; `--plugin` prints
   `mcp_servers=`. `fields.c` and `plugins.c` merge in the release order:
   plugin-yaml-keys, arx-plugin (`setup`), mcp-client (`mcp_servers`),
   long-lived-hooks (`run`), acp-tui (`ui`). `arx-plugin`'s step 15 becomes
   the `arx plugin add` summary and the docs.
5. **The catalog** (`src/mcp/mcp.h`, `src/mcp/catalog.c`): the cache files,
   name mapping, `include` and `exclude`, `selected.json`, and
   `McpTools(a)`, which appends `mcp_search`, `mcp_select`, and the
   selected and preloaded tools to `a->tools` as `kToolMcp`. `harness.h`
   gains `kToolMcp` and two `Tool` fields, `server` and `remote` (the
   server's own name); shorten comments in `harness.h` to stay at 400 lines.
6. **Search** (`src/mcp/search.c`): section 6, and `mcp_search` and
   `mcp_select` as calls that end once the servers they need have listed.
7. **Servers** (`src/mcp/servers.c`): start, era probe, `initialize`,
   `subscriptions/listen`, `tools/list`, messages from the server,
   restarts, `failed`, `McpSync(a)` after a reload, and `McpShutdown(a)`.
8. **Calls** (`src/mcp/calls.c`): `McpCallStart`, `McpCallDone`,
   `McpCallFinish`, result conversion, timeout and Ctrl-C cancel, progress
   events, and `McpPump(a)`, which feeds buffered output to each peer,
   handles exits and fires timeouts.
9. **The runtime** (`src/harness/tool_exec.c`, `src/harness/tools.c`,
   `src/harness/keys.c`, `src/agent/tool_calls.c`, `src/agent/model_call.c`,
   `src/agent/loop.c`, `src/agent/run.c`, `src/harness/hooks.c`):
   - `ToolStart` dispatches `kToolMcp`; `ToolRun` holds an `McpCall`;
     `ToolChild` returns NULL for it; a new `ToolDone(run)` answers for both
     kinds. This is the "ask the `ToolRun` if it is done" rule that
     `async-calls` proposed for `CallsPoll`.
   - `ToolFind` falls back to the catalog and selects the tool (section 5).
     No code may keep a `Tool*` across a `ToolFind`, since the set can
     grow.
   - The runtime's poll calls `McpPump` each round and stays in its loop
     while any call runs, not only while a child runs.
   - `KeysFor` uses the server's keys; `AddConfigured` accepts
     `<server>__<tool>` entries; `NewCall` adds `server`.
   - `loop.c`: `McpPump` and the selection check before each model call;
     `McpSync` after a reload. `run.c`: `McpTools` after `ToolsBuild`, and
     `McpShutdown` when the session ends.
10. **The HTTP bridge** (`src/mcp/http.c`, `src/mcp/http_legacy.c`):
    section 9, on `HttpStart` and `HttpFinish` from wasm steps 1 to 3 (wave
    1), not on one curl argv per request. If wave 1 ships without response
    headers, `DELETE` or the `$ARX_CURL` fallback, add them to
    `src/base/http.c` in this step's first PR, with the wasm plan's owner.
    Generic SSE event splitting lives in the bridge; `sse.c` stays specific
    to model replies.
11. **The command** (`src/mcp/command.c`, `src/cli/commands.c`): `arx mcp
    list|search|call|http` in `kCommands`; `commands/arx-doctor` runs
    `arx mcp list --refresh`.
12. **`plugins/mcp-oauth`**: section 12, its tests, and a row in
    `plugins/README.md`. Add the Client ID Metadata Document at
    `https://arx-documentation.vercel.app/oauth/mcp-client.json` (open
    decision 8), a change in the arx-docs repo, before the plugin merges.
13. **Tests and docs**: the next two sections.
14. **Budgets**: `make bench` with a spec that names 20 servers (startup
    and edit-to-live must not move, since nothing starts), and the binary
    size; `make lint` for the 400-line limit on every new file.

## Tests

A new suite, `tests/mcp.sh`, in `make test`, with `tests/fake-mcp`: a
Python stdio server whose behavior `FAKE_MCP_MODE` and a JSON tool file
choose (modern, legacy, silent on `server/discover`, slow, crash after N
calls, chatty stderr, `list_changed`, `isError`, `input_required`, image).
It logs each message it gets to `$FAKE_DIR/mcp-<server>.jsonl` and its pid
to `mcp-<server>.pid`. `tests/fake-curl` learns to answer by the
`Mcp-Method` header from `$FAKE_DIR/mcp-<method>-NN.resp`, for the bridge.

| Area | Checks |
|---|---|
| No servers | `arx tools` has no `mcp_search`; the request's tools do not change |
| Prompt cost | with 3 servers and 300 tools, the request has `mcp_search` and `mcp_select` only, and the description names the 3 servers; no server process starts |
| Search | starts the server, writes the cache, ranks `create_issue` first for "create issue"; camelCase split; prefix match; `server` filter; `limit`; an empty query lists servers; a second session searches the cache with no start; a config change or an expired `ttlMs` lists again |
| Select | the next request holds the full schema without `$schema`; `selected.json`; `--resume` keeps it; unknown names get suggestions; `drop`; the cap of 32 |
| Calls | the server gets its own tool name and the arguments; text, `isError`, `structuredContent` only, image saved to a file, `resource_link`; long output cut with `tool-NNNN.out`; a call to an unselected catalog tool runs and selects it |
| Eras | modern via `server/discover`; legacy via `initialize` and `notifications/initialized`; a silent server falls back after 5 s; the second start skips the probe; a legacy `ping` gets `{}` |
| Keys | default `*` runs two calls one at a time; `keys: []` runs them together (timestamps, as in `runtime.sh`) |
| Timeout and Ctrl-C | a slow call ends with the timeout text, `notifications/cancelled` reaches the server with the request id, and the next call uses the same pid; after Ctrl-C in a headless run no server pid is alive |
| Crash | an exit mid-call gives the error with the log tail; the next call restarts the server; 3 exits make it `failed` with one `[harness]` note; an edit to its entry clears it |
| Reload | a changed entry gets a new pid; an unchanged one keeps its pid; a removed one stops |
| `list_changed` | modern (via `subscriptions/listen`) and legacy: the next request has the new schema |
| Stderr | a server that writes 2 MB to stderr while arx waits on a slow model reply does not block, and the log holds it |
| Hooks | `before_tool` sees `server` and can deny; `after_tool` changes the result; `RanAs` text when a hook renames to an MCP tool |
| Plugins | a plugin's server with a relative `command` runs and gets `ARX_PLUGIN_DIR`; the spec's `enabled: false` turns it off; settings override `args`; `arx check --plugin` prints `mcp_servers=` |
| Validation | `command` and `url` together; `type: sse`; a bad name; an unknown key with its hint; a missing `${NAME}` at start |
| Credentials | stdio: the program's `api_key` lands in `api_key_env` and the program does not run before the start; HTTP: a 401 reruns it with `reason: rejected`, `status` and `challenge`, and the request is repeated once (added to `tests/credentials.sh`) |
| HTTP bridge | `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name` and `Mcp-Param-*` headers, with the base64 form; a tool with a bad `x-mcp-header` is dropped; JSON and SSE replies; the legacy fallback with `Mcp-Session-Id`; a 404 starts a new session once; a cancel calls `HttpFinish` and fake-curl sees its process end; a `WWW-Authenticate` value reaches the credential's `challenge` |
| Commands | `arx mcp search` matches `mcp_search`'s text; `arx mcp call`; `arx check` and `--hosts` |
| Events | `mcp.server` states, `server` on `tool.end`, `tool.progress` |

`plugins/mcp-oauth/tests/test_mcp_oauth.py` covers discovery, the `iss`
table, PKCE, token refresh under the lock, and the exit codes, against a
local fake authorization server; `tests/plugins.sh` loads the plugin.

## Docs to change

All written to `docs/WRITING.md`. Nothing on these pages may describe MCP
in the present tense before it ships.

- **New: `docs/mcp.md`** (guide, "MCP servers"): opens with "arx runs the
  MCP servers your spec names and gives the agent their tools through two
  tools, `mcp_search` and `mcp_select`." Sections: add a server (stdio,
  then HTTP), how the agent finds tools, sign in to an HTTP server, keep
  tools out (`include`, `exclude`), keys, servers in a plugin, a common
  mistakes table (`npx` slower than `startup_timeout`, a server that
  prints to stdout, a token in `agent.yaml`, `type: sse`), and Related. One
  `[!WARNING]`: a server runs as you, outside any sandbox, and its tool
  descriptions reach the prompt. Add it to `src/lib/nav.mjs` in arx-docs.
- **`docs/spec.md`**: a `mcp_servers` row in "Top-level keys" and a
  `### mcp_servers` table.
- **`docs/plugins/reference.md`**: `mcp_servers` in the `plugin.yaml`
  table; `mcp.server` and `tool.progress` in "Events", `server` on
  `tool.start` and `tool.end`; the `.arx/mcp/` and `mcp/` files in
  "Session files"; `arx mcp` next to `arx tool`.
- **`docs/plugins/credentials.md`**: the input fields `server`, `url`,
  `status` and `challenge`; when arx runs the program for an MCP server.
- **`docs/plugins/tools.md`**: MCP tool names in "Tool names", and the
  default keys of MCP tools in "Keys".
- **`docs/plugins/hooks.md`**: `server` in the `before_tool` object.
- **`docs/cli.md`**: `arx mcp`.
- **`docs/architecture.md`**: `src/mcp/` and `rpc.c` in the source layout
  and its diagram; a design-decision row: "MCP over pipes in the agent, HTTP
  in a bridge process".
- **`docs/roadmap.md`**: item 6 done; drop the MCP bullet from "More of
  `arx plugin`"; the "MCP client" section goes.
- **`docs/plugins/planned.md`**: the "MCP client" row and section go.
- **`plugins/README.md`** and **`plugins/mcp-oauth/README.md`**.

## Dependencies

| Slug | What we share | Agreement |
|---|---|---|
| `acp-tui` | `src/base/rpc.c` (section 14). ACP's `session/new` and `session/load` carry `mcpServers` | `rpc.c` lands first, in its own PR. `arx acp` maps each `mcpServers` entry to `mcp_servers.<name>` as a session override that every reload applies, the way `--set` does: stdio `{name, command, args, env: [{name, value}]}` becomes `{command, args, env: {...}}`, `{type: "http", name, url, headers: [...]}` becomes `{url, headers: {...}}`, and `type: "sse"` is refused with `-32602`. `arx acp` puts each `env` and header value in the child's environment as `ARX_ACP_MCP_N` and writes `"${ARX_ACP_MCP_N}"` in the override, so tokens never reach `argv`: this relies on the `${NAME}` expansion of section 2 in `env` and `headers` values, which must stay in the contract. `agentCapabilities.mcpCapabilities` is `{"http": true, "sse": false}`. `arx acp` also uses `dir` and `ProcClose` from step 2. `tool.start` carries `server` for the ACP tool call's title. MCP calls pass `before_tool`, so the `ask` plugin (the long-lived-hooks `ask` contract, which `arx acp` maps to `session/request_permission`) covers them |
| `arx-plugin` | the `mcp_servers` shape, `fields.c`, `Adopt`, `describe.c`, `setup:` for servers that install packages | section 3; this plan builds the key for both files in step 4, so `arx-plugin` step 15 is the `arx plugin add` summary and the docs |
| `async-calls` | the session-lived child registry (`ProcKeep`, `ProcRelease`, `ProcStop`); `CallsPoll` | MCP servers join the registry; `CallsPoll` asks `ToolDone(run)`; whichever plan lands first builds the registry. A background MCP call works as any background call. The MCP Tasks extension, a server-side form of background calls, waits for a later release |
| `long-lived-hooks` | the registry; `ProcClose`, `LineSink` and `LinePop` (its step 1); the `ask` contract; `rpc.c` if its line protocol becomes JSON-RPC | its step 1 helpers serve MCP servers; they land with `rpc.c` in wave 1 step 5. Any MCP feature that asks a person (elicitation, after 0.2.0) goes through `ask`, not a channel of its own |
| `plugin-yaml-keys` | `kPluginFields` and `Adopt`; `PluginText()` | merge order in `fields.c` and `plugins.c`: plugin-yaml-keys, arx-plugin, mcp-client, long-lived-hooks, acp-tui. Server `instructions` do not go into the system prompt: they go into `mcp_search`'s overview, so `PluginText()` is not needed |
| `plugin-state` | none | `ARX_DATA_DIR` is `.arx/data/<name>/`; the MCP cache is a core command's folder, `.arx/mcp/`, so its orphan check does not flag it |
| `wasm` | `HttpStart` and `HttpFinish` (phase A, wave 1); `proc_host.c` stubs | the bridge builds on them (section 9 lists three additions it needs). stdio servers can't run in the browser; a remote server that allows CORS can, in phase B |
| `trust` | `mcp_servers` names host programs | `mcp_servers` joins the spec keys a policy rejects, and each server's `command` joins the file walk as `kind: program`. A policy hook can deny MCP calls by `server` |
| `sandboxes` | MCP servers run on the host | arx passes `ARX_SANDBOX` to servers. A sandbox plugin can offer a launcher that a server's `command` uses; arx wraps nothing on its own (open decision 10) |
| `climb` | none | |

## Size and risks

**Size: L.** About 2,400 new lines of C in 9 files (`rpc.c` 260,
`catalog.c` 330, `search.c` 260, `servers.c` 380, `calls.c` 300, `http.c`
390, `http_legacy.c` 200, `command.c` 180, `mcp.h` 150), 350 lines of
edits, about 600 lines of Python in `mcp-oauth`, and 700 lines of tests.

| Risk | Mitigation |
|---|---|
| The spec moves: `2026-07-28` replaced the handshake 3 months ago, and most servers still speak `2025-11-25` | era logic in two places only (`servers.c` probe, `http_legacy.c`); both eras in the tests; the era cached per config |
| A legacy server that ignores `server/discover` costs 5 seconds on its first start | the era cache; the time shows in `mcp.server` `secs` |
| Providers reject some JSON Schema 2020-12 keywords in a selected tool (`$defs`, `prefixItems`) | arx strips `$schema` and `x-*` keys; a `before_model` hook can rewrite the rest; the guide's common mistakes table names it |
| Each `mcp_select` changes the tools list, so the provider's prompt cache misses once | selected tools go last, in order; `mcp_select` takes several names; `preload` for tools a run always needs |
| Tool descriptions from a server are prompt text you did not write | only selected tools and one-line search results reach the prompt; `exclude`; guard hooks see `server`; the guide's warning |
| A server runs as you, outside a sandbox, and the agent can add one by editing `agent.yaml` | the same power as a tool file today; `trust` rejects such edits under a policy; the warning |
| `npx` servers take 10 to 60 seconds on a cold cache | lazy start, a 60-second `startup_timeout`, and `mcp.server` events that show the wait |
| A server that ignores stdin EOF and SIGTERM | SIGKILL to its process group after 3 seconds, as for tools |
| `harness.h` is at the 400-line limit | trim comments in step 5 |
| The Client ID Metadata Document's URL is the client id, so the site must not move: a new URL makes every user consent again | the URL is fixed on `arx-documentation.vercel.app` (open decision 8); dynamic registration remains as a fallback |
| `HttpStart` lacks response headers, `DELETE` or a curl path without a spec | section 9's table; step 10 adds what wave 1 left out, with the wasm plan's owner |

## Open decisions

1. **The client in the binary or in a plugin.** **Decided on 2026-11-09:
   in the binary, as `src/mcp/`, outside the loop, with HTTP in the `arx mcp
   http` bridge and sign-in in the `mcp-oauth` plugin** (release plan,
   decision 2). Section 1 has the reasons.
2. **The key's name: `mcp_servers` or `mcp`.** **Recommend:
   `mcp_servers`.** It names what the map holds, as `credentials` and
   `adapters` do, leaves `mcp` free for client options later, and is what
   `arx-plugin` assumed.
3. **The entry's shape: other hosts' keys, or an arx list
   (`command: [npx, -y, pkg]`).** **Recommend: other hosts' keys**
   (`command`, `args`, `env`, `url`, `headers`, `type`), so README snippets
   paste in.
4. **A call to a catalog tool that is not selected.** **Recommend: run it
   and select it.** It saves a turn, and the history never holds a call to
   a tool the request lacks.
5. **Default keys for MCP calls.** **Recommend: `["*"]`, with `keys:` per
   server.** It matches the default for any tool. `readOnlyHint` is
   untrusted, so it decides nothing.
6. **Legacy servers.** **Recommend: support `2025-11-25` and earlier with
   the `initialize` handshake, on stdio and HTTP; refuse the HTTP+SSE
   transport.** Most servers are legacy today; HTTP+SSE is deprecated and
   `mcp-remote` covers it.
7. **Ranking.** **Recommend: BM25F in C, as in section 6.** No index, no
   model and no network. A semantic `mcp_search` can replace it as a layer
   tool that reads the cache.
8. **OAuth client registration.** **Decided on 2026-11-09: a Client ID
   Metadata Document at a fixed URL on the arx site,
   `https://arx-documentation.vercel.app/oauth/mcp-client.json`, then
   dynamic registration, with a pre-registered id from settings first.**
   `arx-documentation.vercel.app` is the final arx domain. The document's
   URL is the client id, so the URL must not change once 0.2.0 ships.
9. **Elicitation and sampling (`input_required`).** **Recommend: not in
   0.2.0;** the call ends with an error that names the request. Elicitation
   can come later through the long-lived-hooks `ask` contract, the one way
   arx asks a person, at the terminal or through `arx acp`.
10. **Wrapping servers in the sandbox.** **Recommend: no automatic wrap in
    0.2.0.** arx passes `ARX_SANDBOX`, and a sandbox plugin can ship a
    launcher for `command`.
11. **Server `instructions` in the system prompt.** **Recommend: no.** They
    go into `mcp_search`'s overview and the server's line in its
    description, so they cost tokens only when the agent looks.
12. **The selection cap.** **Recommend: 32 at once, with `drop`.** Some
    providers allow 128 tools in a request, and 32 schemas are already
    thousands of tokens.
13. **Startup: lazy or at session start.** **Recommend: lazy, with
    `preload` to start a server before the first model call.** Nothing
    starts for a run that never uses MCP.
14. **The name separator.** **Recommend: `<server>__<tool>`.** Model APIs
    allow no `.` in names, and a double underscore rarely occurs in a tool
    name.
15. **Progress.** **Recommend: forward `notifications/progress` as
    `tool.progress` events, and never extend a timeout for it.** Front-ends
    get the updates; the timeout stays a hard limit.
