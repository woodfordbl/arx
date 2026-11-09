# arx 0.2.0 release plan

0.2.0 ships every planned item from the roadmap and the plugin guide's
planned changes, plus an interactive installer and the first phase of a
browser build. Each item has its own plan in this folder. This page fixes
the order of work, settles what the plans left to each other, and records
the four decisions made on 2026-11-09.

**Status (2026-11-09):** every plan is approved. [wasm.md](wasm.md) was
re-scoped before approval: the docs site hosts arx in the browser, and this
repo builds and releases the binary.

## What ships

| Item | Plan | What you get | Size |
|---|---|---|---|
| Plugin state | [plugin-state.md](plugin-state.md) | `ARX_STATE_DIR` and `ARX_DATA_DIR`, one folder per plugin | S |
| New plugin.yaml keys | [plugin-yaml-keys.md](plugin-yaml-keys.md) | `instructions` (prompt text) and `model_settings` (request fields) | M |
| More of `arx plugin` | [arx-plugin.md](arx-plugin.md) | `update`, `search`, `eject`, named marketplaces (`@acme/lint`), `setup:`, `index.yaml` | L |
| Installer and settings menus | [installer.md](installer.md) | `pick`, a small C menu program outside the core; `install.sh` hands off to a four-question wizard; `arx setup` becomes a settings menu | M |
| Trust | [trust.md](trust.md) | `--policy DIR`, the `harness_edit` gate, exit code 5 | L |
| Sandboxes | [sandboxes.md](sandboxes.md) | `sandbox:`, `ARX_SANDBOX`, `ARX_HARNESS`, and a `sandbox-native` plugin (Seatbelt on macOS, bubblewrap on Linux) | M |
| Calls that don't block | [async-calls.md](async-calls.md) | `started as c7` now, the result later in the inbox; a `background` plugin; `arx ctl ID cancel CALL` | L |
| Long-lived and concurrent hooks | [long-lived-hooks.md](long-lived-hooks.md) | `run: session` hooks, a separate hook chain for each call, and an `ask` reply that asks a person | L |
| MCP client | [mcp-client.md](mcp-client.md) | `mcp_servers:`, `mcp_search` and `mcp_select`, `src/base/rpc.c`, an `arx mcp http` bridge, an `mcp-oauth` plugin | L |
| `arx acp` and the TUI | [acp-tui.md](acp-tui.md) | an ACP v1 server on stdio (Zed works), and a `tui` plugin on OpenTUI and bun | L |
| `arx climb` | [climb.md](climb.md) | a keep/revert driver with a scorer the agent can't reach, and a `climber` kit | M |
| Browser build | [wasm.md](wasm.md) | `arx-wasm32-wasi.tar.gz` in each release: `arx.wasm`, its `arx.js` runtime and a `browser` kit. The docs site builds the page from it. | M |

That's six L, five M and one S item. By the plans' own estimates, the core
gains about 6,000 to 7,000 lines of C against about 8,000 today. Trust and
long-lived-hooks give no line count. Most of the growth is the MCP client
(about 2,400 lines in `src/mcp/`) and `arx acp` (about 1,250 in `src/acp/`).
Both stay outside the turn loop.

The page itself (the chat view, OpenRouter sign-in, key storage and
just-bash for `bash`) is docs-repo work, built from a 0.2.0 pre-release.
This follows fx, whose repo releases the wasm and its runtime while fx.sh
hosts the page.

## Order of work

### Wave 1: shared seams

Small pull requests that several items build on. Land them in this order,
each with no change in behavior:

1. **wasm steps 1 to 3.** `HttpRun` replaces the two curl call sites,
   `IsRunnable()` replaces eleven `access(X_OK)` checks, and the last
   POSIX-only calls move into `src/base/proc.c`.
2. **plugin-state.** `ToolEnv` and `HookEnv` gain the two variables. It's
   the smallest item and three others edit the same arrays.
3. **trust step 1.** Split `src/harness/hooks.c` (394 of 400 lines) into
   `hooks.c` and `chain.c`, and export `HookRunOne`.
