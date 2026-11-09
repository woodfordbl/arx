# Plan: `arx climb` (roadmap item 7)

Slug: `climb`. Target: arx 0.2.0. Status: plan only, no code changed.

## Goal

`arx climb` runs a self-improving agent in rounds. After each round, climb
takes the agent's change, scores it with an official evaluation that the
agent does not run, and keeps or reverts the change itself. The agent never
reports its own score, never decides what is kept, and never touches the
scorer that counts.

When this ships:

- `arx climb` runs the [TSP example](../../examples/tsp) to the end of a
  budget with no scorer in the agent's loop, and leaves a branch that holds
  only scored, kept commits.
- Every round is one line in `results.jsonl`, with all of its runs, so a
  person can audit each keep or revert.
- The docs say plainly what climb protects against without a sandbox, and
  what it needs a sandbox for.

Out of scope: running rounds in parallel, a population of candidates
(evolutionary search), and a web view of results.

## Current state

What exists today, and what each part means for climb:

- **The roadmap names the item and nothing more.** `docs/roadmap.md:16` lists
  it as planned, and `docs/roadmap.md:61-66` says what it will do in two
  sentences.
- **The agent runs its own scorer.** The TSP prompt tells the agent to
  commit, score, log, and keep or revert (`examples/tsp/harness/prompts/system.md:4-14`).
  The rule "do not change `eval/`" is a sentence in `examples/tsp/program.md:12-15`,
  and `examples/tsp/README.md:37-42` says that nothing enforces it.
- **The docs already point at climb.** The "Trust" row of the long-run checklist
  (`docs/autoresearch.md:162`) and the drivers page's last common mistake
  (`docs/plugins/drivers.md:106`, "measure the result with your own program")
  both describe the gap. `docs/plugins/planned.md:62` names climb results as
  the example for `ARX_DATA_DIR`.
- **The scorer is a good model of the contract.** `examples/tsp/eval/score`
  builds its own inputs, checks every tour itself, prints `score: <value>` as
  its last line (`:47-59`), prints `score: inf` and exits 1 on failure
  (`:53-56`), and has holdout seeds that the agent should not tune on
  (`:15-16`).
- **The driver contract is enough to build climb.** A driver uses only the
  command line, the exit code, the JSON result and the event stream
  (`docs/plugins/drivers.md:6-9`). The JSON result has `session`, `status`,
  `exit`, `turns`, `tokens` and `cost` (`src/agent/run.c:150-163`). The exit
  codes are fixed in `src/base/base.h:27-32`. The example driver resumes a
  session in rounds (`examples/plugins/drivers/resume_on_cap.sh:13-22`).
- **A resumed session takes a new message and keeps its counters.**
  `arx --resume ID -p TEXT` adds `TEXT` as a user message (`src/agent/run.c:104-111`).
  `turns`, `tokens` and `cost` come back from `meta.json` (`src/io/session.c:93-105`),
  so `--cap usd` and `--cap turns` count the whole session across rounds,
  while `--cap wall` counts only the current process (`src/agent/loop.c:17-39`).
- **`limits.max_turns` would stop a long climb.** Its default is 200 and it
  counts session turns (`src/agent/loop.c:18-24`), so a climb must raise it
  with `--set` each round.
- **Restart compaction keeps the latest round message.** After a restart,
  `{{prompt}}` is the last `-p` text (`src/harness/compact.c:196-199`), so the
  agent still sees the latest result.
- **Subagent cost is not in the parent's cost.** `session.cost` adds only this
  session's model calls (`src/agent/model_call.c:85-88`, `src/harness/compact.c:167`).
- **Commands are short scripts, and arx's own come first.** `arx foo` runs
  `arx-foo`, searching arx's `libexec/arx` and `commands/` before the user's
  folders and plugins (`src/cli/external.c:26-55`), with `ARX_BIN` and
  `ARX_LIBEXEC` set (`src/cli/external.c:99-117`). The scripts use bash, jq
  and git (`commands/arx-sessions`, `commands/arx-kit`).
- **Scripts read YAML through the binary.** `arx check --kit-dir DIR` and
  `--plugin DIR` validate a folder and print `key=value` lines
  (`src/cli/check.c:236-254`), using the field tables in
  `src/harness/fields.c:68-123` and the YAML loader `SpecParse`
  (`src/harness/spec.c:98`). `src/harness/validate.c` is at 393 of the 400
  lines that `scripts/lint.sh` allows.
- **Never-stop is the default for experiment loops.** `arx init autoresearch`
  writes a `hooks/stop` that always continues (`commands/arx-init:139-144`),
  and the `research` kit turns on `never-stop` (`kits/research/kit.yaml:8-11`).
  A stop hook that continues would keep a climb round from ending.
- **Stop hooks: the first decision wins.** Hooks run by band, `policy` first
  (`docs/plugins/hooks.md:192-194`); at `stop`, the first hook that prints a
  decision wins (`docs/plugins/hooks.md:204`), and any decision other than
  `continue` or `restart` ends the session (`docs/plugins/hooks.md:135-145`).
- **Trust and sandboxes are designs, not code.** `--policy DIR` and
  `harness_edit` are in `docs/plugins/planned.md:31-43`; the `sandbox:` value
  is in `docs/plugins/planned.md:45-53`.

## Design

### The shape: a climb is a loop of rounds

