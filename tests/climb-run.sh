#!/usr/bin/env bash
# climb-run.sh: tests `arx climb` with a stub agent (tests/climb-agent):
# noise (repeats, confirm, min_delta, rescore), eval.compare, budgets,
# errors, `arx climb stop`, Ctrl-C and TERM, --resume, holdout, --json,
# status and rm, and one climb with the real arx and tests/fake-curl. Run
# with `make test`.
set -u
. "$(dirname "$0")/climb-lib.sh"

# The scores of each round, as "r1 r2 ...", where r is the runs joined by ,.
round_runs() { jl '[.[] | select(.round > 0 and .status != "rescore") | .scores | map(tostring) | join(",")] | join(" ")'; }

project "repeats and the median" <<<'eval: {command: eval/score, files: [eval/], repeats: 3}
budget: {usd: 5, rounds: 1}'
noisy 10 10 10 9 20 8
round 1 'echo 1 >work/value'
climb
check "three runs per candidate" test "$(round_runs)" = "9,20,8"
check "the median decides: a keep" test "$(jl '.[1] | "\(.status) \(.score)"')" = "keep 9"

project "confirm" <<<'eval: {command: eval/score, files: [eval/], confirm: 2}
budget: {usd: 5, rounds: 3}'
noisy 10 10 10 12 9 11 12 9 8 9
for n in 1 2 3; do round $n "echo $n >work/value"; done
climb
check "only a likely winner gets confirm runs" test "$(round_runs)" = "12 9,11,12 9,8,9"
check "and the median of all decides" test "$(jl '[.[1:][] | .status] | join(" ")')" = "revert revert keep"

project "min_delta" <<<'eval: {command: eval/score, files: [eval/], min_delta: 1}
budget: {usd: 5, rounds: 2}'
noisy 10 10 10 9.5 8.9
round 1 'echo 1 >work/value'
round 2 'echo 2 >work/value'
climb
check "a number: 9.5 does not beat 10 by more than 1" test "$(jl '[.[1:][] | .status] | join(" ")')" = "revert keep"
sed 's/min_delta: 1/min_delta: 10%/' climb.yaml >pct.yaml
printf '%s\n' 10 10 10 9.5 8.9 >"$FAKE_DIR/scores" && rm "$FAKE_DIR/n"
round 3 'echo 3 >work/value'
round 4 'echo 4 >work/value'
climb --config pct.yaml --name t2
check "a percent of the best does the same" test "$(jl '[.[1:][] | .status] | join(" ")')" = "revert keep"
check "the agent hears the margin" has fake/argv-04 'To be kept, a change must beat the best by more than 1.0000 (10%); lower is better.'

project "rescore" <<<'eval: {command: eval/score, files: [eval/], rescore: 2}
budget: {usd: 5, rounds: 3}'
noisy 10 10 10 11 9 12 13
for n in 1 2 3; do round $n "echo $n >work/value"; done
climb
check "round 2 scores the best again" test "$(jl -c '[.[] | select(.status == "rescore") | [.round, .scores, .commit == .best_commit]]')" = '[[2,[9],true]]'
check "then the round's own candidate" test "$(jl -r '.[] | select(.round == 2 and .status == "revert") | "\(.scores) \(.commit == .best_commit) \(.note)"')" = "[12] false idea 02"
check "rounds and rescores alike" test "$(round_runs)" = "11 12 13"
check "the agent hears it" has fake/argv-03 'The best was measured again: 10.0000 (4 runs).'

