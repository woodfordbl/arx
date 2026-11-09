# Command line

`arx` is one executable: with no command it runs an agent, and with a
command it sets up, inspects or steers one.

```text
arx [options]                         run the agent (interactive, or headless if stdin is piped)
arx -p TASK|- [options]               run one task until the agent stops
arx setup                             provider, API key and default model (run this first)
arx init [basic|autoresearch|KIT]     start a harness in this folder
arx doctor [--live]                   check the install, spec, key and endpoint
arx models [FILTER]                   the endpoint's models, with prices
arx sessions                          the sessions in this folder
arx climb [--dry-run] [--resume RUN]  run in rounds; climb scores and keeps each change
arx update [--check]                  update to the latest release
arx plugin add|rm|ls|new              install and manage plugins (`arx add` for short)
arx kit add|rm|ls                     install and manage kits
arx config get|set|unset|add|remove   read and change top-level spec keys
arx check | tools | schema | tool | request PATH | watch | ctl | version | help
```

`arx help` lists everything, including any `arx-*` command it can find.
`arx help COMMAND` prints the usage of one command.

## Running an agent

`arx` with no command runs the agent, in one of two modes:

| Mode | Starts when | Use it when |
|---|---|---|
| Interactive | stdin is a terminal and there is no `-p` | you want to watch and steer the agent turn by turn |
| Headless | you pass `-p TASK` or `-p -` (task on stdin), or stdin is a pipe | the agent runs alone: scripts, CI, long experiments |

- **Interactive**: each line you type is a message. Ctrl-C stops the
  current turn. `/exit`, `/quit`, Ctrl-D, or Ctrl-C at the prompt ends the
  session.
- **Headless**: the agent runs until it stops, then arx exits.

