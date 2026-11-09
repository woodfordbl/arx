# arx climb

`arx climb` runs an agent in rounds, scores each change with your evaluation
outside the agent's loop, and keeps or reverts the change itself. The agent
never runs the scorer that counts, never reports its own score, and never
decides what is kept.

Use it for a [self-improving run](autoresearch.md) when you don't want to
trust the agent with its own score.

## When to use it

Use `arx climb` when both hold:

- **One command scores the task.** It prints one number as its last line,
  such as `score: 5.41`.
- **You don't want to trust the agent's own scorer.** In a plain
  self-improving run the agent commits, scores and keeps its own changes, so
  it could edit the scorer or keep a change by mistake.

A plain run is faster to set up and the agent never waits for a score. A
climb trades that for a score the agent can't change: the agent waits while
climb evaluates each round.

## Set up a climb

You need a git repository with the work to improve and a scorer, arx set up
with a model (`arx setup`), and `jq` and git 2.23 or later on `PATH`. climb
runs in the repository's top folder and keeps its files in `.arx/climb/`,
which must be in `.gitignore`. `arx init` adds `.arx/` there.

1. Add the climber kit, the agent's side of a climb:

   ```sh
   arx kit add climber
   ```

2. In the project's top folder, write the harness and a `climb.yaml`:

   ```sh
   arx init climber      # agent.yaml, program.md, prompts/, climb.yaml
   ```