project "eval.compare" <<<'eval: {command: eval/score, files: [eval/], compare: eval/compare, confirm: 1}
budget: {usd: 5, rounds: 5}'
script eval/compare <<'EOF'
#!/bin/sh
cat >>"$FAKE_DIR/compare.in"
n=$(($(cat "$FAKE_DIR/cn" 2>/dev/null || echo 0) + 1))
echo "$n" >"$FAKE_DIR/cn"
answer=$(sed -n "${n}p" "$FAKE_DIR/answers")
[ "$answer" != fail ] || { echo keep; exit 3; }
echo "$answer"
EOF
git add -A && git commit -qm compare
noisy 10 10 10 11 11 11 11 11 11
printf '%s\n' keep revert more keep maybe fail >"$FAKE_DIR/answers"
for n in 1 2 3 4 5; do round $n "echo $n >work/value"; done
climb
check "keep, revert, more then keep" test "$(jl '[.[1:][] | .status] | join(" ")')" = "keep revert keep revert revert"
check "more runs the confirm runs" test "$(round_runs)" = "11 11 11,11 11 11"
check "and asks again at stage final" has fake/compare.in '"stage":"final"'
check "with both lists" has fake/compare.in '"best":[11],"candidate":[11,11]'
check "an unknown answer reverts with a warning" has err.txt 'eval.compare answered "maybe" (exit 0) at stage first, so round 4 reverts'
check "so does a failed program" has err.txt '(exit 3) at stage first, so round 5 reverts'

project "caps for each round" <<<'budget: {usd: 5, tokens: 100000, rounds: 2}'
climb --round turns=5
argv() { sed -n "/^$2\$/{n;p;}" "fake/argv-$1" | tr '\n' ' '; }
check "round 1: turns, wall, usd and tokens" test "$(argv 01 --cap)" = "turns=5 wall=1800 usd=5 tokens=100000 "
check "and limits.max_turns" test "$(argv 01 --set)" = "limits.max_turns=5 "
check "round 2 adds the session's turns" test "$(argv 02 --cap)" = "turns=7 wall=1800 usd=5 tokens=100000 "

project "budget.usd" <<<'budget: {usd: 0.025}'
climb
check "a spent budget exits 3" exited 3
check "after the round that spent it" test "$(jq -r '"\(.stop) \(.rounds) \(.cost)"' .arx/climb/t/summary.json)" = "cap:usd 3 0.03"
climb --name t2 --cap usd=1 --cap tokens=2500
check "budget.tokens too" test "$(jq -r '"\(.stop) \(.rounds) \(.tokens)"' .arx/climb/t2/summary.json)" = "cap:tokens 3 3300"

project "budget.target" <<<'budget: {usd: 5}'
for n in 9 8 7; do round $((10 - n)) "echo $n >work/value"; done
climb --target 8
check "stops when the best reaches it" test "$(jq -r '"\(.stop) \(.exit) \(.rounds) \(.best)"' .arx/climb/t/summary.json)" = "target 0 2 8"

project "budget.wall" <<<'budget: {wall: 3}'
round 1 'echo 8 >work/value; sleep 3'
climb
check "a round that spends it is not scored" test "$(jq -r '"\(.stop) \(.exit) \(.aborted)"' .arx/climb/t/summary.json)" = "cap:wall 3 1"
check "and is reverted" test "$(cat work/value)" = 10
check "the round got the time left" grep -qE '^wall=[12]$' fake/argv-01

project "errors" <<<'budget: {usd: 5}'
for n in 1 2 3; do echo 1 >"$FAKE_DIR/round-0$n.exit"; done
climb
check "three arx errors in a row exit 1" exited 1
check "each is still scored" test "$(jl '[.[1:][] | .status] | join(" ")')" = "empty empty empty"
project "exit 4" <<<'budget: {usd: 5}'
round 1 'echo 8 >work/value'
echo 4 >"$FAKE_DIR/round-01.exit"
climb
check "arx exiting 4 stops at once" test "$code $(jl '.[1].status')" = "4 abort"
check "and restores the change paths" test "$(cat work/value)" = 10

project "arx climb stop" <<<'budget: {usd: 5}'
round 1 "echo 8 >work/value; sleep 0.5; \"$CLIMB\" stop >fake/stop.out"
climb
check "ends the climb after the round, exit 0" test "$code $(jq -r .stop .arx/climb/t/summary.json)" = "0 stopped"
check "the round is scored" test "$(jl '.[1].status')" = keep
check "no round follows" test ! -e fake/argv-02
check "the session got arx ctl stop" has .arx/sessions/stub-01/inbox '"cmd":"stop"'
check "and says what happens" has fake/stop.out 'Asked climb t to stop'

