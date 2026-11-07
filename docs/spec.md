# agent.yaml reference

The spec is one YAML file that describes an agent: its model, prompts, tools,
hooks, compaction and limits. arx reads `./agent.yaml` unless you pass
`--spec PATH`. Paths inside the spec are relative to the spec's directory.

**Your defaults.** `arx setup` writes `config.yaml` in `~/.config/arx/` (or
`$ARX_CONFIG_DIR`). With no `./agent.yaml`, arx runs on it alone. When a
project has an `agent.yaml`, it is merged over `config.yaml` key by key, and
the project wins, so a project's spec only needs what differs. `arx check`
shows both files when both are in use.

## Validation

arx validates the spec when it starts and every time the file changes. Each
problem is reported with its line number, and an unknown key gets a "did you
mean" hint:

```
agent.yaml:6: modle: unknown key (did you mean "model"?)
```

- **`arx check`** validates the spec, its tools and its hooks without starting
  a session.
- **`arx schema`** prints a JSON Schema for the spec. Point your editor's YAML
  plugin at it for completion and inline errors.
- **At run time**, an invalid edit is rejected: the previous version stays in
  use and the agent is told why.

The validator and the schema are generated from one field table in
`src/harness/validate.zig`, so they always agree.

## A complete example

```yaml
name: tsp-climber
model: your/model-id
endpoint: {base_url: https://openrouter.ai/api/v1, api_key_env: OPENROUTER_API_KEY}
context_window: 128000
model_settings: {temperature: 0.7, max_tokens: 8000}
instructions: [{file: prompts/system.md}]
first_message: {file: prompts/first.md}
tools:
  bash: {timeout: 120}
  quick_eval: {timeout: 60}                 # tools/quick_eval
  researcher: {agent: subagents/r.yaml}     # a subagent
tool_output: {head: 2kb, tail: 6kb}
hooks: {stop: {timeout: 10s}}               # hooks/stop
compaction: {strategy: mask, trigger: 0.7, keep: 5}
skills: skills
limits: {max_turns: 200, turn_timeout: 10m}
observers: ["cat >> all-events.jsonl"]
prices: {input: 3, output: 15}
```

## Value types

| Type | Accepts |
|---|---|
| duration | seconds as a number, or `"10s"`, `"5m"`, `"1h"` |
| size | bytes as a number, or `"2kb"`, `"1mb"` |
| text | a string, or `{file: path}` (relative to the spec) |
| text list | a text, or a list of texts joined by blank lines |

## Top-level keys

