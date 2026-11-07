# Getting started

This page takes you from nothing to a running agent in a few minutes. arx
needs `curl` at run time; `arx setup`, `arx models` and `arx sessions` also
need `jq`.

## Install

Install the latest release (macOS and Linux, x86_64 and arm64):

```sh
curl -fsSL https://arx-documentation.vercel.app/install.sh | sh
```

The installer downloads the release for your OS and architecture from the
arx site, which serves arx's GitHub releases, checks its sha256, and installs `arx` into `~/.local/bin` and its commands into
`~/.local/libexec/arx`. Pass `--prefix DIR` to install somewhere else, or
`--version vX.Y.Z` for a given release. If `~/.local/bin` is not on your
`PATH`, the installer says how to add it.

**From source** (needs [Zig 0.17.0](https://ziglang.org/download/), exactly
that release, and `make`):

```sh
git clone https://github.com/woodfordbl/arx.git && cd arx
make install                 # arx into ~/.local/bin (PREFIX=... to change)
```

`make static` builds fully static Linux binaries (musl) for x86_64 and
arm64. Zig cross-compiles, so this works from macOS too, without Docker.

`arx update` installs the newest release later, from the same place and with
the same checksum check.

## Set up a provider

```sh
arx setup
```

`arx setup` asks for a provider (Vercel AI Gateway, OpenRouter, OpenAI,
Ollama, or any OpenAI-compatible URL), your API key, and a default model. It
checks the key against the endpoint, then saves:

- **the key** in the macOS Keychain (service `arx`), or elsewhere in
  `~/.config/arx/credentials` with 0600 permissions;
- **your defaults** in `~/.config/arx/config.yaml`.

An environment variable with the same name as the saved key always wins, so
CI and containers can pass the key in the environment instead. Check
everything with:

```sh
arx doctor            # the install, your spec, your key and your endpoint
arx doctor --live     # also makes one small model call
arx models haiku      # the endpoint's models, with prices
```

## Run it

arx works in any folder. With no `agent.yaml` there, it uses your defaults.

**Interactive.** Run `arx` on a terminal and type a message. The agent works
until it replies without calling a tool, then waits for your next message.

```sh
arx
› Find the largest file in this directory and tell me what it is.
```

- Ctrl-C stops the current turn. A second Ctrl-C exits at once.
- `/exit`, `/quit` or Ctrl-D ends the session.

**Headless.** Give a task with `-p` (or pipe it on stdin). The agent runs until
it stops, then arx exits.

```sh
arx -p "Find the largest file here" --cap usd=1
echo "Summarize README.md" | arx --quiet
```

`--cap` sets a hard limit that the spec cannot raise: `turns`, `tokens`,
`usd`, `wall` (for example `wall=2h`) or `depth`. Always set one for runs you
do not watch.

## Give a project its own harness

```sh
arx init                  # agent.yaml, prompts/system.md, tools/, hooks/, skills/
arx init autoresearch     # the same, set up for a self-improving loop
arx check                 # validate it; list its tools, hooks and plugins
```

The project's `agent.yaml` is merged over your defaults key by key, and the
project wins, so it only needs what differs:

```yaml
name: helper
instructions: [{file: prompts/system.md}]
limits: {max_turns: 50}
```

Every key is described in the [agent.yaml reference](spec.md).

## Watch and steer a run

Every run writes its events to `.arx/sessions/<id>/`. From another terminal:

```sh
arx watch                             # follow the newest session live
arx ctl last note "try a smaller input first"
arx ctl last stop                     # stop after the current turn
arx sessions                          # the sessions in this folder
```

The agent sees a note before its next model call. See
[Command line](cli.md) for every command and option.

## Continue a session

```sh
arx --resume last                     # interactive, with the full history
arx --resume last -p "Now write the tests"
```

## Give the agent a tool

A tool is any executable in `tools/`, next to the spec. It describes itself
when called with `--schema`, and gets its arguments as JSON on stdin:

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
arx tools          # prints the tools as the model sees them
```

There is no restart and no registration. arx checks `tools/` before every
model call, so the agent can also write tools for itself while it runs.

Or install one someone else wrote:

```sh
arx plugin add clock       # plugins/clock from the arx marketplace
arx plugin list
```

The [plugin guide](plugins.md) covers every plugin kind and how plugin folders
load.

## Next steps

- [How arx works](concepts.md): the turn loop, hot reload and sessions.
- [Self-improving runs](autoresearch.md): set up an agent that climbs a score
  without supervision, and improves its own harness as it goes.
- [`plugins/`](../plugins): the marketplace, one working plugin of each kind.
- [`examples/tsp`](../examples/tsp): a complete self-improving TSP solver.
