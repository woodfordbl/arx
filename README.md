<h1 align="center">arx</h1>

<p align="center">
  <b>A minimal agent harness that improves itself while it works.</b><br>
  One 183 KB C binary. Every plugin is an executable, in any language.
</p>

<p align="center">
  <a href="docs/getting-started.md">Getting started</a> ·
  <a href="docs/concepts.md">How it works</a> ·
  <a href="docs/autoresearch.md">Self-improving runs</a> ·
  <a href="docs/spec.md">agent.yaml</a> ·
  <a href="docs/plugins.md">Plugins</a> ·
  <a href="docs/cli.md">CLI</a>
</p>

---

arx runs an agent on one task without supervision, for minutes or for days. It
is built for autoresearch-style hill climbing: the agent tries an idea,
measures it, keeps it or reverts it, and tries the next one.

While it works, the agent **improves its own harness**. It writes its own
tools, hooks, prompts and compaction settings, and each edit is live on its
next turn. A bad edit is rejected with a line number and a hint, and the run
goes on.

```
$ arx --spec harness/agent.yaml -p "Start the experiment loop." --cap usd=5
● arx 0.1.0 · tsp-climber · your/model-id · session 20261030-221403-a1b2
  ⏵ bash python3 eval/score > run.log 2>&1; tail -4 run.log
    ↳ exit 0 · 31.2s · 58 B  score: 25102.9
  · 4.1k in · 212 out · $0.0153
  ⏵ edit harness/tools/experiment
    ↳ exit 0 · 0.0s · 0 B  created harness/tools/experiment (1840 bytes)
  ↻ harness reloaded (0.1 ms)
  ⏵ experiment {"idea": "2-opt with neighbour lists"}
```

<sub>An illustrative run: the agent writes itself a tool, and it is live on the
next turn.</sub>

## Why arx

- **Small and fast.** One binary, no runtime. Starts in under a millisecond
  and stays under 8 MB over hundreds of turns. `make bench` fails the build if
  a budget is missed.
- **Everything is a plugin.** Tools, hooks, subagents, compactors, observers,
  drivers and commands are executables that speak JSON. Write them in shell,
  Python or Go, install them with `arx plugin add`, or let the agent write
  them.
- **Hot reload without risk.** arx checks the harness before every model call.
  Valid edits go live at once; invalid ones are rejected and explained to the
  agent.
- **Built for long runs.** Hard caps on cost, tokens, turns and time that the
  agent cannot raise. Compaction keeps the context in bounds. Every session
  can be watched, steered and resumed from another terminal.
- **Any OpenAI-compatible endpoint.** Vercel AI Gateway, OpenRouter, OpenAI,
  LiteLLM, Ollama or vLLM.

| Measured | macOS (arm64) | Linux (static, musl) |
|---|---|---|
| Binary | 183 KB | 258 KB, libc included |
| Startup | 0.6 ms above `true` | within noise of `true` |
| Peak memory over 500 turns | 4 MB | 7 MB |
| Harness edit to live | 0.10 ms | 0.05 ms |

## Quick start

Install the latest release (macOS and Linux, x86_64 and arm64), then set your
provider, key and default model:

```sh
curl -fsSL https://arx-documentation.vercel.app/install.sh | sh
arx setup                    # provider, API key (saved in your Keychain), default model
```

The installer downloads from the arx site, which serves arx's GitHub
releases, checks the release's sha256 and installs into `~/.local`. From a
source checkout, `make install` does the same with your own build.

**Planned:** on a terminal, the installer goes straight on into `arx setup`,
a short wizard you answer with the arrow keys (`--no-setup` skips it). Run
`arx setup` again later for a settings menu: provider and key, model, kit,
plugins, update and doctor.

```sh
arx                                          # talk to the agent, in any folder
arx -p "Find the largest file here" --cap usd=1   # one task, then exit
arx watch                                    # follow the latest session from another terminal
arx init autoresearch                        # start a self-improving harness here
```

For a complete self-improving setup, see [`examples/tsp`](examples/tsp) and
the [self-improving runs guide](docs/autoresearch.md).

## How it works

```
   before each model call                    after it
 ┌──────────────────────────────┐   ┌───────────────────────────────────┐
 │ check caps                   │   │ tool calls → before_tool → run →  │
 │ reload harness if it changed │──▶│              after_tool           │
 │ read the inbox (arx ctl)     │   │ no tool calls → stop hook:        │
 │ hand notes to the agent      │   │   continue, restart, or done      │
 │ compact if over the trigger  │   └───────────────────────────────────┘
 └──────────────────────────────┘
```

An agent is a **spec** (`agent.yaml`) plus the `tools/`, `hooks/`, prompts and
skills next to it. Together they are the **harness**, and the agent may change
any of it. Your defaults from `arx setup` fill in what the spec leaves out, so
a project's spec only needs what differs. The core, one C binary, only runs
the loop. Read [How arx works](docs/concepts.md) for the details.

