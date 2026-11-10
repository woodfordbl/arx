# Example policy folders

A policy folder is a plugin folder that loads before the spec folder and
that the agent cannot remove. Name one when you start a run:

```sh
arx --policy examples/policies/prompts-only -p "improve your prompt"
```

| Folder | What it does |
|---|---|
| `prompts-only/` | Its `harness_edit` hook accepts edits to prompt files and skills, and rejects every other harness edit. It needs `jq`. |

These folders are in `examples/`, not `plugins/`, because every installed
plugin is on by default, and a policy only makes sense with `--policy`.

A policy without a sandbox stops mistakes, not a hostile agent. The agent's
`bash` can still write any file arx reads. See
[Policies](../../docs/plugins/policies.md).
