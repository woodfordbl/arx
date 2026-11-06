# How arx works

arx runs one agent: a model, a set of tools and a conversation. It is built for
long runs without supervision, where the agent also changes the harness it runs
in. This page explains the parts and how they fit together.

## The three parts

| Part | What it is | Who changes it |
|---|---|---|
| **The core** | one C binary: the turn loop, model calls, sessions, events | nobody at run time |
| **The harness** | the spec (`agent.yaml`), its prompts, and the `tools/`, `hooks/` and skills next to it, over your defaults and installed plugins | you, and the agent itself |
| **The work** | the directory arx runs in: the code, data and files the task is about | the agent, through its tools |

The core does as little as possible. Everything else is a plugin: an
executable in any language that arx runs and talks to with JSON. See the
[plugin guide](plugins.md).

**Layers.** The harness is read from up to four places, in order: the spec
folder, the project's `plugins/`, your config folder (`~/.config/arx/`), and
the plugins you installed. For tools, the first layer wins, so a tool the
agent writes always beats a plugin's. Hooks from every layer run in order.
A spec that lists `plugins: [...]` uses only the spec folder and the plugins it
names, so a run cannot change because you installed something later. See
[Plugin folders](plugins.md#plugin-folders).

## The turn loop

One turn is one model call. Before each call, arx gets the harness and the
context ready. After it, arx runs the tools the model asked for.

```
            ┌──────────────────────────────────────────────┐
            │                                              │
            ▼                                              │
   1. check caps ──── cap reached ──▶ exit 3               │
            │                                              │
   2. reload harness if any file changed (stat only)       │
   3. read the inbox (arx ctl note / stop)                 │
   4. hand queued [harness] notes to the agent             │
   5. compact the context if it passed the trigger         │
            │                                              │
   6. call the model (streamed, with retries)              │
            │                                              │
            ├── tool calls ──▶ before_tool ─▶ run ─▶ after_tool
            │                                              │
            └── no tool calls ──▶ stop hook                │
                                   ├── continue / restart ─┘
                                   └── nothing ──▶ done, exit 0
```

1. **Caps.** If a `--cap` or `limits.max_turns` is reached, the run stops with
   exit code 3.
2. **Hot reload.** arx fingerprints every harness file with `stat()`. If one
   changed, it reloads the spec, the tools and the system prompt. This costs
   about 0.1 ms when nothing changed. Linked plugins are checked the same way.
3. **Inbox.** Commands from `arx ctl` are applied: a note for the agent, or a
   request to stop.
4. **Notes.** Problems found by arx (a rejected spec edit, a broken tool, an
   operator note) reach the agent as one `[harness]` message.
5. **Compaction.** If the prompt passed `compaction.trigger × context_window`,
   the context is made smaller with the spec's strategy.
6. **Model call.** The request goes out through `curl`. Network errors, 429s
   and 5xx answers are retried with backoff. If the provider says the prompt
   is too long, arx compacts once and tries again.

After the call:

- **Tool calls** run one after the other. Each goes through the `before_tool`
  hook (which can deny it), runs, and goes through the `after_tool` hook (which
  can add a note to the result).
- **No tool calls** means the agent thinks it is done. The `stop` hook decides:
  it can send a message and `continue`, `restart` from a fresh context, or say
  nothing, which ends the run.

## The harness edits itself

The agent's system prompt can include `{{harness}}`, which tells the agent
where its spec, tools, hooks and skills are and how to change them. Because
arx reloads before every model call, an edit made in turn 12 is live in
turn 13.

- **A new tool** is any executable the agent writes to `tools/`.
- **A new hook** is any executable at `hooks/<point>`.
- **A spec edit** can change the model settings, the compaction strategy, the
  tool timeouts and the prompts.

**Bad edits are safe.** If the agent writes a spec that does not validate, arx
keeps the previous version and tells the agent what is wrong, with the line
number and a "did you mean" hint:

```
[harness]
Your harness edit was rejected; the previous version is still in use:
harness/agent.yaml:14: compaction.stratgy: unknown key (did you mean "strategy"?)
```

A tool whose `--schema` fails is skipped, and the agent gets a "Tool problems"
note. A hook that crashes is reported and ignored, so a broken hook cannot stop
the run.

## Caps and limits

There are two kinds of limit, and the difference matters when the agent can
edit its own spec.

| | Set by | Can the agent change it? |
|---|---|---|
| **Caps** (`--cap turns=, tokens=, usd=, wall=, depth=`) | whoever starts arx | no |
| **Limits** (`limits.max_turns`, `limits.turn_timeout`) | the spec | yes |

When both apply, the lower one wins. Caps are passed down to subagents, so a
subagent cannot spend more than its parent may.

## Context and compaction

Long runs fill the context window. arx keeps it in bounds with one of these
strategies (`compaction.strategy`):

| Strategy | What it does | Good for |
|---|---|---|
| `mask` (default) | clears old tool outputs and leaves a pointer to the saved file | most runs; cheap, and keeps the prompt cache warm |
| `summarize` | one model call summarizes the older turns | conversations where the reasoning matters more than the outputs |
| `hybrid` | `mask`, then `summarize` if still too large | long runs with large outputs |
| `restart` | starts over from the system prompt and first message | loops where memory lives in files (Ralph-style) |
| a path | your own executable rewrites the messages | anything else |

`mask` is the default because "The Complexity Trap" (JetBrains/TUM, 2025)
found that masking matches model-written summaries at about half the cost.
arx masks in one batch when the trigger is passed, so the provider's prompt
cache is invalidated rarely.

Full tool outputs are always saved to `.arx/sessions/<id>/tool-NNNN.out`, so
nothing is lost when a result is masked or cut short. The agent can read the
file again if it needs it.

## Sessions

Every run is a session, stored in `.arx/sessions/<id>/` in the working
directory. `.arx/sessions/last` points at the newest one.

| File | Contents |
|---|---|
| `transcript.jsonl` | every message; `--resume` replays it |
| `events.jsonl` | the event stream |
| `meta.json` | turns, tokens, cost and status |
| `tool-NNNN.out` | full tool outputs |
| `inbox` | commands from `arx ctl` |

The transcript is flushed after every message, so a crash loses at most the
current turn.

## Events

Everything that happens is an event: one JSON object per line, with a version
field (`"v": 1`). The terminal view, `arx watch`, observers and drivers all
read the same stream. Fields may be added within version 1, but none are
renamed or removed. The [event reference](plugins.md#events) lists every type.

## Subagents

A tool entry with `agent: path/to/spec.yaml` runs arx again as a child
process, one level deeper. The child has its own harness and starts with no
context except the task. Its events appear in the parent's stream with a
higher `depth`, and its final answer is the tool result. See
[Subagents](plugins.md#subagents).

## What arx does not do

- **No TLS, no HTTP client.** Model calls go through `curl`. The API key is
  passed in a private header file, never on the command line.
- **No sandbox.** Tools run as your user, in the working directory. Run arx in
  a container or VM when the task needs isolation. A `before_tool` hook can
  deny commands, but it is a guard, not a security boundary.
- **No plugin API.** Plugins are processes. Nothing is linked into the binary.
