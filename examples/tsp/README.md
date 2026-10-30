# Example: a self-improving TSP solver

This is an autoresearch-style task that runs on a CPU. The agent improves
`work/solve.py` against `eval/score`. Along the way it can change its own
harness in `harness/`: the spec, prompts, tools, hooks and skills.

## Run it

```sh
cp -r examples/tsp /tmp/tsp && cd /tmp/tsp     # it needs its own git repo
printf 'results.tsv\nnotes.md\nrun.log\n.arx/\n' > .gitignore
git init -q && git add -A && git commit -qm baseline
python3 eval/score                              # the baseline score

export OPENROUTER_API_KEY=...
/path/to/arx --spec harness/agent.yaml --set model=<model id> \
  -p "Start the experiment loop." --cap usd=5 --cap wall=2h
```

From another terminal:

```sh
/path/to/arx watch                    # follow the run live
/path/to/arx ctl last note "try Or-opt next"
/path/to/arx ctl last stop
```

## What to look at afterwards

- `results.tsv` shows every experiment and its score.
- `git log` shows the solver changes that were kept.
- `harness/` shows what the agent built for itself: new `tools/`, `hooks/`,
  `skills/`, and edits to `agent.yaml` and its prompts.
- `python3 eval/score --holdout` checks the result on instances the agent was
  not scored on.

## Trust

In this example the agent runs its own scorer, the same way autoresearch
works. It is told not to edit `eval/`, but nothing stops it. A driver that
runs the official scoring outside the agent's reach is planned for a later
phase.
