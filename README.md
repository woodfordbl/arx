# arx

`arx` is a minimal agent harness for autoresearch-style hill climbing: an agent
works on one task without supervision, and **improves its own harness as it
goes**. It writes its own tools, hooks, prompts and compaction settings, and
those edits take effect on its next turn.

The core is one C binary that does as little as possible. Everything else is a
plugin: an executable in any language.


| Measured                   | macOS (arm64)       | Linux (static, musl)   |
| -------------------------- | ------------------- | ---------------------- |
| Binary                     | 183 KB              | 258 KB, libc included  |
| Startup                    | 0.6 ms above `true` | within noise of `true` |
| Peak memory over 500 turns | 4 MB                | 7 MB                   |
| Harness edit to live       | 0.10 ms             | 0.05 ms                |


`make bench` checks these budgets and fails the build if one is missed. On
macOS, a tool the agent has just created takes ~35 ms to go live, because the
OS checks every new executable the first time it runs. On Linux it takes
0.2 ms.

## Install

From a release (macOS and Linux, x86_64 and arm64):

```sh
sh install.sh                # or: curl -fsSL <raw install.sh URL> | sh, once public
```

From source (needs a C compiler):

```sh
make install                 # arx into ~/.local/bin, its commands into ~/.local/libexec/arx
```

Then:

```sh
arx setup                    # provider, API key (saved in your Keychain), default model
arx                          # talk to the agent, in any folder
arx -p "Find the largest file here" --cap usd=1   # one task, then exit
arx watch                    # follow the latest session from another terminal
arx update                   # newest release, checksum-verified
```

`arx setup` saves your defaults in `~/.config/arx/config.yaml`. A project's
`agent.yaml`, created by `arx init`, only needs what differs from them.

API keys are found the way fx finds them:
1. the environment variable named by `endpoint.api_key_env`;
2. otherwise, the key `arx setup` saved: in the macOS Keychain (service `arx`),
   or in `~/.config/arx/credentials` with 0600 permissions elsewhere.

The key reaches `curl` in a 0600 file, never on a command line.

Any OpenAI-compatible Chat Completions endpoint works: Vercel AI Gateway,
OpenRouter, LiteLLM, Ollama, vLLM or OpenAI. `arx` sends requests with `curl`,
so the binary has no TLS code. For a full self-improving setup, see
[examples/tsp](examples/tsp).


