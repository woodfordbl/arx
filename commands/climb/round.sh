# round.sh: the round loop of arx climb, its stop conditions, and the
# status, stop and rm commands. Sourced by arx-climb.

# INT and TERM: stop the agent and the evaluation; the loop then restores
# the change paths, writes the summary and exits 130. arx gets TERM, not a
# second INT, which would make it exit at once.
on_signal() {
  interrupted=1
  [ -z "$agent_pid" ] || kill -TERM "$agent_pid" 2>/dev/null
  [ -z "$eval_pid" ] || kill -TERM -- "-$eval_pid" 2>/dev/null
}

cleanup() {
  [ -z "$eval_pid" ] || kill -KILL -- "-$eval_pid" 2>/dev/null
  [ -z "$watch_pid" ] || kill -KILL -- "-$watch_pid" 2>/dev/null
  [ -z "$agent_pid" ] || kill -TERM "$agent_pid" 2>/dev/null
  [ -z "$tmp" ] || rm -rf "$tmp"
  [ "$locked" -eq 0 ] || rm -rf "$lock"
}

# Sets the stop reason; the loop ends at its next check.
halt() { [ -n "$stop_code" ] || stop_code=$1 stop_reason=$2; }

# Records the session id once it is known, so `arx climb stop` can reach it.
note_session() {
  [ "$quiet" -eq 1 ] || echo "climb $name · session $session (follow it with \`arx watch $session\`)" >&2
  jq --arg s "$session" '.session = $s' "$dir/climb.json" >"$tmp/climb.json" &&
    mv -f "$tmp/climb.json" "$dir/climb.json"
  write_summary running
}

