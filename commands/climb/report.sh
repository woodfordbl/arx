# report.sh: what arx climb writes and says, sourced by arx-climb. Numbers
# are formatted in jq, so bash never does floating-point arithmetic.
#   results.jsonl  one line per evaluation (record)
#   results.tsv    the same, for people and the agent's prompt
#   summary.json   the state so far, rewritten after every round
#   the round message the agent gets, and the line per round on stderr

# jq definitions shared by every jq program here and in eval.sh.
climb_jq='
def fixed($k): (if . < 0 then "-" else "" end) as $s
  | (if . < 0 then -. else . end) as $a | pow(10; $k) as $p
  | ($a * $p | round) as $n | ($n / $p | floor) as $i
  | if $k == 0 then "\($s)\($i)"
    else "\($s)\($i).\("0000000000\($n - $i * $p)" | .[-$k:])" end;
def num: if . == null then "-"
  elif (. != 0 and . < 0.001 and . > -0.001) or . >= 1e9 or . <= -1e9
  then tostring else fixed(4) end;
def money: "$" + (if . != 0 and . < 0.01 and . > -0.01 then fixed(4) else fixed(2) end);
def two: tostring | if length < 2 then "0" + . else . end;
def dur: floor as $t
  | if $t >= 3600 then "\($t / 3600 | floor)h\($t % 3600 / 60 | floor | two)m"
    elif $t >= 60 then "\($t / 60 | floor)m\($t % 60 | two)s"
    else "\($t)s" end;
def median: sort | if length == 0 then null
  elif length % 2 == 1 then .[(length - 1) / 2]
  else (.[length / 2 - 1] + .[length / 2]) / 2 end;
