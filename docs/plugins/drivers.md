# Drivers

A driver is any program that runs arx: a supervisor, an evaluation loop, a
batch job, a CI step. arx does not load it. A driver uses only the command
line, the exit code, the JSON result and the event stream.

**Status:** today. **Example:**
[`examples/plugins/drivers/resume_on_cap.sh`](../../examples/plugins/drivers/resume_on_cap.sh).

## Contract

| Option | Use |
|---|---|
| `-p TASK` or `-p -` | run one task until the agent stops; `-` reads the task from stdin |
| `--json` | print one JSON result on stdout (below) |
| `--quiet` | no terminal view |
| `--events PATH`, `--events -`, `--events fd:N` | also write the [event stream](reference.md#events) to a file, stdout or an open file descriptor |
| `--resume ID` or `--resume last` | continue a session with its history |
| `--cap turns=N`, `tokens=N`, `usd=N`, `wall=8h`, `depth=N` | hard limits that the spec cannot raise |
| `--set key.path=value` | set a spec value for this run; it stays in force after every reload |
| `--spec PATH` | the spec to use, instead of `./agent.yaml` |

**The JSON result** (`--json`):

```json
{"session": "20261030-221403-a1b2", "status": "done", "exit": 0,
 "final_output": "...", "turns": 12, "tokens": {"input": 41230, "output": 2210},
 "cost": 0.0153}
```

`status` is `done`, `cap`, `auth`, `interrupted` or `error`.

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | done: the agent stopped |
| `1` | error |
| `2` | usage error, or a spec that is not valid |
| `3` | a cap was reached |
| `4` | authentication failed |
| `130` | interrupted (Ctrl-C) |

**Steering a running session** from another process:

```sh
arx ctl last note "Try a smaller input first."   # the agent sees it before its next model call
arx ctl last stop                                # it stops after the current turn
```

`arx ctl` appends a line to the session's `inbox` file. Use a session id in
place of `last` when more than one session runs in the folder.

## Minimal example

Run a task with a turn cap, and resume it each time the cap stops it:

```sh
#!/bin/sh
arx -p "$1" --cap turns=20 --json --quiet > result.json
code=$?
while [ "$code" -eq 3 ]; do
  used=$(sed 's/.*"turns":\([0-9]*\).*/\1/' result.json)
  arx --resume last -p "Continue where you stopped." \
    --cap "turns=$((used + 20))" --json --quiet > result.json
  code=$?
done
cat result.json
```

The full version, with a limit on the rounds, is
[`resume_on_cap.sh`](../../examples/plugins/drivers/resume_on_cap.sh).

## Common mistakes

| Mistake | What happens | Fix |
|---|---|---|
| The driver parses the terminal view | the format can change, and it has colors | use `--json` and `--quiet`, or `--events` |
| A resumed run has the same turn cap | the turn count includes the turns before, so the cap stops it at once | raise `--cap turns` by the turns already used |
| The driver uses `last` while other runs start in the same folder | `last` points at the newest session, which may be another one | read `session` from the JSON result and use the id |
| The driver lets the agent choose its plugins | the agent can edit `plugins:` in its spec | pin them with `--set 'plugins=[...]'` |
| The driver trusts `final_output` as the score | the agent can write anything | measure the result with your own program |

## Planned

`--kit NAME` will choose a kit for the run, and stay in force after reloads,
like `--set`. See [Planned changes](planned.md#kits).