# start_slow SIGNAL TARGET: a climb whose round 1 sleeps; sends SIGNAL to
# the climb's process group (group) or to climb alone (climb).
start_slow() {
  round 1 'echo 8 >work/value; : >fake/started; exec sleep 30'
  set -m
  ARX_BIN=$ROOT/tests/climb-agent "$CLIMB" --name t >out.txt 2>err.txt </dev/null &
  pid=$!
  set +m
  for _ in $(seq 100); do [ -f fake/started ] && break; sleep 0.1; done
  if [ "$2" = group ]; then kill "-$1" -- "-$pid"; else kill "-$1" "$pid"; fi
  wait "$pid"
  code=$?
}
project "Ctrl-C" <<<'budget: {usd: 5}'
start_slow INT group
check "exits 130" exited 130
check "restores the change paths" test "$(cat work/value)" = 10
check "writes the summary" test "$(jq -r '"\(.status) \(.stop)"' .arx/climb/t/summary.json)" = "done interrupted"
project "TERM" <<<'budget: {usd: 5}'
start_slow TERM climb
check "TERM to climb alone stops the agent too" test "$code $(cat work/value)" = "130 10"

project "resume" <<<'budget: {usd: 5, rounds: 2}'
round 1 'echo 8 >work/value'
round 2 'echo 9 >work/value'
climb
round 3 'echo 7 >work/value'
climb --resume last --rounds 1 --cap usd=2
check "exits 0" exited 0
check "continues the session" grep -qx stub-01 fake/argv-03
check "scores the best again first" test "$(jl -c '[.[] | select(.status == "baseline") | .round]')" = "[0,2]"
check "counts the rounds from the resume" test "$(jq -r '"\(.stop) \(.rounds) \(.kept)"' .arx/climb/t/summary.json)" = "rounds 3 2"
check "and the money" grep -qx 'usd=2.02' fake/argv-03
check "the message counts on" has fake/argv-03 '[arx climb] Round 3 of 3.'
climb --resume last --rounds 1 --new-session
check "--new-session starts a fresh one with the task" test "$(sed -n 3p fake/argv-04)" = -p
check "  (no --resume)" lacks fake/argv-04 '--resume'
climb --resume last --name x
check "a resume takes only budget flags" exited 2

project "holdout" <<<'holdout: {command: eval/score --holdout}
budget: {usd: 5, rounds: 1}'
round 1 'echo 8 >work/value'
climb --json
check "runs on the baseline and the final best" test "$(jq -rs '[.[] | .for] | join(" ")' .arx/climb/t/holdout.jsonl)" = "baseline best"
check "is in the summary" test "$(jq -c .holdout out.txt)" = '{"baseline":4242,"best":4242}'
check "and never in a round message" sh -c '! grep -q 4242 fake/argv-*'
check "--json prints every summary field" jq -e 'has("run") and has("status") and has("stop") and has("exit") and has("rounds") and has("kept") and has("reverted") and has("crashed") and has("empty") and has("baseline") and has("best") and has("best_commit") and has("holdout") and has("branch") and has("session") and has("cost") and has("tokens") and has("secs") and has("isolation")' out.txt
"$CLIMB" status >out.txt 2>&1
check "status names the run and how it ended" has out.txt 'climb t: done (stop: rounds, exit 0)'
check "status --json is summary.json" sh -c '"$0" status --json | cmp -s - .arx/climb/t/summary.json' "$CLIMB"
"$CLIMB" rm t --yes >out.txt 2>&1
code=$?
check "rm refuses while HEAD is on the branch" exited 2
git checkout -q main
"$CLIMB" rm t </dev/null >out.txt 2>&1
code=$?
check "rm asks first (no terminal: nothing changes)" test "$code $(git branch --list climb/t | wc -l | tr -d ' ')" = "1 1"
"$CLIMB" rm t --yes >out.txt 2>&1
check "rm removes the branch" test -z "$(git branch --list climb/t)"
check "  its candidates" test -z "$(git for-each-ref refs/climb/t/)"
check "  and the run folder" test ! -e .arx/climb/t -a ! -L .arx/climb/last