# Runs one round of the agent in the background, so a signal reaches climb
# at once. Sets `code` to arx's exit code.
run_agent() {
  local args=(--json --quiet) turns=$((s_turns + r_turns)) wall=$r_wall left i=0 now last
  if [ -z "$session" ]; then args+=(-p "$c_task

$msg"); else args+=(--resume "$session" -p "$msg"); fi
  args+=(${spec_args[@]+"${spec_args[@]}"} --set "limits.max_turns=$turns" --cap "turns=$turns")
  if [ -n "$b_wall" ]; then
    left=$((b_wall - $(date +%s) + start_epoch - reserve))
    [ "$left" -ge "$wall" ] || wall=$left
  fi
  [ "$wall" -ge 1 ] || wall=1
  args+=(--cap "wall=$wall")
  [ -z "$b_usd" ] || args+=(--cap "usd=$(jq -n --argjson c "$s_cost" --argjson b "$b_usd" --argjson s "$spent_usd" '$c + $b - $s')")
  [ -z "$b_tokens" ] || args+=(--cap "tokens=$((s_tokens + b_tokens - spent_tokens))")
  args+=(${c_caps[@]+"${c_caps[@]}"})
  ls .arx/sessions 2>/dev/null | sort >"$tmp/sessions.before"
  last=$(readlink .arx/sessions/last 2>/dev/null)
  "$arx" "${args[@]}" >"$tmp/result.json" 2>"$tmp/agent.err" </dev/null &
  agent_pid=$!
  while [ -z "$session" ] && [ "$i" -lt 100 ] && kill -0 "$agent_pid" 2>/dev/null; do
    now=$(readlink .arx/sessions/last 2>/dev/null)
    if [ -n "$now" ] && [ "$now" != "$last" ]; then session=$now; note_session; fi
    sleep 0.05
    i=$((i + 1))
  done
  wait_child "$agent_pid"
  code=$?
  agent_pid=""
  [ ! -s "$tmp/agent.err" ] || cp "$tmp/agent.err" "$dir/logs/$round-agent.log"
}

# Reads the round's JSON result: the round's turns, tokens and cost (with
# sessions that started during the round, such as subagents), the session
# totals, the budget spent, and `note`, the first line of final_output.
account() {
  local res subs="" s own
  res=$(jq -c 'select(type == "object")' "$tmp/result.json" 2>/dev/null | head -n 1)
  [ -n "$res" ] || res='{}'
  own=$(printf '%s' "$res" | jq -r '.session // empty')
  ls .arx/sessions 2>/dev/null | sort >"$tmp/sessions.after"
  for s in $(comm -13 "$tmp/sessions.before" "$tmp/sessions.after"); do
    case "$s" in last | "$session" | "$own") ;; *) subs="$subs .arx/sessions/$s/meta.json" ;; esac
  done
  subs=$(if [ -n "$subs" ]; then cat $subs 2>/dev/null; fi | jq -sc .)
  eval "$(jq -nr --argjson r "$res" --argjson subs "$subs" \
    --argjson t "$s_turns" --argjson c "$s_cost" --argjson k "$s_tokens" --argjson code "$code" \
    --argjson su "$spent_usd" --argjson st "$spent_tokens" \
    --argjson bu "${b_usd:-null}" --argjson bt "${b_tokens:-null}" '
    ($r.turns // $t) as $turns | ($r.cost // $c) as $cost
    | (if $r.tokens then ($r.tokens.input // 0) + ($r.tokens.output // 0) else $k end) as $tokens
    | ($cost - $c + ([$subs[].cost // 0] | add // 0)) as $dc
    | ($tokens - $k + ([$subs[] | (.tokens_in // 0) + (.tokens_out // 0)] | add // 0)) as $dt
    | {session: ($r.session // ""), exit: $code, status: ($r.status // ""),
       turns: ($turns - $t), tokens: $dt, cost: $dc} as $agent
    | @sh "a_session=\($agent.session) agent_json=\($agent | tojson)",
      @sh "s_turns=\($turns) s_cost=\($cost) s_tokens=\($tokens)",
      @sh "spent_usd=\($su + $dc) spent_tokens=\($st + $dt)",
      @sh "over=\(if $bu != null and $su + $dc >= $bu then "usd"
        elif $bt != null and $st + $dt >= $bt then "tokens" else "" end)",
      @sh "note=\(($r.final_output // "") | split("\n")
        | map(select(test("\\S"))) | (.[0] // "") | .[0:120])"')"
}

# True when the best has reached budget.target.
at_target() {
  [ -n "$b_target" ] && jq -ne --argjson B "$B" --argjson t "$b_target" \
    --arg goal "$e_goal" "$climb_jq"'($B | median) as $b
    | if $goal == "min" then $b <= $t else $b >= $t end' >/dev/null
}

# Checks the stop conditions before a round. Returns 1 to stop.
before_round() {
  [ "$interrupted" -eq 0 ] || halt 130 interrupted
  [ ! -f "$dir/stop" ] || halt 0 stopped
  [ "$over" != usd ] || halt 3 cap:usd
  [ "$over" != tokens ] || halt 3 cap:tokens
  if [ -n "$b_wall" ] && [ $(($(date +%s) - start_epoch + reserve)) -ge "$b_wall" ]; then halt 3 cap:wall; fi
  ! at_target || halt 0 target
  [ -z "$b_rounds" ] || [ "$started" -lt "$b_rounds" ] || halt 0 rounds
  [ -z "$b_patience" ] || [ "$no_keep" -lt "$b_patience" ] || halt 0 patience
  [ -z "$stop_code" ]
}

# Ends a round early: restores the change paths and records an abort.
abort_round() {
  git_revert
  record abort "[]" "$1" "" "$tamper" false "$outside" "" "" ""
  halt "$2" "$3"
}

# Everything after the agent stops: fold git back, repair the scorer, take
# the snapshot, score it, keep or revert, record. Returns 1 to stop.
after_round() {
  local why="" lines=""
  account
  [ -n "$session" ] || [ -z "$a_session" ] || { session=$a_session; note_session; }
  git_fold || { halt 1 error; warn "a git step failed at the end of round $round"; return 1; }
  tamper=$(git_repair_eval) || { halt 1 error; warn "cannot restore eval.files"; return 1; }
  outside=$(git_outside)
  [ "$interrupted" -eq 0 ] || code=130
  case "$code" in
    2) sed 's/^/  /' "$tmp/agent.err" >&2
       abort_round "arx exited 2" 2 usage
       warn "arx exited 2 in round $round: the spec or a flag no longer works (above)"
       return 1 ;;
    4) abort_round "arx exited 4" 4 auth; return 1 ;;
    5) abort_round "arx exited 5" 5 policy; return 1 ;;
    130) abort_round "interrupted" 130 interrupted; return 1 ;;
    1) errors=$((errors + 1)) ;;
    *) errors=0 ;;
  esac
  git_snapshot || { halt 1 error; warn "cannot commit round $round"; return 1; }
  rescored=false
  if [ "$e_rescore" -gt 0 ] && [ $((round % e_rescore)) -eq 0 ]; then rescore; fi
  if [ -n "$b_wall" ] && [ $(($(date +%s) - start_epoch)) -ge "$b_wall" ]; then
    abort_round "the wall budget ran out before the evaluation" 3 cap:wall
    return 1
  fi
  vs="" runs="[]" secs_list=""
  if [ -z "$target" ]; then status=empty; else evaluate; vs=$cur_b; fi
  if [ "$interrupted" -eq 1 ]; then
    abort_round "interrupted" 130 interrupted
    return 1
  fi
  case "$status" in
    keep) git_keep || { halt 1 error; return 1; }
          B=$runs best_round=$round no_keep=0
          [ "$h_when" != keep ] || holdout "$best" keep ;;
    empty) no_keep=$((no_keep + 1)) ;;
    *) git_revert || { halt 1 error; return 1; }
       no_keep=$((no_keep + 1)) ;;
  esac
  if [ "$status" = crash ]; then
    why=$run_why
    [ "$e_show" -eq 0 ] || lines=$(tail -n "$e_show" "$run_log" 2>/dev/null)
  fi
  record "$status" "$runs" "$why" "$lines" "$tamper" "$rescored" "$outside" \
    "$files" "$target" "$secs_list"
  write_summary running
  [ "$errors" -lt 3 ] || halt 1 error
  [ -z "$stop_code" ]
}

# The climb: the baseline, then rounds until a stop condition.
climb() {
  local code status tamper outside rescored files target
  [ "$quiet" -eq 1 ] || echo "climb $name · branch $branch · isolation none" >&2
  isolation_warning
  if ! baseline; then
    if [ "$interrupted" -eq 1 ]; then halt 130 interrupted; else halt 1 error; fi
    finish
  fi
  reserve=$(jq -nr --arg s "$secs_list" --argjson n "$e_repeats" \
    '$s | split(" ") | map(select(length > 0) | tonumber) | (add / length * $n) | ceil')
  [ "$round" -gt 0 ] || holdout "$best" baseline
  write_summary running
  if [ "$dry" -eq 1 ]; then
    halt 0 dry-run
    finish
  fi
  round_base=$round round=$((round + 1))
  start_message
  round=$((round - 1))
  while before_round; do
    round=$((round + 1)) started=$((started + 1))
    run_agent
    after_round || break
  done
  finish
}

# Ends the climb: the final holdout, summary.json and the result line, then
# exits with the stop code.
finish() {
  if [ -n "$h_command" ] && [ "$dry" -eq 0 ] && [ "$stop_reason" != interrupted ] &&
    ! grep -q "\"commit\":\"${best:0:7}\"" "$dir/holdout.jsonl"; then
    holdout "$best" best
  fi
  write_summary "done" "$stop_reason" "$stop_code"
  [ "$quiet" -eq 1 ] || jq -r --arg branch "$branch" "$climb_jq"'
    "climb \(.run) stopped (\(.stop)) after \(.rounds) rounds, exit \(.exit). Best \(.best | num) from "
    + "\(.best_round | from) (\(.kept) kept), baseline \(.baseline | num). \(.rounds as $r
    | if $r > 0 then "The branch \($branch) holds only kept changes." else "" end)"' \
    "$dir/summary.json" >&2
  [ "$json" -eq 0 ] || cat "$dir/summary.json"
  exit "$stop_code"
}