| Key | Type | Default | Description |
|---|---|---|---|
| `name` | string | | Agent name, shown in events. |
| `model` | string | **required**, here or in your defaults | Model id your endpoint accepts. |
| `endpoint` | map | **required**, here or in your defaults | Where requests go. See [endpoint](#endpoint). |
| `model_settings` | map | | Extra request fields, such as `temperature` or `max_tokens`. Passed through as they are; `null` removes a field. |
| `context_window` | integer | `128000` | Context size in tokens. Compaction triggers are a fraction of it. |
| `instructions` | text list | a short default | The system prompt. `{{vars}}` are expanded. |
| `first_message` | text | the task | The first user message. `{{prompt}}` is the task. |
| `tools` | map of maps | | Options per tool, and subagent tools. See [tools](#tools). |
| `tool_output` | map | | How much tool output the model sees. See [tool_output](#tool_output). |
| `hooks` | map of maps | | Options per hook point. See [hooks](#hooks). |
| `compaction` | map | | How the context stays in the window. See [compaction](#compaction). |
| `skills` | string | | Directory of `<name>/SKILL.md` files. |
| `limits` | map | | Per-session limits. See [limits](#limits). |
| `observers` | string list | | Shell commands fed the event stream on stdin. |
| `prices` | map | | Token prices for cost tracking. See [prices](#prices). |
| `plugins` | string list | all installed | The only installed plugins to use; `[]` for none. See [Plugin folders](plugins.md#plugin-folders). |
| `compactors` | map | | Named compaction programs, `name: path`, for `compaction.strategy`. |

### endpoint

| Key | Type | Default | Description |
|---|---|---|---|
| `base_url` | string | **required** | OpenAI-compatible base URL, e.g. `https://openrouter.ai/api/v1`. |
| `api_key_env` | string | `OPENAI_API_KEY` | Environment variable that holds the API key. |
| `headers` | map | | Extra HTTP headers. |
| `curl` | string | `$ARX_CURL` or `curl` | The curl executable. |
| `retry_base` | duration | `2s` | First retry delay. |
| `retry_max` | duration | `5m` | Longest retry delay. |
| `retry_attempts` | integer | `0` | Give up after this many retries. `0` means never. |

arx retries on network errors, timeouts, HTTP 408, 409, 425, 429 and 5xx,
with exponential backoff (or the server's `Retry-After`). HTTP 401 and 403
stop the run with exit code 4.

### tools

Every executable in `tools/` is a tool, with or without an entry here. `bash`
and `edit` are built in. Each entry is a map of options:

| Key | Type | Default | Description |
|---|---|---|---|
| `timeout` | duration | `120s` | Longest a call may run. |
| `enabled` | boolean | `true` | `false` hides the tool from the model. |
| `agent` | string | | A spec path. Makes this tool a subagent. |
| `description` | string | | The description shown to the model (for subagents). |

Tool names may contain letters, digits, `_` and `-`.

**Built-in tools:**
- **`bash`** runs `{"command": "..."}` with `sh -c` in the working directory.
- **`edit`** replaces `old` with `new` in `path`. `old` must occur exactly once;
  an empty `old` creates a new file.

### tool_output

| Key | Type | Default | Description |
|---|---|---|---|
| `head` | size | `2kb` | Bytes kept from the start of a long output. |
| `tail` | size | `6kb` | Bytes kept from the end of a long output. |

The full output is always saved to `.arx/sessions/<id>/tool-NNNN.out`, and the
cut is marked with that path.

### hooks

Keys are hook points: `session_start`, `before_tool`, `after_tool` and `stop`.
The hook itself is the executable `hooks/<point>`.

| Key | Type | Default | Description |
|---|---|---|---|
| `timeout` | duration | `10s` | Longest the hook may run. |
| `fail` | string | `open` | `closed` makes a failed `before_tool` hook deny the call. |

### compaction

| Key | Type | Default | Description |
|---|---|---|---|
| `strategy` | string | `mask` | `mask`, `summarize`, `hybrid`, `restart`, a `compactors` name, or a path to an executable. |
| `trigger` | number | `0.7` | Compact when the prompt passes this fraction of `context_window` (0 to 1). |
| `keep` | integer | `5` | Recent tool outputs (`mask`) or turns (`summarize`) kept intact. |
| `exclude_tools` | string list | | Tools whose outputs are never masked. |
| `clear_inputs` | boolean | `false` | Also clear the arguments of old tool calls. |
| `prompt` | text | a default | Instructions for the `summarize` call. |

[How arx works](concepts.md#context-and-compaction) compares the strategies.

### limits

| Key | Type | Default | Description |
|---|---|---|---|
| `max_turns` | integer | `200` | Model calls per session. |
| `turn_timeout` | duration | `10m` | Longest single model call. |

The agent can edit these. Use `--cap` for limits it cannot raise.

### prices

| Key | Type | Description |
|---|---|---|
| `input` | number | USD per 1M input tokens. |
| `output` | number | USD per 1M output tokens. |

If the provider reports a cost (OpenRouter does), arx uses it. Otherwise it
computes the cost from these prices. `--cap usd=N` needs one or the other.

## Templates

`instructions` and `first_message` are templates. arx expands these
variables every time it builds the prompt:

| Variable | Value |
|---|---|
| `{{prompt}}` | the task (`-p`, stdin, or the first interactive message) |
| `{{harness}}` | where the spec, tools, hooks, skills and session files are, and how to change them |
| `{{skills}}` | one line per skill: name, description and path |
| `{{date}}` | today, as `YYYY-MM-DD` |
| `{{cwd}}` | the working directory |
| `{{session}}` | the session id |
| `{{turn}}` | the current turn number |
| `{{file:PATH}}` | the contents of a file |
| `{{file:PATH:tail=N}}` | the last N lines of a file |
| `{{file:PATH:max=SIZE}}` | a file, cut to SIZE (e.g. `8kb`) |

`{{file:...}}` paths are relative to the working directory. A missing file
renders as `(missing: PATH)`, so a template can name a file the agent has not
written yet. An unknown variable is a validation error.

**When templates are rendered:**
- The system prompt is rendered at the start and again whenever the harness
  reloads.
- The first message is rendered at the start and again after every `restart`
  compaction. This is how a restarting agent gets its notes back: put
  `{{file:notes.md}}` in `first_message`.

## Overrides

`--set key.path=value` overrides one value for this run. It is applied on
every reload, so the agent's edits cannot undo it:

```sh
arx --set model=your/other-model --set limits.max_turns=10 -p "..."
```

Values are parsed like YAML scalars: `10` is a number and `true` a boolean.