project "end to end with arx" <<<'budget: {usd: 1, rounds: 2}'
sse_tool bash '{\"command\":\"echo 7 >work/value\"}' | reply 1 "200 OK"
sse_text "Lowered it to 7." | reply 2 "200 OK"
sse_text "Nothing better." | reply 3 "200 OK"
ARX_BIN=$ARX "$CLIMB" --name t >out.txt 2>err.txt </dev/null
code=$?
check "exits 0" exited 0
check "keeps the agent's change, labeled with its reply" test "$(jl '.[1] | "\(.status) \(.score) \(.note)"')" = "keep 7 Lowered it to 7."
check "round 2 resumes the same session" test "$(ls .arx/sessions | grep -vc last)" = 1
check "and the model hears the result" has fake/req-03.json '[arx climb] Round 1 of 2: your change to work/ was kept.'
check "an empty round 2" test "$(jl '.[2].status')" = empty

# The TSP example under arx climb, with the real arx and a scripted model:
# the agent's only command copies in a 2-opt solver. It never runs a scorer.
begin "the TSP example, to the end of a budget"
rm agent.yaml && cp -R "$ROOT/examples/tsp/." . && rm harness/hooks/stop
printf 'results.tsv\nnotes.md\nrun.log\n.arx/\nfake/\n*.txt\n' >.gitignore
git init -q && git symbolic-ref HEAD refs/heads/main && git add -A && git commit -qm baseline
cat >fake/solve.py <<'EOF'
import math, sys, time
start = time.time()
data = sys.stdin.read().split()
n = int(data[0])
pts = [(float(data[1 + 2 * i]), float(data[2 + 2 * i])) for i in range(n)]
left, tour = set(range(1, n)), [0]
while left:
    x, y = pts[tour[-1]]
    j = min(left, key=lambda k: (pts[k][0] - x) ** 2 + (pts[k][1] - y) ** 2)
    tour.append(j)
    left.remove(j)
d = lambda a, b: math.dist(pts[a], pts[b])
improved = True
while improved and time.time() - start < 0.5:  # 2-opt within a window
    improved = False
    for i in range(1, n - 1):
        for j in range(i + 1, min(i + 30, n)):
            a, b, c, e = tour[i - 1], tour[i], tour[j], tour[(j + 1) % n]
            if d(a, c) + d(b, e) < d(a, b) + d(c, e) - 1e-12:
                tour[i:j + 1] = reversed(tour[i:j + 1])
                improved = True
print("\n".join(map(str, tour)))
EOF
sse_tool bash '{\"command\":\"cp fake/solve.py work/solve.py\"}' | reply 1 "200 OK"
sse_text "2-opt within a window of 30." | reply 2 "200 OK"
sse_text "No better idea yet." | reply 3 "200 OK"
OPENROUTER_API_KEY=test ARX_BIN=$ARX "$CLIMB" --name t --set model=test-model \
  --cap usd=0.0025 >out.txt 2>err.txt </dev/null
code=$?
check "stops at the end of the budget, exit 3" test "$code $(jq -r .stop .arx/climb/t/summary.json)" = "3 cap:usd"
check "keeps the 2-opt solver: a lower score" test "$(jl '"\(.[1].status) \(.[1].score < .[0].score)"')" = "keep true"
check "round 2 changed nothing" test "$(jl '.[2].status')" = empty
check "the agent never ran a scorer" test "$(jq -rs '[.[] | .tool_calls[]? | .function.arguments] | unique | join(" ")' .arx/sessions/*/transcript.jsonl)" = '{"command":"cp fake/solve.py work/solve.py"}'
check "the branch holds the kept solver" sh -c 'git show climb/t:work/solve.py | cmp -s - fake/solve.py'
check "the holdout scored the start and the best" test "$(jq -r '[.holdout.baseline > .holdout.best, .best < .baseline] | map(tostring) | join(" ")' .arx/climb/t/summary.json)" = "true true"

summary