| Option | Description |
|---|---|
| `-p`, `--prompt TASK` | Runs one task. `-` reads the task from stdin. |
| `--spec PATH` | Sets the agent spec. Default `./agent.yaml`, or your defaults from `arx setup` when there is none. |
| `--kit NAME` | Uses an installed kit: its plugins, in order, and its prompt. The agent cannot change it. |
| `--set KEY=VALUE` | Overrides a spec value for this run, such as `limits.max_turns=10`. Repeatable. See [Overrides](spec.md#overrides). |
| `--cap KEY=VALUE` | Sets a hard limit the spec cannot raise. Repeatable. See [Caps](#caps). |
| `--resume ID\|last` | Continues a session with its full history. |
| `--json` | Prints the result as JSON on stdout. See [JSON result](#json-result). |
| `--events PATH\|-\|fd:N` | Also writes the event stream to a file, stdout or a file descriptor. |
| `-q`, `--quiet` | Turns off the terminal view. |

### Caps

A cap is a hard limit for one run. Unlike `limits` in the spec, the agent
cannot raise a cap by editing its spec.

| Cap | Example | Limits |
|---|---|---|
| `turns` | `--cap turns=50` | model calls in this session |
| `tokens` | `--cap tokens=2000000` | input + output tokens in this session |
| `usd` | `--cap usd=5` | cost in this session |
| `wall` | `--cap wall=8h` | time since this process started |
| `depth` | `--cap depth=2` | subagent nesting (default 4) |

arx passes caps down to subagents. When a cap is reached, the agent stops
after its current turn and arx exits with code 3.

> [!WARNING]
> Set a `--cap` for every run you don't watch. Without one, the only stop is
> `limits.max_turns`, which the agent can edit.

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
| `arx setup` | Asks for a provider, API key and default model, and checks the key. Saves the key in the macOS Keychain (or a 0600 file) and the defaults in `config.yaml`. `--provider`, `--base-url`, `--key-env`, `--model`, `--key-stdin` and `--no-test` make it scriptable. |
| `arx init [basic\|autoresearch\|KIT]` | Writes a harness into this folder: `agent.yaml`, `prompts/system.md` and empty `tools/`, `hooks/` and `skills/`. `autoresearch` adds `program.md`, an experiment-loop prompt, a never-stop hook and restart compaction. `KIT` copies an installed kit's `init/` files, with an `agent.yaml` that uses the kit. Keeps existing files unless you pass `--force`. |
| `arx doctor [--live]` | Checks the install, `curl`, `jq` and `git`, the spec, the key and the endpoint. `--live` also makes one small model call. |
| `arx models [FILTER] [--json]` | Lists the endpoint's models whose id contains `FILTER`, with prices per million tokens. `*` marks your default. `--json` prints the endpoint's raw JSON. |
| `arx sessions [--all]` | Lists the sessions in this folder: id, status, turns, cost and task. Shows the last 20 unless you pass `--all`. |
| `arx update [--check] [--version V] [--prefix DIR]` | Installs the latest release, after checking its sha256. `--check` only reports, and exits 10 if a newer release exists. |
| `arx plugin ...` | Installs, removes, lists, turns on and off, and starts plugins. See [arx plugin](plugins/reference.md#arx-plugin). |
| `arx kit ...` | Installs, lists and removes kits. See [Kits](plugins/kits.md#commands). |
| `arx config ...` | Reads or changes one top-level key of `./agent.yaml`, or of `config.yaml` with `--global`. |
| `arx request [-X METHOD] [--data JSON\|-] PATH` | Sends an authenticated request to the endpoint, such as `arx request /models`. `--auth-source` says where the key came from, without printing it. |

### `arx-*` commands

`arx foo` runs an executable named `arx-foo`, the way git runs `git-foo`.
arx looks in its own commands first, then `~/.config/arx/commands/`, then
each user plugin's `commands/`, then `PATH`. The first match wins, so a
plugin can add a command but not replace one. See
[Commands](plugins/commands.md) to write one.

## Inspecting a harness

| Command | What it does |
|---|---|
| `arx check [--spec PATH] [--kit NAME]` | Validates the harness without starting a session, and lists its kit, tools, hooks, plugins in order, problems and warnings. |
| `arx check --list` | Prints the active list as tab-separated rows, for scripts. |
| `arx check --hosts` | Prints the network hosts the run needs, one per line, for an egress allowlist. See [Hosts](plugins/reference.md#hosts). |
| `arx check --plugin DIR` | Checks one plugin folder without loading it. |
| `arx check --kit-dir DIR` | Checks one kit folder. |
| `arx check --climb FILE` | Checks a `climb.yaml` and prints it as JSON, with every default filled in and durations in seconds. |
| `arx tools [--spec PATH]` | Prints the tools JSON as the model sees it. |
| `arx schema` | Prints the JSON Schema of `agent.yaml`, for editors. |
| `arx tool bash\|edit [--schema]` | Runs a tool of the `shell` plugin with JSON arguments on stdin, or prints its schema. |

For example:

```sh
arx check --spec harness/agent.yaml   # validate; list tools, hooks and problems
arx tools --spec harness/agent.yaml   # the tools JSON sent to the model
arx schema > agent.schema.json        # JSON Schema for editors
```

`arx check` exits with code 2 when the spec is invalid, so it works in CI and
in a pre-commit hook.

## Following a session

`arx watch [ID|last] [--json] [--from start|now]` follows a session's
`events.jsonl` until the session ends. It draws the same view as the
running agent, subagents included:

```sh
arx watch                                   # the newest session, from the start
arx watch 20261030-221403-a1b2 --from now   # one session, from this moment on
arx watch last --json                       # raw events, one JSON object per line
```

## Controlling a session

`arx ctl ID|last` steers a running session:

```sh
arx ctl last note "the eval is flaky above 5000 cities; ignore those"
arx ctl last stop
```

- **`note TEXT`**: the agent sees the note as a `[harness]` message before
  its next model call.
- **`stop`**: the agent stops after its current turn, with exit code 0.

Both append a line to the session's `inbox` file, so anything that can write
a file can steer a run.

## Climbing a score

`arx climb` runs the agent in rounds and scores each change itself, with
your evaluation outside the agent's reach. It reads `./climb.yaml` and keeps
or reverts every change on the branch `climb/RUN`. See
[arx climb](climb.md) for the keep rule, the isolation levels and every key.

```text
arx climb [--config PATH] [--name RUN] [--rounds N] [--patience N]
          [--target X] [--cap usd=N|tokens=N|wall=D] [--round turns=N|wall=D]
          [--spec PATH] [--kit NAME] [--set KEY=VALUE]... [--json] [--quiet]
          [--dry-run]
arx climb --resume RUN|last [budget flags] [--new-session]
arx climb status [RUN|last] [--json]
arx climb stop [RUN|last]
arx climb rm RUN [--yes]
```

| Option | Description |
|---|---|
| `--config PATH` | The climb file. Default `./climb.yaml`. |
| `--name RUN` | Names the run, its folder `.arx/climb/RUN/` and the branch `climb/RUN`. Default: the time, such as `20261109-1530`. |
| `--rounds N`, `--patience N`, `--target X` | Stop after N rounds, after N rounds in a row without a keep, or once the best reaches X. |
| `--cap usd=N`, `tokens=N`, `wall=D` | The climb's budget, over `budget:` in `climb.yaml`. Other caps, such as `depth`, pass through to each round. |
| `--round turns=N`, `wall=D` | The limits of one round. Default 40 turns and 30 minutes. |
| `--spec PATH`, `--kit NAME`, `--set KEY=VALUE` | Added to every round, after the values in `agent:`. |
| `--dry-run` | Checks everything and scores the baseline, then stops without starting the agent. |
| `--resume RUN\|last` | Scores the best commit again and continues the run's session. Budget flags count from the resume; `--new-session` starts a fresh session. |
| `--json` | Prints `summary.json` on stdout at the end. |
| `--quiet` | No line per round on stderr. |

`arx climb status` prints a run's state, and `--json` its `summary.json`.
`arx climb stop` ends the climb after the current round. `arx climb rm`
deletes a run's branch, its candidate refs and its folder, after asking.

| Code | Meaning |
|---|---|
| `0` | done: rounds, patience, target, `arx climb stop`, or a dry run |
| `1` | error: three arx errors in a row, a baseline that crashes, or a git step that fails |
| `2` | usage: a bad `climb.yaml`, no budget, dirty change paths, not at the top of a git repository, or another climb running here |
| `3` | a budget was spent: `usd`, `tokens` or `wall` |
| `4` | authentication failed |
| `130` | interrupted (Ctrl-C) |

## Environment

| Variable | Use |
|---|---|
| the variable named by `endpoint.api_key_env` | the API key; wins over the key `arx setup` saved |
| `ARX_CONFIG_DIR` | the config folder, instead of `$XDG_CONFIG_HOME/arx` or `~/.config/arx` |
| `ARX_CURL` | the curl executable, when `endpoint.curl` is not set |
| `ARX_DOWNLOAD_URL` | where `install.sh`, `arx update` and `arx plugin add` download from, instead of `https://arx-documentation.vercel.app` |

arx looks for the API key in this order: the environment variable named by
`endpoint.api_key_env`, then the key `arx setup` saved under that name, in
the macOS Keychain (service `arx`) or in `~/.config/arx/credentials`. The
key reaches `curl` in a 0600 file, never on a command line.

With `endpoint.credential`, a [credential program](plugins/credentials.md)
gives the key instead, and arx does not look in those places.
`arx request --auth-source` then runs the program and names it.

Plugins get more `ARX_*` variables. See
[What every plugin gets](plugins/reference.md#environment).
