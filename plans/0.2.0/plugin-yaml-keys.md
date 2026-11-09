# Plan: new plugin.yaml keys

Slug: `plugin-yaml-keys`. Release: arx 0.2.0.

## Goal

A plugin can add text to the system prompt with `instructions`, and fields
to the model request with `model_settings`. Both keys use merges that arx
already has, so the core gets no new hook point, flag, variable or program.

What this enables:

- A plugin that ships a tool tells the model when to use it, without an edit
  to the kit's prompt.
- A plugin that needs a request field sets it, such as
  `parallel_tool_calls: true` for a scheduler that runs calls at once.
- A sandbox plugin tells the model what it cannot reach.

Not in scope: a plugin still cannot set `model`, `endpoint` or any other
spec key. Logic for each call stays in `before_model` hooks.

## Current state

**Keys today**

- The spec has both keys: `model_settings` (any map, `null` removes a field)
  at `src/harness/fields.c:72`, and `instructions` (a text list) at
  `fields.c:74`.
- A kit has `model_settings` and `prompt` (`fields.c:118-119`). `kits.c:148-157`
  merges `model_settings` along `extends`, and makes `prompt` an absolute
  path. `active.c:129-143` (`KitRoot`) turns them into the spec's
  `model_settings` and `instructions: [{file: <absolute path>}]`.
- `plugin.yaml` has neither key (`fields.c:97-111`). `PluginValidate`
  (`validate.c:369-379`) rejects them as unknown keys, and
  `docs/plugins/reference.md:59` says they are not allowed.

**Merge order today** (`SpecLoad`, `spec.c:231-279`)

1. arx parses `agent.yaml`.
2. `BuildList` merges the kit under the spec (`spec.c:204-228`).
3. arx merges `config.yaml` under both (`spec.c:259-263`).
4. arx applies `--set` on top (`spec.c:266-269`).
5. `PluginsLoad` (`spec.c:270`) calls `Adopt` (`plugins.c:161-203`) for each
   plugin in layer order. `Adopt` merges the rest of `plugin.yaml` under the
   spec with `SpecMergeUnder` (`plugins.c:202`). `MergeDefaults`
   (`spec.c:145-161`) moves only the keys that the target does not have, and
   recurses into maps.

So for a merged key, the order is: `--set`, then `agent.yaml`, the kit,
`config.yaml`, the first plugin, and the later plugins. The keys in
`kOwnKeys` (`plugins.c:18-20`) stay out of the merge. Settings from the
active list change a plugin's `tools` and `hooks` before the merge
(`plugins.c:165-178`). Settings merge in the order `config.yaml`, kit,
`agent.yaml`, `--set` (`active.c:190-196`).

**The prompt today**

- `SystemPrompt` (`agent.c:257-263`) takes the spec's `instructions`, or
  `kDefaultInstructions` (`agent.c:17-23`), and renders it with
  `RenderTemplate` (`agent.c:234-255`; variables at `agent.c:206-232`).
- `SpecText` reads `{file:}` paths relative to the spec folder
  (`spec.c:314-338`).
- arx calls `SystemPrompt` at the session start (`run.c:85-89`), at a
  `restart` compaction (`compact.c:196-205`), and at a reload
  (`loop.c:64-70`). A reload replaces message 0 and writes a `_reset` line
  when the text changed.
- `{{harness}}` lists the plugins in use (`PluginsText`, `agent.c:124-147`).
- `validate.c:16-17`, `210-228` and `341-346` check the template variables.

**The request today**

- `NewRequest` (`model_call.c:28-39`) copies the spec's `model_settings`
  into `settings`. `before_model` hooks can change it for one call
  (`hooks.c:26-27`).
- `RequestBody` (`llm.c:26-57`) puts the settings on top of the body. A
  `null` removes a field. A setting can replace any field, including
  `model`, `messages`, `tools` and `stream`.
- `LlmChat` (`llm.c:207-213`) uses the spec's `model_settings` for the
  `summarize` call (`compact.c:163`).

**Reload today**

`SpecSignature` (`signature.c:63-94`) covers the spec, `config.yaml`, the
files that the spec's text keys name (`signature.c:49-60`, `67-69`),
`tools/`, `hooks/` and skills in each layer, and every `plugin.yaml` and
`kit.yaml`. It does not cover a plugin's prompt files.

