#!/usr/bin/env bash
# climb.sh: tests `arx check --climb` and `arx climb` (commands/arx-climb).
# A stub, tests/climb-agent, stands in for arx in the rounds, so no model
# runs: each test is a git project whose eval/score prints work/value.
# keep, revert, files, tamper, the agent's git, empty rounds, crashes,
# usage errors and the warnings; tests/climb-run.sh has the rest. Run with
# `make test`.
set -u
. "$(dirname "$0")/climb-lib.sh"

begin "arx check --climb"
cat >climb.yaml <<'EOF'
change: [work/]
eval: {command: eval/score, timeout: 5m, min_delta: 0.1%}
budget: {wall: 2h, usd: 5}
EOF
"$ARX" check --climb climb.yaml >out.txt 2>err.txt
code=$?
check "a valid file exits 0" exited 0
jqo() { jq -r "$1" out.txt; }
check "durations are seconds" test "$(jqo '[.eval.timeout, .budget.wall, .round.wall] | map(tostring) | join(" ")')" = "300 7200 1800"
check "defaults are filled in" test "$(jqo '[.eval.goal, .eval.ref, .eval.repeats, .eval.confirm, .eval.show, .round.turns, .holdout.when] | map(tostring) | join(" ")')" = "min HEAD 1 0 20 40 end"
check "the default pattern" test "$(jqo .eval.pattern)" = '^score:[[:space:]]*([-+0-9.eE]+)[[:space:]]*$'
check "a percent min_delta" test "$(jqo '[.eval.min_delta, .eval.min_delta_percent] | map(tostring) | join(" ")')" = "0.1 true"
check "unset keys are null" test "$(jqo '[.agent.spec, .budget.tokens, .eval.compare, .holdout.command] | map(tostring) | join(" ")')" = "null null null null"
check "the default task names the change paths" test "$(jqo .task)" = "Make one change to work/ that improves the score, then end your turn."
printf 'Lower the score.\n' >task.md
printf 'task: {file: task.md}\nchange: [a, b]\neval: {command: x, min_delta: 2}\nagent: {set: {model: m, limits: {max_turns: 9}}}\n' >climb.yaml
"$ARX" check --climb climb.yaml >out.txt 2>err.txt
check "task from a file" test "$(jqo .task)" = "Lower the score."
check "agent.set keeps its values" test "$(jq -c .agent.set out.txt)" = '{"model":"m","limits":{"max_turns":9}}'
check "a number min_delta" test "$(jqo '[.eval.min_delta, .eval.min_delta_percent] | map(tostring) | join(" ")')" = "2 false"
cat >climb.yaml <<'EOF'
change: [/abs, ../up]
eval:
  goal: maximum
  repeats: 0
  min_delta: 5x
  pattern: "score: [0-9]+"
  timout: 5m
budget: {usd: -1, wall: 3 days}
sandbox: {}
EOF
"$ARX" check --climb climb.yaml >out.txt 2>err.txt
code=$?
check "problems exit 2" exited 2
check "and print nothing on stdout" test ! -s out.txt
check "an unknown key, with its line" has err.txt 'climb.yaml:7: eval.timout: unknown key (known: command, files,'
check "an unknown top-level key" has err.txt 'climb.yaml:9: sandbox: unknown key'
check "a bad choice" has err.txt 'climb.yaml:3: eval.goal: must be min or max'
check "a bad range" has err.txt 'climb.yaml:4: eval.repeats: must be at least 1'
check "a bad duration" has err.txt 'climb.yaml:8: budget.wall: must be a duration'
check "a bad percent" has err.txt 'climb.yaml:5: eval.min_delta: must be a number or a percent'
check "a pattern without a group" has err.txt 'climb.yaml:6: eval.pattern: must be an extended regular expression with one group'
check "a path outside the project" has err.txt 'climb.yaml:1: change: "../up" must be a path inside the project'
check "a required key" has err.txt 'eval.command: required'
"$ARX" check --climb nope.yaml >out.txt 2>err.txt
code=$?
check "a missing file exits 2" exited 2

