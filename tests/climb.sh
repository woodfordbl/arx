#!/usr/bin/env bash
# climb.sh: tests `arx check --climb`, which reads climb.yaml for
# `arx climb`: the defaults, durations in seconds, and problems with line
# numbers. Run with `make test`.
set -u
. "$(dirname "$0")/lib.sh"

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
check "durations are seconds" test "$(jqo '[.eval.timeout, .budget.wall, .round.wall] | join(" ")')" = "300 7200 1800"
check "defaults are filled in" test "$(jqo '[.eval.goal, .eval.ref, .eval.repeats, .eval.confirm, .eval.show, .round.turns, .holdout.when] | join(" ")')" = "min HEAD 1 0 20 40 end"
check "the default pattern" test "$(jqo .eval.pattern)" = '^score:[[:space:]]*([-+0-9.eE]+)[[:space:]]*$'
check "a percent min_delta" test "$(jqo '[.eval.min_delta, .eval.min_delta_percent] | join(" ")')" = "0.1 true"
check "unset keys are null" test "$(jqo '[.agent.spec, .budget.tokens, .eval.compare, .holdout.command] | map(tostring) | join(" ")')" = "null null null null"
check "the default task names the change paths" test "$(jqo .task)" = "Make one change to work/ that improves the score, then end your turn."
printf 'Lower the score.\n' >task.md
printf 'task: {file: task.md}\nchange: [a, b]\neval: {command: x, min_delta: 2}\nagent: {set: {model: m, limits: {max_turns: 9}}}\n' >climb.yaml
"$ARX" check --climb climb.yaml >out.txt 2>err.txt
check "task from a file" test "$(jqo .task)" = "Lower the score."
check "agent.set keeps its values" test "$(jq -c .agent.set out.txt)" = '{"model":"m","limits":{"max_turns":9}}'
check "a number min_delta" test "$(jqo '[.eval.min_delta, .eval.min_delta_percent] | join(" ")')" = "2 false"
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

summary
