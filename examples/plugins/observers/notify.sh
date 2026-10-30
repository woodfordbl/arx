#!/bin/sh
# notify: an example observer. Reads the event stream (one JSON event per
# line) on stdin and reports when the top-level session ends: to ntfy.sh if
# NTFY_TOPIC is set, otherwise on stderr.
while IFS= read -r line; do
  case "$line" in
    *'"depth":0,'*'"type":"session.end"'*)
      status=$(printf '%s' "$line" | sed 's/.*"status":"\([a-z]*\)".*/\1/')
      message="arx session $ARX_SESSION ended: $status"
      if [ -n "${NTFY_TOPIC:-}" ]; then
        curl -s -d "$message" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null
      else
        echo "$message" >&2
      fi
      ;;
  esac
done
