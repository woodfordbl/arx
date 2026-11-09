# Drivers

A driver is any program that runs arx: a supervisor, an evaluation loop, a
batch job or a CI step.

arx does not load a driver. A driver uses only the command line, the exit
code, the JSON result and the event stream. Write one when a run must go on
without you: resume it after a cap, repeat it until a score climbs, or run it
on every commit.

**Status:** today. **Example:**
[`examples/plugins/drivers/resume_on_cap.sh`](../../examples/plugins/drivers/resume_on_cap.sh).

## Contract

### Options for drivers

These options start and shape a run. [Command line](../cli.md) lists the
rest.

| Option | What it does |
|---|---|
| `-p TASK` or `-p -` | Runs one task until the agent stops. `-` reads the task from stdin. |
| `--json` | Prints one JSON result on stdout. See [Read the result](#read-the-result). |
| `--quiet` | Turns off the terminal view. |
| `--events PATH`, `--events -`, `--events fd:N` | Also writes the [event stream](reference.md#events) to a file, stdout or an open file descriptor. |
| `--resume ID` or `--resume last` | Continues a session with its history. |
| `--cap turns=N`, `tokens=N`, `usd=N`, `wall=8h`, `depth=N` | Sets hard limits that the spec cannot raise. |
| `--set key.path=value` | Sets a spec value for this run. It stays in force after every reload. |
| `--kit NAME` | Uses an installed [kit](kits.md) for this run. It is the same as `--set kit=NAME`, so the agent cannot change it. |
| `--spec PATH` | Uses this spec instead of `./agent.yaml`. |

> [!WARNING]
> The agent can edit `kit:` and `plugins:` in its own spec. For a run you
> don't watch, pin them with `--kit NAME` or `--set`, and set a `--cap`.

### Read the result

With `--json`, arx prints one object on stdout when the run ends:

```json
{"session": "20261030-221403-a1b2", "status": "done", "exit": 0,
 "final_output": "...", "turns": 12, "tokens": {"input": 41230, "output": 2210},
 "cost": 0.0153}
```

`status` is `done`, `cap`, `auth`, `interrupted` or `error`. Read `session`
from here when you resume or steer the run, rather than `last`.

### Exit codes

The exit code tells the driver what to do next:

| Code | Meaning |
|---|---|
| `0` | done: the agent stopped |
| `1` | error |
| `2` | usage error, or a spec that is not valid |
| `3` | a cap was reached |
| `4` | authentication failed |
| `130` | interrupted (Ctrl-C) |

### Steer a running session

A driver, or you in another terminal, can steer a session while it runs:

```sh
arx ctl last note "Try a smaller input first."   # the agent sees it before its next model call
arx ctl last stop                                # it stops after the current turn
```

`arx ctl` appends a line to the session's `inbox` file. Use a session id in
place of `last` when more than one session runs in the folder.

## Write a driver

This driver runs a task with a turn cap. Each time the cap stops it (exit
`3`), it resumes the session with 20 more turns:

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

When a run ends with any other code, the driver prints its JSON result. The
full version, with a limit on the rounds, is
[`resume_on_cap.sh`](../../examples/plugins/drivers/resume_on_cap.sh).

## Common mistakes

| Mistake | What happens | Fix |
|---|---|---|
| The driver parses the terminal view | the format can change, and it has colors | use `--json` and `--quiet`, or `--events` |
| A resumed run has the same turn cap | the turn count includes the turns before, so the cap stops it at once | raise `--cap turns` by the turns already used |
| The driver uses `last` while other runs start in the same folder | `last` points at the newest session, which may be another one | read `session` from the JSON result and use the id |
| The driver lets the agent choose its plugins | the agent can edit `kit:` and `plugins:` in its spec | pin them with `--kit NAME`, or `--set 'plugins=["guard","shell"]'`; keep `shell`, or the agent has no `bash` and `edit` |
| A climb uses a kit that names plugins without versions | a later `arx kit add` can change a plugin between runs | pin versions in the kit (`guard@v0.2.0`), and keep the `kit.lock` that arx writes |
| The driver trusts `final_output` as the score | the agent can write anything | measure the result with your own program |

## Planned

**Planned:** a policy folder (`--policy DIR`) that loads first and that the
spec cannot remove. See [Planned changes](planned.md#trust).

## Related

- [Command line](../cli.md#caps): every option, and each cap in detail.
- [Self-improving runs](../autoresearch.md): set up an agent that climbs a
  score without supervision.
- [Observers](observers.md): read the event stream from inside the session.
- [Kits](kits.md): pin the plugins a run uses.