A round is one agent turn-to-stop: climb runs `arx` headless, the agent
makes a change and ends its turn, and arx exits. Climb then scores the
change, keeps or reverts it, and starts the next round with
`arx --resume SESSION -p MESSAGE`, where the message carries the result.

```text
baseline: score HEAD (3+ runs)
loop:
  arx -p|--resume ... --json --quiet      agent edits work/, then stops
  snapshot work/ into a candidate commit   (climb, not the agent)
  export candidate + pinned eval files to a temp folder, run eval N times
  keep: move the climb branch to the candidate
  revert: restore work/ from the best commit
  append results.jsonl and results.tsv, check budgets, write the next message
```

This uses only the driver contract. arx gains no new run mode, and the
agent keeps one session, so its context and restart compaction work as
today. The agent waits while the evaluation runs; for a 30-second scorer
that is a fair trade for having no concurrent edits to reconcile.

### What a change is

A change is the content of the **change paths** (`change:` in `climb.yaml`,
such as `[work/]`) in the agent's working tree when a round ends. Climb
commits it itself. It is not the agent's commit and not a harness diff.

- **Not the agent's commit.** The agent may commit anything, including
  `eval/`, or forget to commit. Climb takes the working tree, so neither
  matters.
- **Not a harness diff.** The harness is how the agent works, not what is
  scored. Harness edits (`harness/tools/`, prompts, `agent.yaml`) are carried
  along in the working tree, never scored, never reverted, and never
  committed by climb. Each round's record lists them as `outside`.
- **A harness climb is the same mechanism.** To score a harness, put its
  paths in `change:` and make the eval command run `arx` on a benchmark.
  Climb does not care what the paths hold.

Climb builds the candidate without touching the agent's index:

```sh
GIT_INDEX_FILE=$tmp/index git read-tree BEST
GIT_INDEX_FILE=$tmp/index git add -A -- CHANGE...      # respects .gitignore
tree=$(GIT_INDEX_FILE=$tmp/index git write-tree)
# tree == BEST^{tree}: an empty round
cand=$(git commit-tree "$tree" -p BEST -m "climb RUN round N: NOTE")
git update-ref refs/climb/RUN/rN "$cand"
```

### Where the agent works

The agent works in the project checkout, on a branch that climb owns:

- **Start.** Climb requires a git repository and clean change paths
  (`git status --porcelain -- CHANGE` is empty; exit 2 otherwise). It
  creates `refs/heads/climb/RUN` at `HEAD` and checks it out. `BEST` starts
  at `HEAD`.
- **Round end, before the snapshot.** Climb puts git back in its own shape:
  it aborts a merge, rebase or cherry-pick in progress, points `HEAD` at
  `refs/heads/climb/RUN` with `git symbolic-ref`, resets that ref to `BEST`,
  and runs `git reset -q --mixed BEST`. Commits the agent made are folded
  back into the working tree; nothing in the tree is lost.
- **Keep.** `git update-ref refs/heads/climb/RUN CAND BEST`, then
  `git reset -q` so the index matches. `BEST` becomes `CAND`.
- **Revert.** `git restore --source=BEST --staged --worktree -- CHANGE`, then
  `git clean -fdq -- CHANGE` for files the change added.
- **End.** The branch holds only kept commits, each one scored. Edits outside
  the change paths stay in the working tree for you to review. Every
  candidate stays reachable at `refs/climb/RUN/rN` until `arx climb rm RUN`.

### How the scorer stays out of reach

Climb runs the official evaluation itself, from files the agent's tree does
not define:

- **Pinned eval files.** At the start, climb resolves `eval.ref` (default
  `HEAD`) to a commit, `EVAL`, and records the tree id of each path in
  `eval.files` (such as `eval/`). It keeps `EVAL` in memory for the run.
- **A fresh export per run.** Each evaluation runs in a new temp folder
  outside the project: `git archive CAND | tar -x`, then
  `git archive EVAL -- FILES | tar -x` on top. Edits the agent made to
  `eval/` in its tree never reach an evaluation. The folder is deleted after
  the run; the output is kept in `logs/`.
- **Tamper repair.** At each round end, climb compares `eval.files` in the
  working tree with `EVAL`. It restores any difference, records the paths as
  `tamper`, and tells the agent that `eval/` is read-only.
- **Climb reads only its own numbers.** It never reads `final_output`,
  `results.tsv` written by the agent, or any score the agent prints. The
  agent's own runs of `eval/score` stay useful for quick checks, and they do
  not count.
- **Holdout scores never reach the agent.** They go to `holdout.jsonl` and
  the summary, never into a round message or `results.tsv`.

Climb is honest about the limit. The agent's tools, and the candidate's own
code when the scorer runs it, run as you. Without a sandbox, either can
rewrite `.git`, climb's state, or anything else you can. Climb records the
level it ran at and warns when it is not `full`:

| `isolation` | The agent's tools | The candidate's code at eval time | Needs |
|---|---|---|---|
| `none` | run as you | run as you | nothing; climb warns at start |
| `agent` | in a sandbox: `.git`, `eval.files`, `climb.yaml` and `.arx/climb/` are read-only | run as you | `sandboxes` |
| `full` | in a sandbox | in a sandbox, or on another host | `sandboxes`, and `eval.sandbox: agent` or an eval command that isolates itself, such as `docker run` |

At `none`, climb still stops the common failures: an agent that edits the
scorer in its tree, that lies about its score in `final_output`, or that
keeps a change its own scorer liked by mistake. It does not stop a
determined agent with a shell.

