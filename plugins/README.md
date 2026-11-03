# The arx marketplace

Each folder here is a plugin: a `plugin.yaml` and any of `tools/`, `hooks/`,
`skills/` and `commands/`. The arx release does not include them. Install
one with `arx plugin add <name>`: arx gets it from this repo, at the tag of
the arx you have, so you get the version that CI tested with it.

| Plugin | What it adds |
|---|---|
| [clock](clock) | a `now` tool: the date and time in UTC |
| [word-count](word-count) | a `word_count` tool, in Python |
| [guard](guard) | a `before_tool` hook that denies destructive shell commands |
| [git-context](git-context) | a `session_start` hook that adds `git status` |
| [fail-hint](fail-hint) | an `after_tool` hook that adds a hint when a tool fails |
| [notify](notify) | an observer that reports when a session ends |
| [keep-last](keep-last) | a `keep_last` compactor |
| [reviewer](reviewer) | a `reviewer` subagent |
| [plugin-authoring](plugin-authoring) | a skill about changing your own harness |

To work on one, link it from your checkout: `arx plugin add --link
./plugins/<name>`. `make test` checks each one against the arx of the same
commit. Start a new one with `arx plugin new <name>`. The full guide is
[docs/plugins.md](../docs/plugins.md).
