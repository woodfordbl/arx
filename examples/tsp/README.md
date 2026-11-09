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

## Run it with `arx climb`

In the run above the agent runs its own scorer, the same way autoresearch
works. It is told not to edit `eval/`, but nothing stops it. With
[`arx climb`](../../docs/climb.md), arx scores every change itself, with its
own copy of `eval/`, and keeps or reverts it:

```sh
cp -r examples/tsp /tmp/tsp-climb && cd /tmp/tsp-climb
rm harness/hooks/stop                # it would keep every round going
printf 'results.tsv\nnotes.md\nrun.log\n.arx/\n' > .gitignore
git init -q && git add -A && git commit -qm baseline
/path/to/arx climb --dry-run --set model=<model id>   # score the baseline
/path/to/arx climb --set model=<model id>             # rounds until the budget
```

`climb.yaml` sets the budget and what is scored, and points the agent at
`harness/prompts/climb.md`: one change per round, with no scorer step and no
keep or revert step. climb adds:

- **A scorer out of reach**: each run uses a fresh export with `eval/` from
  the starting commit, and climb undoes the agent's edits to `eval/`.
- **A branch of scored commits**: `climb/RUN` holds only kept changes, and
  `.arx/climb/last/results.tsv` holds every round.
- **A holdout the agent never sees**: `python3 eval/score --holdout` on the
  starting version and the final best, in `summary.json`.

Until climb can end a round itself (planned), delete `harness/hooks/stop`
first, as above.
