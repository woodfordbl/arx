# Plan: a browser build (`wasm`)

Slug: `wasm`. Release: arx 0.2.0 builds and releases the binary; the docs
site hosts the page from that release. Status: plan only, no code changed.
Revised 2026-11-09: the docs site hosts arx in the browser, and this repo
only builds the binary and the glue that belongs with it.

## Goal

arx runs in a browser tab on the docs site, `arx-documentation.vercel.app`,
purely client side where the providers allow it: the C core compiled to
WebAssembly, a small JavaScript runtime, files in memory, and model calls
through `fetch`.

Two repos share the work:

- **This repo** builds, tests and releases `arx-wasm32-wasi.tar.gz`: the
  binary (`arx.wasm`), its runtime glue (`arx.js`), and the read-only files
  the binary needs in a browser (the `shell` plugin and a `browser` kit).
  It has no page, no UI, no sign-in screens and no npm dependency.
- **The docs repo** pulls that tarball from a release, by version and
  SHA-256, and builds the page: the chat view, provider sign-in, where keys
  and sessions are kept, just-bash for `bash`, and the sandbox for
  untrusted JavaScript tools.

fx does the same split: the fx repo publishes `fx-core.wasm`,
`fx-term.wasm` and their JavaScript runtime in the `libfx` package, and
fx.sh depends on it. See [How fx does it](#how-fx-does-it).

0.2.0 ships everything in this repo, so the docs site can host arx from the
0.2.0 release. The page is docs-repo work and can start on a 0.2.0
pre-release.

Not goals: real processes in a browser, Python plugins, a Linux VM
(WebContainers, v86), an npm package, and ChatGPT sign-in in a browser.

### What lives where

| Part | Repo | Why |
|---|---|---|
| Platform seams in `src/` (`HttpRun`, `IsRunnable`, POSIX calls in `proc.c`) | this | they are the core |
| `src/base/proc_host.c`: the wasm side of the platform | this | it is half of the host interface |
| `arx.js`: WASI over in-memory files, the host interface, `fetch` streaming, instances | this | it changes in the same commit as `proc_host.c`; fx keeps `wasm-runtime.js` with its wasm for the same reason |
| `kits/browser`: the prompt that tells the model what a browser can't do | this | it ships with the binary it describes |
| `make wasm`, `make dist` for wasm, the release asset, headless tests in CI | this | the binary's build and checks |
| The page: chat view, settings, Stop, import and export | docs | the site owns the UI |
| OpenRouter sign-in (PKCE), Gateway key entry, key storage | docs | redirects and storage belong to the origin |
| just-bash and its bridge to `arx.files` | docs | an npm dependency; this repo stays free of them |
| Saving files to OPFS or IndexedDB | docs | `arx.js` exposes a snapshot and change hook |
| The sandbox iframe for plugin and agent JavaScript | docs | it needs the site's origin and CSP |
| Response headers (`Content-Type: application/wasm`, CSP, cache) | docs | Vercel config of the site |
| An optional free-token proxy, as fx.sh has | docs | server code, if the site wants it |

### Where purely client side fails

Each row was checked against the live service or its current docs on
2026-11-09 (see [Provider checks](#provider-checks-2026-11-09)).

| Where | Why | What the plan does |
|---|---|---|
| ChatGPT sign-in | Sign in with ChatGPT is for "open-source and locally hosted apps", needs a redirect to `127.0.0.1`, and says "Keep tokens out of browser storage". fx runs ChatGPT turns on a server: "Codex doesn't accept requests from web pages". | Not in the browser build. Native arx keeps the `chatgpt` plugin. |
| Vercel AI Gateway without a key you paste | Every request needs Vercel authentication. fx signs in to Vercel in the browser with the device flow (`api.vercel.com/login/oauth/*` sends CORS headers), but with its own first-party client. Sign in with Vercel documents no AI Gateway scope for other apps. | The user pastes a key with a budget and an expiry. A Gateway sign-in waits for Vercel. |
| Trying arx with no account at all | Every provider needs a key. fx.sh's try page sends keyless visitors to a same-origin proxy that holds fx's own Gateway key. | Default to OpenRouter sign-in and a `:free` model: one click, $0, no server. A proxy is the docs site's choice and is server code. |
| Gateway auth errors | A 401 from the Gateway has no `Access-Control-Allow-Origin`, so `fetch` rejects with a `TypeError`. | The page checks a pasted key once before the first run. |
| `Retry-After` from OpenRouter and OpenAI | Not in `Access-Control-Expose-Headers`, so JavaScript can't read it. | arx's exponential backoff (`src/model/llm.c:167`). |
| Real programs | A tab has no `sh`, `python3`, `git`, `node` or `curl`. | `bash` runs in just-bash. A tool or hook runs only if the page has a runner for it. |
| Free model limits | OpenRouter's `:free` models allow 20 requests a minute and 50 a day (1,000 a day after you buy 10 credits). | The page says so, and shows the 429. |

## How fx does it

fx ([github.com/vercel-labs/fx](https://github.com/vercel-labs/fx),
Apache-2.0) is a "Tiny, open, native coding agent" written in Zig. Its
browser version is real and runs on [fx.sh](https://fx.sh) and
[fx.sh/try](https://fx.sh/try): "This demo runs the full fx CLI as
WebAssembly compiled with the Zig toolchain. Networking is delegated to
browser fetch". Checked 2026-11-09 against fx and `libfx` 0.0.16.

**Build.** `zig build -Dwasm-surface=core|term` targets `wasm32-wasi`
(`build.zig:363-421`): optimize for size, single-threaded, libc, stripped,
1 MiB stack for the core. Then `sdk/scripts/optimize-wasm.mjs` runs
binaryen's `wasm-opt -Oz` from npm. Two modules come out:

| Module | What | Raw | Brotli |
|---|---|---|---|
| `fx-core.wasm` | the headless engine | 2,260,477 bytes | 719,950 (q11) |
| `fx-term.wasm` | the whole terminal CLI | 3,554,437 bytes | 1,157,838 (q11); fx.sh serves 1,476,359 |
| `ghostty-vt.wasm` | the site's terminal renderer, not fx | 591,867 bytes | 194,460 as served |

The JavaScript runtime is in `libfx`: `wasm-runtime.js` (42,635 bytes, not
minified) implements WASI and the host imports. `engine.js` (118,052 bytes)
drives the core. The package is 9.9 MB unpacked, with native addons.

**Host interface.** Both modules are WASI commands (exports `memory` and
`_start`) that import 33 WASI preview1 functions and 22 (core) or 25 (term)
functions from module `fx`: `fx_http_stream_open`, `_next`, `_status`,
`_close`, `fx_http_request`, session, OAuth-session, config and history
stores (bytes plus a revision), `fx_workspace_exec`,
`fx_workspace_read_file`, `fx_host_tool_call`, `fx_open_url` and terminal
input. `wasm-runtime.js` wraps every waiting import in
`WebAssembly.Suspending` and `_start` in `WebAssembly.promising`. It
requires JSPI and offers `supportsJspi()`; there is no fallback.

**No files.** `wasm-runtime.js` answers every WASI file call
(`path_open`, `fd_readdir`, `path_create_directory` and the rest) with
`ENOTSUP`. Sessions, config and logins go through the store imports, and
the host decides where they live. By default "a browser agent keeps its
sessions in the page's memory".

**The engine speaks ACP.** `createFxAgent()` starts `fx-core.wasm` with
`args: ["acp"]` and talks JSON-RPC over stdin and stdout; `fd_read` is a
suspending import (`wasm-runtime.js:882-883`).

**Hosting.** fx.sh is a Next.js site on Vercel that installs `libfx` from
npm. The build copies the modules to
`/_next/static/immutable/media/NAME.HASH.wasm`, served with
`Content-Type: application/wasm`, brotli, and
`Cache-Control: public,max-age=31536000,immutable`, with
`<link rel="preload" as="fetch" type="application/wasm" crossorigin>`.
There is no COOP or COEP header. The try page loads 636 KB of JavaScript,
uncompressed.

**Providers, keys and sign-in.** AI Gateway is the default:

- **Keyless visitors** reach a same-origin proxy, `/fx-wasm/gateway/*`,
  that adds fx's own Gateway key, allows two paths and adds a system prompt.
  The browser example says: "Keep a shared application key on the server
  and proxy requests through your backend".
- **A visitor's own key** goes straight to the Gateway; the try page keeps
  it in `localStorage` (`FX_API_KEY`).
- **Vercel login** uses the OAuth device flow with fx's client id, from
  inside the browser. The login is kept in `localStorage`
  (`fx-oauth-session`).
- **ChatGPT and Grok plans** run on a server, never in a page.
- **Custom providers** work in a browser only when the server allows CORS:
  "the server must accept cross-origin requests, and the page can read the
  key".
- **Where keys go**: "libfx adds ChatGPT, Grok, and custom-provider
  credentials to each request in JavaScript, just before it's sent … They
  never reach the engine."

**Tools and files.** "WebAssembly can't start native processes or reach a
native keychain or filesystem. Tool calls run one after another." The page
gives the terminal a workspace adapter: one `shell` tool (`{action: "run",
command}`) that the try page runs in just-bash over an in-memory folder,
with 64 KiB commands, 64 KiB of output and 30 s per command, and
`readFile` for `AGENTS.md`. Embedders add JavaScript tools through
`fx_host_tool_call`. The core adds a prompt that says web fetch, search and
network access are unavailable in the browser
(`src/core/hosts/browser_capabilities.zig`).

**What arx copies:**

- **The split.** The agent repo releases the wasm and its runtime
  together; the site pulls a pinned version.
- **WASI with our own runtime**, not a shim and not Emscripten.
- **JSPI only**, with a `supportsJspi()` check and a plain message.
- **Streaming HTTP as host imports**, with the response read in chunks.
- **Credentials added in JavaScript just before `fetch`**, for one origin,
  so they never reach the wasm memory or its files.
- **Adapters for what the page owns**: the shell (just-bash), extra tools,
  storage.
- **A prompt that tells the model what the browser lacks**, as a kit.
- **One long-lived instance per session that reads input on stdin**: fx
  uses `fx acp`; arx uses `--input jsonl` from `acp-tui`.
- **The build and serving details**: `wasm-opt -Oz`, content-hashed
  immutable URLs, `application/wasm`, preload, and no cross-origin
  isolation.

**What arx does differently:**

- **Files.** arx is built on files: the spec, layers, hot reload by
  `stat()`, sessions. `arx.js` keeps them in memory, and the page saves
  them. fx has no files in the browser.
- **No npm package.** The docs site already serves releases; a tarball
  with a `.sha256` is enough. An npm package can come later.
- **OpenRouter as the free path,** in place of a server proxy.
- **Size.** arx's module is about a ninth of `fx-core.wasm` (spike: 248,795
  bytes raw before `wasm-opt`).

## Current state

The core is 9,314 lines of C11 in `src/` plus vendored cJSON and libyaml.
Everything a browser lacks goes through a few places:

| What | Where | Browser problem |
|---|---|---|
| Process runner for tools, hooks, curl, subagents, schedulers, compactors, credential programs | `src/base/proc.c:95-128` (`posix_spawnp`), `:255-278` (`poll`), `:220-226` (`kill`) | no processes |
| Model call: `[adapter] curl -sS -N --max-time T -D FILE -H @FILE --data-binary @- URL` | `src/model/llm.c:61-104` | no curl |
| `arx request` (for `arx models`): the same curl command again | `src/cli/commands.c:127-170` | duplicate of the above |
| The key reaches curl in a 0600 file in the session folder | `src/model/auth.c:137-166` (file at `:158`) | the page saves the session folder |
| Observers: `sh -c` on a non-blocking pipe; `dup(1)` | `src/io/events.c:134-155`, `:158-174`, `:26` | no `sh`, no `dup` in WASI |
| External commands: `execv` of `arx-NAME` | `src/cli/external.c:111` | no exec |
| `bash` tool: `execlp("sh", "sh", "-c", ...)` | `src/cli/shell_tools.c:106-123` | no exec, no `dup2` |
| Signal handlers | `src/main.c:14-29` | no `sigaction` |
| Subagents: `g_self -p - --spec PATH --json --events fd:3` | `src/harness/tool_exec.c:105-134` | a process |
| "Executable" checks with `access(X_OK)` or mode bits | `src/harness/tools.c:240`, `hooks.c:142`, `validate.c:266,289,331`, `describe.c:16,21`, `kits.c:47`, `src/agent/scheduler.c:75`, `src/cli/check.c:31`, `external.c:80` | WASI has no mode bits: every file passes |
| Retry wait: `nanosleep` | `src/base/util.c:330-336` | blocks the thread |
| Hot reload by `stat()` mtime and size | `src/harness/signature.c:25`, `:63` | needs ns mtimes from the runtime's files |
| `last` session link: `symlink`, `rename`; `realpath` | `src/io/session.c:23-29`, `:50` | needs `readlink` and `symlink` |
| Interactive mode: `getline` on stdin | `src/agent/run.c:123` | stdin must suspend |

### Spike results (2026-11-09)

The spike used `zig cc` 0.17.0 (`-target wasm32-wasi`, bundled wasi-libc)
on a copy of the code in the scratchpad.

- **Compile**: 40 of 45 files compile unchanged. The five that fail are the
  process layer: `main.c`, `proc.c`, `events.c`, `external.c` and
  `shell_tools.c`.
- **Size**: with those stubbed, the core links at 248,795 bytes raw, 93,129
  gzip, 80,283 brotli (`-Os`, LTO, `--gc-sections`, stripped, no
  `wasm-opt`). The native binary is 221,264 bytes.
- **Imports**: 23 WASI preview1 functions, plus the spike's four
  `arx.http_*`.
- **Headless**: under `node:wasi` (Node 22), `arx --version`, `arx check`
  and `arx -p` ran in 1 to 8 ms and stopped at the model call.
- **JSPI**: in Bun 1.3.14 (JavaScriptCore), a suspending `http_read` fed
  `fetch` chunks to arx's own `sse.c` as the server sent them, 150 ms apart.
- **Browser**: in the Claude app's browser pane (Chromium, not
  cross-origin isolated), with files in memory: compile and instantiate in
  10 to 18 ms; `arx -p "say hello" --json` loaded the spec, wrote the
  session files, streamed the reply, and exited 0 after 776 ms (the mock
  streamed for 750 ms).

What broke, and the fix:

| Found | Fix |
|---|---|
| `access(X_OK)` succeeds for every file, so a non-executable `tools/now` became a tool | `IsRunnable()`, answered by `arx.js` |
| musl's `realpath` fails when `readlink` returns `ENOTSUP`, so the session folder could not be made | `arx.js` returns `EINVAL` for a non-link |
| no `symlink` in the shim, so `.arx/sessions/last` is missing | `arx.js` supports symlinks |
| relative paths resolve from `/` | `arx.js` preopens the workspace as `/` |
| the terminal view writes ANSI colors | `arx.js` runs `--quiet`; the page draws events |
| the key reaches curl in a session file | headers stay in memory; `arx.js` adds the key |
| Bun's `node:wasi` polyfill hung before the first file call | `arx.js` implements WASI itself, as fx does |

### Provider checks (2026-11-09)

CORS, from `curl` preflights and real requests without a key, with an
`Origin` header:

| Endpoint | Preflight | Real reply has `Access-Control-Allow-Origin` | Exposes `retry-after` |
|---|---|---|---|
| `openrouter.ai/api/v1/chat/completions` | 204, `*`, `Authorization` allowed | yes, `*`, also on 401 | no |
| `openrouter.ai/api/v1/auth/keys` (PKCE exchange) | 204, `*` | not tested | no |
| `ai-gateway.vercel.sh/v1/chat/completions` | 200, echoes the origin | **no on 401** | yes |
| `ai-gateway.vercel.sh/v1/models` | n/a | yes | yes |
| `api.vercel.com/login/oauth/device-authorization` and `/token` | 200, `*` | yes, `*`, on 400 | n/a |
| `api.openai.com/v1/responses` and `/v1/models` | 200, `*` | yes, `*`, also on 401 | no |
| `auth.openai.com` token endpoints | 200, `*` | yes, `*` | n/a |
| `auth.openai.com` discovery and JWKS | n/a | **no** | n/a |
| `arx-documentation.vercel.app/archive/main.tar.gz` | n/a | **no** | n/a |

Docs (fetched 2026-11-09):

| Fact | Source |
|---|---|
| OpenRouter PKCE: `https://openrouter.ai/auth?callback_url=…&code_challenge=…&code_challenge_method=S256`, then `POST /api/v1/auth/keys {code, code_verifier, code_challenge_method}` returns `{key}`, "user-controlled". No registration. Codes expire after 10 minutes. | openrouter.ai/docs/use-cases/oauth-pkce |
| `:free` models: 20 requests a minute; 50 a day, or 1,000 after buying 10 credits. A key is required. "If you need a key without a limit, keep it out of client-side code." | openrouter.ai/docs/api-reference/limits, /authentication |
| Gateway: "Every request to AI Gateway requires Vercel authentication." Keys take `expiresAt` and a budget. "Do not expose your Gateway API key or OIDC token to browser clients." | vercel.com/docs/ai-gateway/authentication-and-byok, ai-sdk.dev |
| Sign in with Vercel: no device flow and no AI Gateway scope documented; a community request asks for the scope. | vercel.com/docs/sign-in-with-vercel, community.vercel.com/t/29083 |
| Sign in with ChatGPT: open-source and locally hosted apps; redirect on `127.0.0.1`; "Keep tokens out of browser storage". | developers.openai.com/siwc/token-sharing-open-source |
| JSPI on by default: Chrome and Edge 137 (2025-05-27), Firefox 153 (2026-07-21), Safari 27.0 (2026-09-14). Node 24 needs `--experimental-wasm-jspi`. | web-features `wasm-jspi`, MDN Firefox 153, webkit.org/blog/18325, fx.sh/docs/lib/webassembly |
| just-bash 3.6.0: Apache-2.0, beta, in-memory files, the core shell runs in browsers; `python3`, `sqlite3`, `js-exec` need Node. | npm, vercel-labs/just-bash |
| WebContainers: needs COOP and COEP; "Licensing is required for production usage … in a commercial, for-profit setting". | webcontainers.io |

## Design

```text
 docs site (arx-documentation.vercel.app)          this repo's release
 ┌─────────────────────────────────────────┐       arx-wasm32-wasi.tar.gz
 │ page: chat view, settings, Stop         │       ┌───────────────────────┐
 │ sign-in: OpenRouter PKCE, Gateway key   │       │ arx.wasm              │
 │ storage: OPFS / IndexedDB               │ uses  │ arx.js  (runtime)     │
 │ just-bash bridge, sandbox iframe        │──────▶│ arx.d.ts              │
 │ worker ──────────────────────────────┐  │       │ files/ (shell, kit)   │
 │   arx.js ─ arx.wasm instances        │  │       └───────────────────────┘
 │   fetch() to the provider            │  │
 └──────────────────────────────────────┴──┘
```

### Toolchain: `zig cc` and `wasm-opt`

Build with `zig cc -target wasm32-wasi`, pinned by version and SHA-256 in
CI. It is one static download for macOS and Linux, it bundles wasi-libc,
and the spike used it. fx builds its modules with the same toolchain.
`WASI_CC` can name wasi-sdk's clang instead (`--target=wasm32-wasip1`);
both use wasi-libc.

Then run binaryen's `wasm-opt -Oz --strip-debug --strip-producers`, as fx
does, when it is installed. The release build requires it.

Not Emscripten: 40 files compile as they are, and Emscripten would add a
runtime and a file system the plan doesn't need.

Size budget, checked in CI next to `make bench`:

| Part | Budget | Measured |
|---|---|---|
| `arx.wasm`, raw | 300 KB | 248,795 bytes in the spike, before `wasm-opt` |
| `arx.wasm`, brotli | 100 KB | 80,283 bytes |
| `arx.js`, minified | 30 KB | fx's `wasm-runtime.js` is 42,635 bytes unminified |
| Compile and instantiate | 50 ms | 10 to 18 ms |
| One more instance (subagent, `arx tool edit`) | 10 ms | not measured |

### Async: JSPI only

The core keeps its blocking calls. `arx.js` marks the imports that wait
(`poll`, `sleep`, and `fd_read` on stdin) as `WebAssembly.Suspending` and
wraps the entry point in `WebAssembly.promising`. fx does the same and has
no fallback.

- JSPI ships on by default in Chrome 137, Firefox 153 and Safari 27.0.
  `supportsJspi()` lets the page show an update message to other browsers.
- Not Asyncify: a second, larger build for browsers that are being
  replaced.
- Not `Atomics.wait` in a worker: it needs cross-origin isolation, which
  breaks OAuth redirects in popups and third-party embeds. fx.sh sends no
  COOP or COEP either.
- Not a step-driven loop: it would rewrite `RunTurns`, `LlmChatWith`,
  `RunToolCalls`, `HookRun` and `Compact`, and fork the core.

### The platform layer

The platform layer is a small set of functions with two implementations,
chosen by the Makefile:

- **Native**: `src/base/proc.c`, as today, plus the POSIX code that moves
  into it.
- **Browser**: a new `src/base/proc_host.c`, built only for wasm, on the
  [host interface](#the-host-interface-abi-v1).

No `#ifdef __wasi__` goes into the rest of `src/`. `src/base/base.h` gets
a `// ---- platform ----` section that both files must implement. The
`Proc` API stays the seam for every child, including what other 0.2.0
items add (`ProcKeep`, `ProcRelease`, `ProcStop`, `ProcClose`,
`ProcCloseInput`, `ProcPollWith`).

New in `src/base/base.h`:

```c
// ---- platform (proc.c natively, proc_host.c in the browser) ----

// Installs the SIGINT/SIGTERM handlers and ignores SIGPIPE (from main.c).
void ProcInit(void);

// Replaces this process with `argv`; with `null_stdin`, stdin becomes
// /dev/null and SIGPIPE its default. Returns only on failure (errno says
// why; ENOSYS in the browser).
int ProcExec(char* const* argv, int null_stdin);

// True when `path` is a regular file this platform can run: natively
// executable by us; in the browser, a file the runtime has a runner for.
int IsRunnable(const char* path);

// Starts `sh -c command` reading the event stream; returns the write end
// (non-blocking, close-on-exec) and sets *pid, or returns -1.
int ProcObserverStart(const char* command, char* const* env, int* pid);

// Waits up to `secs` for observer `pid` to exit.
void ProcObserverWait(int pid, double secs);

// A close-on-exec copy of fd 1 for `--events -`, or -1.
int ProcDupStdout(void);

// Sleeps for `s` seconds, returning early if g_interrupted is set (moves
// from util.c).
void SleepSeconds(double s);

// ---- HTTP (http.c, on top of the platform) ----

// One HTTP request. Headers stay in memory: the native build writes them
// to a 0600 file for curl itself and deletes it.
typedef struct HttpRequest {
  const char* method;   // "GET" or "POST"
  const char* url;
  const char* headers;  // "Name: value\n" lines
  const char* body;     // or NULL
  size_t body_len;
  double timeout;       // seconds for the whole call; 0 means none
  const char* adapter;  // endpoint.adapter program, or NULL
  const char* tmp_dir;  // native: where the header files go
  DataFn on_body;       // body bytes as they arrive
  void* body_ctx;
} HttpRequest;

// How it ended.
typedef struct HttpResult {
  int status;          // HTTP status of the last response, 0 if none
  double retry_after;  // seconds, or -1
  int net_error;       // 0, or a curl exit code: 6, 7, 28, 35, 52, 56...
  int interrupted;
  int spawn_failed;    // native: curl or the adapter did not start
  Buffer err;          // curl's stderr, or the runtime's error text
  double secs;
} HttpResult;

// Starts a request; ProcPoll runs it like a child. NULL if it could not
// start (errno says why).
ProcChild* HttpStart(const HttpRequest* req);

// Ends a started request (stopping it if needed), fills `r`, frees `c`.
void HttpFinish(ProcChild* c, HttpResult* r);

// HttpStart, ProcPoll until done, HttpFinish. Returns 0, or -1.
int HttpRun(const HttpRequest* req, HttpResult* r);
```

`HttpStart` returns a `ProcChild` so that `ProcPoll` serves model calls,
tools and MCP requests in one loop. Natively it is the curl child; in the
browser it is a `fetch` handle.

How callers change:

| Call site | Today | After |
|---|---|---|
| `src/model/llm.c:61-104` `Attempt` | curl argv, `WriteRequestHeaders`, `ProcRun`, `ReadResponseHeaders` | an `HttpRequest` and `HttpRun`; `Classify` reads `HttpResult`, and `net_error` keeps curl's codes, so `RetryableCurl` stays |
| `src/cli/commands.c:127-170` `Request` | a second copy | `HttpRun` with `on_body` writing to stdout |
| `src/model/auth.c:137-166` `WriteRequestHeaders` | writes the file | `RequestHeaders(root, streaming, Buffer* out)`; the file moves into native `HttpStart` |
| `src/main.c:14-29` | `InstallSignals` | `ProcInit()` |
| `src/cli/external.c:111` | `execv` | `ProcExec(args, 0)` |
| `src/cli/shell_tools.c:115-121` | `open`, `dup2`, `signal`, `execlp` | `ProcExec({"sh","-c",cmd}, 1)` |
| `src/io/events.c:26`, `:134-155`, `:165` | `dup`, `pipe` and `posix_spawnp`, `waitpid` | `ProcDupStdout`, `ProcObserverStart`, `ProcObserverWait` |
| the eleven `access(X_OK)` and mode-bit checks | inline | `IsRunnable(path)` |
| `src/base/util.c:330` | `SleepSeconds` | moves to `proc.c` |

In `proc_host.c`: `ProcInit` does nothing, `ProcExec` and
`ProcObserverStart` fail with `ENOSYS` (so `arx foo` is an unknown command
and `observers:` add one `note` event), `ProcDupStdout` returns -1,
`IsRunnable` asks `arx.js`, `SleepSeconds` and `ProcPoll` suspend, and
`HttpStart` opens a `fetch`. It also holds the exports `arx_main` and
`arx_abi`.

### The host interface (ABI v1)

The contract between `arx.wasm` and `arx.js`. Both ship in one tarball,
so it never crosses a release. Imports are in module `arx`; pointers are
offsets into the module's memory; strings are UTF-8 `(ptr, len)`.

| Import | Suspends | Does |
|---|---|---|
| `http_open(req, req_len, body, body_len) -> id` | no | starts a `fetch`. `req` is JSON: `{"method", "url", "headers": [[name, value], ...], "timeout_ms", "adapter"}`. Returns an id > 0, or `-errno`. |
| `task_start(req, req_len, stdin, stdin_len) -> id` | no | starts a child. `req`: `{"argv", "env": ["K=V", ...], "cwd", "timeout_ms", "open_in", "fd3", "keep_on_interrupt"}`. `-ENOENT` when no runner takes `argv[0]`. |
| `poll(ids, n, wait_ms) -> k` | yes | waits until one handle has output or ended, or `wait_ms` passed. Returns how many are ready, or -3 on Stop. |
| `read(id, stream, buf, cap) -> n` | no | stream 1 is stdout or the response body, 2 stderr, 3 fd 3. Bytes, 0 at end, -2 when nothing waits. |
| `write(id, buf, len) -> n` | no | stdin of an `open_in` child |
| `status(id, out, cap) -> n` | no | JSON `{"done", "code", "timed_out", "secs", "http_status", "retry_after", "net_error", "error"}` |
| `close(id)` | no | stops the child or aborts the `fetch`; frees the handle |
| `runnable(path, len) -> 0 or 1` | no | does a runner take this file |
| `sleep(ms) -> 0 or -3` | yes | a timer; -3 on Stop |

When `poll` or `sleep` returns -3, `proc_host.c` sets `g_interrupted = 1`
and arx takes its Ctrl-C path. `arx.js` maps `fetch` failures to curl's
exit codes: no response to 7, a timeout to 28, a broken stream to 56. Then
`Classify` (`src/model/llm.c:123`) retries as it does natively.

Exports: `memory`, `_initialize`, `arx_main() -> exit code` (reads its
arguments with WASI `args_get` and calls `main`), and `arx_abi() -> 1`.

WASI preview1, implemented by `arx.js` over its files: `args_get`,
`args_sizes_get`, `environ_get`, `environ_sizes_get`, `clock_time_get`,
`random_get`, `fd_close`, `fd_fdstat_get`, `fd_fdstat_set_flags`,
`fd_filestat_get`, `fd_prestat_get`, `fd_prestat_dir_name`, `fd_read`
(suspends on fd 0), `fd_readdir`, `fd_seek`, `fd_write`,
`path_create_directory`, `path_filestat_get`, `path_open`,
`path_readlink`, `path_remove_directory`, `path_rename`, `path_symlink`,
`path_unlink_file`, `poll_oneoff` (clock only) and `proc_exit`.
`scripts/wasm-imports.sh` fails the build on any other import.

Fd 3 is the `/` preopen. Fd 4 is the event sink for `--events fd:4`; its
`fd_prestat_get` returns `EBADF`, where wasi-libc stops looking for
preopens.

### `arx.js`: the runtime

One ES module with no dependencies, for a dedicated worker or for Node 24
and Bun. It is the only API the docs site uses:

```js
import { createArx, supportsJspi } from './arx.js'

const arx = await createArx({
  wasm,          // URL, Response, bytes or WebAssembly.Module
  files,         // optional: {path: string | Uint8Array} to start from
  fetch,         // optional: defaults to globalThis.fetch
  credentials,   // (url) => headers or null, for the provider's origin
  shell,         // optional: {exec({command, cwd, signal, timeoutMs})}
  runners,       // optional: {runnable(path), run({path, argv, stdin,
                 //   env, cwd, signal})}
  onChange,      // optional: (path) => void, after each write
})

const session = arx.session({ args: ['--kit', 'browser'] })
for await (const event of session.prompt('Fix the failing test')) {
  // arx events, as in events.jsonl, until prompt.end
}
session.stop()                      // the Ctrl-C path
session.answer(callId, optionId)    // an `ask` from long-lived-hooks
await session.close()               // EOF on stdin: the session ends
arx.files.read(path); arx.files.write(path, data); arx.files.snapshot()
```

What it does:

- **Sessions**: one instance per session runs
  `arx --input jsonl --quiet --events fd:4` with the session's args, as fx
  runs one `fx acp` instance. `prompt()` writes `{"prompt": TEXT}` to stdin
  and yields events until `prompt.end`. `answer()` appends to the session's
  `inbox`, which arx already reads. Until `--input jsonl` lands, each
  prompt runs `arx -p TEXT --resume ID`.
- **Children**: `task_start` with `argv[0]` equal to `g_self` (`/arx`)
  starts an instance on the same files, for subagents and `arx tool edit`.
  `/arx tool bash` goes to `shell.exec`. Any other path goes to `runners`,
  or fails with `ENOENT`. Instances switch only at suspending imports, so
  a `WriteFileAtomic` (temp file, then rename) is atomic for the others.
- **Files**: one tree in memory, with ns mtimes, `readlink` that returns
  `EINVAL` for a non-link, symlinks, atomic rename and `O_APPEND`. `/` is
  the workspace, `/.config/arx/` the config folder, and `/arx/` the
  read-only files from the tarball. `onChange` and `snapshot()` let the
  page save the tree; `arx.js` never touches browser storage.
- **Keys**: `credentials(url)` returns headers that `arx.js` adds to a
  request just before `fetch`, only for an origin the page named. The core
  runs with no key (`ApiKey()` finds none, so it sends no `Authorization`),
  so no key is in its memory, its files or a tool's environment. fx does
  the same.
- **Adapters**: `endpoint.adapter` names a program, which can't run here.
  `arx.js` rejects it with a clear error; a browser adapter contract can
  come later.

### The release asset

`make dist TARGET=wasm32-wasi` builds:

```text
arx-wasm32-wasi/
  arx.wasm               the core, wasm-opt -Oz
  arx.js                 the runtime
  arx.d.ts               its types
  files/arx/plugins/shell/   the shell plugin, read-only at /arx
  files/arx/kits/browser/    the browser kit
  LICENSE
arx-wasm32-wasi.tar.gz.sha256
```

The release workflow uploads it next to the native tarballs, and the docs
site serves it at `/releases/download/VERSION/arx-wasm32-wasi.tar.gz`, as
it does the others.

`kits/browser` sets `plugins: [shell]` and a prompt in the spirit of fx's
`browser_capabilities.zig`: `bash` is a virtual shell with no network, no
`git`, `python3`, `node` or package managers, and files live in the
browser.

### What the docs site builds

A sketch, for the docs repo's own plan:

- **Getting the files**: at build time, download the tarball for a pinned
  version, check its `.sha256`, and copy `arx.wasm` and `arx.js` to
  content-hashed paths. Serve the module with `Content-Type:
  application/wasm`, brotli, an immutable cache header, and a preload link,
  as fx.sh does. No COOP or COEP.
- **The page**: a worker that runs `arx.js`; a chat view that draws events
  (as `src/io/render.c` does), settings, Stop, and file import and export.
- **OpenRouter sign-in**: redirect to `https://openrouter.ai/auth` with
  `callback_url` set to the page, PKCE S256 and `state`; on return, post the
  code to `/api/v1/auth/keys`. The page writes `config.yaml` with
  `base_url: https://openrouter.ai/api/v1` and a `:free` model that
  supports tools, and returns the key from `credentials()` for
  `https://openrouter.ai`.
- **Vercel AI Gateway**: a pasted key, checked once (load `/v1/models`,
  then one short chat request), with advice to set a budget and an expiry.
- **Keys at rest**: memory by default; "Remember on this device" stores the
  key in IndexedDB, encrypted with a non-extractable `CryptoKey`. That
  protects a copy on disk, not against code in the origin. fx.sh uses
  `localStorage`; the plan does not.
- **just-bash**: loaded on the first `bash` call, behind `shell.exec`,
  over a bridge to `arx.files`. Limits as fx's workspace: 64 KiB command,
  64 KiB of output, 30 s.
- **JavaScript tools**: a `runners` that runs a `NAME.js` sibling in a
  sandboxed iframe with an opaque origin, so it can't read storage or keys,
  and a CSP `connect-src` from the plugin's `hosts:`.
- **Persistence**: `snapshot()` into OPFS after each `prompt.end` and on
  `onChange` while idle; `navigator.storage.persist()`.
- **CSP**: `script-src 'self'`, no inline scripts, no third-party scripts.
- **Optional**: a free-token proxy, as fx.sh's `/fx-wasm/gateway/*`, if the
  site wants a try page with no sign-in. It is server code with a site key
  and a cost.

## Implementation steps

This repo, all in 0.2.0. Native behavior does not change.

1. **One HTTP function** (`src/base/http.c` new, `src/base/base.h`,
   `src/base/proc.c`, `src/model/llm.c`, `src/model/auth.c`,
   `src/model/model.h`, `src/cli/commands.c`): `HttpRequest`, `HttpResult`,
   `HttpStart`, `HttpFinish` (curl and the adapter, in `proc.c`) and
   `HttpRun`; `RequestHeaders` replaces `WriteRequestHeaders`.
   `tests/fake-curl` and `tests/credentials.sh` pass unchanged.
2. **The platform section** (`src/base/base.h`, `src/base/proc.c`,
   `src/base/util.c`, `src/main.c`, `src/io/events.c`,
   `src/cli/external.c`, `src/cli/shell_tools.c`): `ProcInit`, `ProcExec`,
   `ProcObserverStart`, `ProcObserverWait`, `ProcDupStdout`, and
   `SleepSeconds` moved.
3. **`IsRunnable`** (`src/base/proc.c` and the eleven call sites).
4. **`src/base/proc_host.c`**: the wasm side of the platform section and
   `HttpStart`, on ABI v1, with `arx_main` and `arx_abi`. Stubs for the
   `Proc` functions other items add, until `arx.js` can serve them.
5. **Build** (`Makefile`, `scripts/wasm-imports.sh`): `make wasm` with
   `WASI_CC ?= zig cc -target wasm32-wasi`, the sources `$(SRC)` without
   `src/base/proc.c` plus `src/base/proc_host.c`,
   `-Os -flto -ffunction-sections -fdata-sections -mexec-model=reactor
   -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_GETPID`,
   `--gc-sections -s`, then `wasm-opt -Oz`; the import check.
6. **`arx.js` and `arx.d.ts`** (`wasm/arx.js`, `wasm/arx.d.ts`): ABI v1,
   WASI over the in-memory tree, the `fetch` bridge with `credentials`,
   instances, sessions, `shell` and `runners`, `supportsJspi()`.
7. **Browser files** (`kits/browser/kit.yaml`,
   `kits/browser/prompts/system.md`).
8. **Tests** (`tests/wasm.sh`, `tests/wasm/mock.mjs`): see [Tests](#tests).
9. **Release** (`Makefile` `dist` for `TARGET=wasm32-wasi`,
   `.github/workflows/release.yml`, `.github/workflows/ci.yml`): build with
   pinned `zig` and binaryen, run `make wasm-test` under Node 24 with
   `--experimental-wasm-jspi`, check the size budget, upload the tarball and
   its `.sha256`.
10. **Docs**: [Docs to change](#docs-to-change).

The docs repo, after a 0.2.0 pre-release:

11. Download and serve the pinned tarball; response headers.
12. The worker and the chat view on `arx.js` sessions and events.
13. OpenRouter PKCE, the Gateway key, the key store, `credentials()`.
14. just-bash behind `shell`, the sandbox iframe behind `runners`.
15. Saving to OPFS, import and export.
16. Playwright on Chromium, Firefox and WebKit.
17. The browser page in the docs, and `/try`.

## Tests

In this repo:

- **Native**: every suite in `make test` passes after steps 1 to 3, with
  new cases for `IsRunnable` (a non-executable file in `tools/` is still
  skipped) and for `arx request` through `HttpRun`.
- **Lint**: `scripts/lint.sh` fails when a file other than `proc.c` uses
  `posix_spawn`, `exec*`, `fork`, `pipe`, `dup`, `kill` or `waitpid`.
- **`make wasm`**: no warnings, only ABI v1 and the WASI list as imports,
  within the size budget.
- **`tests/wasm.sh`**, with `arx.js` under Node 24 and a mock Chat
  Completions server:
  - `arx --version`, `arx check --spec`, `arx schema` match native output.
  - A session: two prompts in one instance; deltas arrive as they are
    sent; `prompt.end` carries `done`, tokens and cost.
  - `credentials()`: the mock sees the header; a request to another origin
    doesn't; the key is in no file of `snapshot()`.
  - 429 with retries, 401 to exit 4, Stop mid-stream to `interrupted`.
  - A tool call through `runners`, `edit` through a second instance, and
    `bash` through a fake `shell`.
  - A subagent: its events arrive with `depth: 1`.
  - Hot reload: a write to `agent.yaml` between prompts gives a
    `harness.reload` event.
  - The files: `readlink` on a non-link is `EINVAL`, `realpath`, symlinks,
    rename over a file, ns mtimes, `O_APPEND`.
  - `supportsJspi()` is false without the flag.

In the docs repo: Playwright across the three engines, a turn against a
mock provider, Stop, a reload that keeps the session, the sandbox (no
storage, no `fetch` outside `hosts:`), and by hand before each release one
OpenRouter `:free` turn and one Gateway turn. `scripts/cors-check.sh` in
this repo repeats the CORS table and fails if a header went away.

## Docs to change

Every page follows `docs/WRITING.md`: the first sentence defines the
subject, planned behavior is in the future tense or on a planned page,
headings are sentence case, there are no em dashes, and every command runs
as shown.

This repo, in 0.2.0:

- **`docs/architecture.md`**: in "Source layout", the platform section of
  `src/base/proc.c`, `src/base/proc_host.c`, `src/base/http.c` and
  `wasm/`; in "Building and testing", `make wasm` and `make wasm-test`; in
  "CI and releases", the wasm tarball; in "Design decisions", that model
  calls go through `HttpRun`, which runs curl natively.
- **`docs/browser.md`** (new, a reference page, "The browser build"): what
  the tarball holds, the `arx.js` API, ABI v1 for anyone who embeds arx,
  what runs in a browser and what doesn't, and the size budget. The page
  that hosts arx is the docs site's own.
- **`docs/roadmap.md`**: a row for the browser build, done in 0.2.0, with
  the page on the docs site.
- **`docs/plugins/planned.md`**: "Plugins in the browser": runners decide
  what runs, `.js` siblings on the docs site, `hosts:` as its network
  allow list, and no Python.
- **`plugins/chatgpt/README.md`**: one line: the browser build has no
  ChatGPT sign-in, and why.

The docs repo, with the page: a guide, "Run arx in the browser" (sign in
with OpenRouter, pick a free model, what `bash` can do, where files and
keys live), and its entry in `src/lib/nav.mjs`.

## Dependencies

| Slug | Why | Order |
|---|---|---|
| `acp-tui` | `--input jsonl` (its step 2) and the `prompt.start` and `prompt.end` events (its step 1) give `arx.js` one instance per session. `ProcPollWith` (its step 3) is a new `Proc` function. | Land acp-tui part 1 before wasm step 6. If it slips, `arx.js` runs one instance per prompt with `--resume`. |
| `async-calls` | adds `ProcKeep`, `ProcRelease`, `ProcStop` | after wasm steps 1 to 3; `proc_host.c` follows each new function |
| `long-lived-hooks` | adds `ProcClose`, `LineSink`, `LinePop`; the `ask` contract and the inbox `answer` line | as above; `session.answer()` writes its inbox line |
| `mcp-client` | its HTTP bridge | builds on `HttpStart` (settled in the release plan). stdio servers can't run in a browser |
| `sandboxes` | `arx tool bash` and `edit` refuse when `ARX_SANDBOX` is set and `ARX_IN_SANDBOX` is not 1 | `arx.js` sets `ARX_IN_SANDBOX=1` for its own `bash` and `edit` |
| `installer` | the release workflow and `make dist` | the wasm tarball joins the same release |
| `trust`, `plugin-state`, `plugin-yaml-keys` | files and hooks | no conflict |
| `arx-plugin` | downloads | none: the browser build ships its plugin in the tarball. Runtime installs from the site need CORS on `/archive/` |
| `climb` | none | |

## Size and risks

**This repo: M.** About 300 lines of C change, most of them moves, plus
`proc_host.c` (about 250 lines), `arx.js` (about 900 lines with WASI and
the file tree), the tests (about 300 lines of JS) and the release job.
**The docs repo: M to L** for the page, sign-in, storage and the sandbox.

Risks:

- **Two `proc` files drift.** `make wasm` in CI makes a missing function a
  link error.
- **The ABI is new.** Both halves ship in one tarball and `arx_abi()` is
  checked, so a site can't mix versions.
- **just-bash is beta** and its browser size is not measured. Without it,
  the site turns `bash` off and the kit says so.
- **CORS can change** on any provider. `scripts/cors-check.sh` runs before
  each release.
- **Gateway CORS on errors**: a rejected key looks like a network error.
- **Free model limits**: 50 requests a day is a few short runs.
- **Browsers without JSPI** (Safari before 27, Firefox before 153) can't
  run it.

## Release fit

- **0.2.0** ships the whole of this repo's part, steps 1 to 10: the seams
  in wave 1, then `proc_host.c`, `make wasm`, `arx.js`, the browser kit,
  the tests and `arx-wasm32-wasi.tar.gz` in the release. That is what the
  docs site needs to host arx.
- **Docs repo**, steps 11 to 17: on its own schedule, from a 0.2.0
  pre-release. Nothing there changes this repo.
- **After 0.2.0**: a browser adapter contract, runtime plugin installs, an
  npm package if others want to embed arx, and a Gateway sign-in if Vercel
  opens an AI Gateway scope.

## Open decisions

1. **What 0.2.0 ships.** Recommend all of this repo's part (steps 1 to 10),
   so the docs site can host arx from the 0.2.0 release. The smaller
   choice is the seams and `make wasm` only, with `arx.js` in 0.3.0, which
   leaves the site nothing to host.
2. **The keyless path.** Recommend OpenRouter sign-in with a `:free` model,
   with no server. A free-token proxy on the docs site, as fx.sh has, is a
   docs-repo choice with a running cost.
3. **ChatGPT in the browser.** Recommend none. OpenAI's rules and fx's own
   choice point the same way.
4. **Toolchain.** Recommend `zig cc` with `wasm-opt -Oz`, as fx and the
   spike use; wasi-sdk through `WASI_CC` stays possible.
5. **Asyncify fallback.** Recommend none: JSPI ships in all three engines,
   and fx has none.
6. **Distribution.** Recommend a release tarball with a `.sha256`, served
   by the docs site like the native ones. An npm package can come later.
7. **Session mode.** Recommend `--input jsonl` from acp-tui part 1, one
   instance per session. The fallback is one instance per prompt with
   `--resume`. ACP over `postMessage` can come later.
8. **Where `arx.js` lives.** Recommend `wasm/` in this repo, next to the
   `Makefile` target that builds `arx.wasm`.
9. **Keys at rest on the site.** Recommend memory by default and an opt-in
   encrypted copy in IndexedDB, never `localStorage`.
10. **CI runtime.** Recommend Node 24 with `--experimental-wasm-jspi`, as
    fx's tests use, so CI needs no Bun.
