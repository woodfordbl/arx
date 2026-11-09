# Commands

A command is an executable named `arx-<name>` that adds the subcommand
`arx <name>`. arx runs it with the remaining arguments, the way `git foo` runs
`git-foo`.

Write one to give arx a subcommand of your own, such as a report or a setup
step. arx's own `setup`, `init`, `doctor`, `models`, `sessions`, `update` and
`plugin` work the same way: they are short scripts in arx's `commands/`
folder.

**Status:** today. **Examples:** [`commands/`](../../commands).

## Contract

### How a command runs

- **The file**: an executable named `arx-<name>`.
- **Arguments**: everything after `arx <name>`.
- **Output and exit code**: the command's own. arx replaces itself with the
  command, so the command's exit code is the exit code of `arx <name>`.
- **Environment**: `ARX_BIN` (the arx binary) and `ARX_LIBEXEC` (the folder
  arx found the command in). A command in a user plugin also gets
  `ARX_PLUGIN_DIR` and `ARX_DATA_DIR`, the plugin's
  [data folder](concepts.md#plugin-state) in the current folder. The
  session variables, such as `ARX_SESSION` and `ARX_STATE_DIR`, are not
  set, because no session runs.
- **Help**: a line `# arx-<name>: one-line summary` in the first 512 bytes
  makes the command show up in `arx help`. `arx help <name>` runs
  `arx-<name> --help`.

### Where arx looks

arx searches these places in order, and the first match wins:

1. arx's built-in commands: `check`, `tools`, `schema`, `tool`, `watch`,
   `ctl`, `request`, `version`, `help`.
2. `../libexec/arx/` next to the binary (an installed arx).
3. `commands/` next to the binary (a source checkout).
4. `~/.config/arx/commands/` (yours; `arx update` never touches it).
5. `~/.config/arx/plugins/<name>/commands/` (user plugins, in name order).
6. Your `PATH`.

So a plugin can add a command, but it cannot replace one of arx's own.

### Call your model endpoint

`"$ARX_BIN" request PATH` calls your model endpoint with your API key. The
key never passes through your script:

```sh
"$ARX_BIN" request /models
"$ARX_BIN" request -X POST --data '{"model": "..."}' /chat/completions
"$ARX_BIN" request --auth-source            # says where the key came from, without the key
```

## Write a command

This command says hello. Its second line is the summary that `arx help`
shows:

```sh
#!/bin/sh
# arx-hello: says hello
echo "hello $* from $("$ARX_BIN" version)"
```

Install it in your commands folder and run it:

```sh
mkdir -p ~/.config/arx/commands
cp arx-hello ~/.config/arx/commands/ && chmod +x ~/.config/arx/commands/arx-hello
arx hello world        # hello world from arx 0.1.0
arx help               # lists hello with its summary
```

To ship it in a plugin, put the file in `commands/arx-hello` and install the
plugin for your user with `arx plugin add`. Only user plugins add commands.

## Common mistakes

| Mistake | What happens | Fix |
|---|---|---|
| The command is in a project plugin (`./plugins/<name>/commands/`) | arx does not find it: only user plugins add commands | install the plugin for your user, without `--project` |
| The command has the name of an arx command | arx runs its own command | choose another name |
| The command calls `arx` by name | it can run a different arx from your `PATH` | call `"$ARX_BIN"` |
| The command reads `$ARX_SESSION` | it is empty: commands run outside a session | take a session id as an argument, as `arx ctl` does |
| The summary line is missing or far down | `arx help` lists the command with no summary | put `# arx-<name>: ...` near the top |

## Planned

**Planned:** a `setup:` command in `plugin.yaml` that runs once after an
install. See [Planned changes](planned.md#more-of-arx-plugin).

## Related

- [Command line](../cli.md): every built-in command and option.
- [Plugin reference](reference.md#arx-plugin): `arx plugin add` and where it
  installs plugins.
- [Plugin concepts](concepts.md#layer): user plugins, project plugins and
  the order arx loads them in.
