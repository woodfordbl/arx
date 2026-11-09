# Getting started

Install arx, connect it to a model, and run your first agent. It takes about
five minutes, and by the end you'll have an agent with a tool you wrote.

You need macOS or Linux and `curl`. `arx setup`, `arx models` and
`arx sessions` also use `jq`.

## Install arx

Run the installer:

```sh
curl -fsSL https://arx-documentation.vercel.app/install.sh | sh
```

The installer picks the release for your OS and architecture (x86_64 or
arm64), checks its sha256, and installs `arx` into `~/.local/bin` and its
commands into `~/.local/libexec/arx`. If `~/.local/bin` is not on your
`PATH`, it tells you how to add it.

To install somewhere else, pass `--prefix DIR`. To pin a release, pass
`--version vX.Y.Z`. Later, `arx update` installs the newest release the same
way, with the same checksum check.

**Planned:** on a terminal, the installer goes straight on into
[`arx setup`](#connect-a-model), and a first install ends like this:

```text
Downloading arx v0.2.0 for darwin-arm64...
Updated arx ? -> 0.2.0 in /Users/you/.local.
Set up arx. Esc goes back, Ctrl-C quits; nothing is saved until the end.
✓ Provider  OpenRouter
✓ API key   from $OPENROUTER_API_KEY, checked
✓ Model     anthropic/claude-sonnet-5.5
✓ Kit       No kit
~/.local/bin is not on your PATH.
✓ PATH      Add it to ~/.zshrc
✓ Saved     the key in your macOS Keychain
✓ Saved     ~/.config/arx/config.yaml (model anthropic/claude-sonnet-5.5)
✓ Tools     bash and edit (the shell plugin)
✓ PATH      added to ~/.zshrc
✓ Test      "arx is ready" in 2 s

  arx            talk to the agent in this folder
  arx init       start a harness here
  arx setup      change any of this later
```

The installer asks nothing when its output is not a terminal or `CI` is
set, and it leaves an arx that is set up already as it is. Scripts can pass
`--no-setup` to stop after the install.

### Build from source

You need a C compiler and `make`:

```sh
git clone https://github.com/woodfordbl/arx.git && cd arx
make install                 # into ~/.local/bin; set PREFIX to change
```

On Linux, `make static` builds a fully static binary (musl, in Docker) that
runs on any x86_64 or arm64 machine.

## Connect a model

Run `arx setup`:

```sh
arx setup
```

It asks for a provider (Vercel AI Gateway, OpenRouter, OpenAI, Ollama, or
any OpenAI-compatible URL), your API key, and a default model. It checks the
key against the endpoint, then saves:

- **Your key**: in the macOS Keychain (service `arx`), or in
  `~/.config/arx/credentials` with 0600 permissions elsewhere.
- **Your defaults**: in `~/.config/arx/config.yaml`.

An environment variable with the same name as the saved key always wins, so
CI jobs and containers can pass the key in the environment instead.

**Planned:** on a terminal, `arx setup` is a wizard of five questions:
provider, key, model, kit and `PATH`. Each question is one menu, and each
answer collapses to one line:

- **Up and Down** (or `j` and `k`): move. Typing filters the model list.
- **Enter**: choose.
- **Esc**: go back one question.
- **Ctrl-C**: quit. Nothing is saved until you answer the last question,
  so quitting leaves your settings as they were.

Once a model is set, `arx setup` opens a settings menu instead: provider and
key, model, kit, plugins, update and doctor. Every answer also has a flag;
[Command line](cli.md#arx-setup) lists them.

> [!TIP]
> If the menus don't draw well in your terminal, set `ARX_UI=plain` to get
> numbered questions instead.

Check that everything works:

```sh
arx doctor                   # checks the install, spec, key and endpoint
arx doctor --live            # also makes one small model call
arx models haiku             # lists matching models, with prices
```

## Run your first agent

arx works in any folder. With no `agent.yaml` in the folder, it uses the
defaults you just saved.

### Interactive

Run `arx` and type a message:

```sh
arx
› Find the largest file in this directory and tell me what it is.
```

The agent calls tools until it can answer, replies, then waits for your
next message.

- **Ctrl-C**: stops the current turn. A second Ctrl-C exits.
- **`/exit`, `/quit` or Ctrl-D**: ends the session.

### Headless

Pass a task with `-p`, or pipe it on stdin. The agent runs until it stops,
then arx exits:

```sh
arx -p "Find the largest file here" --cap usd=1
echo "Summarize README.md" | arx --quiet
```

`--cap` sets a hard limit that nothing in the spec can raise: `turns`,
`tokens`, `usd`, `wall` (for example `wall=2h`) or `depth`.

> [!WARNING]
> Set a `--cap` for every run you don't watch. Without one, the only stop is
> the spec's `limits.max_turns` (200 by default), and the agent can edit
> its own spec.

## Give a project its own harness

A harness is the `agent.yaml` spec and everything next to it: prompts,
tools, hooks and skills. Create one in the current folder:

```sh
arx init                     # creates agent.yaml, prompts/, tools/, hooks/
arx init autoresearch        # the same, for a self-improving loop
arx check                    # validates it; lists tools, hooks, plugins
```

The project's `agent.yaml` is merged over your defaults key by key, and the
project wins. So it only needs what differs:

```yaml
# agent.yaml
name: helper
instructions: [{file: prompts/system.md}]
limits: {max_turns: 50}
```

The [agent.yaml reference](spec.md) lists every key.

## Watch and steer a run

Every run writes its events to `.arx/sessions/<id>/`. Open a second
terminal in the same folder to follow it:

```sh
arx watch                              # follows the newest session live
arx ctl last note "try a smaller input first"
arx ctl last stop                      # stops after the current turn
arx sessions                           # lists the sessions in this folder
```

The agent sees a note before its next model call. [Command line](cli.md)
lists every command and option.

To continue a session later, with its full history:

```sh
arx --resume last                      # interactive
arx --resume last -p "Now write the tests"
```

## Give the agent a tool

A tool is any executable in `tools/`, next to the spec. Called with
`--schema`, it prints its description. Called without it, it reads its
arguments as JSON on stdin and prints the result.

Write one that tells the time:

```sh
mkdir -p tools
cat > tools/now <<'EOF'
#!/bin/sh
if [ "$1" = --schema ]; then
  echo '{"description": "The current UTC time.", "parameters": {"type": "object", "properties": {}}}'
  exit 0
fi
date -u +%Y-%m-%dT%H:%M:%SZ
EOF
chmod +x tools/now
arx tools                              # prints the tools as the model sees them
```

There is no restart and no registration step. arx checks `tools/` before
every model call, so the next turn sees the new tool. The agent can write
tools for itself the same way while it runs.

To install a tool someone else wrote, add a plugin:

```sh
arx plugin add clock                   # installs it from the arx marketplace
arx plugin list
```

## Next steps

- [How arx works](concepts.md): the turn loop, hot reload, caps and
  sessions.
- [Self-improving runs](autoresearch.md): set up an agent that climbs a
  score without supervision and improves its own harness as it goes.
- [Plugins](plugins.md): every way to extend arx, from tools and hooks to
  kits.
- [`examples/tsp`](../examples/tsp): a complete self-improving TSP solver.
