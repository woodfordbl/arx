# Commands

A command adds a subcommand to arx. `arx <name>` runs the executable
`arx-<name>` with the remaining arguments, the way `git foo` runs `git-foo`.
`arx setup`, `init`, `doctor`, `models`, `sessions`, `update` and `plugin` are
commands like this, written as short scripts in [`commands/`](../../commands).

**Status:** today. **Examples:** [`commands/`](../../commands).

## Contract

- **The file:** an executable named `arx-<name>`.
- **Arguments:** everything after `arx <name>`.
- **Output and exit code:** the command's own. arx replaces itself with the
  command, so the command's exit code is the exit code of `arx <name>`.
- **Environment:** `ARX_BIN` (the arx binary) and `ARX_LIBEXEC` (the folder
  the command was found in). A command in a user plugin also gets
  `ARX_PLUGIN_DIR`. The session variables, such as `ARX_SESSION`, are not
  set, because no session runs.
- **Help:** a line `# arx-<name>: one-line summary` in the first 512 bytes
  makes the command show up in `arx help`. `arx help <name>` runs
  `arx-<name> --help`.

**Where arx looks,** in this order. The first match wins:

1. arx's built-in commands: `check`, `tools`, `schema`, `tool`, `watch`,
   `ctl`, `request`, `version`, `help`;
2. `../libexec/arx/` next to the binary (an installed arx);
3. `commands/` next to the binary (a source checkout);
4. `~/.config/arx/commands/` (yours; `arx update` never touches it);
5. `~/.config/arx/plugins/<name>/commands/` (user plugins, in name order);
6. your `PATH`.

So a plugin can add a command, but it cannot replace one of arx's own.

**Calling your endpoint:** `"$ARX_BIN" request PATH` calls your model
endpoint with your API key, and the key never passes through your script:

```sh
"$ARX_BIN" request /models
"$ARX_BIN" request -X POST --data '{"model": "..."}' /chat/completions
"$ARX_BIN" request --auth-source            # says where the key came from, without the key
```

## Minimal example

```sh
#!/bin/sh
# arx-hello: says hello
echo "hello $* from $("$ARX_BIN" version)"
```

```sh
mkdir -p ~/.config/arx/commands
cp arx-hello ~/.config/arx/commands/ && chmod +x ~/.config/arx/commands/arx-hello
arx hello world        # hello world from arx 0.1.0
arx help               # lists hello with its summary
```

In a plugin, put the file in `commands/arx-hello` and install the plugin with
`arx plugin add`.

## Common mistakes

| Mistake | What happens | Fix |
|---|---|---|
| The command is in a project plugin (`./plugins/<name>/commands/`) | arx does not find it: only user plugins add commands | install the plugin for your user, without `--project` |
| The command has the name of an arx command | arx runs its own command | choose another name |
| The command calls `arx` by name | it can run a different arx from your `PATH` | call `"$ARX_BIN"` |
| The command reads `$ARX_SESSION` | it is empty: commands run outside a session | take a session id as an argument, as `arx ctl` does |
| The summary line is missing or far down | `arx help` lists the command with no summary | put `# arx-<name>: ...` near the top |

## Planned

A `setup:` command in `plugin.yaml` that runs once after an install. See
[Planned changes](planned.md#more-of-arx-plugin).
