#!/usr/bin/env python3
"""keep_last: an example compactor.

Keeps the system prompt, the first user message and roughly the last
KEEP messages. It cuts only in front of an assistant message, so no tool
result loses the tool call it answers.

stdin:  {"messages": [...], "usage": {"prompt_tokens": N},
         "context_window": N}
stdout: {"messages": [...]}  (a non-zero exit or bad output makes arx fall
        back to the built-in mask strategy)
"""
import json
import sys

KEEP = 12

request = json.load(sys.stdin)
messages = request["messages"]
head, rest = messages[:2], messages[2:]
cut = max(0, len(rest) - KEEP)
while cut < len(rest) and rest[cut]["role"] != "assistant":
    cut += 1
if 0 < cut < len(rest):
    note = {"role": "user",
            "content": f"[{cut} earlier messages were dropped to save "
                       "context; your notes and files still hold the work]"}
    messages = head + [note] + rest[cut:]
print(json.dumps({"messages": messages}))
