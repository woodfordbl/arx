#!/usr/bin/env bash
# bench.sh: checks the performance budgets from the plan against ./arx and
# fails if any is exceeded (like fx's CI). Timing uses python3, which is
# only a dev dependency.
#   size     binary <= 400 KB on macOS, <= 1 MB on Linux; commands/lib/pick
#            (the menu program) <= 64 KB on macOS, <= 256 KB on Linux
#   startup  median `arx version` within 1 ms of `true` (the OS floor)
#   memory   peak RSS <= 16 MB over a 500-turn session
#   reload   a harness edit is live in <= 10 ms (plus the tool's --schema)
set -u
. "$(dirname "$0")/lib.sh"
ARX="$ROOT/arx"
status=0

# Prints one result line and records a failure.
budget() {
  local what=$1 value=$2 limit=$3 unit=$4
  if [ -n "$value" ] && awk -v v="$value" -v l="$limit" 'BEGIN { exit !(v <= l) }'; then
    printf '  ok    %-8s %8s %s (budget %s)\n' "$what" "$value" "$unit" "$limit"
  else
    printf '  FAIL  %-8s %8s %s (budget %s)\n' "$what" "$value" "$unit" "$limit"
    status=1
  fi
}

# Binary size.
size_kb=$(($(wc -c <"$ARX") / 1024))
limit_kb=$([ "$(uname)" = Darwin ] && echo 400 || echo 1024)
budget size "$size_kb" "$limit_kb" KB
pick_kb=$(($(wc -c <"$ROOT/commands/lib/pick") / 1024))
budget pick "$pick_kb" "$([ "$(uname)" = Darwin ] && echo 64 || echo 256)" KB

# Startup: median of 60 launches each, measured the same way, as the
# difference from `true` on the same machine.
measure_startup() {
  python3 - "$ARX" <<'EOF'
import os, shutil, statistics, sys, time
def median_ms(argv):
    times = []
    quiet = [(os.POSIX_SPAWN_OPEN, 1, os.devnull, os.O_WRONLY, 0)]
    for _ in range(60):
        t = time.perf_counter()
        pid = os.posix_spawn(argv[0], argv, os.environ, file_actions=quiet)
        os.waitpid(pid, 0)
        times.append((time.perf_counter() - t) * 1000)
    return statistics.median(times[10:])
floor = median_ms([shutil.which("true")])  # /usr/bin/true or /bin/true
print(f"{median_ms([sys.argv[1], 'version']) - floor:.2f}")
EOF
}
startup_ms=$(measure_startup)
# Shared CI machines are noisy: measure once more before failing.
if ! awk -v v="$startup_ms" 'BEGIN { exit !(v <= 1.0) }'; then
  echo "  ...   startup  $startup_ms ms over true; measuring again"
  startup_ms=$(measure_startup)
fi
budget startup "$startup_ms" 1.0 "ms over true"

# Memory: 499 tool calls and a final answer, all scripted.
begin "bench"
for i in $(seq 1 499); do
  sse_tool bash '{\"command\":\"echo turn\"}' | reply "$i" "200 OK"
done
sse_text "done" | reply 500 "200 OK"
rss_mb=$(python3 - "$ARX" <<'EOF'
import os, sys
argv = [sys.argv[1], "-p", "go", "--quiet", "--set", "limits.max_turns=600"]
quiet = [(os.POSIX_SPAWN_OPEN, 1, os.devnull, os.O_WRONLY, 0)]
pid = os.posix_spawn(argv[0], argv, os.environ, file_actions=quiet)
_, status, usage = os.wait4(pid, 0)
scale = 1 if sys.platform == "darwin" else 1024  # bytes on macOS, KB on Linux
print(f"{usage.ru_maxrss * scale / 1048576:.1f}")
EOF
)
budget memory "$rss_mb" 16 "MB over 500 turns"

# Prints the "ms" of the first harness.reload event in the last session.
reload_ms() {
  grep -o '"type":"harness.reload"[^}]*"ms":[0-9.]*' \
    .arx/sessions/last/events.jsonl | grep -o '[0-9.]*$' | head -1 |
    awk '{ printf "%.2f", $1 }'
}

# Reload: the agent edits its spec; the reload event says how long it took.
begin "bench-reload"
sse_tool bash '{\"command\":\"echo \\\"context_window: 64000\\\" >> agent.yaml\"}' |
  reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
"$ARX" -p go --quiet >/dev/null 2>&1
budget reload "$(reload_ms)" 10 "ms for a spec edit"

# Adding a tool also runs its --schema once. Not a budget: on macOS the
# first run of any new executable includes ~40-50 ms of OS security checks.
begin "bench-reload-tool"
script staged/fast <<'EOF'
#!/bin/sh
[ "$1" = --schema ] && echo '{"description":"x","parameters":{"type":"object"}}'
EOF
sse_tool bash '{\"command\":\"mkdir -p tools && mv staged/fast tools/fast\"}' |
  reply 1 "200 OK"
sse_text "done" | reply 2 "200 OK"
"$ARX" -p go --quiet >/dev/null 2>&1
printf '  info  %-8s %8s ms for a new tool (incl. its first --schema run)\n' \
  "reload" "$(reload_ms)"

exit "$status"
