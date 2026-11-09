# Prompt text and model settings

A plugin adds text to the system prompt with `instructions`, and fields to
the model request with `model_settings`.

Use them when a plugin needs the model to know or do something on every
call: a plugin that ships a tool tells the model when to use it, and a
plugin that needs a request field, such as `parallel_tool_calls`, sets it.
The spec, the kit and `config.yaml` still choose the prompt and the model.
Plugins add to them.

| Use | For | Use it when |
|---|---|---|
| `instructions` | short rules that must always be in the prompt | the model must follow the rule on every turn, such as when to call your tool |
| a [skill](skills.md) | long guides that the agent reads when it needs them | the know-how matters for some tasks only |
| `session_start` [context](hooks.md#points-with-a-decision) | facts that change with each session | the text comes from the state of the project, such as the git branch |

**Status:** today, since arx 0.2.0. **Example:**
[`plugins/plugin-authoring`](../../plugins/plugin-authoring), whose one line
of text points the agent to its skill.

## Contract

### Add text to the prompt

`instructions` in `plugin.yaml` is a text list, as in the spec: a string,
`{file: path}`, or a list of them, joined by blank lines.

```yaml
# plugin.yaml
name: test-runner
version: 0.1.0
arx: ">=0.2.0"
instructions: {file: prompts/instructions.md}
```

arx checks the text when it reads `plugin.yaml`. A problem is an error, so
`arx check --plugin` exits 2, `arx plugin add` refuses the plugin, and a run
skips it:

- **Paths**: a `file:` path is relative to the plugin folder, must stay
  inside it after symlinks resolve, and must be readable.
- **Template variables**: `{{date}}`, `{{cwd}}`, `{{session}}`, `{{turn}}`
  and `{{file:PATH}}` work as in the [spec](../spec.md#templates).
  `{{prompt}}`, `{{harness}}`, `{{skills}}` and `{{plugin_instructions}}`
  belong in the spec's prompt, and are errors in a plugin's text.

### Where the text goes

arx builds the system prompt in this order:

1. **The base**: the spec's `instructions` after the merge (`--set`, then
   `agent.yaml`, the kit's `prompt`, `config.yaml`), else the built-in
   default. Plugins do not change it.
2. **The plugin text**: the `instructions` of each plugin, in
   [layer](concepts.md#layer) order, each rendered on its own and joined by
   one blank line. With a kit or a `plugins:` list, the order is the list's.
   Without one, it is the project's plugins by name, then your user plugins
   by name.
3. **The place**: where the base names `{{plugin_instructions}}`, the plugin
   text goes there. Otherwise arx adds it after the base and one blank line.

arx adds no header before a plugin's text, so write it as the model should
read it. `{{harness}}` names the plugins that add text, so the agent can
find it and change it. With no plugin text, the prompt is the same as before
0.2.0, byte for byte.

**Planned:** with [trust](planned.md#trust), the text of a policy folder
will come before the base, and the spec will not be able to move or drop it.

### Add request fields

`model_settings` in `plugin.yaml` is a map of request fields, as in the
spec. A `null` removes a field.

```yaml
# plugin.yaml
model_settings: {parallel_tool_calls: true}
```

For each field, the first source in this order that sets it wins:

| Rank | Source |
|---|---|
| 1 | `--set model_settings.<field>=...` |
| 2 | `agent.yaml` |
| 3 | the kit, with the kits it extends |
| 4 | `config.yaml` |
| 5 | each plugin, in layer order |
| each call | `before_model` [hooks](hooks.md#before_model) can change `settings` for that call |

- **Field by field**: maps merge one field at a time. A number, a string,
  a list or `null` is one field.
- **`null`**: a plugin's `null` removes the field, unless a source above it
  sets one. A later plugin cannot set the field again.
- **Fields a plugin cannot set**: `model`, `messages`, `tools`, `stream`
  and `stream_options`. arx builds them, so they are an error in
  `plugin.yaml`.
- **Where they apply**: every model call, the `summarize` compaction call,
  and subagents, which load plugins the same way.

arx sends the fields in Chat Completions form. An [adapter](adapters.md)
translates them for its endpoint, and drops the ones its endpoint rejects.
See [Map model settings](adapters.md#map-model-settings).

**Planned:** with [trust](planned.md#trust), a policy folder's settings will
rank above `--set`.

### Change one plugin's text and settings

Settings in the [active list](kits.md#the-active-list) change one plugin's
`instructions` and `model_settings`, the same way they change its `tools`
and `hooks`:

```yaml
# agent.yaml
plugins:
  - reviewer: {instructions: null}                           # drops its text
  - test-runner: {instructions: {file: prompts/short.md}}    # its other file
  - lint: {instructions: "Run lint before you commit."}      # new text
  - deep-think: {model_settings: {reasoning_effort: high}}   # its value
```

A string or a `file:` replaces the text, and the path is in the plugin's
folder. `null` drops the text and keeps the plugin's tools and hooks.
`model_settings` merge over the plugin's own and keep the plugin's rank. A
bad value, such as a file that is missing, is a spec error, because you
wrote it: `arx check` exits 2, and arx does not skip the plugin.

### Check what a plugin adds

`arx check` shows the prompt and the settings of a run:

```text
prompt: kit coding; plugins add test-runner (121 bytes)
model_settings: reasoning_effort="medium" (spec), parallel_tool_calls=true (plugin test-runner)
```

The `prompt:` line names the source of the base, then the plugins that add
text, with the size of their raw text. The `model_settings:` line shows each
field and its source: `spec` for the spec, the kit, `config.yaml` and
`--set`, or the plugin's name. Under `warnings:`, arx reports two plugins
that set one field to different values, and a plugin that adds more than
4096 bytes:

```text
- model_settings.temperature: plugins precise (0.2) and creative (0.9) both set it; precise wins, as it loads first
- plugin big-rules adds 9216 bytes to the prompt; keep instructions short and put long guides in a skill
```

A conflict is not an error: the run goes on and the first plugin wins.
Before an install, `arx plugin add` shows the same facts from
`arx check --plugin`:

```text
  prompt    adds 121 bytes to the system prompt
  settings  parallel_tool_calls
```

### Reload

An edit to a plugin's prompt file, to its `plugin.yaml`, or to its settings
in the active list reloads the harness before the next model call. arx
renders the prompt again, and when the text changed, it replaces message 0
and writes a `{"_reset":true}` line to the transcript.

- **A bad value in the settings**: arx rejects the edit like any bad spec
  edit, and the previous prompt stays.
- **A `plugin.yaml` or prompt file that is no longer valid**: arx skips the
  plugin, as it would at the start, and `arx check` says why.

`{{file:PATH}}` contents are not watched. They render again only at a
reload.

## Write a plugin with instructions

This plugin ships a `run_tests` tool, and tells the model when to call it.
The folder:

```text
test-runner/
  plugin.yaml
  prompts/instructions.md
  tools/run_tests
```

The `plugin.yaml` names the text file and turns on parallel tool calls:

```yaml
# plugin.yaml
name: test-runner
version: 0.1.0
description: Runs the project's tests, and tells the model when to.
arx: ">=0.2.0"
instructions: {file: prompts/instructions.md}
model_settings: {parallel_tool_calls: true}
```

The text is two sentences, written to the model:

```markdown
Run `run_tests` after you change a source file, and before you say a task
is done. It prints only the tests that failed.
```

Check the folder, then the harness with it:

```sh
arx check --plugin test-runner                        # checks the folder
arx plugin add --link ./test-runner --project --yes   # uses it here
arx check                                             # the prompt and settings
```

`arx check --plugin` prints `instructions=121` and
`model_settings=parallel_tool_calls` with the other lines.

Set `arx: ">=0.2.0"`. arx 0.1.0 does not know these keys, and skips the
plugin as broken; the version check says why.

## Common mistakes

| Mistake | What happens | Fix |
|---|---|---|
| A long guide in `instructions` | every call pays for it, and `arx check` warns above 4096 bytes | put the guide in a skill, and keep one line in `instructions` that names it |
| `{{date}}` or `{{turn}}` in plugin text | the prompt changes at each reload, and breaks the provider's prompt cache | leave them out, or use a `session_start` hook |
| A kit's `temperature` hides a plugin's | the kit ranks above plugins: that is the design | use settings for that plugin to change only its value |
| A field for one provider only, such as `verbosity` | other routes may drop it with no message | say so in the plugin's `description` |
| No `arx: ">=0.2.0"` | arx 0.1.0 skips the plugin with "unknown key" | set it |
| `{file: ../shared.md}` | arx refuses the plugin: the path leaves its folder | copy the file into the plugin |

## Related

- [Plugin reference](reference.md#pluginyaml): every `plugin.yaml` key, and
  the lines of `arx check`.
- [Kits](kits.md#the-active-list): the active list, and settings for one
  plugin.
- [agent.yaml reference](../spec.md#templates): the template variables.
- [Adapters](adapters.md#map-model-settings): what each route does with a
  request field.
