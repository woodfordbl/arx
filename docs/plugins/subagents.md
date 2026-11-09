# Subagents

A subagent is a tool that runs arx again, one level deeper, with its own
spec.

Use a subagent to hand a self-contained task, such as a code review, to an
agent with its own prompt, tools and limits. The model gives it a task and
gets its final answer back as the tool result. The parent's history holds
only that answer, not the subagent's work.

**Status:** today. **Example:** [`plugins/reviewer`](../../plugins/reviewer).

## Contract

A subagent is an entry under `tools:` with an `agent:` key. It needs no
executable:

```yaml
tools:
  reviewer:
    agent: subagents/reviewer.yaml     # the subagent's spec
    description: Ask a reviewer to critique files. Give it the paths.
    timeout: 30m                       # default 30m
```

| Field | Meaning |
|---|---|
| `agent` | The subagent's spec. In `agent.yaml` the path is relative to the spec folder; in `plugin.yaml`, to the plugin folder. |
| `description` | What the model sees. The default says that the subagent starts with no context. |
| `timeout` | How long the whole subagent run may take. Default 30 minutes. |

### A call

- **Arguments**: the model calls the tool with `{"task": "..."}`. The task
  is the subagent's first message, and it has no other context.
- **How it runs**: arx runs itself as
  `arx -p - --spec <agent> --json --quiet --events fd:3`, with the task on
  stdin, the parent's `--cap` values, and `ARX_DEPTH` one higher.
- **Result**: the subagent's final answer. If a cap stopped it, the result
  starts with `[the subagent stopped at a cap]`. If it failed, the result
  starts with `[the subagent failed with exit N]` and includes its error
  output.
- **Session**: the subagent gets its own session folder. Its events also go
  into the parent's event stream, with `depth` one higher. Its plugins get
  their own `ARX_STATE_DIR` in that folder, and share `ARX_DATA_DIR` with
  the parent (see [Plugin state](concepts.md#plugin-state)).

### Its harness

A subagent builds its harness from its own spec, as any run does:

- its own spec folder: the `tools/`, `hooks/` and `plugins/` next to its
  spec, not the parent's;
- your config folder and your user plugins, unless its spec has a
  `plugins:` list;
- your defaults from `arx setup`, under its spec.

### Parallel calls and caps

- **In parallel**: a subagent tool has no [keys](tools.md#keys) (`[]`), so
  several subagent calls of one reply run at the same time. Their events
  stay whole lines in the parent's stream.
- **Depth**: `--cap depth=N` limits nesting. The default is 4.
- **Budget**: a subagent gets the same caps as the parent, not what is left
  of them.

> [!WARNING]
> Caps are not shared. Under `--cap usd=1`, each subagent can spend up to
> $1 of its own. Set lower `limits:` in each subagent's spec.

## Write a subagent

This plugin adds a `reviewer` subagent that reads files and reports
problems without changing anything.

1. Lay out the plugin folder:

   ```text
   reviewer/
     plugin.yaml
     subagents/reviewer.yaml
   ```

2. Declare the tool in `plugin.yaml`:

   ```yaml
   # plugin.yaml
   name: reviewer
   version: 0.1.0
   description: A reviewer subagent.
   tools:
     reviewer: {agent: subagents/reviewer.yaml, description: "Review files. Give it the paths."}
   ```

3. Write the subagent's spec. Turn off `edit`, and give it a lower turn
   limit than the parent:

   ```yaml
   # subagents/reviewer.yaml
   name: reviewer
   instructions: >-
     You review code. Read the files named in the task and reply with the three
     most important problems, most severe first. Do not change any files.
   tools:
     edit: {enabled: false}
   limits: {max_turns: 20}
   ```

   This spec has no `model:` or `endpoint:`, so it uses your defaults from
   `arx setup`.

4. Check both harnesses. `arx check` in the parent lists `reviewer` under
   `tools:`, and `arx check --spec subagents/reviewer.yaml` checks the
   subagent's own harness.

## Common mistakes

| Mistake | What happens | Fix |
|---|---|---|
| The subagent's spec is in the parent's spec folder | it shares the parent's `tools/`, `hooks/` and `plugins/`, so the parent's hooks also run in the subagent | put each subagent spec in its own folder, such as `subagents/` |
| The task leaves out context | the subagent starts with nothing but the task | say in `description` that the model must give the complete task |
| The `agent:` path is wrong | `tools.x: subagent spec ... not found`, and there is no tool | `agent:` is relative to the folder of the spec or `plugin.yaml` that names it |
| You expect the parent's budget to be shared | each subagent gets the full caps again | set lower `limits:` in the subagent's spec |
| The subagent comes from a user plugin | it loads your user plugins too, so it has its own subagent tool and can call itself, up to the depth cap | add a `plugins:` list to its spec, such as `plugins: [shell]` |
| The subagent can edit files you did not plan | it gets `bash` and `edit` from your `shell` plugin | turn `edit` off in its spec with `tools: {edit: {enabled: false}}` |

## Planned

**Planned:** calls that do not block. A scheduler will return
`started as c7` at once and send the real result later, so the parent goes
on working while a subagent runs. See
[Planned changes](planned.md#calls-that-do-not-block).

## Related

- [Tools](tools.md): keys, timeouts and the other tool options a subagent
  shares.
- [Command line](../cli.md#caps): the caps a subagent inherits from the
  parent.
- [Plugin concepts](concepts.md#active-list): limit which plugins a
  subagent loads with a `plugins:` list.
- [Hooks](hooks.md): guard what a subagent does, from its own spec folder.