def lpad($n): tostring | if length < $n then " " * ($n - length) + . else . end;
def rpad($n): tostring | if length < $n then . + " " * ($n - length) else . end;
def lines: split("\n") | map(select(length > 0));
def secs: (capture("^(?<n>[0-9]+([.][0-9]+)?) *(?<u>ms|s|m|h)?$")
  // error("not a duration: \(.)"))
  | (.n | tonumber) * {"ms": 0.001, "s": 1, "m": 60, "h": 3600}[.u // "s"];
def runs: "\(length) run\(if length == 1 then "" else "s" end): \(map(num) | join(" "))";
def from: if . == 0 then "the starting version" else "round \(.)" end;
def message: . as $m | ($m.best_runs | median) as $b
  | (if $m.goal == "min" then "lower" else "higher" end) as $dir
  | ($m.tail | lines) as $tail
  | (if $m.pct then ($b | if . < 0 then -. else . end) * $m.md / 100 else $m.md end) as $d
  | [ "[arx climb] Round \($m.round)\(if $m.rounds then " of \($m.rounds)" else "" end)"
      + ({start: ".", keep: ": your change to \($m.change) was kept.",
          empty: ": nothing was scored."}[$m.status]
         // ": your change to \($m.change) was reverted."),
      ({start: "The best so far is \($b | num) (\($m.best_runs | runs)), from \($m.best_round | from).",
        keep: "Score \($m.runs | median | num) (\($m.runs | runs)). It is the new best; the change is committed.",
        revert: "Score \($m.runs | median | num) (\($m.runs | runs)). Best \($b | num) (\($m.best_round | from)).",
        crash: "The evaluation failed: \($m.why).\($tail | length
          | if . == 0 then "" elif . == 1 then " Its last line:" else " Its last \(.) lines:" end)\($tail | map("\n" + .) | join(""))",
        empty: "You changed nothing in \($m.change)."}[$m.status]),
      (select($m.status == "revert" or $m.status == "crash")
       | "\($m.change) is back at the best version."),
      ($m.tamper | select(length > 0)
       | "Your edits to \(join(", ")) were undone: arx climb scores with its own copy."),
      (select($m.rescored) | "The best was measured again: \($b | num) (\($m.best_runs | length) runs)."),
      (if $m.compare then "eval.compare decides what is kept; \($dir) is better."
       elif $d > 0 then "To be kept, a change must beat the best by more than \($d | num)\(if $m.pct then " (\($m.md)%)" else "" end); \($dir) is better."
       else "To be kept, a change must score \($dir) than the best." end),
      ($m.outside | select(length > 0)
       | "Edits outside \($m.change) are kept but not scored: \(.[:5] | join(", "))\(if length > 5 then ", and \(length - 5) more" else "" end)."),
      ([($m.left.usd // empty | if . < 0 then 0 else . end | money),
        ($m.left.tokens // empty | "\(.) tokens"),
        ($m.left.wall // empty | if . < 0 then 0 else . end | dur),
        ($m.left.rounds // empty | "\(.) round\(if . == 1 then "" else "s" end)")]
       | select(length > 0) | "Budget left: \(join(", "))."),
      "Make the next change to \($m.change), then end your turn without a tool call."
    ] | join("\n");
'

# The message state for jq: status and the round's facts, plus the climb's.
# Usage: message_state STATUS RUNS WHY TAIL TAMPER RESCORED OUTSIDE.
message_state() {
  jq -nc --arg status "$1" --argjson runs "$2" --arg why "$3" --arg tail "$4" \
    --arg tamper "$5" --argjson rescored "$6" --arg outside "$7" \
    --argjson round "$round" --argjson rounds "$([ -z "$b_rounds" ] && echo null || echo $((round_base + b_rounds)))" \
    --arg change "$change_text" --argjson best_runs "$B" \
    --argjson best_round "$best_round" --arg goal "$e_goal" \
    --argjson pct "$e_pct" --argjson md "$e_delta" \
    --argjson compare "$([ -n "$e_compare" ] && echo true || echo false)" \
    --argjson left "$(budget_left)" "$climb_jq"'
    {$status, $runs, $why, $tail, tamper: ($tamper | lines), $rescored,
     outside: ($outside | lines), $round, $rounds, $change, $best_runs,
     $best_round, $goal, $pct, $md, $compare, $left}'
}

# What is left of each budget, as JSON (null for budgets that are not set).
budget_left() {
  local wall=null rounds=null tokens=null
  [ -n "$b_wall" ] && wall=$((b_wall - $(date +%s) + start_epoch))
  [ -n "$b_rounds" ] && rounds=$((b_rounds - started))
  [ -n "$b_tokens" ] && tokens=$((b_tokens - spent_tokens))
  jq -nc --argjson usd "${b_usd:-null}" --argjson spent "$spent_usd" \
    "{usd: (if \$usd then \$usd - \$spent else null end), tokens: $tokens, wall: $wall, rounds: $rounds}"
}

# Writes one evaluation to results.jsonl and results.tsv, prints its line on
# stderr, and sets `msg` to the next round message. Reads the round state
# from globals; usage: record STATUS RUNS WHY TAIL TAMPER RESCORED OUTSIDE
# FILES COMMIT EVAL_SECS.
record() {
  local state out
  state=$(message_state "$1" "$2" "$3" "$4" "$5" "$6" "$7")
  out=$(jq -nr --argjson m "$state" --arg run "$name" --arg files "$8" \
    --arg commit "$9" --arg secs "${10:-}" --arg best_commit "${best:0:7}" \
    --argjson vs "${vs:-null}" --argjson agent "${agent_json:-null}" \
    --arg note "${note:-}" "$climb_jq"'
    ($m.runs | median) as $score | ($m.best_runs | median) as $best
    | (if $score != null and $vs != null and $m.status != "crash"
       then $score - $vs else null end) as $delta
    | {v: 1, $run, round: $m.round, t: (now | todate), status: $m.status,
       commit: (if $commit == "" then null else $commit[:7] end), $best_commit,
       scores: $m.runs, score: (if $m.status == "crash" then null else $score end),
       $best, $delta, eval_secs: ($secs | split(" ") | map(select(length > 0)
         | tonumber) | add // 0 | . * 10 | round / 10), $agent,
       files: ($files | lines), outside: $m.outside, tamper: $m.tamper,
       $note, error: (if $m.why == "" then null else $m.why end)} as $r
    | ($r | tojson),
      ([$r.round, $r.status, ($r.score | num), ($best | num),
        (if $delta == null then "" else $delta | num end), ($r.commit // ""),
        ($agent.turns // ""), ($agent.cost // null | if . then money else "" end),
        $note] | @tsv),
      "round \($r.round | lpad(3))  \($r.status | rpad(8))  \($r.score | num | lpad(9))  "
      + (if $r.status == "baseline" or $r.status == "rescore"
         then "\($m.runs | length) runs, spread \($m.runs | max - min | num)"
         else "best \($best | num)  "
           + (if $r.status == "keep" and $vs != null and $vs != 0
              then ($delta / (if $vs < 0 then -$vs else $vs end) * 100 | fixed(1))
                + "%" else "" end | lpad(7))
           + "  \($agent.turns // 0 | lpad(3)) turns  \($agent.cost // 0 | money)  \($note)"
           + (if $r.error then " (\($r.error))" else "" end) end),
      (if $r.status == "baseline" or $r.status == "rescore" or $r.status == "abort"
       then "" else $m | message end)')
  printf '%s\n' "$out" | sed -n 1p >>"$dir/results.jsonl"
  printf '%s\n' "$out" | sed -n 2p >>"$dir/results.tsv"
  [ "$quiet" -eq 1 ] || printf '%s\n' "$out" | sed -n 3p >&2
  msg=$(printf '%s\n' "$out" | sed -n '4,$p')
}

# Sets `msg` to the message that starts a round when there is no result to
# report: the first round, or the first after a resume.
start_message() {
  msg=$(jq -nr --argjson m "$(message_state start '[]' '' '' '' false '')" \
    "$climb_jq"'$m | message')
}

# Rewrites summary.json. Usage: write_summary STATUS [STOP EXIT].
write_summary() {
  local secs=$((secs_before + $(date +%s) - start_epoch))
  jq -n --slurpfile r "$dir/results.jsonl" --slurpfile h "$dir/holdout.jsonl" \
    --arg run "$name" --arg status "$1" --arg stop "${2:-}" \
    --argjson exit "${3:-null}" --argjson best "$(jq -nc --argjson B "$B" "$climb_jq"'$B | median')" \
    --arg best_commit "${best:0:7}" --argjson best_round "$best_round" \
    --arg branch "$([ "$dry" -eq 1 ] || echo "$branch")" --arg session "$session" \
    --argjson secs "$secs" '
    def count($s): map(select(.status == $s)) | length;
    ($r | map(select(.status as $s
      | ["keep", "revert", "crash", "empty", "abort"] | any(. == $s)))) as $rounds
    | {v: 1, $run, $status, stop: (if $stop == "" then null else $stop end),
       $exit, rounds: ($rounds | length), kept: ($r | count("keep")),
       reverted: ($r | count("revert")), crashed: ($r | count("crash")),
       empty: ($r | count("empty")), aborted: ($r | count("abort")),
       baseline: ([$r[] | select(.status == "baseline")][0].score),
       $best, $best_commit, $best_round,
       holdout: {baseline: ([$h[] | select(.for == "baseline")][0].score),
                 best: ([$h[] | select(.commit == $best_commit)] | last | .score)},
       branch: (if $branch == "" then null else $branch end),
       session: (if $session == "" then null else $session end),
       cost: ([$rounds[].agent.cost // 0] | add // 0),
       tokens: ([$rounds[].agent.tokens // 0] | add // 0),
       $secs, isolation: "none"}' >"$dir/summary.json.new" &&
    mv -f "$dir/summary.json.new" "$dir/summary.json"
}

# Prints a run's state for `arx climb status`.
print_status() {
  local d=$1 running=$2
  jq -r --arg running "$running" "$climb_jq"'
    "climb \(.run): \(if $running != "" then "running (pid \($running))"
      else "\(.status) (stop: \(.stop // "-"), exit \(.exit // "-"))" end)",
    "  rounds \(.rounds): \(.kept) kept, \(.reverted) reverted, \(.crashed) crashed, \(.empty) empty",
    "  best \(.best | num) (round \(.best_round), commit \(.best_commit)), baseline \(.baseline | num)",
    (select(.holdout.baseline != null)
     | "  holdout: baseline \(.holdout.baseline | num), best \(.holdout.best | num)"),
    "  spent \(.cost | money), \(.tokens) tokens, \(.secs | dur); branch \(.branch // "-"), session \(.session // "-"), isolation \(.isolation)"' \
    "$d/summary.json"
  echo
  tail -n 6 "$d/results.tsv" | awk -F'\t' '{ printf "  %-6s %-9s %-10s %-10s %-10s %-8s %s\n", $1, $2, $3, $4, $5, $6, $9 }'
}