project "keep and revert" <<<'budget: {usd: 5, rounds: 2}'
round 1 'echo 8 >work/value'
round 2 'echo 9 >work/value'
climb
check "exits 0 at the round budget" exited 0
check "the start says what isolation none protects against" has err.txt 'That stops mistakes and casual'
check "  and what it does not" has err.txt 'not a determined agent: its shell can still rewrite .git,'
check "round 1 is a keep" test "$(jl '.[1].status')" = keep
check "the branch moved to it" test "$(git rev-parse climb/t)" = "$(git rev-parse refs/climb/t/r1)"
check "round 2 is a revert" test "$(jl '.[2].status')" = revert
check "work/ is back at the best" test "$(cat work/value)" = 8
check "the reverted candidate stays reachable" git rev-parse -q --verify refs/climb/t/r2
check "the branch holds only kept, scored commits" test "$(git log --format=%s climb/t | tr '\n' '|')" = "climb t round 1: idea 01|base|"
check "HEAD is on the branch" test "$(git symbolic-ref HEAD)" = refs/heads/climb/t
check "the first round gets the task and the baseline" has fake/argv-01 'The best so far is 10.0000 (3 runs: 10.0000 10.0000 10.0000), from the starting version.'
check "the next round hears the result" has fake/argv-02 '[arx climb] Round 1 of 2: your change to work/ was kept.'
check "and resumes the session" grep -qx stub-01 fake/argv-02
check "the revert's line on stderr" grep -qE '^round   2  revert +9.0000  best 8.0000' err.txt
check "results.tsv for the agent" grep -qE '^1	keep	8.0000	8.0000	-2.0000	' .arx/climb/t/results.tsv
check ".arx/climb/last links the run" test "$(readlink .arx/climb/last)" = t

project "new and deleted files" <<<'budget: {usd: 5, rounds: 1}'
round 1 'echo 11 >work/value; echo new >work/new.py; rm work/old.py'
climb
check "a revert removes an added file" test ! -e work/new.py
check "and restores a deleted one" test -f work/old.py
check "the round lists both" test "$(jl -c '.[1].files')" = '["work/new.py","work/old.py","work/value"]'

project "tamper" <<<'budget: {usd: 5, rounds: 2}'
round 1 'echo 9 >work/value; printf "#!/bin/sh\necho score: 0\n" >eval/score; echo x >eval/extra'
climb
check "is scored with the pinned scorer" test "$(jl '.[1].score')" = 9
check "lists the tampered paths" test "$(jl -c '.[1].tamper')" = '["eval/extra","eval/score"]'
check "restores eval/score" grep -q 'cat work/value' eval/score
check "removes what it added" test ! -e eval/extra
check "tells the agent" has .arx/climb/t/results.jsonl '"tamper":["eval/extra"'
check "the next round's message says so" has fake/argv-02 'Your edits to eval/extra, eval/score were undone: arx climb scores with its own copy.'

project "the agent's git" <<<'budget: {usd: 5, rounds: 2}'
round 1 'echo 8 >work/value && git add work && git commit -qm agent-commit && mkdir -p harness/tools && echo t >harness/tools/run_exp'
round 2 'git checkout -q -b side && echo 7 >work/value && git commit -qam side-commit'
climb
check "commits by the agent are folded back" test "$(git log --format=%s climb/t | tr '\n' '|')" = "climb t round 2: idea 02|climb t round 1: idea 01|base|"
check "a harness edit stays in the tree" test -f harness/tools/run_exp
check "and is listed as outside" test "$(jl -c '.[1].outside')" = '["harness/tools/run_exp"]'
check "a branch switch ends on the climb branch" test "$(git symbolic-ref HEAD)" = refs/heads/climb/t
check "with no lost edits" test "$(cat work/value)" = 7
check "the agent's branch is left alone" test "$(git log -1 --format=%s side)" = side-commit

project "a rebase in progress" <<<'budget: {usd: 5, rounds: 1}'
git checkout -q -b other && echo 1 >work/value && git commit -qam other && git checkout -q main
round 1 'echo 9 >work/value && git commit -qam mine; git rebase other >/dev/null 2>&1; true'
climb
check "the rebase is gone" test ! -d .git/rebase-merge -a ! -d .git/rebase-apply
check "and HEAD is back on the branch" test "$(git symbolic-ref HEAD)" = refs/heads/climb/t

