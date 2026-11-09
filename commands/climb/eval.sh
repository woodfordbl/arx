# eval.sh: the official evaluation, sourced by arx-climb. Each run scores
# one commit in a fresh export outside the project: the commit's files,
# then eval.files from the pinned commit EVAL on top, so edits the agent
# made to its copy of the scorer never count. Each run gets its own process
# group, which a watcher stops at eval.timeout (macOS has no `timeout`).

# Waits for background child $1 and returns its exit code. A trapped signal
# interrupts `wait`; the child is still running then, so wait again.
wait_child() {
  local rc
  while :; do
    wait "$1"
    rc=$?
    if [ "$rc" -gt 128 ] && kill -0 "$1" 2>/dev/null; then continue; fi
    return "$rc"
  done
}

# Fills the new folder $1 with commit $2, then eval.files from EVAL.
export_to() {
  local f
  mkdir -p "$1" && git archive "$2" | tar -xf - -C "$1" || return 1
  [ "$n_files" -gt 0 ] || return 0
  for f in "${e_files[@]}"; do rm -rf "${1:?}/${f%/}"; done
  git archive "$eval_commit" -- "${e_files[@]}" | tar -xf - -C "$1"
}

# Runs command $5 once on commit $1 as kind $2, round $3, repeat $4. Sets
# run_score (a JSON number) and run_secs, or returns 1 with run_why set.
# The output goes to logs/R-K.log (logs/R-KIND-K.log for other kinds).
eval_run() {
  local ex=$tmp/export rc line raw out t0 log=$dir/logs/$3-$4.log
  case "$2:$3" in candidate:* | baseline:0) ;; *) log=$dir/logs/$3-$2-$4.log ;; esac
  run_log=$log
  run_score="" run_why="" run_secs=0
  rm -rf "$ex" "$tmp/timed_out"
  if ! export_to "$ex" "$1" 2>"$log"; then
    run_why="climb could not export $1 (see $log)"
    return 1
  fi
  t0=$(jq -n now)
  set -m
  (
    cd "$ex" || exit 1
    for v in $(env | sed -n 's/^\(ARX_SESSION[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
    export ARX_CLIMB_RUN=$name ARX_CLIMB_ROUND=$3 ARX_CLIMB_KIND=$2 \
      ARX_CLIMB_REPEAT=$4 ARX_CLIMB_COMMIT=$1 ARX_BIN=$arx
    exec sh -c "$5"
  ) >"$tmp/out" 2>"$tmp/err" </dev/null &
  eval_pid=$!
  (sleep "$e_timeout"; : >"$tmp/timed_out"; kill -TERM -- "-$eval_pid"
   sleep 5; kill -KILL -- "-$eval_pid") >/dev/null 2>&1 &
  watch_pid=$!
  set +m
  wait_child "$eval_pid"
  rc=$?
  # Stop what the run left behind, and the watcher.
  kill -KILL -- "-$eval_pid" "-$watch_pid" 2>/dev/null
  wait "$watch_pid" 2>/dev/null
  eval_pid="" watch_pid=""
  { cat "$tmp/out"; [ -s "$tmp/err" ] && printf -- '--- stderr\n' && cat "$tmp/err"; } |
    tail -c 1048576 >"$log"
  rm -rf "$ex"
  line=$(grep -E -- "$e_pattern" "$tmp/out" | tail -n 1)
  raw=""
  if [ -n "$line" ] && [[ $line =~ $e_pattern ]]; then raw=${BASH_REMATCH[1]}; fi
  out=$(jq -nr --arg s "$raw" --argjson t0 "$t0" '(now - $t0),
    (try ($s | tonumber | select(isinfinite or isnan | not)) catch empty)')
  run_secs=${out%%$'\n'*}
  case "$out" in *$'\n'*) run_score=${out#*$'\n'} ;; esac
  if [ "$interrupted" -eq 1 ]; then run_why="interrupted"
  elif [ -f "$tmp/timed_out" ]; then
    run_why="it ran past eval.timeout ($(jq -nr --argjson t "$e_timeout" "$climb_jq"'$t | dur'))"
  elif [ "$rc" -ne 0 ]; then run_why="exit $rc"
  elif [ -z "$raw" ]; then run_why="it printed no line that matches eval.pattern"
  elif [ -z "$run_score" ]; then run_why="its score is not a finite number: $raw"
  else return 0; fi
  run_score=""
  return 1
}

# Runs eval.command $3 more times on commit $1 as kind $2, adding each
# score to `runs` and each duration to `secs_list`. Returns 1 at the first
# crash.
more_runs() {
  local i=0
  while [ "$i" -lt "$3" ]; do
    eval_run "$1" "$2" "$round" "$next_k" "$e_command" || return 1
    if [ "$runs" = "[]" ]; then runs="[$run_score]"; else runs="${runs%]},$run_score]"; fi
    secs_list="$secs_list $run_secs"
    next_k=$((next_k + 1)) i=$((i + 1))
  done
}

# Compares `runs` with the best's runs `B`: sets better (true or false),
# cur_b and cur_c (the medians) and cur_d (the margin to beat).
decide() {
  set -- $(jq -nr --argjson B "$B" --argjson C "$runs" --arg goal "$e_goal" \
    --argjson md "$e_delta" --argjson pct "$e_pct" "$climb_jq"'
    ($B | median) as $b | ($C | median) as $c
    | (if $pct then (if $b < 0 then -$b else $b end) * $md / 100 else $md end) as $d
    | "\(if $goal == "min" then $c < $b - $d else $c > $b + $d end) \($b) \($c) \($d)"')
  better=$1 cur_b=$2 cur_c=$3 cur_d=$4
}

# Asks eval.compare at stage $1 (first or final), in an export of the
# candidate, and prints keep, revert or more. A failed or unknown answer
# is a revert, with a warning.
compare() {
  local ex=$tmp/compare ans="" rc=1
  rm -rf "$ex"
  if export_to "$ex" "$target" 2>/dev/null; then
    jq -nc --arg goal "$e_goal" --argjson d "$cur_d" --arg stage "$1" \
      --argjson best "$B" --argjson candidate "$runs" \
      '{$goal, min_delta: $d, $stage, $best, $candidate}' >"$tmp/compare.in"
    (cd "$ex" && sh -c "$e_compare") <"$tmp/compare.in" >"$tmp/compare.out" \
      2>>"$dir/logs/compare.log"
    rc=$?
    ans=$(tail -n 1 "$tmp/compare.out" | tr -d '[:space:]')
  fi
  rm -rf "$ex"
  case "$rc:$1:$ans" in
    0:first:keep | 0:first:revert | 0:first:more | 0:final:keep | 0:final:revert) echo "$ans" ;;
    *) warn "eval.compare answered \"$ans\" (exit $rc) at stage $1, so round $round reverts"
       echo revert ;;
  esac
}