```yaml
name: tsp-climber
instructions: [{file: prompts/system.md}]   # {{harness}}, {{skills}}, {{file:PATH}}, ...
first_message: {file: prompts/first.md}
tools:
  bash: {timeout: 120}
  researcher: {agent: subagents/r.yaml}     # a subagent: runs arx again
hooks: {stop: {timeout: 10s}}               # hooks/stop: "never stop" loops
compaction: {strategy: restart, trigger: 0.6}
limits: {max_turns: 1000, turn_timeout: 10m}
plugins: [guard]                            # only these installed plugins
```

Every key is in the [agent.yaml reference](docs/spec.md). `arx schema` prints a
JSON Schema for editor completion.

## Plugins

A plugin is a folder with a `plugin.yaml` and its parts: tools, hooks,
skills, commands. Each part except a skill is an executable in any language.
arx starts it, gives it JSON, and reads what it prints.

| Kind | Where | Contract |
|---|---|---|
| [Tool](docs/plugins/tools.md) | `tools/<name>` | `tools/<name>.json` or `--schema` gives `{"description", "parameters"}`; a call gets JSON on stdin; stdout is the result. `bash` and `edit` come from the `shell` plugin. |
| [Subagent](docs/plugins/subagents.md) | `tools: {name: {agent: spec.yaml}}` | arx runs itself one level deeper. |
| [Hook](docs/plugins/hooks.md) | `hooks/<point>` | `before_model`, `after_model`, `before_tool`, `after_tool`: the raw request, reply, call or result in, the changed fields out. `session_start`, `stop`: JSON in, optional decision out. |
| [Compactor](docs/plugins/compactors.md) | `compaction.strategy: <name or path>` | `{"messages", ...}` in, `{"messages"}` out. |
| [Observer](docs/plugins/observers.md) | `observers: [command]` | the event stream on stdin, one JSON object per line. |
| [Driver](docs/plugins/drivers.md) | anything that runs `arx -p … --json` | exit code, JSON result, event stream. |
| [Command](docs/plugins/commands.md) | `arx-<name>` | `arx <name>` runs it, git-style. |
| [Skill](docs/plugins/skills.md) | `skills/<name>/SKILL.md` | the agent reads it when it needs it. |
| [Scheduler](docs/plugins/schedulers.md) | `scheduler` at the top of a layer | the queued tool calls in, which to start out, one JSON line each. |

The agent's own parts live next to its spec. Plugins load below them, so a
tool the agent writes always wins. Tool calls run at the same time when their
keys allow it.

A [kit](docs/plugins/kits.md) has no code: it chooses the plugins of a run,
in order, with their settings and the prompt. arx ships three in
[`kits/`](kits): `coding`, `explorer` and `research`.

```sh
arx kit add coding --default            # the coding kit and its plugins, for every run
arx --kit explorer -p "Where is the config parsed?"
```

[`plugins/`](plugins) is the arx marketplace, with one plugin of each kind:

```sh
arx plugin add guard                     # plugins/guard, at the tag of your arx
arx plugin add acme/tools/lint           # a plugin folder in any GitHub repo
arx plugin add --link ./plugins/notify   # develop one in place
arx plugin list
```

To write one, start with the [plugin quickstart](docs/plugins/quickstart.md):
a tool and a hook in five minutes, with no API key. The
[plugin guide](docs/plugins.md) has the concepts, one page per kind, and the
reference.

## Documentation

| | |
|---|---|
| [Getting started](docs/getting-started.md) | install, setup, first run, first tool |
| [How arx works](docs/concepts.md) | the turn loop, hot reload, caps, compaction, sessions |
| [Self-improving runs](docs/autoresearch.md) | set up an agent that climbs a score on its own |
| [arx climb](docs/climb.md) | run the agent in rounds; arx scores and keeps or reverts each change |
| [agent.yaml reference](docs/spec.md) | every key, its type and default, and the templates |
| [Plugins](docs/plugins.md) | every plugin kind, plugin folders, the marketplace, events |
| [Command line](docs/cli.md) | commands, options, caps, exit codes |
| [Architecture](docs/architecture.md) | design decisions, source layout, building, testing, releases |
| [Roadmap](docs/roadmap.md) | ACP, a TUI, MCP |

The same pages are published as a docs site by
[arx-docs](https://github.com/woodfordbl/arx-docs), which renders this
folder; [`.github/workflows/docs.yml`](.github/workflows/docs.yml) rebuilds it
when `docs/` changes on `main`.

## Development

```sh
make test     # 180 end-to-end checks, offline, under ASan + UBSan
make bench    # the performance budgets
make lint     # Google style, 400-line files, doc comments
```

CI runs lint, the tests and the budgets on every push and pull request.
Releases run them on macOS and Linux before publishing. See
[Architecture](docs/architecture.md) and the [style guide](docs/STYLE.md).
