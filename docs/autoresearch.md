# Self-improving runs

arx was built for autoresearch-style hill climbing: an agent works on one task
for hours without supervision. It tries an idea, measures it, keeps it if the
score got better, and tries the next one. Along the way it also improves its
own harness: it writes tools that make its loop faster, hooks that catch its
mistakes, and skills that record what it learned.

This page explains how to set up such a run. The complete example is
[`examples/tsp`](../examples/tsp), an agent that makes a travelling-salesman
solver faster and better on a CPU.

## The shape of a run

```
 ┌───────────┐   edit    ┌──────────┐   score   ┌──────────────┐
 │  harness  │──────────▶│   work   │──────────▶│  eval/score  │
 │ (agent's  │           │ solve.py │           └──────┬───────┘
 │  tools,   │◀──┐       └──────────┘                  │
 │  prompts) │   │                                     ▼
 └───────────┘   │                         keep (git commit) or
       ▲         │                         revert (git reset)
       │         │                                     │
       │   improve the harness              results.tsv, notes.md
       │         │                                     │
       └─────────┴──────── next experiment ◀───────────┘
```

A good setup has four parts:

1. **A score.** One command that prints one number. In the TSP example,
   `python3 eval/score` prints the mean tour length; lower is better.
2. **A loop in the prompt.** The system prompt tells the agent to pick an idea,
   commit it, score it, log it, and keep or revert it.
3. **Memory in files.** `results.tsv` and `notes.md` hold what was tried and
   what was learned. The context can be cleared at any time without losing
   anything.
4. **A harness the agent may change.** `{{harness}}` in the prompt tells the
   agent where its tools, hooks and skills live.

## Never stop: the stop hook

A model ends its turn when it thinks it is done. For an open-ended climb, a
`stop` hook sends it straight into the next experiment:

```sh
#!/bin/sh
# hooks/stop
echo '{"decision":"continue","message":"Next experiment. Log it in results.tsv and keep notes.md current."}'
```

The run then ends only at a cap (`--cap usd=5`, `--cap wall=2h`), at
`arx ctl last stop`, or when you press Ctrl-C.

## Memory in files: restart compaction

With `compaction: {strategy: restart}`, arx clears the context when it fills,
and starts again from the system prompt and the first message. The first
message pulls the memory back in:

```markdown
{{file:program.md}}

Results so far (results.tsv, last 20 lines):
{{file:results.tsv:tail=20}}

Your notes (notes.md):
{{file:notes.md:max=8kb}}

Your skills:
{{skills}}
```

Every restart is a fresh, short context with the current state, instead of a
long one that degrades. This is the "Ralph loop" pattern.

## Letting the agent improve itself

Ask for it in the prompt. The TSP example says:

> Make yourself faster and better as you go. For example, write a tool that
> runs steps 2 to 5 in one call, a skill that records what you learned about
> the problem, or a hook that checks a tour before a full run.

Things an agent can build for itself:

- **A tool that runs one whole experiment**: commit, score, log, keep or
  revert, in one call. This cuts four or five turns per experiment to one.
- **A quick eval tool** on a smaller input, to reject bad ideas in seconds.
- **An `after_tool` hook** that adds the current best score to every result.
- **A skill** that records the approaches that worked and the ones that did
  not, so they survive restarts.
- **Spec edits**: a longer tool timeout, a different temperature, a smaller
  compaction trigger.

Each change is live on the next turn. A broken change is rejected or
reported, and the run goes on.

## Running it

```sh
cp -r examples/tsp /tmp/tsp && cd /tmp/tsp
printf 'results.tsv\nnotes.md\nrun.log\n.arx/\n' > .gitignore
git init -q && git add -A && git commit -qm baseline

arx --spec harness/agent.yaml --set model=<model id> \
  -p "Start the experiment loop." --cap usd=5 --cap wall=2h
```

The example's spec uses OpenRouter, so it needs `OPENROUTER_API_KEY` in the
environment, or saved by `arx setup --provider openrouter`. To use your own
defaults instead, delete its `model` and `endpoint` lines. To start a harness of your own
instead, `arx init autoresearch` writes the same pieces into the current
folder: a program, an experiment-loop prompt, a never-stop hook and restart
compaction.

From another terminal:

```sh
arx watch
arx ctl last note "try Or-opt next"
```

Afterwards:

- `results.tsv` has every experiment and its score.
- `git log` has the solver changes that were kept.
- `harness/` has what the agent built for itself.
- `python3 eval/score --holdout` checks the result on instances the agent was
  not scored on.

## Checklist

| | |
|---|---|
| **Caps** | Always set `--cap usd` or `--cap wall`. The agent can raise `limits.max_turns`, but not a cap. |
| **Git** | Run in its own repository, so every kept change is a commit and a revert is cheap. |
| **Holdout** | Keep instances the agent never sees, and check the final result on them. |
| **Isolation** | Tools run as your user. Use a container or VM for anything you would not run yourself. |
| **Trust** | The agent runs its own scorer, so it could edit it. Keep the official score outside its reach (a planned `arx climb` driver will do this). |
| **Plugins** | Name the plugins a run may use, e.g. `plugins: [guard]`, or `plugins: []` for none, so a plugin you install later cannot change the run. |
| **Observe** | `arx watch`, or an observer that posts to a channel, so you can see a run go wrong early. |
