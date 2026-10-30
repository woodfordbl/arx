#!/bin/sh
# resume_on_cap: an example driver. Runs a task with a turn cap. Each time
# the cap stops it (exit 3), it resumes the same session with a new budget,
# up to ROUNDS rounds. Drivers use only the command line: -p, --resume,
# --cap, --json and the exit codes.
#
# usage: resume_on_cap.sh TASK [ROUNDS] [TURNS_PER_ROUND]
task=${1:?usage: resume_on_cap.sh TASK [ROUNDS] [TURNS_PER_ROUND]}
rounds=${2:-3}
turns=${3:-20}
arx=${ARX:-arx}

"$arx" -p "$task" --cap "turns=$turns" --json --quiet >result.json
code=$?
round=1
while [ "$code" -eq 3 ] && [ "$round" -lt "$rounds" ]; do
  used=$(sed 's/.*"turns":\([0-9]*\).*/\1/' result.json)
  round=$((round + 1))
  "$arx" --resume last -p "Continue where you stopped." \
    --cap "turns=$((used + turns))" --json --quiet >result.json
  code=$?
done
echo "finished with exit $code after $round round(s)"
cat result.json
exit "$code"
