# Skills

A skill is a Markdown file of instructions that the agent reads when it needs
them.

arx lists each skill's name and description in the prompt, and the agent
reads the full file only for the task at hand. Write one for know-how the
agent needs only some of the time: a release process, a project's
conventions, how to use an internal service. A skill has no code. If the
agent needs to act rather than read, write a [tool](tools.md). For a short
rule that must be in every prompt, use a plugin's
[`instructions`](prompt.md) instead.

**Status:** today. **Example:**
[`plugins/plugin-authoring`](../../plugins/plugin-authoring).

## Contract

### How arx finds skills

- **The file**: `<skills folder>/<name>/SKILL.md`.
- **The skills folder**: in the spec folder, the folder that `skills:` in the
  spec names. In a plugin and in your config folder, it is `skills/`.
- **Front matter**: the file starts with `name` and `description`, each on
  one line:

  ```markdown
  ---
  name: plugin-authoring
  description: How to add a tool, hook or observer to your own harness.
  ---
  ```

  Without a `name`, arx uses the folder name.
- **Layers**: arx lists the skills of every [layer](concepts.md#layer). When
  two layers have a skill folder with the same name, the first one wins.
- **Reload**: arx picks up a new or changed `SKILL.md` before the next model
  call.

### Put the index in the prompt

`{{skills}}` in a prompt (`instructions:` or `first_message:`) becomes one
line per skill, in the form `- name: description (path)`. With no skills, it
becomes `(no skills yet)`.

> [!NOTE]
> Only `{{skills}}` lists your skills in the prompt. Without it, the agent
> never learns which skills exist.

## Write a skill

A skill in a plugin sits in its own folder under `skills/`:

```text
my-plugin/
  plugin.yaml
  skills/
    release/
      SKILL.md
```

`skills/release/SKILL.md` holds the front matter, then the steps:

```markdown
---
name: release
description: How to tag and publish a release of this project.
---

1. Run `make test`. Stop if anything fails.
2. Update `CHANGELOG.md` with the changes since the last tag.
3. Tag the commit: `git tag vX.Y.Z && git push --tags`.
```

Then use `{{skills}}` somewhere in the spec's prompt, so the agent learns
that skills exist:

```yaml
# agent.yaml
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

## Related

- [Tools](tools.md): give the agent an action instead of instructions.
- [Plugin concepts](concepts.md#layer): the layers arx reads skills from,
  and their order.
- [agent.yaml reference](../spec.md#templates): `{{skills}}` and the other
  prompt templates.
