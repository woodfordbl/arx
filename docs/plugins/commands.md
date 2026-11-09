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
  set, because no session runs. **Planned:** `ARX_LIB`, the folder with
  arx's `ui.sh` and `pick` (see
  [Ask a question in a command](#ask-a-question-in-a-command)).
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

## Ask a question in a command

**Planned:** a command can ask with the same menus as `arx setup`. Source
`ui.sh` from `ARX_LIB`, then call its functions:

```sh
#!/usr/bin/env bash
# arx-greet: asks for a name, then greets
. "$ARX_LIB/ui.sh"
name=$(ui_input "Your name" world) || ui_stop $?
echo "hello $name"
```

`ui.sh` decides how to ask once, when you source it: a menu on a terminal,
numbered questions with `ARX_UI=plain`, and no questions at all without a
terminal or when `CI` is set. Questions go to the terminal and answers to
stdout, so `$(...)` captures only the answer. A function fails with 4 when
you press Esc (go back) and 130 for Ctrl-C; `ui_stop` handles both.

| Function | Does | Without a terminal |
|---|---|---|
| `ui_select TITLE DEFAULT [--filter] [--custom]` | one item from stdin; prints its value | prints `DEFAULT`, or fails with 2 when there is none |
| `ui_multi TITLE` | items from stdin, `checked` ones on; prints each chosen value | prints the `checked` values |
| `ui_input TITLE DEFAULT` | a line of text | prints `DEFAULT` |
| `ui_secret TITLE` | a line that is never shown | fails with 2 |
| `ui_confirm TITLE yes\|no` | succeeds for yes | fails: no |
| `ui_spin TITLE -- COMMAND...` | runs `COMMAND` with a spinner | runs `COMMAND` |
| `ui_wait TITLE PID` | a spinner until `PID` exits | returns at once |
| `ui_done LABEL TEXT` | prints `✓ LABEL  TEXT` | prints nothing |
| `ui_pause` | waits for a key | returns at once |
| `ui_need FLAG` | says to pass `FLAG`, then exits 2 | the same |
| `ui_stop CODE` | 130: prints `Cancelled. Nothing changed.` and exits 130; 4: returns 4 | the same |

Items are lines of `VALUE<TAB>LABEL<TAB>NOTE<TAB>FLAGS`. Only `VALUE` is
needed, and `FLAGS` can hold `checked` and `off` (shown, but not
selectable).

A command must still work without a terminal. Give every question a flag,
and call `ui_need --flag` when the flag is missing and there is no one to
ask. `ui_spin` runs a program, not a shell function.

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
