# The arx marketplace

Each folder here is a plugin: a `plugin.yaml` and any of `tools/`, `hooks/`,
`skills/` and `commands/`. The arx release ships them next to its commands,
with the kits in [`../kits`](../kits); `arx setup` turns `shell` on, and
`arx kit add <kit>` adds a kit and its plugins. Install one with `arx plugin
add <name>`: arx gets it from this repo, at the tag of the arx you have, so
you get the version that CI tested with it.

| Plugin | What it adds |
|---|---|
| [shell](shell) | the `bash` and `edit` tools (`arx tool bash\|edit`) |
| [clock](clock) | a `now` tool: the date and time in UTC |
| [word-count](word-count) | a `word_count` tool, in Python |
| [guard](guard) | a `before_tool` hook that denies destructive shell commands |
| [git-context](git-context) | a `session_start` hook that adds `git status` |
| [fail-hint](fail-hint) | an `after_tool` hook that adds a hint when a tool fails |
| [notify](notify) | an observer that reports when a session ends |
| [keep-last](keep-last) | a `keep_last` compactor |
| [reviewer](reviewer) | a `reviewer` subagent |
| [background](background) | a scheduler that runs subagents and chosen tools in the background, and a `cancel_call` tool |
| [plugin-authoring](plugin-authoring) | a skill about changing your own harness, and one line in the prompt that points to it |
| [never-stop](never-stop) | a `stop` hook for experiment loops, turned on by its settings |
| [op-key](op-key) | a credential program that reads the API key from 1Password |
| [chatgpt](chatgpt) | Sign in with ChatGPT: a credential program, the `responses` adapter and `arx chatgpt` |

To work on one, link it from your checkout: `arx plugin add --link
./plugins/<name>`. `make test` checks each one against the arx of the same
commit.

**Writing a new one:** start with the
[plugin quickstart](../docs/plugins/quickstart.md), then read the page for
its kind in the [plugin guide](../docs/plugins.md). `arx plugin new <name>`
makes the folder. Before you open a pull request:

- `arx check --plugin plugins/<name>` passes;
- `plugin.yaml` has `name`, `version`, `description`, and `requires` for any
  program the plugin needs;
- [`tests/plugins.sh`](../tests/plugins.sh) lists it in the "every plugin
  loads" check, and runs it in the demo harness
  ([`examples/plugins/`](../examples/plugins), which loads every plugin here).