# Prints the run name for RUN or last, or says why there is none.
resolve_run() {
  local r=${1:-last}
  if [ "$r" = last ]; then
    r=$(readlink .arx/climb/last 2>/dev/null) || { echo "arx climb: no climb in this folder yet" >&2; return 1; }
  fi
  case "$r" in "" | */* | .*) echo "arx climb: no run named $r" >&2; return 1 ;; esac
  [ -d ".arx/climb/$r" ] || { echo "arx climb: no run $r in .arx/climb/" >&2; return 1; }
  echo "$r"
}

# Prints the pid of the climb that runs RUN here, if one does.
running_pid() {
  local pid
  [ "$(cat .arx/climb/lock/run 2>/dev/null)" = "$1" ] || return 1
  pid=$(cat .arx/climb/lock/pid 2>/dev/null)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}

cmd_status() {
  local run="" as_json=0 a d
  for a in "$@"; do
    case "$a" in --json) as_json=1 ;; -*) usage_error "unknown option $a" ;; *) run=$a ;; esac
  done
  d=.arx/climb/$(resolve_run "${run:-last}") || exit 2
  [ -f "$d/summary.json" ] || die 1 "$d has no summary.json yet"
  if [ "$as_json" -eq 1 ]; then cat "$d/summary.json"; return; fi
  print_status "$d" "$(running_pid "$(basename "$d")")"
}

cmd_stop() {
  local run session
  run=$(resolve_run "${1:-last}") || exit 2
  running_pid "$run" >/dev/null || { echo "climb $run is not running."; return 0; }
  : >".arx/climb/$run/stop"
  session=$(jq -r '.session // empty' ".arx/climb/$run/summary.json" 2>/dev/null)
  [ -z "$session" ] || "$arx" ctl "$session" stop >/dev/null 2>&1
  echo "Asked climb $run to stop: the agent ends its current turn, climb scores that round, then stops."
}

cmd_rm() {
  local run="" yes=0 a answer
  for a in "$@"; do
    case "$a" in --yes) yes=1 ;; -*) usage_error "unknown option $a" ;; *) run=$a ;; esac
  done
  [ -n "$run" ] || usage_error "arx climb rm needs a run name (arx climb status shows the last)"
  [ "$run" != last ] || run=$(resolve_run last) || exit 2
  case "$run" in */* | .*) die 2 "no run named $run" ;; esac
  ! running_pid "$run" >/dev/null || die 2 "climb $run is running; stop it first with \`arx climb stop $run\`"
  [ "$(git symbolic-ref -q HEAD)" != "refs/heads/climb/$run" ] ||
    die 2 "HEAD is on climb/$run; check out another branch first, such as \`git checkout main\`"
  if [ "$yes" -eq 0 ]; then
    [ -t 0 ] || die 1 "not a terminal, so nothing changed; add --yes to remove climb $run"
    read -r -p "Remove the branch climb/$run, its refs/climb/$run/ candidates and .arx/climb/$run/? [y/N] " answer
    case "$answer" in y | Y | yes) ;; *) echo "Nothing changed."; exit 1 ;; esac
  fi
  git for-each-ref --format='%(refname)' "refs/climb/$run/" | while read -r a; do git update-ref -d "$a"; done
  ! git rev-parse -q --verify "refs/heads/climb/$run" >/dev/null || git branch -D -q "climb/$run"
  rm -rf ".arx/climb/$run"
  [ "$(readlink .arx/climb/last 2>/dev/null)" != "$run" ] || rm -f .arx/climb/last
  echo "Removed climb $run."
}