With `trust`, climb also passes a **climb policy folder** with
`--policy`. It holds two hooks in band `policy`:

- **`stop`**: always prints `{"decision":"stop"}`, so a round ends when the
  agent ends its turn, even when the spec turns on `never-stop` or a
  `hooks/stop` that continues. Without `trust`, the round cap ends such a
  round instead (see [Budgets and stop conditions](#budgets-and-stop-conditions)).
- **`before_tool`** (`fail: closed`): denies an `edit` whose path is in
  `eval.files`, `climb.yaml` or `.arx/climb/`. It is a guard against
  wasted turns, not a sandbox, and it does not parse `bash` commands.

Climb does not use `harness_edit`: harness edits are outside the change and
never scored.

### The keep/revert rule

Each candidate gets `eval.repeats` runs. The score of one run is the number
on the last stdout line that matches `eval.pattern`, by default
`^score:[[:space:]]*([-+0-9.eE]+)[[:space:]]*$`. A run is a **crash** when
the command exits non-zero, times out, prints no match, or prints a value
that is not finite (`inf`, `nan`). One crashed run makes the candidate a
crash, and climb skips its other runs.

Climb keeps a sample list `B` for the best commit (its last 20 runs) and
decides with medians:

```text
b = median(B), c = median(C)                C = the candidate's runs
d = eval.min_delta, or |b| * pct / 100 when it ends in %
better = (goal == min) ? c < b - d : c > b + d          strict: ties revert
if better and eval.confirm > 0:
    run eval.confirm more times, add them to C, decide again on median(C)
keep if better; then B = C
```

Noise handling has four parts:

- **The baseline measures noise.** Round 0 runs `HEAD` at least 3 times
  (`max(3, repeats + confirm)`). When the spread of those runs is larger
  than `d`, climb warns: "the score varies by 0.031 between runs; set
  eval.repeats, eval.confirm or eval.min_delta".
- **`confirm` is cheap.** Most candidates lose on their first runs, so extra
  runs go only to candidates that look better.
- **`rescore` limits the winner's curse.** Every `eval.rescore` rounds,
  climb runs the best commit `repeats` more times and adds the runs to `B`,
  so a best that won on a lucky run cannot block every later candidate.
- **`compare` is the way out.** When `eval.compare` names a program, climb
  calls it in place of the threshold test, with one JSON object on stdin:

  ```json
  {"goal": "min", "min_delta": 0.005, "stage": "first",
   "best": [5.41, 5.43, 5.40], "candidate": [5.38]}
  ```

  It prints `keep`, `revert`, or `more` (only at `stage` `first`: run the
  confirm runs, then call again with `stage` `final`). A failed or unknown
  answer is a revert, with a warning. A Welch test or a bootstrap fits in a
  few lines of Python here, and none of it is in climb.

### Budgets and stop conditions

A climb runs unattended, so **it will not start without a budget**:
`budget.usd`, `budget.wall` or `budget.tokens`, from `climb.yaml` or `--cap`
(exit 2 otherwise, like the warning in `docs/autoresearch.md:55-58`).

| Limit | Key / flag | Counts | How climb enforces it |
|---|---|---|---|
| Spend | `budget.usd`, `--cap usd=N` | the agent session's `cost`, across rounds | passes `--cap usd=N` to every round; the session's own counter stops it |
| Tokens | `budget.tokens`, `--cap tokens=N` | the session's input and output tokens | `--cap tokens=N` each round |
| Time | `budget.wall`, `--cap wall=D` | time since `arx climb` started, evaluations included | each round gets `--cap wall=` the smaller of `round.wall` and the time left; climb checks before each round and evaluation |
| Rounds | `budget.rounds`, `--rounds N` | rounds started; baseline and rescore runs do not count | climb's counter |
| Patience | `budget.patience`, `--patience N` | rounds in a row without a keep | climb's counter |
| Target | `budget.target`, `--target X` | the best score | stops once `best <= X` (`min`) or `>= X` (`max`) |
| Round turns | `round.turns`, `--round turns=N` (default 40) | turns in one round | `--cap turns=T+N` and `--set limits.max_turns=T+N`, where `T` is the session's turns so far |
| Round time | `round.wall`, `--round wall=D` (default 30m) | one round's time | `--cap wall=D` |

How each way a round ends is handled:

| arx exits | Climb does | Climb goes on? |
|---|---|---|
| `0` done | evaluates | yes |
| `3` cap | evaluates; if the session hit `budget.usd` or `budget.tokens`, stops after | if a round cap, yes |
| `1` error | evaluates whatever is in the change paths | yes; stops after 3 errors in a row |
| `2` usage | restores the change paths; the spec no longer loads | no, exit 2 |
| `4` auth | restores the change paths | no, exit 4 |
| `5` policy (with `trust`) | restores the change paths; a policy stopped the run | no, exit 5 |
| `130` interrupted | restores the change paths | no, exit 130 |

`arx climb stop [RUN|last]` writes `stop` in the run folder and runs
`arx ctl SESSION stop`; the round ends after the agent's current turn, is
evaluated, and the climb stops. Ctrl-C reaches arx and climb together:
arx exits 130, and climb restores the change paths, writes the summary and
exits 130.

Exit codes of `arx climb` follow arx's:

| Code | `stop` in the summary |
|---|---|
| `0` | `rounds`, `patience`, `target`, `stopped` |
| `1` | `error`: three arx errors in a row, a baseline that crashes, or a git step that fails |
| `2` | `usage`: bad `climb.yaml`, not a git repository, dirty change paths, no budget, another climb running here |
| `3` | `cap:usd`, `cap:tokens`, `cap:wall` |
| `4` | `auth` |
| `5` | `policy`: a policy stopped the round (with `trust`) |
| `130` | `interrupted` |

### The round message

Climb sends this plain text with `-p`. The first round puts `task` above
it. The first line starts with `[arx climb]` so prompts and hooks can find
it:

```text
[arx climb] Round 7 of 100: your change to work/ was reverted.
Score 5.4710 (3 runs: 5.4710 5.4688 5.4801). Best 5.4100 (round 5).
It must beat the best by more than 0.0054 (0.1%), and lower is better.
work/ is back at the best version. Edits outside work/ are kept but not
scored: harness/tools/run_exp.
Budget left: $3.21, 5h12m, 93 rounds.
Make the next change to work/, then end your turn without a tool call.
```

The second line changes with the status:

| Status | Second line |
|---|---|
| `keep` | `Score 5.4100 (3 runs: ...). It is the new best; the change is committed.` |
| `revert` | as in the example |
| `crash` | `The evaluation failed: exit 1. Its last 20 lines:` and the lines (`eval.show`) |
| `empty` | `You changed nothing in work/.` |
| `tamper` (added to any) | `Your edits to eval/score were undone: arx climb scores with its own copy.` |
| `rescore` (added to any) | `The best was measured again: 5.4300 (8 runs).` |

### Results format

Results live in `.arx/climb/RUN/`. arx's own commands keep their files in
`.arx/<command>/`; `.arx/data/<name>/` (`ARX_DATA_DIR`) belongs to plugins.
`.arx/climb/last` links to the newest run, as `.arx/sessions/last` does
(`src/io/session.c:22-30`):

| File | Holds | Read by |
|---|---|---|
| `climb.json` | the config as resolved, `EVAL` and its tree ids, `base`, `branch`, `session`, `isolation`, arx version, start time | `--resume`, people |
| `results.jsonl` | one line per evaluation: baseline, each round, each rescore | `arx climb status`, scripts |
| `results.tsv` | `round status score best delta commit turns cost note`, for people and the agent's prompt | the agent (`{{file:.arx/climb/last/results.tsv:tail=20}}`) |
| `holdout.jsonl` | holdout runs; a sandbox can hide this one file | people |
| `summary.json` | the state so far, rewritten after every round | `arx climb status`, `--json`, front-ends |
| `logs/R-K.log` | output of run `K` of round `R`, the last 1 MB | people |
| `stop`, `lock/` | the stop request; the lock, with `pid` | climb |

One `results.jsonl` line (`v` is the format version):

```json
{"v": 1, "run": "20261109-1530", "round": 7, "t": "2026-11-09T15:42:10Z",
 "status": "revert", "commit": "3f2a9c1", "best_commit": "9b1e004",
 "scores": [5.471, 5.4688, 5.4801], "score": 5.471, "best": 5.41,
 "delta": 0.061, "eval_secs": 31.2,
 "agent": {"session": "20261109-153001-a1b2", "exit": 0, "status": "done",
           "turns": 9, "tokens": 45678, "cost": 0.031},
 "files": ["work/solve.py"], "outside": ["harness/tools/run_exp"],
 "tamper": [], "note": "Or-opt moves on the 20 nearest neighbours"}
```

`status` is `baseline`, `rescore`, `keep`, `revert`, `crash`, `empty` or
`abort` (arx exited 2, 4, 5 or 130; nothing evaluated). `note` is the first
line of the agent's `final_output`, cut to 120 characters: a label, never
trusted.

`summary.json`, also printed by `arx climb --json` when the climb ends:

```json
{"run": "20261109-1530", "status": "done", "stop": "rounds", "exit": 0,
 "rounds": 100, "kept": 12, "reverted": 80, "crashed": 6, "empty": 2,
 "baseline": 6.2013, "best": 5.3101, "best_commit": "c41d2e7",
 "holdout": {"baseline": 6.2507, "best": 5.4012},
 "branch": "climb/20261109-1530", "session": "20261109-153001-a1b2",
 "cost": 3.21, "tokens": 1234567, "secs": 28812, "isolation": "none"}
```

While it runs, climb prints one line per round on stderr. Follow the agent
itself with `arx watch SESSION` from another terminal; climb prints the
session id at the start.

```text
climb 20261109-1530 · session 20261109-153001-a1b2 · isolation none
round   0  baseline  6.2013  3 runs, spread 0.0040
round   1  keep      6.1022  best 6.1022  -1.6%   9 turns  $0.03  2-opt
round   2  revert    6.1530  best 6.1022         12 turns  $0.04  Or-opt
round   3  crash     -       best 6.1022          7 turns  $0.02  grid NN
```

### Command line

```text
arx climb [--config PATH] [--name RUN] [--rounds N] [--patience N]
          [--target X] [--cap usd=N|tokens=N|wall=D] [--round turns=N|wall=D]
          [--spec PATH] [--kit NAME] [--set KEY=VALUE]... [--json] [--quiet]
          [--dry-run]
arx climb --resume RUN|last [budget flags] [--new-session]
arx climb status [RUN|last] [--json]
arx climb stop [RUN|last]
arx climb rm RUN [--yes]
```

- **`--config PATH`**: default `./climb.yaml`.
- **`--name RUN`**: default a time stamp, `20261109-1530`. Names the branch
  `climb/RUN` and the run folder.
- **`--spec`, `--kit`, `--set`**: added to every round, after the values in
  `agent:`. Other `--cap` keys, such as `depth`, pass through to each round.
- **`--dry-run`**: checks everything and runs the baseline, then exits
  without starting the agent. Use it to check a scorer.
- **`--resume`**: reads `climb.json`, checks that `refs/heads/climb/RUN`
  exists, scores the best commit again as a new baseline (so numbers in a
  file the agent could reach do not decide anything), and continues the
  same session. On a resume, budget flags count from the resume:
  `--cap usd=2` is two more dollars. `--new-session` starts a fresh session.
- **`--json`**: prints `summary.json` on stdout at the end.
- **`--quiet`**: no per-round lines.

### `climb.yaml`

`climb.yaml` is the driver's file, not the agent's. Climb reads it once at
the start and freezes it in `climb.json`, so an edit during a run changes
nothing.

```yaml
# climb.yaml: what arx climb scores, and how much it may spend
task: Lower the score from eval/score. See program.md.
agent:
  spec: harness/agent.yaml        # --spec for every round
  set: {model: openai/gpt-5.1}    # --set pairs, pinned
change: [work/]                   # only these paths are scored
eval:
  command: python3 eval/score     # sh -c, in a fresh export
  files: [eval/]                  # from eval.ref, never from the tree
  goal: min                       # min or max
  timeout: 5m
  confirm: 2                      # more runs for a likely winner
  min_delta: 0.1%                 # a number, or a percent of the best
holdout: {command: python3 eval/score --holdout}
budget: {usd: 5, wall: 8h, patience: 25}
```

Every key:

| Key | Type | Default | Description |
|---|---|---|---|
| `task` | text | `Make one change to CHANGE that improves the score, then end your turn.` | The first round's message, above the result. |
| `agent.spec` | string | `./agent.yaml` | `--spec` for every round. |
| `agent.kit` | string | | `--kit` for every round. |
| `agent.set` | map | | `--set KEY=VALUE` for every round. |
| `agent.sandbox` | any | | Passed as `--set sandbox=...`, with climb's `readonly` paths added. Needs `sandboxes`. |
| `change` | string list | **required** | The change paths. |
| `eval.command` | string | **required** | The scorer, run with `sh -c` in the export. |
| `eval.files` | string list | `[]` | Paths taken from `eval.ref` for every run and repaired in the tree. |
| `eval.ref` | string | `HEAD` | The commit the eval files come from, resolved once. |
| `eval.goal` | string | `min` | `min` or `max`. |
| `eval.pattern` | string | `^score:[[:space:]]*([-+0-9.eE]+)[[:space:]]*$` | An extended regular expression with one group. |
| `eval.timeout` | duration | `10m` | Longest one run may take; climb stops its process group. |
| `eval.repeats` | integer | `1` | Runs for every candidate. |
| `eval.confirm` | integer | `0` | More runs for a candidate that looks better. |
| `eval.min_delta` | number or percent | `0` | How much better a candidate must be. |
| `eval.rescore` | integer | `0` | Run the best again every N rounds; `0` never. |
| `eval.compare` | string | | A program that decides in place of the threshold test. |
| `eval.show` | integer | `20` | Output lines the agent sees after a crash. |
| `eval.sandbox` | string | `none` | `agent` runs the eval in the agent's sandbox. Needs `sandboxes`. |
| `holdout.command` | string | | A second scorer, never shown to the agent. Runs in the same export. |
| `holdout.when` | string | `end` | `end` (baseline and final best) or `keep` (every keep too). |
| `budget.usd`, `budget.tokens`, `budget.wall` | number, integer, duration | | At least one is required. |
| `budget.rounds`, `budget.patience` | integer | | |
| `budget.target` | number | | |
| `round.turns` | integer | `40` | |
| `round.wall` | duration | `30m` | |

The eval command gets these variables, and climb's environment without
the `ARX_SESSION*` variables:

| Variable | Value |
|---|---|
| `ARX_CLIMB_RUN` | the run name |
| `ARX_CLIMB_ROUND` | the round, `0` for the baseline |
| `ARX_CLIMB_KIND` | `baseline`, `candidate`, `rescore` or `holdout` |
| `ARX_CLIMB_REPEAT` | which run of this candidate, from `1` |
| `ARX_CLIMB_COMMIT` | the commit being scored |
| `ARX_BIN` | the arx binary, for a harness climb that runs arx |

### `arx check --climb FILE`

The script cannot parse nested YAML, so the binary does it, the way
`arx check --kit-dir` reads `kit.yaml`. `arx check --climb FILE` parses the
file with `SpecParse`, validates it against a new `kClimbFields` table,
fills in defaults, converts durations to seconds, and prints one JSON
object on stdout. A problem prints `climb.yaml:12: eval.goal must be min or
max` on stderr and exits 2. Nothing else in arx reads `climb.yaml`.

### Where it runs: an external command

`arx climb` is `commands/arx-climb`, a bash script that ships with arx like
`arx kit`, plus the `climber` kit for the agent's side. It is not a plugin:

- **arx does not load a driver.** A driver needs no plugin contract, and a
  plugin that is on by default would add nothing to a run anyway.
- **arx's own commands come first.** A plugin can add `arx climb` but cannot
  replace arx's (`src/cli/external.c:26-55`), so no installed plugin can
  stand in for the scorer's driver.
- **It ships ready.** A climb is the main use of arx; it belongs next to
  `arx init autoresearch`, not behind `arx plugin add`.

The script needs bash 3.2 (the macOS default: no `mapfile`, no associative
arrays), jq, git 2.23 or later (`git restore`) and awk. It does the
arithmetic in jq. Its body is one `main` function called on the last line,
so bash has read the whole file before it runs: an edit to the installed
script during a climb does not change the running climb.

## Implementation steps

1. **Read `climb.yaml` in the binary.** Add `src/harness/climb.c` (new, about
   120 lines) with `kClimbFields`, `ClimbValidate` and `ClimbDescribe(path,
   out, err)`, declared in `src/harness/harness.h` next to `KitValidate`
   (`:236`). Keep it out of `src/harness/validate.c`, which is at 393 lines.
   Add `--climb FILE` to `CheckOrTools` in `src/cli/check.c:250-254`, next to
   `--kit-dir`, and to the usage text.
2. **Write `commands/arx-climb`: start and baseline.** Arguments and
   subcommands; `arx check --climb`; preflight (git repository, git version,
   clean change paths, a budget, the lock in `.arx/climb/lock/` taken
   with `mkdir`, a stale lock taken over when its `pid` is gone); resolve
   `EVAL` and the tree ids; create the branch and the run folder; write
   `climb.json`; print the isolation warning.
3. **Add the evaluation runner** in the same script: the export with
   `git archive`, the overlay of `eval.files`, the run in its own process
   group (`set -m`) with a watcher that sends `TERM` then `KILL` to the group
   at `eval.timeout` (no coreutils `timeout` on macOS), score parsing,
   `logs/R-K.log`, and the keep rule with `repeats`, `confirm`, `rescore` and
   `compare`. Then the baseline and its noise warning.
4. **Add the round loop:** the arx call with `--json --quiet`, the caps and
   `--set limits.max_turns`, the result parsing, folding the agent's git
   state back, tamper repair, the snapshot, keep or revert, `results.jsonl`,
   `results.tsv`, `summary.json`, the round message, and every stop
   condition. Then `INT` and `TERM` handling and the final holdout.
5. **Add `status`, `stop`, `rm` and `--resume`.** `rm` deletes
   `refs/climb/RUN/*`, the branch (after asking, unless `--yes`) and the run
   folder.
6. **Add the `climber` kit** in `kits/climber/`: `kit.yaml` with
   `plugins: [shell, git-context]` and no `never-stop`; `prompts/system.md`
   for rounds ("make one change to the change paths, check it with
   `eval/score` if you like, then end your turn with a one-line summary of the
   idea; do not commit; do not edit `eval/`; keep `notes.md` current");
   `init/` with `agent.yaml` (restart compaction), `program.md`,
   `prompts/first.md` (with `{{file:.arx/climb/last/results.tsv:tail=20}}`
   and `{{file:notes.md:max=8kb}}`) and `climb.yaml`. Add it to
   `kits/README.md`.
7. **Make the TSP example climb.** Add `examples/tsp/climb.yaml` and
   `examples/tsp/harness/prompts/climb.md` (the round prompt), with
   `agent.set` pointing `instructions` at it. Until `trust` lands, its
   `climb.yaml` comment says to delete `harness/hooks/stop` for a climb.
8. **Wire the build.** `Makefile`: add `tests/climb.sh` to `test` (after
   `:72`) and to the header comment; `install` copies `commands/climb/` (the
   policy folder) to `libexec/arx/climb/`.
9. **After `trust` lands:** add `commands/climb/policy/` (the `stop` and
   `before_tool` hooks in band `policy`), pass `--policy` from
   `ARX_LIBEXEC/climb/policy` on every round, and drop the TSP note from
   step 7.
10. **After `sandboxes` lands:** pass `agent.sandbox` with climb's
    `readonly` and `hide` paths, run the eval through the sandbox when
    `eval.sandbox: agent`, and set `isolation` from what ran.

Steps 1 to 8 need no other 0.2.0 item. Steps 9 and 10 are small and come
last.

## Tests

Add `tests/climb.sh`, run by `make test`. It needs no model: a stub agent,
`tests/climb-agent`, stands in for arx in rounds. The script finds it
through `ARX_BIN`; the stub passes `check` and `ctl` to the real
`./arx-debug`, and for a run it executes `$FAKE_DIR/round-NN.sh` in the
working folder, records its arguments in `argv-NN`, prints the JSON result
from `round-NN.json` (or a default), and exits with the code in
`round-NN.exit`. Each test builds a git repository whose
`eval/score` prints `score: $(cat work/value)`.

| Check | What it proves |
|---|---|
| keep | a lower value is kept; `refs/heads/climb/RUN` moves; `results.jsonl` has `keep` |
| revert | a higher value is reverted; `work/value` is back; `refs/climb/RUN/r1` exists |
| new and deleted files | a revert removes files the change added and restores deleted ones |
| tamper | a round that rewrites `eval/score` to print `0` is scored with the pinned scorer, is listed in `tamper`, and `eval/score` is restored |
| agent commits | commits by the agent are folded back; the branch has only climb's commits; a harness edit stays in the tree and is listed in `outside` |
| agent switches branch | a round that checks out another branch ends with `HEAD` on `climb/RUN` and no lost edits |
| empty and patience | a round that changes nothing is `empty`; `--patience 2` stops with exit 0 and `stop: patience` |
| crash | an eval that exits 1, prints `inf`, prints no score, or passes `eval.timeout` is a `crash` and reverts |
| noise | with a scorer that reads a list of values: `repeats` and the median, `confirm` only for a likely winner, `min_delta` as a number and a percent, the baseline spread warning, `rescore` adding to the best's runs |
| compare | a `compare` program's `keep`, `revert` and `more`; a failing one reverts with a warning |
| budgets | rounds get `--cap usd=`, `--cap tokens=`, `--cap turns=T+N` and `--set limits.max_turns=T+N`; `--rounds 3` stops at 3; a session at `budget.usd` stops with exit 3 and `stop: cap:usd`; `--target` stops |
| no budget | `arx climb` with no budget exits 2 and says how to set one |
| errors | arx exiting 1 three times stops with exit 1; exit 4 stops with exit 4 at once |
| stop | `arx climb stop` between rounds ends the climb after the round, exit 0, `stop: stopped` |
| Ctrl-C | `INT` during a slow round: exit 130, change paths restored, `summary.json` written |
| resume | `--resume last` reuses the session id, rescores the best, and counts budgets from the resume |
| holdout | holdout runs at the end, is in `holdout.jsonl` and the summary, and in no `argv-NN` message |
| usage | no repository, dirty change paths, another climb's lock, and a bad `climb.yaml` exit 2 |
| `arx check --climb` | defaults filled, durations in seconds, unknown keys and bad values reported with a line number |
| `--json` | the summary has every documented field |
| end to end | the real `./arx-debug` with `tests/fake-curl`: a scripted `edit` of `work/value`, then a text reply; climb keeps the change and the second round uses `--resume` |
| with `trust` (step 9) | a spec with a `hooks/stop` that continues still ends each round at the agent's turn end |

In `tests/kits.sh`, "the kits in kits/" (`:238-260`) checks each shipped
kit by name. Add `climber` there: `arx kit add climber` links it,
`arx init climber` writes `climb.yaml`, and `arx check` shows no `stop` hook.

## Docs to change

All pages follow `docs/WRITING.md`: lead with the answer, name the
mechanism, nothing planned in the present tense, at most two callouts.

- **`docs/climb.md` (new, a guide).** H1 "arx climb". First sentence:
  "`arx climb` runs an agent in rounds, scores each change with your
  evaluation outside the agent's loop, and keeps or reverts the change
  itself." Sections: "When to use it" (one command scores the task; you
  don't want to trust the agent's own scorer); "Set up a climb" (numbered
  steps with `arx kit add climber`, `arx init climber`, `arx climb --dry-run`,
  `arx climb`); "What a change is"; "How the scorer stays out of reach" with
  the isolation table and one `[!WARNING]` on what runs as you; "The keep
  rule and noise"; "Budgets and stop conditions"; "Results"; "Resume, stop
  and clean up"; "`climb.yaml`" (every key, a reference table); "Common
  mistakes" (a never-stop hook, a scorer that prints its score before
  checking, holdout data in the agent's tree, outside edits the work needs);
  "Related". Add it to `src/lib/nav.mjs` in arx-docs.
- **`docs/cli.md`.** Add `arx climb` to the synopsis (`:6-19`); a section
  "Climbing a score" with the flags, the subcommands and the exit-code
  table, linking `docs/climb.md`.
- **`docs/autoresearch.md`.** Add a section "Let arx climb keep the score"
  after "Run the TSP example": the same example under `arx climb`, and
  what changes in the prompt (no scorer step, no keep/revert step). Change
  the "Trust" row (`:162`) to "Run the climb with `arx climb`, so the agent
  never runs the scorer that counts" and link it. Note in "Let the agent
  improve itself" (`:95-96`) that under climb the one-experiment tool only
  edits and checks.
- **`docs/plugins/drivers.md`.** Name `arx climb` in the opening as the
  driver that ships with arx; change the fix in `:106` to "measure it with
  your own program, or use `arx climb`"; add it to Related.
- **`docs/roadmap.md`.** Item 7 (`:16`) to **done**, linking `climb.md`;
  remove the `arx climb` section (`:61-66`).
- **`docs/plugins/planned.md`.** The `ARX_DATA_DIR` row (`:62`) names climb
  results as its example; drop that example, since climb keeps its files in
  `.arx/climb/`, not in `.arx/data/`.
- **`examples/tsp/README.md`.** Replace "Trust" (`:37-42`) with "Run it with
  `arx climb`": the commands and what climb adds.
- **`kits/README.md` and `README.md`.** Add `climber` to the kit table; in
  `README.md:183`, drop `arx climb` from the roadmap row and add a row for
  `docs/climb.md`.

## Dependencies

Climb does not block on any other item for its first eight steps. It
shares these with other 0.2.0 items:

| Slug | What climb needs or shares | Ask |
|---|---|---|
| `plugin-state` | the `.arx/` layout | **Answered** (release plan, settled item 2): core commands keep their files in `.arx/<command>/`, so climb writes to `.arx/climb/`; `.arx/data/<name>/` is for plugins. Climb keeps its own `last` link. |
| `trust` | `--policy DIR` for the round-end `stop` hook and the edit guard | **Answered** (trust plan): `--policy` is repeatable, so climb's folder and yours both load. arx does not reload a policy folder; a change to one stops the run with exit 5. Climb's `stop` hook still ends the session through "any other decision" (`docs/plugins/hooks.md:145`). |
| `sandboxes` | a sandbox for the agent's tools, and a way to run the eval in one | The sandbox value takes `readonly:` and `hide:` path lists, which climb adds to. `arx tool bash` runs the active `bash` (the sandbox's when one replaces `shell`), so a driver can run one command in the same sandbox with a given working folder. |
| `acp-tui` | none required | A TUI can show a climb by reading `summary.json` and `results.jsonl`; treat both as stable, versioned by `v`. |
| `arx-plugin` | none | `climber` is a kit, installed by `arx kit add`, which exists. |
| `async-calls`, `long-lived-hooks`, `plugin-yaml-keys`, `mcp-client` | none | |

Order of work: climb steps 1 to 8 can run beside everything; step 9 after
`trust`; step 10 after `sandboxes`.

## Size and risks

**Size: M.** About 550 lines of bash in `commands/arx-climb`, 120 lines of
C, one kit, about 400 lines of tests, and one new docs page.

Risks:

- **Git states the agent leaves.** Rebases in progress, detached `HEAD`,
  submodules, Git LFS, and large or binary files in the change paths. Climb
  aborts operations in progress and owns `HEAD`; tests cover branch
  switches and history rewrites. Large files bloat the repository through
  `refs/climb/RUN/r*`; the docs say to keep data out of the change paths, and
  `arx climb rm` frees them.
- **Overclaiming safety.** At `isolation: none`, climb is a guard against
  mistakes and casual reward hacking, not a boundary. The page and the
  start-up warning must say so, and `isolation` is in every summary.
- **The candidate runs during the eval.** Code the agent wrote runs as you
  inside the scorer. Only `isolation: full` covers it. This is easy to miss,
  so it is in the warning text.
- **Noise.** Medians of 1 to 3 runs still let lucky candidates through.
  The baseline spread warning, `confirm`, `rescore` and `compare` reduce it;
  the default stays at one run, since many scorers are deterministic.
- **Subagent spend is not in the session's cost.** A round that starts
  subagents can pass `budget.usd`. Either core adds subagent cost to the
  parent's `cost`, or climb sums `meta.json` of child sessions; this plan
  takes the second as a fallback and lists the first as a question for core.
- **Shell portability.** bash 3.2, BSD versus GNU tools, and process-group
  timeouts. The arithmetic is in jq, and tests run on macOS and Linux in CI.
- **Rounds idle the agent during long evals.** A 10-minute scorer means 10
  idle minutes per round. Accepted for 0.2.0; see open decision 1.
- **Never-stop hooks before `trust`.** Until climb can pass its policy
  `stop` hook, a spec that always continues runs each round to its turn cap.
  `arx climb` warns at start when `arx check --list` shows a `stop` hook.

## Open decisions

1. **One round per agent stop, or a submit tool in one long turn.** A
   `climb_submit` tool could let the agent keep working while climb
   evaluates, with the score arriving later through the inbox. It needs a
   tool plugin that talks to the driver, depends on `async-calls`, and has
   to reconcile edits made during an evaluation. **Recommendation: rounds.**
   They use only the driver contract and have no concurrent edits.
2. **External command or plugin.** **Recommendation: core
   `commands/arx-climb`,** for the reasons in
   [Where it runs](#where-it-runs-an-external-command).
3. **What a change is.** A snapshot of the change paths, the agent's own
   commit, or a harness diff. **Recommendation: the snapshot, committed by
   climb.**
4. **Edits outside the change paths.** Carry them uncommitted, commit them
   separately on a keep, or revert them with the change. **Recommendation:
   carry them, list them as `outside`, and never score or commit them.**
5. **How the script reads `climb.yaml`.** `arx check --climb FILE` with a
   field table, or a generic `arx check --yaml FILE` that prints any YAML as
   JSON and leaves validation to jq. **Recommendation: `--climb`.** It gives
   line numbers and unknown-key errors for about 120 lines of C.
6. **Ties.** **Recommendation: a tie reverts.** No option in 0.2.0; a
   "simpler at the same score" climb can use `compare`.
7. **Defaults for noise.** **Recommendation: `repeats: 1`, `confirm: 0`,
   `min_delta: 0`,** with the baseline's 3 runs warning you when the scorer
   is noisy.
8. **Refuse or warn at `isolation: none`.** **Recommendation: warn, record
   it, and start.** Sandboxes are plugins that many users won't have; a
   later `--require-isolation full` can refuse.
9. **Eval inputs that are not in git.** **Recommendation: not in 0.2.0.**
   Eval files come from a commit; anything else is an absolute path in
   `eval.command`, outside the project.
10. **Keep every candidate as a ref.** Refs (`refs/climb/RUN/rN`) or `.diff`
    files in the run folder. **Recommendation: refs,** with `arx climb rm`
    to free them.
11. **What the agent sees after a crash.** **Recommendation: the last 20
    lines** (`eval.show`), and only the score otherwise. The agent sees the
    same output today when it runs the scorer itself.
12. **A required budget.** **Recommendation: require `usd`, `tokens` or
    `wall`,** and exit 2 without one.