| Provider                                           | `endpoint`                                                                       | Model ids                                                                 |
| -------------------------------------------------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| [Vercel AI Gateway](https://vercel.com/ai-gateway) | `{base_url: "https://ai-gateway.vercel.sh/v1", api_key_env: AI_GATEWAY_API_KEY}` | `anthropic/claude-haiku-5.5`, `openai/gpt-5-mini`, ... (`GET /v1/models`) |
| OpenRouter                                         | `{base_url: "https://openrouter.ai/api/v1", api_key_env: OPENROUTER_API_KEY}`    | `anthropic/...`, `openai/...`                                             |
| Ollama (local)                                     | `{base_url: "http://localhost:11434/v1"}`                                        | whatever you pulled, e.g. `qwen2.5-coder:7b`                              |


**Cost tracking:**

- `arx` uses the cost the provider reports.
- With Vercel AI Gateway and your own provider key, the gateway reports
`cost: 0` and puts the real price in `market_cost`, which `arx` reads
instead.
- Providers that report no cost use `prices: {input, output}` from the spec
(USD per million tokens).



## The agent spec

One YAML file, validated with line numbers and "did you mean" hints.
`arx schema` prints its JSON Schema for editor autocompletion.

```yaml
name: tsp-climber
model: your/model-id
endpoint: {base_url: https://openrouter.ai/api/v1, api_key_env: OPENROUTER_API_KEY}
model_settings: {temperature: 0.7}          # passed through; null removes a field
instructions: [{file: prompts/system.md}]   # {{vars}}: prompt, harness, skills,
first_message: {file: prompts/first.md}     #   date, cwd, session, turn, file:PATH
tools:
  bash: {timeout: 120}
  quick_eval: {timeout: 60}                 # tools/quick_eval, written by the agent
  researcher: {agent: subagents/r.yaml}     # a subagent: runs arx again
hooks: {stop: {timeout: 10s}}               # hooks/stop
compaction: {strategy: mask, trigger: 0.7, keep: 5}
skills: skills                              # skills/<name>/SKILL.md
limits: {max_turns: 200, turn_timeout: 10m}
observers: ["cat >> all-events.jsonl"]
```

Before every model call, `arx` checks the spec and the files it names, plus
`tools/` and `hooks/`, using `stat` only. If anything changed, it reloads. If an
edit is invalid, the previous version stays in use and the agent is told why.
`--cap` limits (turns, tokens, usd, wall, depth) are set by whoever starts `arx`,
and the spec cannot raise them.

## Plugins

All plugins are executables, in any language. **[docs/plugins.md](docs/plugins.md)**
is the full guide: the exact input and output of each kind, the `ARX_*`
variables they all get, every event type, and the session files.

The agent's own plugins live next to its spec. Plugins you install are
folders with a `plugin.yaml`, loaded in place below the agent's own, so a
tool the agent writes always wins. [plugins/](plugins) is the arx
marketplace, one plugin of each kind; the release leaves it out, so the
install stays bare:

```sh
arx plugin add guard                 # plugins/guard, at the tag of your arx
arx plugin add acme/tools/lint       # a plugin folder in any GitHub repo
arx plugin add --link ./plugins/notify   # develop one in place
arx plugin list
```

`make test` checks every marketplace plugin against the arx of the same
commit.


| Kind      | Where                                               | Contract                                                                                                                                                             |
| --------- | --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Tool      | `tools/<name>`                                      | `--schema` prints `{"description", "parameters"}`. A call gets its arguments as JSON on stdin; stdout and stderr are the result; a non-zero exit marks an error.     |
| Subagent  | `tools: {name: {agent: spec.yaml}}`                 | `arx` runs itself one level deeper. The child's events appear in the parent's stream.                                                                                |
| Hook      | `hooks/<point>`                                     | JSON on stdin; optional JSON decision on stdout. `session_start` adds context; `before_tool` can deny; `after_tool` adds a note; `stop` can `continue` or `restart`. |
| Compactor | `compaction.strategy: <name or path>`               | `{"messages", "usage", "context_window"}` in, `{"messages"}` out.                                                                                                    |
| Observer  | `observers:`, or anything that reads `events.jsonl` | One JSON event per line. A slow observer loses events; the run never waits for it.                                                                                   |
| Driver    | anything that runs `arx -p … --json --events fd:3`  | Exit code, a JSON result, and the event stream. A supervisor is just a driver.                                                                                       |


Built-in compaction strategies:

- `mask` **(the default):** clears old tool outputs and leaves a pointer to the saved file. 
- `summarize`**:** one model call summarizes the older turns.
- `hybrid`**:** mask first, then summarize if the context is still too large.
- `restart`**:** starts from a fresh context each time, like a Ralph loop.



## Roadmap

1. ~~Plugin guide and example plugins~~ (done:
  [docs/plugins.md](docs/plugins.md)).
2. ~~External commands~~ (done: `arx foo` runs `arx-foo`; `setup`, `init`,
  `doctor`, `models`, `sessions` and `update` are built this way).
3. ~~Plugin folders and the marketplace~~ (done: `plugin.yaml`, layers,
  `arx plugin`, [plugins/](plugins)). Still to do: `arx plugin update`,
  `search` and `eject`, named marketplaces, and MCP servers in `plugin.yaml`.
4. `arx acp`**:** an [Agent Client Protocol](https://agentclientprotocol.com)
  server over stdio, for editors and custom front-ends. It shares one small
   JSON-RPC module with the MCP client.
5. **A TUI plugin:** a terminal front-end built with
  [OpenTUI](https://opentui.com) that talks to `arx acp`. It is a plugin, so
   it adds nothing to the binary.
6. **MCP client:** MCP servers in the spec become tools. Their schemas load
  lazily through two built-in tools, `mcp_search` and `mcp_select`.
7. `arx climb`**:** a keep/revert driver that runs the official eval outside
  the agent's reach.



## Command line

```
arx [options]             run the agent (interactive, or headless if stdin is piped)
arx -p TASK|- [options]   run one task until the agent stops
arx setup                 provider, API key and default model (run this first)
arx init [autoresearch]   start a harness in this folder
arx doctor [--live]       check the install, spec, key and endpoint
arx models [FILTER]       the endpoint's models, with prices
arx sessions              the sessions in this folder
arx update [--check]      update to the latest release
arx plugin add|rm|ls|new  install and manage plugins (`arx add` for short)
arx check | tools | schema | request PATH | watch | ctl | version | help
options: --spec --set K=V --cap K=V --resume ID|last --json --events PATH|-|fd:N --quiet
exit codes: 0 done, 1 error, 2 usage, 3 cap reached, 4 auth, 130 interrupted
```

`arx help` lists everything, including any `arx-*` command on your PATH:
`arx foo` runs `arx-foo`, git-style. See
[docs/plugins.md](docs/plugins.md#commands) to write one.

Each session lives in `.arx/sessions/<id>/`:

- `transcript.jsonl`, used by `--resume`;
- `events.jsonl`;
- `meta.json`;
- `tool-NNNN.out`, the full tool outputs;
- `inbox`, for `arx ctl`.



## Development


|                       |                                                                                                                    |
| --------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `make` / `make debug` | release build / AddressSanitizer + UBSan build                                                                     |
| `make test`           | 180 end-to-end checks against `tests/fake-curl` (47 core, 30 marketplace plugins, 46 plugin loading, 57 CLI); no network or API key needed |
| `make bench`          | the performance budgets above                                                                                      |
| `make lint`           | Google style (clang-format, cpplint), files of 400 lines or fewer, doc comments ([docs/STYLE.md](docs/STYLE.md))   |
| `make static`         | static Linux binary, built in Docker                                                                               |
| `make install`        | install arx and its commands into ~/.local (PREFIX=...)                                                            |
| `make dist`           | the release tarball and checksum for this platform, as CI builds them                                               |

**CI** (GitHub Actions) runs on every push to `main` and every pull request:
- **lint**, with clang-format 23.1.3 and cpplint 2.0.2 pinned;
- **all 180 tests and the four performance budgets**, against a static Linux
  build.

**Releases** run the tests and budgets on macOS and Linux before publishing,
so a slow or oversized build fails the release. Startup timing is measured
against `true` on the same machine, and re-measured once before it fails,
because shared CI machines are noisy.


The sources in `src/` have one folder per layer, and one header per folder.
Each layer only uses the layers below it.


| Folder     | Header      | What it holds                                                                                                                                                      |
| ---------- | ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `main.c`   | none        | the command line                                                                                                                                                   |
| `agent/`   | `agent.h`   | the loop (`loop.c`), session lifecycle (`run.c`), prompts and templates (`agent.c`)                                                                                |
| `harness/` | `harness.h` | what the agent can change: • spec loading, validation and schema (`spec.c`, `validate.c`, `schema.c`) • tools (`tools.c`, `tool_exec.c`) • `hooks.c` • `compact.c` |
| `model/`   | `model.h`   | model calls through `curl` (`llm.c`), streamed replies (`sse.c`)                                                                                                   |
| `io/`      | `io.h`      | session files (`session.c`), event stream (`events.c`), terminal view (`render.c`)                                                                                 |
| `base/`    | `base.h`    | buffers and files (`util.c`), JSON helpers (`json.c`), process runner (`proc.c`)                                                                                   |


`vendor/` holds cJSON 1.7.19 and libyaml 0.2.5, unmodified.