4. **async-calls steps 1 to 3.** The session-lived child registry
   (`ProcKeep`, `ProcRelease`, `ProcStop`) and the call table on `Agent`.
   Step 3 is a pure refactor behind the runtime tests.
5. **mcp-client's `rpc.c`,** in its own PR, with `dir`, `ProcCloseInput`,
   `LineSink`, `LinePop` and `ProcClose` in `Proc`.
6. **wasm steps 4 and 5.** `proc_host.c` with stubs for the new `Proc`
   functions, `make wasm` and its import check in CI. From here on, a POSIX
   call outside `proc.c` fails CI.

### Wave 2: the contracts

These run in parallel. Several edit `kPluginFields` and `Adopt` in
`src/harness/fields.c` and `plugins.c`, so they merge there in this order:
plugin-yaml-keys, arx-plugin (`setup`), mcp-client (`mcp_servers`),
long-lived-hooks (`run`), acp-tui (`ui`).

- **plugin-yaml-keys.** async-calls wants it first, for the `background`
  plugin's `instructions`.
- **arx-plugin steps 1 to 11.**
- **trust,** the rest.
- **sandboxes steps 1 to 9.** Its step 0, the proof that hard links and
  renames can't get around the path rules on both OSes, comes before any
  code merges.
- **async-calls,** the rest, and the `background` plugin.
- **long-lived-hooks,** in three parts: the engine with concurrent calls,
  `run: session`, then `ask` and the `ask` plugin.
- **mcp-client,** the rest. Its HTTP bridge builds on `HttpStart` from
  wave 1, not on one curl process per request.
- **installer steps 1 to 6, 8 and 9.**
- **climb steps 1 to 8.**
- **acp-tui part 1:** the core contracts `--input jsonl`, the
  `prompt.start` and `prompt.end` events, `ui:` and `ProcPollWith`. The
  wasm runtime needs them for one instance per session.

### Wave 3: built on the contracts

- **`arx acp`.** It needs `rpc.c`, the async-calls events (`tool.run`,
  `tool.detach`, `tool.end.call`), and for mode `ask`, trust's `--policy`
  and the ask contract (decision 1).
- **The `tui` plugin.** It needs `setup:` and `arx acp`. Its first step is a
  spike of OpenTUI's inline mode, with a full-screen fallback.
- **sandboxes step 10** (`harness: gated`), after trust.
- **climb step 9** after trust, and **step 10** after sandboxes.
- **installer step 7,** after arx-plugin's changes to `commands/arx-plugin`
  and `commands/arx-kit`.
- **wasm steps 6 to 10,** after acp-tui part 1: `arx.js`, the `browser`
  kit, the headless tests, and the wasm tarball in the release.

### Wave 4: release

- Update `docs/roadmap.md` and `docs/plugins/planned.md` to show what
  shipped.
- Add the `index.yaml` route on the arx site. This is a change in the docs
  repo.
- Cut a 0.2.0 pre-release with `arx-wasm32-wasi.tar.gz`, so the docs repo
  can build the browser page from it.
- Write release notes. They tell plugin authors to set `arx: ">=0.2.0"` for
  the new keys, because 0.1.0 skips such a plugin as broken.

## Settled across plans

The plans left these points to each other. Each one follows the plans'
recommendation, and the plans named in it need a one-line edit to match.

1. **The TUI plugin is named `tui`,** with command `arx-tui` and `ui: tui`.
   arx-plugin.md calls it `acp-tui`.
2. **`ARX_DATA_DIR` is `.arx/data/<name>/`,** not `.arx/state/<name>/`, so
   each variable matches its folder. Core commands keep their own files in
   `.arx/<command>/`, so climb writes to `.arx/climb/`. Update planned.md,
   climb.md and long-lived-hooks.md.
3. **A policy wins.** A policy folder's `instructions` come first, and its
   `model_settings` rank above `--set`. plugin-yaml-keys leaves rank 0 free
   for it.