project "empty rounds and patience" <<<'budget: {usd: 5}'
climb --patience 2
check "stops with exit 0" exited 0
check "after two empty rounds" test "$(jl '[.[] | .status] | join(" ")')" = "baseline empty empty"
check "summary says patience" test "$(jq -r .stop .arx/climb/t/summary.json)" = patience
check "the agent hears it changed nothing" has fake/argv-02 'You changed nothing in work/.'

project "crashes" <<<'eval: {command: eval/score, files: [eval/], timeout: 1}
budget: {usd: 5, rounds: 4}'
round 1 'echo exit >work/value'
round 2 'echo 1e999 >work/value'
round 3 'echo none >work/value'
round 4 'echo slow >work/value'
climb
check "every one is a crash" test "$(jl '[.[1:][] | .status] | join(" ")')" = "crash crash crash crash"
check "and reverts" test "$(cat work/value)" = 10
check "a non-zero exit" has fake/argv-02 'The evaluation failed: exit 1. Its last line:'
check "with the scorer's output" grep -qx boom fake/argv-02
check "a score that is not finite" has fake/argv-03 'its score is not a finite number: 1e999'
check "no score line" has fake/argv-04 'it printed no line that matches eval.pattern'
check "a run past eval.timeout" test "$(jl '.[4].error')" = "it ran past eval.timeout (1s)"
check "is stopped at the timeout" test "$(jl '.[4].eval_secs < 5')" = true
check "its log is kept" test -f .arx/climb/t/logs/4-1.log

project "usage errors" <<<'budget: {usd: 5, rounds: 1}'
echo 11 >work/value
climb
check "dirty change paths exit 2" exited 2
check "and say what to commit" has err.txt 'commit or stash these first'
git checkout -q work/value
sed -i.bak 's/usd: 5, //' climb.yaml && rm climb.yaml.bak && git commit -qam no-budget
climb
check "no budget exits 2" exited 2
check "and says how to set one" has err.txt 'set a budget: budget.usd, budget.tokens or budget.wall in climb.yaml, or --cap usd=5'
climb --cap usd=1 --rounds 1 --name t1
check "a --cap is a budget" exited 0
printf 'change: [work/]\neval: {goal: up}\n' >bad.yaml
climb --config bad.yaml --cap usd=1
check "a bad climb.yaml exits 2" exited 2
check "with arx check's message" has err.txt 'bad.yaml:2: eval.goal: must be min or max'
mkdir -p .arx/climb/lock && echo $$ >.arx/climb/lock/pid && echo other >.arx/climb/lock/run
climb --cap usd=1 --rounds 1 --name t2
check "another climb's lock exits 2" exited 2
check "and names it" has err.txt 'another climb (other) runs here'
sh -c 'exit 0' & dead=$!
wait "$dead"
echo "$dead" >.arx/climb/lock/pid
climb --cap usd=1 --rounds 1 --name t3
check "a lock whose climb is gone is taken over" exited 0
check "and released at the end" test ! -e .arx/climb/lock
climb --cap usd=1 --resume nope
check "an unknown run exits 2" exited 2
plain=$(mktemp -d "${TMPDIR:-/tmp}/ar-plain.XXXXXX")
cp climb.yaml "$plain/" && cd "$plain" || exit 1
climb --cap usd=1
check "no repository exits 2" exited 2
check "and says so" has err.txt 'not a git repository'
cd "$WS" || exit 1

project "warnings" <<<'budget: {usd: 5, rounds: 1}'
script hooks/stop <<<'#!/bin/sh'
git add -A && git commit -qm hook
climb --dry-run
check "a stop hook is named" has err.txt 'the spec has a stop hook (hooks/stop) that can keep a round going.'
check "a dry run exits 0" exited 0
check "scores the baseline" test "$(jl '.[0].status')" = baseline
check "starts no round" test ! -e fake/argv-01
check "and leaves no branch" test -z "$(git branch --list 'climb/*')"
noisy 10 11 10
climb --dry-run --name t2
check "a noisy scorer gets a warning" has err.txt 'the score varies by 1.0000 between runs of the same commit; set eval.repeats, eval.confirm or eval.min_delta'

summary
