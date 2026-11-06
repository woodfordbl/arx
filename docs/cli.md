# Command line

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
```

`arx help` lists everything, including any `arx-*` command it can find.

## Running an agent

`arx` with no command runs the agent.

- **Interactive** when stdin is a terminal and there is no `-p`. Each line you
  type is a message. Ctrl-C stops the current turn; `/exit`, `/quit`, Ctrl-D
  or Ctrl-C at the prompt ends the session.
- **Headless** with `-p TASK`, `-p -` (task on stdin), or when stdin is a
  pipe. The agent runs until it stops, then arx exits.

| Option | Description |
|---|---|
| `-p`, `--prompt TASK` | Run one task. `-` reads the task from stdin. |
| `--spec PATH` | The agent spec. Default `./agent.yaml`, or your defaults from `arx setup` when there is none. |
| `--set KEY=VALUE` | Override a spec value for this run, e.g. `limits.max_turns=10`. Repeatable. |
| `--cap KEY=VALUE` | A hard limit the spec cannot raise. Repeatable. See [caps](#caps). |
| `--resume ID\|last` | Continue a session with its full history. |
| `--json` | Print the result as JSON on stdout. See [JSON result](#json-result). |
| `--events PATH\|-\|fd:N` | Also write the event stream to a file, stdout or a file descriptor. |
| `-q`, `--quiet` | No terminal view. |

### Caps

| Cap | Example | Limits |
|---|---|---|
| `turns` | `--cap turns=50` | model calls in this session |
| `tokens` | `--cap tokens=2000000` | input + output tokens in this session |
| `usd` | `--cap usd=5` | cost in this session |
| `wall` | `--cap wall=8h` | time since this process started |
| `depth` | `--cap depth=2` | subagent nesting (default 4) |

Caps are passed down to subagents. When a cap is reached, the agent stops
after its current turn and arx exits with code 3.

### JSON result

With `--json`, arx prints one object on stdout when the run ends:

```json
{"session": "20261030-221403-a1b2", "status": "done", "exit": 0,
 "final_output": "...", "turns": 12,
 "tokens": {"input": 91234, "output": 4210}, "cost": 0.31}
```

`status` is `done`, `cap`, `error`, `auth` or `interrupted`.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | done: the agent stopped on its own, or `arx ctl stop` |
| `1` | error |
| `2` | usage error, or an invalid spec |
| `3` | a cap or limit was reached |
| `4` | authentication failed (HTTP 401 or 403) |
| `130` | interrupted (Ctrl-C) |

## Setup and maintenance

| Command | What it does |
|---|---|
| `arx setup` | Asks for a provider, API key and default model; checks the key; saves the key in the Keychain (or a 0600 file) and the defaults in `config.yaml`. `--provider`, `--model`, `--key-stdin` and `--no-test` make it scriptable. |
| `arx init [basic\|autoresearch]` | Writes a harness into this folder: `agent.yaml`, `prompts/system.md` and empty `tools/`, `hooks/` and `skills/`. `autoresearch` adds `program.md`, an experiment-loop prompt, a never-stop hook and restart compaction. Existing files are kept unless `--force`. |
| `arx doctor [--live]` | Checks the install, `curl`, `jq` and `git`, the spec, the key and the endpoint. `--live` also makes one small model call. |
| `arx models [FILTER] [--json]` | The endpoint's models, with prices per million tokens. `*` marks your default. |
| `arx sessions [--all]` | The sessions in this folder: id, status, turns, cost and task. |
| `arx update [--check] [--version V]` | Installs the latest release, after checking its sha256. `--check` only reports, and exits 10 if a newer release exists. |
| `arx plugin ...` | Installs, lists and removes plugins. See [Plugin folders](plugins.md#plugin-folders). |
| `arx request [-X METHOD] [--data JSON\|-] PATH` | An authenticated request to the endpoint, e.g. `arx request /models`. |

**Commands are plugins.** `arx foo` runs an executable named `arx-foo`, the
way git runs `git-foo`. arx looks in its own commands first, then
`~/.config/arx/commands/`, then each user plugin's `commands/`, then `PATH`.
The first match wins, so a plugin can add a command but not replace one. See
[Commands](plugins.md#commands) to write one.

## Inspecting a harness

```sh
arx check --spec harness/agent.yaml   # validate; list tools, hooks and problems
arx tools --spec harness/agent.yaml   # the tools JSON sent to the model
arx schema > agent.schema.json        # JSON Schema for editors
```

`arx check` exits with code 2 when the spec is invalid, so it works in CI and
in a pre-commit hook.

## Following a session

```sh
arx watch                 # the newest session, from the start
arx watch 20261030-221403-a1b2 --from now
arx watch last --json     # raw events, one JSON object per line
```

`arx watch` follows the session's `events.jsonl` until the session ends. It
draws the same view as the running agent, subagents included.

## Controlling a session

```sh
arx ctl last note "the eval is flaky above 5000 cities; ignore those"
arx ctl last stop
```

- **`note TEXT`**: the agent sees the note as a `[harness]` message before its
  next model call.
- **`stop`**: the agent stops after its current turn, with exit code 0.

Both append a line to the session's `inbox` file, so anything that can write a
file can steer a run.

## Environment

| Variable | Use |
|---|---|
| the variable named by `endpoint.api_key_env` | the API key; wins over the key `arx setup` saved |
| `ARX_CONFIG_DIR` | the config folder, instead of `~/.config/arx` |
| `ARX_CURL` | the curl executable, when `endpoint.curl` is not set |

**API keys** are found in this order: the environment variable named by
`endpoint.api_key_env`, then the key `arx setup` saved under that name, in the
macOS Keychain (service `arx`) or in `~/.config/arx/credentials`. The key
reaches `curl` in a 0600 file, never on a command line.

Plugins get a further set of `ARX_*` variables; see
[What every plugin gets](plugins.md#what-every-plugin-gets).