**arx check today**

- `PrintCheck` (`check.c:206-234`) prints the report. `OverlapWarnings`
  (`check.c:81-119`) and `HiddenWarnings` (`check.c:132-159`) make the
  warnings.
- `arx check --plugin` (`describe.c:76-114`) prints `key=value` lines.
  `commands/arx-plugin` reads them (`describe`, lines 79-95) and shows them
  before an install (lines 179-197).

**Adapters today**

An adapter gets the merged body in Chat Completions format. The `responses`
adapter (`plugins/chatgpt/adapters/responses`, lines 25-26 and 116-136) maps
`reasoning_effort` to `reasoning.effort`, passes six native fields, and
drops the rest: `temperature`, `max_tokens`, `verbosity` and others.

**Docs today**

`docs/plugins/planned.md:81-84` has one line on these keys.
`docs/plugins/hooks.md:77` says that the `settings` of `before_model` are
"`model_settings` from the spec".

## Design

### The keys

| Key | Type | Meaning |
|---|---|---|
| `instructions` | text list: a string, `{file: path}`, or a list of them | Text that arx adds to the system prompt, after the spec's prompt. A path is relative to the plugin folder and must stay inside it. |
| `model_settings` | map | Request fields, as in the spec. `null` removes a field. They rank below the spec, the kit and `config.yaml`. |

```yaml
# plugin.yaml
name: async-calls
version: 0.1.0
arx: ">=0.2.0"
instructions: {file: prompts/instructions.md}
model_settings: {parallel_tool_calls: true}
```

`PluginValidate` checks the new keys. A problem is an error, so
`arx check --plugin` exits 2, `arx plugin add` refuses the plugin, and a run
skips it:

- **`{file:}`**: the path must be relative, must stay inside the plugin
  folder after `realpath`, and must be readable. Then the text that
  `arx plugin add` shows is the text that the model gets.
- **Template variables**: only `{{date}}`, `{{cwd}}`, `{{session}}`,
  `{{turn}}` and `{{file:PATH}}`. `{{prompt}}`, `{{harness}}`, `{{skills}}`
  and `{{plugin_instructions}}` are errors, for example
  `instructions: {{harness}} belongs in the spec's prompt, not a plugin's`.
- **Fields that arx builds**: a plugin's `model_settings` cannot set
  `model`, `messages`, `tools`, `stream` or `stream_options`, for example
  `model_settings.model: arx sets this field; a plugin cannot`. The spec
  keeps the freedom it has today.
- **Other spec keys**: `model`, `endpoint` and the rest stay not allowed.

### The prompt

The spec, the kit and `config.yaml` choose the prompt. Plugins add to it.
A policy's text comes first of all.

0. **The policy text**: the instructions of each policy folder
   (`--policy DIR`, from `trust`), in flag order, start the prompt, before
   the base. The agent writes the spec, so the spec cannot move this text:
   `{{plugin_instructions}}` places only the plugins' text below, and
   active-list settings cannot drop it, because a policy gets no settings.
   The release plan settles this ("Settled across plans", point 3).