# Scores the candidate `target` for this round: sets `status` to keep,
# revert or crash, and `runs` to its scores.
evaluate() {
  local ans
  runs="[]" next_k=1 secs_list=""
  more_runs "$target" candidate "$e_repeats" || { status=crash; return; }
  decide
  if [ -n "$e_compare" ]; then
    ans=$(compare first)
    if [ "$ans" = more ]; then
      more_runs "$target" candidate "$((e_confirm > 0 ? e_confirm : 1))" || { status=crash; return; }
      decide
      ans=$(compare final)
    fi
    better=false
    [ "$ans" = keep ] && better=true
  elif [ "$better" = true ] && [ "$e_confirm" -gt 0 ]; then
    more_runs "$target" candidate "$e_confirm" || { status=crash; return; }
    decide
  fi
  if [ "$better" = true ]; then status=keep; else status=revert; fi
}

# Scores the best commit as a baseline (round 0, or the first round of a
# resume) at least 3 times, so the spread shows how noisy the scorer is.
# Returns 1 when a run crashes.
baseline() {
  local n=$((e_repeats + e_confirm)) spread
  [ "$n" -ge 3 ] || n=3
  runs="[]" next_k=1 secs_list=""
  if ! more_runs "$best" baseline "$n"; then
    [ "$interrupted" -eq 0 ] || return 1
    warn "the baseline crashed: $run_why. Fix eval.command first; its output is in $dir/logs/."
    tail -n "$e_show" "$run_log" 2>/dev/null | sed 's/^/  /' >&2
    record crash "$runs" "$run_why" "" "" false "" "" "" "$secs_list"
    return 1
  fi
  B=$runs best_round=$round vs=""
  decide
  spread=$(jq -nr --argjson B "$B" --argjson d "$cur_d" "$climb_jq"'
    ($B | max - min) as $s | if $s > $d then $s | num else empty end')
  [ -z "$spread" ] || warn "the score varies by $spread between runs of the same commit; set eval.repeats, eval.confirm or eval.min_delta"
  agent_json="" note=""
  record baseline "$runs" "" "" "" false "" "" "$best" "$secs_list"
}

# Scores the best again (every eval.rescore rounds) and adds the runs to B,
# which keeps its last 20, so a best that won on a lucky run cannot block
# every later change. Sets `rescored`.
rescore() {
  local runs="[]" next_k=1 secs_list="" agent_json="" note="" vs="" msg
  if more_runs "$best" rescore "$e_repeats"; then
    B=$(jq -nc --argjson B "$B" --argjson R "$runs" '$B + $R | .[-20:]')
    rescored=true
    record rescore "$runs" "" "" "" true "" "" "$best" "$secs_list"
  else
    warn "scoring the best again crashed ($run_why); B stays as it was"
  fi
}

# Runs holdout.command once on commit $1 and appends the result to
# holdout.jsonl, labeled $2 (baseline, keep or best). The agent never sees it.
holdout() {
  [ -n "$h_command" ] || return 0
  local ok=true
  eval_run "$1" holdout "$round" 1 "$h_command" || ok=false
  jq -nc --arg run "$name" --argjson round "$round" --arg for "$2" \
    --arg commit "${1:0:7}" --arg score "$run_score" --arg why "$run_why" \
    --argjson ok "$ok" --argjson secs "${run_secs:-0}" \
    '{v: 1, $run, $round, t: (now | todate), for: $for, $commit,
      score: (if $ok then $score | tonumber else null end),
      status: (if $ok then "ok" else "crash" end),
      why: (if $ok then null else $why end), secs: ($secs * 10 | round / 10)}' \
    >>"$dir/holdout.jsonl"
  [ "$quiet" -eq 1 ] || echo "         holdout   ${run_score:-crash ($run_why)}  ($2, commit ${1:0:7})" >&2
}
