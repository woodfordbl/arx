# Architecture

This page is for people who work on arx itself. It covers the design
decisions, the layout of the sources, and how to build, test and benchmark.

## Design decisions

| Decision | Why |
|---|---|
| **One C binary, two vendored libraries** | Starts in under a millisecond, uses a few MB over hundreds of turns, and runs anywhere without a runtime. cJSON and libyaml are vendored, unmodified. |
| **Plugins are processes** | Any language works, a crash cannot take the core down, and the agent can write plugins with the same tools it uses for the task. |
| **Model calls through `curl`** | No TLS or HTTP code in the binary. curl handles proxies, certificates and HTTP/2. The API key goes in a 0600 header file, never on the command line. |
| **Hot reload by `stat()`** | A fingerprint of the harness files costs microseconds, so arx checks before every model call instead of watching files. |
| **One field table for the spec** | Validation, "did you mean" hints and `arx schema` all come from `kTopFields` in `validate.c`. Adding a key adds it to all three. |
| **Errors go to the agent** | A rejected edit or a broken tool becomes a `[harness]` note with enough detail for the agent to fix it itself. |
| **Observers cannot block** | The event pipe is non-blocking. A slow observer loses events; the agent never waits. |
| **Every plugin in its own process group** | A timeout or Ctrl-C kills the whole group: SIGTERM, then SIGKILL 3 seconds later. No orphans. |
| **Commands are plugins too** | `arx setup`, `init`, `doctor`, `models`, `sessions`, `update` and `plugin` are small scripts named `arx-<name>`, run git-style. The binary stays small, and anyone can add a command. |
| **Files are the interface** | Sessions, transcripts, events and the control inbox are plain files, so drivers and front-ends need no library. |

## Performance budgets

`make bench` measures these and fails if one is missed:

| Budget | Limit | macOS (arm64) | Linux (static, musl) |
|---|---|---|---|
| Binary size | 400 KB (macOS), 1 MB (Linux) | 183 KB | 258 KB, libc included |
| Startup, above `true` | 1 ms | 0.6 ms | within noise |
| Peak memory over 500 turns | 16 MB | 4 MB | 7 MB |
| Harness edit to live | 10 ms | 0.10 ms | 0.05 ms |

On macOS, a tool the agent has just created takes about 35 ms to go live,
because the OS checks every new executable the first time it runs. On Linux it
takes 0.2 ms.

## Source layout

`src/` has one folder per layer and one header per folder. A layer only uses
the layers below it.

```
main.c                the entry point
  └─ cli/             options, built-in and external commands   cli.h
       └─ agent/      the loop, session lifecycle, prompts      agent.h
            ├─ harness/   what the agent can change             harness.h
            ├─ model/     model calls through curl              model.h
            └─ io/        sessions, events, terminal view       io.h
                 └─ base/   buffers, files, JSON, processes     base.h
```

| Folder | File | What it holds |
|---|---|---|
| | `main.c` | the entry point: signals, then the command line |
| `cli/` | `options.c` | option parsing, spec lookup and usage errors |
| | `commands.c` | built-in commands: `check`, `tools`, `schema`, `watch`, `ctl`, `request`, `version`, `help` |
| | `external.c` | `arx foo` runs `arx-foo`; `arx help` lists every command |
| `agent/` | `loop.c` | the turn loop: caps, reload, inbox, notes, compaction, tool calls, stop hook |
| | `run.c` | session lifecycle: load, open or resume, observers, headless or interactive, result |
| | `agent.c` | caps parsing, notes, the system prompt and `{{templates}}` |
| `harness/` | `spec.c` | YAML to JSON with line numbers, `--set`, merging over `config.yaml` |
| | `plugins.c` | the layers: spec folder, project plugins, config folder, user plugins |
| | `signature.c` | the hot-reload fingerprint, over every layer, by `stat()` |
| | `validate.c` | the field tables (spec and `plugin.yaml`) and validation |
| | `schema.c` | the JSON Schema, from the same table |
| | `tools.c` | finds tools and caches their `--schema` |
| | `tool_exec.c` | runs one tool call; subagents run arx again |
| | `hooks.c` | runs `hooks/<point>` |
| | `compact.c` | the compaction strategies |
| `model/` | `llm.c` | builds the request, runs curl, classifies errors, retries |
| | `auth.c` | finds the API key (environment, Keychain or credentials file) and writes the 0600 header file |
| | `sse.c` | parses the streamed reply |
| `io/` | `session.c` | session folders, transcript, meta, inbox |
| | `events.c` | the event stream and observers |
| | `render.c` | the terminal view and `arx watch` |
| `base/` | `util.c` | buffers, files, paths, durations and sizes |
| | `json.c` | small cJSON helpers |
| | `proc.c` | the process runner: pipes, timeouts, process groups |

## Building and testing

| Command | What it does |
|---|---|
| `make` | release build: `-Os`, LTO, dead code stripped |
| `make debug` | `./arx-debug` with AddressSanitizer and UBSan |
| `make test` | 180 end-to-end checks against `tests/fake-curl` (47 core, 30 marketplace plugins, 46 plugin loading, 57 CLI). No network or API key needed. |
| `make bench` | the performance budgets above |
| `make lint` | clang-format, cpplint, files of 400 lines or fewer, doc comments |
| `make format` | rewrites `src/` in Google style |
| `make static` | a static Linux (musl) binary, built in Docker |
| `make install` | `arx` into `$(PREFIX)/bin` and its commands into `$(PREFIX)/libexec/arx` (default `~/.local`) |
| `make dist` | the release tarball and its sha256 for this platform, as CI builds them |

The tests run the debug build, so every check also runs under the sanitizers.
`tests/fake-curl` stands in for curl and replays scripted model replies, so the
whole loop runs offline.

## CI and releases

- **CI** (GitHub Actions) runs on every push to `main` and every pull request:
  lint, with clang-format 23.1.3 and cpplint 2.0.2 pinned, then all the tests
  and the four performance budgets against a static Linux build.
- **Releases** build `darwin-arm64`, `darwin-x86_64`, `linux-x86_64` and
  `linux-arm64`, and run the tests and budgets on macOS and Linux before
  publishing, so a slow or oversized build fails the release. Each tarball
  ships with a `.sha256`, which `install.sh` and `arx update` check.
- **Startup timing** is measured against `true` on the same machine, and
  measured again once before it fails, because shared CI machines are noisy.
- **Docs**: `.github/workflows/docs.yml` calls the docs site's deploy hook when
  `docs/` changes on `main`.

## Code style

The C sources follow Google style with a few rules of their own: files of at
most 400 lines, a comment on every file and function, and comments that say
why. See the [style guide](STYLE.md).
