# Kits

Each folder here is a kit: a `kit.yaml`, `prompts/` and `init/`, and no
executables. A kit chooses the plugins of a run (from [`../plugins`](../plugins)),
their order and settings, and the prompt, so it makes one kind of agent.

| Kit | What it makes |
|---|---|
| [coding](coding) | a general coding agent: `guard` first, then `shell` and the other plugins |
| [explorer](explorer) | reads and answers: `shell` with `edit` turned off |
| [research](research) | an experiment loop that never stops (what `arx init autoresearch` makes) |
| [climber](climber) | one change per round for [`arx climb`](../docs/climb.md), which scores and keeps or reverts each change itself |

```sh
arx kit add coding          # the kit and each plugin it names
arx --kit explorer -p "Where is the config parsed?"
arx init research           # copies init/ into this folder
```

`arx check --kit-dir kits/<name>` checks a kit, and `make test` checks each
one here (`tests/kits.sh`).