1. **The base**: the spec's `instructions` after the merge that exists now
   (`--set`, then `agent.yaml`, the kit's `prompt`, `config.yaml`), else the
   built-in default. This step does not change.
2. **The plugin text**: the instructions of each plugin layer, in layer
   order, each rendered on its own and joined by one blank line. Layer order
   is the active list. Without a list, it is the project plugins by name,
   then the user plugins by name.
3. **The place**: when the base contains `{{plugin_instructions}}`, the
   plugin text goes there. Otherwise arx appends it to the base after one
   blank line. With no policy text and no plugin text, the prompt renders
   byte for byte as it does today.

These rules also apply:

- **No header**: arx adds no header before each plugin's text.
- **`{{harness}}`**: when a plugin adds text, it gets one more sentence:
  `The plugins reviewer and async-calls add text after your instructions,
  from the instructions key of their plugin.yaml.` Then the agent can find
  and change that text.
- **Where it applies**: everywhere `SystemPrompt` runs, which is the
  session start, a `restart` compaction and a reload. The `summarize` call
  keeps its own prompt.
- **No bands**: bands order hooks only. A plugin cannot put its text before
  the base or before another plugin. The active list decides the order.
  Only a policy's text goes before the base.

Settings from the active list can replace a plugin's text, the same way
they change its `tools` and `hooks`:

```yaml
plugins:
  - reviewer: {instructions: null}                        # drops its text
  - async-calls: {instructions: {file: prompts/short.md}} # another file in that plugin
  - lint: {instructions: "Run lint before you commit."}   # new text
```

A string replaces the text. `{file:}` names a file in the plugin folder.
`null` drops the text. A bad value here, such as a file that is missing, is
a spec error from `SpecValidate`, because you wrote it. arx does not skip
the plugin for it.

### Model settings

The first source in this order that sets a field wins:

| # | Source |
|---|---|
| 0 | each policy folder (`--policy DIR`, from `trust`), in flag order: the first policy wins |
| 1 | `--set model_settings.<field>=...` |
| 2 | `agent.yaml` |
| 3 | the kit, with the kits it extends |
| 4 | `config.yaml` |
| 5 | each plugin, in layer order: the first plugin wins |
| each call | `before_model` hooks, by band, can change `settings` for that call |

- **Policy**: a policy's settings rank above `--set`, so neither the agent
  nor the launcher can change them. The release plan settles this, to match
  `trust`. Active-list settings do not reach a policy.
- **Leaf by leaf**: maps merge field by field. Scalars, arrays and `null`
  are leaves. This is the `SpecMergeUnder` that exists now, so the merge
  needs no new code.
- **`null`**: a plugin's `null` removes the field, unless a source above it
  sets one. A later plugin cannot set the field again.
- **Settings for one plugin**: active-list settings merge over the plugin's
  own `model_settings` before the merge, such as
  `- deep-think: {model_settings: {reasoning_effort: medium}}`. The value
  keeps the plugin's rank, and it goes away when the plugin is disabled.
  That is the difference from the kit's own `model_settings`.
- **Hooks**: `before_model` hooks get the merged result in `settings`.
- **Compaction**: the `summarize` call uses the same merged settings
  through `LlmChat`, as it uses the spec's settings today.
- **Subagents**: a subagent builds its own active list. Plugin settings and
  text reach it the same way plugin tools do.

### Conflicts and arx check

A conflict is two plugins that set the same leaf to different values. It is
not an error. The run goes on, the first plugin wins, and `arx check`
warns:

- **Same value**: no warning.
- **The spec, the kit, `config.yaml` or `--set` over a plugin**: no
  warning, because the design wants that result. The `model_settings:` line
  shows which value won.
- **A policy over any other source**: no warning, for the same reason. The
  line shows `(policy NAME)`. Two policies that differ get the same warning
  as two plugins.
- **A map and a scalar at one path**: a conflict at the shorter path.

`arx check` gets two lines after `hooks:` and before `plugins:`:

```text
prompt: kit coding; plugins add reviewer (212 bytes), async-calls (96 bytes)
model_settings: reasoning_effort="medium" (spec), parallel_tool_calls=true (plugin async-calls)
```

- **`prompt:`** always prints. The base is `agent.yaml`, `kit NAME`,
  `config.yaml`, `--set` or `default`. The part from `; plugins add` prints
  only when a plugin adds text. With a policy that adds text, the line
  starts with it: `prompt: policy rules (96 bytes), then kit coding; ...`.
- **`model_settings:`** prints only when the settings are not empty. Values
  are compact JSON. The source is `policy NAME`, `spec` (that is,
  `agent.yaml`, the kit, `config.yaml` or `--set` after the merge), or
  `plugin NAME`.

New warnings, under `warnings:` with the overlap and hidden-tool warnings:

```text
- model_settings.temperature: plugins precise (0.2) and creative (0.9) both set it; precise wins, as it loads first
- plugin big-rules adds 9216 bytes to the prompt; keep instructions short and put long guides in a skill
```

The size warning starts at 4096 bytes for one plugin, counted on the raw
text before it renders.

`arx check --plugin DIR` gets two lines after `hosts=`:

```text
instructions=212
model_settings=parallel_tool_calls temperature
```

`instructions=` is the size of the raw text in bytes, and is empty when the
plugin has none. `model_settings=` lists the top-level field names.
`arx plugin add` shows them before it asks:

```text
  prompt    adds 212 bytes to the system prompt
  settings  parallel_tool_calls temperature
```

### Kits and agent.yaml

| Source | Prompt | Model settings |
|---|---|---|
| a policy's `instructions`, `model_settings` (`trust`) | comes before the base; the spec cannot move or drop it | wins over every other source, `--set` included |
| `agent.yaml` `instructions`, `model_settings` | chooses the base, in place of the kit's | wins over the kit, `config.yaml` and plugins, field by field; only `--set` and a policy win over it |
| kit `prompt`, `model_settings` | chooses the base when `agent.yaml` has none | wins over `config.yaml` and plugins |
| `config.yaml` | is the base when neither of the above sets one | wins over plugins |
| plugin `instructions`, `model_settings` | adds after the base | ranks last; the first plugin wins |
| active-list settings for one plugin | replace or drop that plugin's text | change that plugin's values, at its rank |

`kit.yaml` gets no new keys.

### Which tool wins

The new keys do not change which tool wins. Tools follow the rule that the
release plan settles ("Settled across plans", point 4):

1. A policy layer's tool.
2. A tool from a plugin that lists the name in `replaces:`.
3. The first tool with the name, the rule that exists now.

`replaces:` decides tools only. It gives a plugin no rank for its
`instructions` or `model_settings`: those follow the list order above.

### Adapters

The adapter contract does not change. arx merges every source into one set
of top-level Chat Completions fields before the adapter runs. The adapter
cannot tell which plugin set a field, and does not need to. Each adapter
owns the mapping for its provider:

- **A field it knows**: it translates the field.
- **A native field that the provider takes**: it passes the field through.
- **A field that the provider rejects**: it drops the field and does not
  fail the call. A plugin setting must not break a run on one provider.

Each adapter lists its mapping in its README. For the routes that arx
supports in 0.2.0:

| Field | No adapter (OpenAI, OpenRouter, vLLM, Ollama) | `responses` (ChatGPT plan) |
|---|---|---|
| `temperature`, `top_p` | passed | dropped: the route rejects it |
| `max_tokens`, `max_completion_tokens` | passed | dropped |
| `reasoning_effort` | passed | `reasoning.effort` |
| `verbosity` | passed | `text.verbosity` (new in 0.2.0) |
| `tool_choice` | passed | mapped (exists now) |
| `parallel_tool_calls`, `reasoning`, `text`, `include`, `prompt_cache_key`, `service_tier` | passed | passed |
| any other field | passed | dropped |

A plugin author uses Chat Completions field names. A plugin that sets a
field for one provider only says so in its `description`. A future adapter
plugin, such as one for the Anthropic Messages API, writes its own row: for
example `max_tokens` stays `max_tokens`, `stop` becomes `stop_sequences`,
and `parallel_tool_calls: false` becomes
`tool_choice.disable_parallel_tool_use`.

### Reload

Plugin instructions reload. The rules:

- **The fingerprint**: `SpecSignature` also hashes the instruction files of
  each layer. These paths are absolute after `Adopt`.
- **What triggers a reload**: an edit to a plugin's prompt file, to its
  `plugin.yaml`, or to the active-list settings. The reload happens before
  the next model call.
- **What the reload does**: `SystemPrompt` renders the prompt again. When
  the text changed, arx replaces message 0 and writes a `_reset` line, as it
  does for the spec's prompt today (`loop.c:64-70`).
- **Model settings**: arx reads them from the reloaded spec on each call,
  so a change applies on the next call.
- **`{{file:PATH}}` contents**: not watched, the same as today. They render
  again only at a reload.
- **A bad edit**, such as settings that name a missing file: arx rejects it
  like any bad spec edit, and the previous prompt stays in use.
- **A policy's text** does not reload. `trust` stops the run when a file in
  a policy folder changes.

### What does not change

- No new CLI flags, environment variables, hook points or event fields.
- `kit.yaml` keys stay the same.
- `ARX_PLUGIN_SETTINGS` still holds all of a plugin's settings, including
  `instructions` and `model_settings`.

## Implementation steps

1. **`src/harness/fields.c`**: add the two rows to `kPluginFields`. This
   plan merges first in `kPluginFields` and in `Adopt` (step 4). The
   release order there is: plugin-yaml-keys, arx-plugin (`setup`),
   mcp-client (`mcp_servers`), long-lived-hooks (`run`), acp-tui (`ui`).
2. **`src/harness/harness.h`**: give `Layer` a `cJSON* instructions` field:
   the text node with absolute paths, or NULL. Give `Spec` these fields:
   - `cJSON* setting_from`: `{"model_settings.<path>": "<plugin>"}`.
   - `Buffer warnings`: for `arx check`.
   - `char* prompt_from`: the label of the base prompt.

   `SpecFree` and `LayersFree` free them.
3. **`src/harness/validate.c`**:
   - Add `kPluginTemplateVars`.
   - Add `ValidatePluginText(spec, node, where, err)`. It checks that the
     path stays in the folder, that the file is readable, and the template
     variables. `PluginValidate` calls it. `SpecValidate` calls it for each
     plugin layer too, so that it catches overrides from settings.
   - Make `PluginValidate` reject the fields that arx builds in
     `model_settings`.
   - Add `plugin_instructions` to `kTemplateVars`, for the spec only, and
     to the message at `validate.c:221-222`.
4. **`src/harness/plugins.c`**, in `Adopt`:
   - Extend the settings override to `model_settings`, which merges over,
     and to `instructions`, which a value replaces and `null` drops.
   - Detach `instructions` into `layer->instructions` with absolute paths,
     the way `Absolute` does for `agent`.
   - Walk the leaves of `model_settings` against `spec->setting_from` and
     `spec->root`. Record the source of each new leaf, and add a conflict
     warning where two plugins differ.
   - Then call `SpecMergeUnder` as today.
   - Leave a seam for `trust` step 5, which adds policy layers later. For a
     policy layer, `Adopt` skips the settings override and still detaches
     `instructions` into the layer. Only the other values merge over the
     spec, policies first-wins among themselves. `trust` writes that branch.
5. **`src/harness/spec.c`**: record `prompt_from` in `SpecLoad`. The base
   comes from `agent.yaml` when its line is a number, from `config.yaml`
   when it is a `file:line` string, else from the kit, `--set`, or the
   default.
6. **`src/harness/signature.c`**: hash the instruction files of each layer.
7. **`src/agent/agent.c`**:
   - Add `PluginText(a, policy)`: it renders the text of each plugin layer,
     or of each policy layer when `policy` is set, and joins them.
   - `SystemPrompt` puts the policy text before the base, and appends the
     plugin text, unless the base names `{{plugin_instructions}}`. Until
     `trust` lands, there is no policy text.
   - `AppendVar` renders `{{plugin_instructions}}`.
   - `PluginsText` adds the sentence that names the plugins with text.

   Export `PluginText` in `agent.h` only if `mcp-client` needs it.
8. **`src/harness/describe.c`**: print `instructions=` and
   `model_settings=`.
9. **`src/cli/check.c`**: print the `prompt:` and `model_settings:` lines.
   Print `spec->warnings` and the size warning with the other warnings.
10. **`commands/arx-plugin`**: read `instructions` and `model_settings` in
    `describe()`, and show the `prompt` and `settings` lines in `add`.
11. **`plugins/chatgpt/adapters/responses`**, with its README and
    `plugins/chatgpt/tests/test_chatgpt.py`: map `verbosity` to
    `text.verbosity`, and list the fields that it maps and drops in the
    README.
12. **`plugins/plugin-authoring/plugin.yaml`** (optional): add
    `instructions: "Before you add a tool, hook or observer to your harness,
    read the plugin-authoring skill."` and `arx: ">=0.2.0"`, so the
    marketplace has an example. This changes the prompt of the `coding` kit.
    Leave it out if that is not wanted.
13. **Docs**: change the pages in the next section, then remove the item
    from `docs/plugins/planned.md`.

Steps 1 to 4 must land together, because a plugin with the keys must load
and merge. Steps 5 to 10 do not depend on each other after that. Steps 11
and 12 can land at any time.

## Tests

**`tests/layers.sh`** (plugin loading, against `tests/fake-curl`):

- A plugin with `instructions: "Answer in French."` makes message 0 of
  `fake/req-01.json` the spec's prompt, a blank line, then the text.
- Two plugins in a `plugins:` list give their text in list order. The
  reversed list gives the reversed order.
- `{{plugin_instructions}}` in the spec's `instructions` puts the text at
  that place, one time.
- `{file: prompts/p.md}` resolves in the plugin folder. `{file: ../x.md}`
  and `{{harness}}` make `arx check --plugin` exit 2 with the message.
- `{{date}}` in a plugin's text renders.
- A plugin's `model_settings: {temperature: 0.1}` is in the request body.
  `temperature: 0.5` in `agent.yaml` wins over it, and
  `--set model_settings.temperature=0.9` wins over both.
- Plugin A sets `temperature: null` and plugin B sets `temperature: 0.7`.
  The body has no `temperature`.
- `model_settings: {model: x}` and `{stream: false}` make
  `arx check --plugin` exit 2.
- `arx check --plugin` prints `instructions=` with the byte count and
  `model_settings=` with the field names. Both are empty for a plugin
  without the keys.
- **Reload**: change a plugin's prompt file between turns. Message 0 of
  `req-02.json` has the new text, and the transcript has
  `{"_reset":true}`.
- A `before_model` hook that prints its input shows the plugin's field in
  `settings`.
- **Regression**: with no plugin text, message 0 is the same as before the
  change. Compare it to a stored copy.
- `arx plugin add ./PATH --yes` shows the `prompt` and `settings` lines.

**`tests/kits.sh`** (the active list, settings and warnings):

- The kit's `model_settings` win over a plugin's, and so do the settings
  of `config.yaml`.
- The kit's prompt comes first, then the plugin text.
- `- p: {instructions: null}` drops the text. `{instructions: "x"}`
  replaces it. `{instructions: {file: prompts/short.md}}` uses the other
  file. `{model_settings: {temperature: 0.3}}` changes the plugin's value.
- `{instructions: {file: missing.md}}` makes `arx check` exit 2.
- Two plugins with different `temperature` values give the exact warning
  line. The same value gives no warning. A spec value over a plugin's gives
  no warning, and the `model_settings:` line shows `(spec)`.
- The `prompt:` line reads `kit coding; plugins add ...`.
- A plugin with more than 4096 bytes of text gets the size warning.

**`tests/credentials.sh`** (adapters): run the `responses` adapter against
fake-curl with `verbosity` and `temperature` from a plugin. The body that
the adapter sends has `text.verbosity` and no `temperature`. Add a unit
test for `to_responses` in `plugins/chatgpt/tests/test_chatgpt.py`.

**With `trust`** (add these to its tests when its step 5 lands): a
policy's text comes before the base, even when the spec names
`{{plugin_instructions}}`. `{instructions: null}` in the active list does
not drop it. A policy's `temperature` wins over
`--set model_settings.temperature=...`, and the `model_settings:` line shows
`(policy NAME)`.

**`tests/plugins.sh`**: the marketplace check still passes. If step 12
lands, message 0 of a run with the `coding` kit holds the text of
`plugin-authoring`.

## Docs to change

Write each change to the rules in `docs/WRITING.md`: open with the
definition, name the default, give exact numbers, and use no em dashes.

- **`docs/plugins/reference.md`**:
  - Add both rows to the `plugin.yaml` table, and the keys to the example.
  - Add a bullet for each key under "arx uses the keys this way".
  - Take both keys out of "Not allowed", which keeps `model` and the other
    spec keys.
  - Add the `instructions=` and `model_settings=` lines to `arx check`, and
    the `prompt:` and `model_settings:` lines with the new warnings.
  - Update the `before_model` row in "Hook points".
- **`docs/plugins/prompt.md`** (new guide, "Prompt text and model
  settings"):
  - Open: "A plugin adds text to the system prompt with `instructions`, and
    fields to the model request with `model_settings`."
  - A "Use it when" table: `instructions` for short rules that must always
    be there, a skill for long guides that the agent reads when it needs
    them, and `session_start` `context` for facts that change with each
    session.
  - The order of the prompt, the ranks of the settings, overrides from
    settings, conflicts, and reload.
  - End with "Common mistakes" and "Related".
- **`docs/plugins.md`**: after the kinds table, one paragraph that links
  the new page. The table lists kinds of executables, so it gets no new
  row.
- **`docs/plugins/concepts.md`**: two rows in "Which part wins":
  - "Prompt text: every plugin's is added, in layer order, after the
    spec's prompt."
  - "Model settings: the spec wins, then the first plugin."
- **`docs/plugins/kits.md`**:
  - In "What it sets" and in **Settings**: settings can change
    `instructions` and `model_settings`, and plugins rank below
    `config.yaml`.
  - A "Common mistakes" row: "a kit's `temperature` hides a plugin's: that
    is the design; use settings for that plugin to change only its value."
- **`docs/spec.md`**:
  - The `instructions` and `model_settings` rows say that plugins add to
    them.
  - Add `{{plugin_instructions}}` to the Templates table.
  - "When templates render" covers plugin text and its files.
- **`docs/plugins/hooks.md:77`**: `settings` holds "`model_settings` from
  the spec, the kit, `config.yaml` and plugins, merged".
- **`docs/plugins/adapters.md`**:
  - Add a section, "Map model settings", with the drop rule and the table
    from this plan.
  - Add a "Common mistakes" row: "an adapter fails on a field it does not
    know; drop it and list it in the README."
- **`docs/plugins/skills.md`**: one sentence that sends short rules that
  must always be there to `instructions`.
- **`docs/plugins/planned.md`**: remove the table row and the section.
- **`plugins/chatgpt/README.md`**: the settings that `responses` maps and
  drops.
- **The docs site**: list `docs/plugins/prompt.md` in the site's
  navigation.

## Dependencies

No other 0.2.0 item blocks this one, and it blocks none. Several items use
it or share a contract with it:

- **`async-calls`** uses it. A scheduler plugin that returns
  `started as c7` can explain those results to the model with
  `instructions`, and set `parallel_tool_calls` with `model_settings`. Land
  this item first, or in the same PR series.
- **`sandboxes`** uses it. A sandbox plugin can tell the model what it
  cannot reach, with `instructions`.
- **`mcp-client`** shares the prompt assembly. MCP servers send their own
  `instructions` in the `initialize` result. If the client puts that text
  in the prompt, it adds the text through `PluginText(a, policy)` in `agent.c`, so
  that the order, `{{plugin_instructions}}` and the `prompt:` line in
  `arx check` cover it. Agree on the function's signature.
- **`trust`** shares two things:
  - The set of harness files: plugin prompt files join `SpecSignature`, so
    a `harness_edit` policy sees an edit to them.
  - The ranks, now settled: a policy's text comes first, before the base,
    and its settings take rank 0, above `--set`. Two details for the
    `trust` code. First, its "merge over the spec" must not apply to
    `instructions`, because that would replace the base prompt. Detach the
    text into the layer as for any plugin. Second, `JsonMergeOver` once for
    each policy, in flag order, makes the last policy win. Merge the
    policies first-wins among themselves, then over the spec.
  - Hooks: a `before_model` hook can still change `settings` for one call,
    the policy's fields included. `trust` decides whether that needs a
    guard.
- **Merge order in `fields.c` and `Adopt`**: this plan merges first, then
  `arx-plugin` (`setup`), `mcp-client` (`mcp_servers`), `long-lived-hooks`
  (`run`) and `acp-tui` (`ui`). Each one rebases on the one before it.
- **`sandboxes`** (and `trust`) own the settled rule for which tool wins:
  a policy tool, then a tool named in `replaces:`, then the first tool. One
  point is still open: `sandboxes.md` says the spec folder's own tool wins
  over a plugin that `replaces:` it, but the release plan's rule doesn't
  say. Settle that line before sandboxes step 5. This plan doesn't depend
  on it.
- **`arx-plugin`** shares the `key=value` lines of `arx check --plugin`
  (`instructions=`, `model_settings=`) and the summary of `arx plugin add`.
  If `index.yaml` describes what each plugin adds, it can use the same two
  names. `eject` needs nothing, because the prompt files are in the plugin
  folder.
- **`climb`**: message 0 of the transcript holds the whole prompt with the
  plugin text. A run with a pinned kit (`kit.lock`) pins that text. No
  shared code.
- **`acp-tui`, `plugin-state`, `long-lived-hooks`**: none.

## Size and risks

**Size: M.** About 300 to 400 lines of C in nine files (`fields.c`,
`harness.h`, `validate.c`, `plugins.c`, `spec.c`, `signature.c`,
`agent.c`, `describe.c`, `check.c`), plus `commands/arx-plugin`, a small
change to the adapter, tests and docs. It adds no subsystem, and the
settings merge is code that exists now.

Risks:

- **Prompt injection from installed plugins.** A user plugin is on in every
  harness, so its text reaches every agent, subagents included.
  Mitigations: `arx plugin add` shows the bytes it adds, and `arx check`
  shows the `prompt:` line. File paths stay inside the plugin folder. A kit
  or a `plugins:` list keeps a harness exact. This is not a new kind of
  risk, because a plugin can already run code. But text is easier to miss
  in a review.
- **Settings that are dropped without a word.** `responses` drops
  `temperature`, so a plugin that needs it has no effect on the ChatGPT
  route, and nothing says so. The adapter's README table is the only
  record.
- **Order surprises without an active list.** Then plugins load by name, so
  the name decides which plugin's `temperature` wins. The conflict warning
  shows this, but only in `arx check`.
- **Prompt cache.** Each change to plugin text replaces message 0 and
  breaks the provider's prompt cache. A spec prompt change does the same
  today. `{{turn}}` or `{{date}}` in plugin text make this happen at each
  reload, so the docs advise against them.
- **Older arx.** arx 0.1.0 skips a plugin with these keys as broken
  ("unknown key"). The docs tell authors to set `arx: ">=0.2.0"` so that the
  message is clear.
- **Who set which field.** The conflict check must not read plugin names
  out of `spec->lines` paths. The `setting_from` map makes the source
  explicit.

## Open decisions

The release plan ("Settled across plans", point 9) accepts each of these as
recommended unless you object.

1. **Does plugin text go into every prompt on its own, or only where the
   spec asks for it?** Recommendation: on its own. arx appends the text by
   default, and `{{plugin_instructions}}` sets the place. To leave it out,
   use active-list settings (`{instructions: null}`) or a kit. If the spec
   had to ask, every kit and spec would need an edit, and a plugin's text
   would do nothing in most harnesses.
2. **When two plugins set the same field, is that a warning or an error?**
   Recommendation: a warning in `arx check`, and the first plugin wins. This
   matches hook overlaps and hidden tools. An error would let one new
   plugin stop every harness.
3. **Does the first or the last plugin win a setting?** Recommendation: the
   first. The position in the list is the priority, as for tools,
   compactors, credentials and adapters. Hooks differ only because they
   form a chain.
4. **Which request fields can a plugin not set?** Recommendation: `model`,
   `messages`, `tools`, `stream` and `stream_options`, as an error in
   `plugin.yaml`. Leave the spec as it is now. A warning for the spec can
   come later.
5. **Which template variables can plugin text use?** Recommendation:
   `date`, `cwd`, `session`, `turn` and `file:PATH`. `harness`, `skills`
   and `prompt` belong to the spec's prompt, and in plugin text they would
   repeat it.
6. **Is there a size limit?** Recommendation: a warning above 4096 bytes
   for one plugin, and no hard cap. Long guides belong in skills.
7. **Do plugin text and settings reach subagents?** Recommendation: yes,
   by the same rule as plugin tools, with no special case. A follow-up, not
   part of this item, gives the `reviewer` plugin's subagent spec a
   `plugins:` list, so that its harness stays exact.
8. **Do adapters report the settings they drop?** Recommendation: not in
   0.2.0. The adapter contract stays the same, and each adapter lists its
   mapping in its README. If people miss settings that were dropped, add an
   optional report later.
9. **Does each plugin's text get a header in the prompt?** Recommendation:
   no. The plugin author writes the text the model reads. `{{harness}}`
   names the plugins that add text, so that the agent can find it.
10. **Can active-list settings change `instructions` and `model_settings`?**
    Recommendation: yes. It is the mechanism that changes `tools` and
    `hooks` today, and it is the only way to leave out one plugin's text
    and keep its tools.
11. **Does the feature get its own docs page?** Recommendation: yes, a
    short guide, `docs/plugins/prompt.md`. Then the reference keeps the
    exact rules, and the guide says when to use `instructions`, a skill or
    `session_start` context.
12. **Does `plugin-authoring` get `instructions` as the example
    (step 12)?** Recommendation: yes. It is the only shipped plugin whose
    text helps the model at once. It changes the prompt of the `coding`
    kit, so ship it as a separate commit that is easy to revert.