3. Describe the task in `program.md`. In `climb.yaml`, set the paths that
   are scored (`change`), the scorer (`eval`) and a budget. See
   [`climb.yaml`](#climbyaml).
4. Commit, so the change paths and the scorer are clean:

   ```sh
   git add -A && git commit -m "Set up a climb"
   ```

5. Check the scorer. A dry run scores the starting version at least 3 times
   and stops without starting the agent:

   ```sh
   arx climb --dry-run
   ```

   ```text
   round   0  baseline    28.7666  3 runs, spread 0.0000
   ```

6. Start the climb. It runs until a budget or a stop condition ends it:

   ```sh
   arx climb
   ```

climb prints one line per round on stderr, and the session id once the
first round starts. Follow the agent itself with `arx watch SESSION` from
another terminal.

```text
round   1  keep        27.3062  best 27.3062    -5.1%    9 turns  $0.03  2-opt
round   2  revert      27.4410  best 27.3062            12 turns  $0.04  Or-opt
round   3  crash             -  best 27.3062             7 turns  $0.02  grid NN (exit 1)
```

To run the TSP example this way, see
[Let arx climb keep the score](autoresearch.md#let-arx-climb-keep-the-score).

## What a change is

A change is the content of the change paths (`change:`, such as `[work/]`)
in the working tree when a round ends. climb commits it itself:

- **Not the agent's commit.** The agent may commit anything or forget to.
  climb takes the working tree, so neither matters.
- **Edits outside the change paths are carried, never scored.** The agent's
  new tools, prompt edits and notes stay in the tree. climb never reverts
  or commits them, and lists them as `outside` in each round's record.
- **A harness climb is the same mechanism.** To score a harness, put its
  paths in `change` and make `eval.command` run `"$ARX_BIN"` on a
  benchmark.

The agent works on the branch `climb/RUN`, which climb creates at `HEAD` and
checks out. At each round's end climb quits any merge, rebase or
cherry-pick in progress, puts `HEAD` back on the branch at the best commit,
and folds the agent's own commits back into the working tree. Nothing in the
tree is lost. Then:

- **Keep**: the branch moves to the candidate.
- **Revert**: climb restores the change paths from the best commit and
  removes files the change added.

So the branch holds only kept commits, each one scored. Every candidate
stays reachable at `refs/climb/RUN/rN` until `arx climb rm RUN`.

## How the scorer stays out of reach

climb runs the evaluation itself, from files the agent's tree does not
define:

- **Pinned eval files.** At the start climb resolves `eval.ref` (default
  `HEAD`) to one commit. `eval.files`, such as `[eval/]`, always come from
  it. Without `eval.files`, the scorer comes from the candidate commit, in
  which only the change paths come from the agent.
- **A fresh export for every run.** Each run is a new folder outside the
  project: `git archive` of the candidate, then `eval.files` from the pinned
  commit on top. climb runs `eval.command` there with `sh -c`, in its own
  process group, and deletes the folder after. The output stays in `logs/`.
- **Tamper repair.** At each round's end, climb puts `eval.files` in the
  tree back to the pinned version and tells the agent its edits were undone.
- **climb reads only its own numbers.** It never reads `final_output` or a
  results file the agent writes. The agent may run the scorer itself to
  check a change, and those runs don't count.
- **Holdout scores never reach the agent.** They go to `holdout.jsonl` and
  the summary, never into a round message or `results.tsv`.

> [!WARNING]
> Without a sandbox, the agent's tools run as you, and so does the code it
> writes when the scorer runs it. Either can rewrite `.git`, `.arx/climb/`
> or anything else you can. climb stops mistakes and casual reward hacking,
> not a determined agent with a shell. Run a climb you would not run
> yourself in a container or VM.

climb records the level it ran at as `isolation`, and warns at the start
when it is not `full`:

| `isolation` | The agent's tools | The candidate's code at eval time | Status |
|---|---|---|---|
| `none` | run as you | run as you | today; climb warns at start |
| `agent` | in a sandbox: `.git`, `eval.files`, `climb.yaml` and `.arx/climb/` read-only | run as you | **Planned**, with sandboxes |
| `full` | in a sandbox | in a sandbox, or on another host | **Planned**, with sandboxes |

At `none`, climb still stops an agent that edits the scorer in its tree,
that reports a false score, or that keeps a change its own scorer liked by
mistake.

## The keep rule and noise

Each candidate gets `eval.repeats` runs. The score of a run is the number on
the last stdout line that matches `eval.pattern`, by default
`^score:[[:space:]]*([-+0-9.eE]+)[[:space:]]*$`. A run is a crash when the
command exits non-zero, runs past `eval.timeout`, prints no matching line,
or prints a value that is not finite. One crashed run makes the candidate a
crash, and climb skips its other runs.

climb keeps the best commit's runs (the last 20) and decides on medians:

```text
b = median(best's runs), c = median(candidate's runs)
d = eval.min_delta, or |b| * pct / 100 when it ends in %
better = (goal == min) ? c < b - d : c > b + d       a tie reverts
if better and eval.confirm > 0: run confirm more times, decide again
keep if better; the candidate's runs become the best's
```

Four settings handle a noisy scorer:

- **The baseline measures noise.** The starting version runs at least 3
  times. When those runs spread by more than `d`, climb warns: "the score
  varies by 0.0310 between runs of the same commit".
- **`eval.confirm` is cheap.** Most candidates lose on their first runs, so
  the extra runs go only to a candidate that looks better.
- **`eval.rescore` limits the winner's curse.** Every N rounds climb scores
  the best again and adds the runs to its list, so a best that won on a
  lucky run cannot block every later change.
- **`eval.compare` replaces the rule.** climb runs the program in an export
  of the candidate, with one JSON object on stdin. It prints `keep`,
  `revert`, or `more` (at stage `first` only: climb runs the confirm runs,
  then asks again at stage `final`). A failed or unknown answer reverts,
  with a warning.

  ```json
  {"goal": "min", "min_delta": 0.005, "stage": "first",
   "best": [5.41, 5.43, 5.40], "candidate": [5.38]}
  ```

For a deterministic scorer, keep the defaults: one run, no confirm runs and
no margin.

## Budgets and stop conditions

A climb runs alone, so it does not start without a budget: `budget.usd`,
`budget.tokens` or `budget.wall`, in `climb.yaml` or as a `--cap` flag.

| Limit | Key or flag | Counts | How climb enforces it |
|---|---|---|---|
| Spend | `budget.usd`, `--cap usd=N` | the agent's cost, across rounds | each round gets `--cap usd` for what is left |
| Tokens | `budget.tokens`, `--cap tokens=N` | input and output tokens | each round gets `--cap tokens` for what is left |
| Time | `budget.wall`, `--cap wall=D` | time since `arx climb` started, evaluations included | each round gets `--cap wall` for the time left, less what the baseline's evaluation took |
| Rounds | `budget.rounds`, `--rounds N` | rounds started | climb's counter |
| Patience | `budget.patience`, `--patience N` | rounds in a row without a keep | climb's counter |
| Target | `budget.target`, `--target X` | the best score | stops once the best reaches it |
| Round turns | `round.turns`, `--round turns=N` | turns in one round (default 40) | `--cap turns` and `--set limits.max_turns` |
| Round time | `round.wall`, `--round wall=D` | one round's time (default 30m) | `--cap wall` |

Cost and tokens include sessions that start during a round, such as
subagents. climb checks the time before each round and each evaluation. When
the time runs out before an evaluation, the round is an `abort` and its
change is reverted.

How each way a round ends is handled:

| arx exits | climb |
|---|---|
| `0` done | evaluates, and goes on |
| `3` cap | evaluates; stops after it when the budget is spent, else goes on |
| `1` error | evaluates what is in the change paths; stops after 3 errors in a row |
| `2`, `4` or `130` | restores the change paths and stops with the same code |

`arx climb` exits with the code of its stop reason:

| Code | `stop` in the summary |
|---|---|
| `0` | `rounds`, `patience`, `target`, `stopped`, `dry-run` |
| `1` | `error`: three arx errors in a row, a baseline that crashes, or a git step that fails |
| `2` | `usage`: a bad `climb.yaml`, not at the top of a git repository, dirty change paths, no budget, another climb running here |
| `3` | `cap:usd`, `cap:tokens`, `cap:wall` |
| `4` | `auth` |
| `130` | `interrupted` |

Ctrl-C reaches arx and climb together. climb restores the change paths,
writes the summary and exits 130.

## The round message

climb sends each round its result as the next message. The first round puts
`task` above it, and every message starts with `[arx climb]`:

```text
[arx climb] Round 7 of 100: your change to work/ was reverted.
Score 5.4710 (3 runs: 5.4710 5.4688 5.4801). Best 5.4100 (round 5).
work/ is back at the best version.
To be kept, a change must beat the best by more than 0.0054 (0.1%); lower is better.
Edits outside work/ are kept but not scored: harness/tools/run_exp.
Budget left: $3.21, 5h12m, 93 rounds.
Make the next change to work/, then end your turn without a tool call.
```

After a crash the agent sees why and the last `eval.show` lines of the
output. When it edited `eval.files`, it reads that the edits were undone.

## Results

A run keeps its files in `.arx/climb/RUN/`, and `.arx/climb/last` links the
newest:

| File | Holds |
|---|---|
| `climb.json` | the config as resolved, the pinned eval commit and its tree ids, the base, branch, session and isolation |
| `results.jsonl` | one line per evaluation: the baseline, each round, each rescore |
| `results.tsv` | `round status score best delta commit turns cost note`, for people and the agent's prompt |
| `holdout.jsonl` | the holdout runs |
| `summary.json` | the state so far, rewritten after every round |
| `logs/` | the output of each run (`R-K.log`, the last 1 MB) and of arx when it printed errors |

One `results.jsonl` line (`v` is the format version):

```json
{"v": 1, "run": "20261109-1530", "round": 7, "t": "2026-11-09T15:42:10Z",
 "status": "revert", "commit": "3f2a9c1", "best_commit": "9b1e004",
 "scores": [5.471, 5.4688, 5.4801], "score": 5.471, "best": 5.41,
 "delta": 0.061, "eval_secs": 31.2,
 "agent": {"session": "20261109-153001-a1b2", "exit": 0, "status": "done",
           "turns": 9, "tokens": 45678, "cost": 0.031},
 "files": ["work/solve.py"], "outside": ["harness/tools/run_exp"],
 "tamper": [], "note": "Or-opt moves on the 20 nearest neighbours",
 "error": null}
```

`status` is `baseline`, `rescore`, `keep`, `revert`, `crash`, `empty` or
`abort`. `note` is the first line of the agent's reply, cut to 120
characters: a label, never trusted. `error` says why a round crashed or
aborted.

`arx climb --json` prints `summary.json` when the climb ends:

```json
{"v": 1, "run": "20261109-1530", "status": "done", "stop": "patience",
 "exit": 0, "rounds": 100, "kept": 12, "reverted": 80, "crashed": 6,
 "empty": 2, "aborted": 0, "baseline": 6.2013, "best": 5.3101,
 "best_commit": "c41d2e7", "best_round": 61,
 "holdout": {"baseline": 6.2507, "best": 5.4012},
 "branch": "climb/20261109-1530", "session": "20261109-153001-a1b2",
 "cost": 3.21, "tokens": 1234567, "secs": 28812, "isolation": "none"}
```

## Resume, stop and clean up

```sh
arx climb status                  # the last run: rounds, best, spend
arx climb stop                    # stop after the current round
arx climb --resume last --cap usd=2   # two more dollars, same session
arx climb rm 20261109-1530        # the branch, its candidates and folder
```

- **`arx climb stop [RUN|last]`** asks the agent to end its current turn.
  climb scores that round, then stops with exit 0.
- **`--resume RUN|last`** scores the best commit again as a new baseline, so
  no number in a file the agent could reach decides anything, and continues
  the same session. Budget flags count from the resume. `--new-session`
  starts a fresh one.
- **`arx climb rm RUN [--yes]`** deletes `refs/climb/RUN/*`, the branch and
  the run folder, after asking. Check out another branch first.

## `climb.yaml`

`climb.yaml` is the driver's file, not the agent's. climb reads it once, at
the start, and freezes it in `climb.json`, so an edit during a climb changes
nothing. `arx check --climb climb.yaml` checks it and prints it as JSON.

```yaml
# climb.yaml
task: Lower the score from eval/score. See program.md.
agent:
  spec: harness/agent.yaml
change: [work/]
eval:
  command: python3 eval/score
  files: [eval/]
  goal: min
  timeout: 5m
  confirm: 2
  min_delta: 0.1%
holdout: {command: python3 eval/score --holdout}
budget: {usd: 5, wall: 8h, patience: 25}
```

| Key | Type | Default | Description |
|---|---|---|---|
| `task` | text | "Make one change to CHANGE that improves the score, then end your turn." | The first round's message, above the result. A string or `{file: path}`. |
| `agent.spec` | string | `./agent.yaml`, else your defaults | `--spec` for every round. |
| `agent.kit` | string | | `--kit` for every round. |
| `agent.set` | map | | `--set KEY=VALUE` for every round. |
| `change` | string list | **required** | The change paths. |
| `eval.command` | string | **required** | The scorer, run with `sh -c` in the export. |
| `eval.files` | string list | `[]` | Paths taken from `eval.ref` for every run, and repaired in the tree. |
| `eval.ref` | string | `HEAD` | The commit the eval files come from, resolved once. |
| `eval.goal` | string | `min` | `min` or `max`. |
| `eval.pattern` | string | `^score:[[:space:]]*([-+0-9.eE]+)[[:space:]]*$` | An extended regular expression; its first group is the score. |
| `eval.timeout` | duration | `10m` | The longest one run may take; climb then stops its process group. |
| `eval.repeats` | integer | `1` | Runs for every candidate. |
| `eval.confirm` | integer | `0` | More runs for a candidate that looks better. |
| `eval.min_delta` | number or percent | `0` | How much better a candidate must be, such as `0.01` or `0.1%`. |
| `eval.rescore` | integer | `0` | Score the best again every N rounds; `0` never. |
| `eval.compare` | string | | A program that decides in place of the rule. |
| `eval.show` | integer | `20` | Output lines the agent sees after a crash. |
| `holdout.command` | string | | A second scorer whose results the agent never sees. |
| `holdout.when` | string | `end` | `end` (the baseline and the final best) or `keep` (every keep too). |
| `budget.usd`, `budget.tokens`, `budget.wall` | number, integer, duration | | At least one is required. |
| `budget.rounds`, `budget.patience` | integer | | |
| `budget.target` | number | | |
| `round.turns` | integer | `40` | |
| `round.wall` | duration | `30m` | |

**Planned:** `agent.sandbox` and `eval.sandbox`, with sandboxes.

The eval command gets these variables, and climb's environment without the
`ARX_SESSION*` variables:

| Variable | Value |
|---|---|
| `ARX_CLIMB_RUN` | the run name |
| `ARX_CLIMB_ROUND` | the round, `0` for the first baseline |
| `ARX_CLIMB_KIND` | `baseline`, `candidate`, `rescore` or `holdout` |
| `ARX_CLIMB_REPEAT` | which run of this candidate, from `1` |
| `ARX_CLIMB_COMMIT` | the commit being scored |
| `ARX_BIN` | the arx binary, for a harness climb that runs arx |

## Common mistakes

| Mistake | What happens | Fix |
|---|---|---|
| The spec has a never-stop hook | a round never ends on its own, so each one runs to its turn cap; climb warns at start | use the climber kit, `disable: [never-stop]`, or delete `hooks/stop` |
| The scorer prints its score before it checks the result | a broken candidate gets a score | check first, and print `score:` last; print `score: inf` or exit non-zero on failure |
| Holdout data is in the agent's tree | the agent can read it and tune on it | keep it outside the project and name it by an absolute path in `holdout.command` |
| The work needs an edit outside the change paths | the edit is never committed, so the export lacks it and the candidate crashes | widen `change` to the paths the work needs |
| Large data files in the change paths | every candidate commit stores them | keep data outside the change paths; `arx climb rm` frees old candidates |

## Related

- [Self-improving runs](autoresearch.md): the agent-scored loop, and the TSP
  example under `arx climb`.
- [Drivers](plugins/drivers.md): the contract climb is built on.
- [Kits](plugins/kits.md): the climber kit and how kits choose plugins.
- [Command line](cli.md#climbing-a-score): every flag and exit code.
