# arx

`arx` is a minimal agent harness for autoresearch-style hill climbing: an agent
works on one task without supervision, and **improves its own harness as it
goes**. It writes its own tools, hooks, prompts and compaction settings, and
those edits take effect on its next turn.

The core is one C binary that does as little as possible. Everything else is a
plugin: an executable in any language.

| Measured | macOS (arm64) | Linux (static, musl) |
|---|---|---|
| Binary | 167 KB | 258 KB, libc included |
| Startup | 0.6 ms above `true` | within noise of `true` |
| Peak memory over 500 turns | 4 MB | 7 MB |
| Harness edit to live | 0.06 ms | 0.05 ms |

`make bench` checks these budgets and fails the build if one is missed. On
macOS, a tool the agent has just created takes ~35 ms to go live, because the
OS checks every new executable the first time it runs. On Linux it takes
0.2 ms.

## Quick start

```sh
make                       # builds ./arx (needs a C compiler; curl at run time)
cat > agent.yaml <<'EOF'
name: helper
model: your/model-id
endpoint: {base_url: https://openrouter.ai/api/v1, api_key_env: OPENROUTER_API_KEY}
EOF
export OPENROUTER_API_KEY=...
./arx                       # interactive
./arx -p "Find the largest file here" --cap usd=1   # one task, then exit
./arx watch                 # follow the latest session from another terminal
```

Any OpenAI-compatible Chat Completions endpoint works: OpenRouter, LiteLLM,
Ollama, vLLM or OpenAI. `arx` sends requests with `curl`, so the binary has no TLS
code. For a full self-improving setup, see [examples/tsp](examples/tsp).

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

All plugins are executables, in any language.

| Kind | Where | Contract |
|---|---|---|
| Tool | `tools/<name>` | `--schema` prints `{"description", "parameters"}`. A call gets its arguments as JSON on stdin; stdout and stderr are the result; a non-zero exit marks an error. |
| Subagent | `tools: {name: {agent: spec.yaml}}` | `arx` runs itself one level deeper. The child's events appear in the parent's stream. |
| Hook | `hooks/<point>` | JSON on stdin; optional JSON decision on stdout. `session_start` adds context; `before_tool` can deny; `after_tool` adds a note; `stop` can `continue` or `restart`. |
| Compactor | `compaction.strategy: <path>` | `{"messages", "usage", "context_window"}` in, `{"messages"}` out. |
| Observer | `observers:`, or anything that reads `events.jsonl` | One JSON event per line. A slow observer loses events; the run never waits for it. |
| Driver | anything that runs `arx -p … --json --events fd:3` | Exit code, a JSON result, and the event stream. A supervisor is just a driver. |

Built-in compaction strategies:
- **`mask` (the default):** clears old tool outputs and leaves a pointer to the saved file. "The Complexity Trap" (JetBrains/TUM, 2025) found this matches model-written summaries at half the cost.
- **`summarize`:** one model call summarizes the older turns.
- **`hybrid`:** mask first, then summarize if the context is still too large.
- **`restart`:** starts from a fresh context each time, like the Ralph loop.

## Command line

```
arx [options]                 interactive (headless if stdin is not a terminal)
arx -p TASK|- [options]       run one task until the agent stops
arx check | tools | schema    validate the harness, list tools, print the schema
arx watch [ID|last] [--json]  follow a session's events
arx ctl ID|last stop|note TEXT
options: --spec --set K=V --cap K=V --resume ID|last --json --events PATH|-|fd:N --quiet
exit codes: 0 done, 1 error, 2 usage, 3 cap reached, 4 auth, 130 interrupted
```

Each session lives in `.arx/sessions/<id>/`:
- `transcript.jsonl`, used by `--resume`;
- `events.jsonl`;
- `meta.json`;
- `tool-NNNN.out`, the full tool outputs;
- `inbox`, for `arx ctl`.

## Development

| | |
|---|---|
| `make` / `make debug` | release build / AddressSanitizer + UBSan build |
| `make test` | 46 end-to-end checks against `tests/fake-curl`; no network or API key needed |
| `make bench` | the performance budgets above |
| `make lint` | Google style (clang-format, cpplint), files of 400 lines or fewer, doc comments ([docs/STYLE.md](docs/STYLE.md)) |
| `make static` | static Linux binary, built in Docker |

The sources in `src/` have one folder per layer, and one header per folder.
Each layer only uses the layers below it.

| Folder | Header | What it holds |
|---|---|---|
| `main.c` | none | the command line |
| `agent/` | `agent.h` | the loop (`loop.c`), session lifecycle (`run.c`), prompts and templates (`agent.c`) |
| `harness/` | `harness.h` | what the agent can change:<br>• spec loading, validation and schema (`spec.c`, `validate.c`, `schema.c`)<br>• tools (`tools.c`, `tool_exec.c`)<br>• `hooks.c`<br>• `compact.c` |
| `model/` | `model.h` | model calls through `curl` (`llm.c`), streamed replies (`sse.c`) |
| `io/` | `io.h` | session files (`session.c`), event stream (`events.c`), terminal view (`render.c`) |
| `base/` | `base.h` | buffers and files (`util.c`), JSON helpers (`json.c`), process runner (`proc.c`) |

`vendor/` holds cJSON 1.7.19 and libyaml 0.2.5, unmodified.