4. **One rule for which tool wins,** written before sandboxes step 5 or
   trust merges. The proposed rule: a policy layer's tool first, then a
   tool that `replaces:` the name, then the current rule that the first
   tool with a name wins.
5. **One scheduler protocol table.** async-calls adds `detach`, `cancel`,
   `kind` and `args` on `ready`, and `done` for cancelled calls.
   long-lived-hooks adds `waiting` and `done.ran`.
6. **`ARX_HARNESS` joins the core.** The sandboxes plan adds it beyond its
   brief, because a sandbox can't protect files it can't name. It comes
   from the same file walk as reload and trust.
7. **No `permissions:` spec key.** The agent can write the spec, so the
   permission mode comes from a flag or a front-end.
8. **Exit codes.** 5 means `policy` (trust). 10 means an update is
   available (`arx plugin update --check`, as `arx update --check` does).
9. **The smaller open decisions in each plan** stand as recommended unless
   you object.

## Decisions

Decided on 2026-11-09.

1. **One way to ask a person: the long-lived-hooks `ask` contract.** Any
   `before_tool` hook can reply `ask`. arx then asks at the terminal,
   through `arx ctl answer`, or through a front-end, and the `ask` plugin
   implements `permissions: ask`. `arx acp` starts each child with
   `--ask ctl` and the `ask` plugin as `--policy`, so the agent can't turn
   it off. It maps `ask` events to `session/request_permission` and answers
   through the session inbox. The `arx acp ask`
   client and its socket from the first acp-tui draft are dropped. Mode
   `ask` in `arx acp` waits for long-lived-hooks part 3 and trust. Until
   both land, it ships with mode `allow` only.
2. **MCP and ACP in the core binary.** `src/mcp/` and `src/acp/` go in the
   `arx` binary, outside the loop. HTTP and OAuth stay out of the agent
   process (`arx mcp http`, the `mcp-oauth` plugin).
3. **The arx site stays at `arx-documentation.vercel.app`.** No other
   domain is planned, so this is the long-term name. The MCP OAuth Client
   ID Metadata Document, the `index.yaml` route and the downloads all live
   there. The Client ID Metadata Document's URL is the client id, so moving
   the site later would make every user consent again.
4. **One 0.2.0 release, tagged when wave 3 lands.** If it must ship sooner,
   the cut is after wave 2 and its follow-on steps, with `arx acp` and the
   TUI moved to 0.3.0.

## Risks across the release

- **Security wording.** A policy without a sandbox stops mistakes, not a
  hostile agent. Trust, sandboxes and climb must all say so plainly.
- **Shared hot files.** `tool_calls.c`, `proc.c`, `hooks.c`, `fields.c` and
  `tool_exec.c` are edited by four or more items. Wave 1 and the merge
  order above keep that to one owner at a time.
- **File limits.** `hooks.c` and `harness.h` are at the 400-line lint limit.
  Wave 1 step 3 and mcp-client step 5 make room.
- **bash 3.2.** `arx-plugin`, `arx-climb` and `ui.sh` must run on macOS's
  `/bin/bash`. CI runs them on macOS and Linux.
- **External churn.** The MCP spec changed its handshake in 2026-07, ACP adds
  update kinds, and `sandbox-exec` is deprecated. Each plan pins versions or
  keeps a fallback.

## After 0.2.0

- **The browser page, in the docs repo.** OpenRouter sign-in (OAuth PKCE)
  with a `:free` model as the default, a pasted Vercel AI Gateway key, and
  no ChatGPT sign-in in the browser. A free-token proxy like fx.sh's is the
  site's choice, since it's server code with a running cost.
- **Later in this repo:** a browser adapter contract, plugin installs at
  runtime in the browser, and an npm package if others want to embed arx.
- **`sandbox-docker`,** with the same contract.
- **The TUI as the default for bare `arx`,** once `arx setup` can install
  it.
- **MCP elicitation through `arx acp`,** the MCP Tasks extension,
  marketplaces at a plain URL, and `arx kit update`.
