# Skills

A skill is a Markdown file of instructions that the agent reads when it needs
them. arx lists each skill's name and description in the prompt, and the
agent reads the full file only for the task at hand. A skill has no code.

**Status:** today. **Example:**
[`plugins/plugin-authoring`](../../plugins/plugin-authoring).

## Contract

- **The file:** `<skills folder>/<name>/SKILL.md`.
- **The skills folder:** in the spec folder, the folder that `skills:` in the
  spec names. In a plugin and in your config folder, it is `skills/`.
- **Front matter:** the file starts with `name` and `description`, each on one
  line:

  ```markdown
  ---
  name: plugin-authoring
  description: How to add a tool, hook or observer to your own harness.
  ---
  ```

  Without a `name`, arx uses the folder name.
- **The index:** `{{skills}}` in a prompt (`instructions:` or
  `first_message:`) becomes one line per skill:
  `- name: description (path)`. With no skills, it is `(no skills yet)`.
- **Layers:** `{{skills}}` lists the skills of every layer. When two layers
  have a skill folder with the same name, the first one wins.
- **Reload:** a new or changed `SKILL.md` is picked up before the next model
  call.

## Minimal example

```
my-plugin/
  plugin.yaml
  skills/
    release/
      SKILL.md
```

```markdown
---
name: release
description: How to tag and publish a release of this project.
---

1. Run `make test`. Stop if anything fails.
2. Update `CHANGELOG.md` with the changes since the last tag.
3. Tag the commit: `git tag vX.Y.Z && git push --tags`.
```

The spec must use `{{skills}}` somewhere, so the agent learns that skills
exist:

```yaml
instructions: |
  You are a careful engineer.
  Skills (read the file when one applies):
  {{skills}}
```

## Common mistakes

| Mistake | What happens | Fix |
|---|---|---|
| The prompt has no `{{skills}}` | the agent never learns about the skills | add `{{skills}}` to `instructions:` |
| `skills:` is not set in the spec | the spec folder has no skills folder; plugin skills still load | set `skills: skills` |
| The file is `skill.md` or sits directly in `skills/` | arx does not find it | use `skills/<name>/SKILL.md` |
| The description is long or vague | the agent cannot tell when to read the skill | one line: what it covers and when to use it |
| The front matter spans more lines, such as a YAML block | arx reads only `name:` and `description:` lines | keep each on one line |

## Planned

No change is planned for skills.
