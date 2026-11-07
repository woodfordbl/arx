# Plugin quickstart

In this guide you write a plugin with one tool and one hook, check it, and
see both run in a session. It takes about five minutes. A fake model plays
back replies from files, so you need no API key and spend nothing.

You need a C compiler, `make` and `python3`.

## 1. Build arx and make a test folder

From the root of your arx checkout:

```sh
make                                     # builds ./arx
export PATH="$PWD:$PATH"                 # `arx` is now this build
export ARX_CURL="$PWD/tests/fake-curl"   # model replies come from files
export ARX_CONFIG_DIR="$(mktemp -d)"     # an empty config folder, so your own plugins stay out
cd "$(mktemp -d)"
```

`tests/fake-curl` is the stand-in for `curl` that `make test` uses. It answers
model call N with the file `$FAKE_DIR/0N.resp`.

Write a minimal spec. `NO_KEY` is an environment variable that is not set, so
arx sends no API key:

```sh
cat > agent.yaml <<'EOF'
name: hello
model: test-model
endpoint: {base_url: "http://fake.invalid/v1", api_key_env: NO_KEY}
EOF
```

## 2. Write a tool

A plugin is a folder with a `plugin.yaml`. A folder in `plugins/` next to
`agent.yaml` is a plugin for this harness only, and it loads without an
install step.

```sh
mkdir -p plugins/hello/tools
cat > plugins/hello/plugin.yaml <<'EOF'
name: hello
version: 0.1.0
description: A greet tool and a hook that guards it.
EOF
```

A tool is an executable in `tools/`. Its file name is the tool name. Called
with `--schema`, it prints its description. Called without it, it reads its
arguments as JSON on stdin and prints the result:

```sh
cat > plugins/hello/tools/greet <<'EOF'
#!/usr/bin/env python3
import json
import sys

if sys.argv[1:] == ["--schema"]:
    print(json.dumps({
        "description": "Greet a person by name.",
        "parameters": {
            "type": "object",
            "properties": {"name": {"type": "string"}},
            "required": ["name"],
        },
    }))
    sys.exit(0)

args = json.load(sys.stdin)
print(f"Hello, {args['name']}!")
EOF
chmod +x plugins/hello/tools/greet
```

Run it by hand first, the way arx will:

```sh
echo '{"name": "Ada"}' | plugins/hello/tools/greet
```

```
Hello, Ada!
```

Then check the harness. `arx check` lists every tool, hook and plugin, and
any problems:

```sh
arx check
```

```
ok: agent.yaml (model test-model at http://fake.invalid/v1)
tools: bash edit greet
hooks:
plugins: hello
```

`bash` and `edit` are built in. `arx tools` prints all three as the model
sees them.

## 3. Write a hook

A hook is an executable in `hooks/`, named after its hook point. A
`before_tool` hook runs before each tool call. It gets the call as JSON on
stdin. It prints nothing to allow the call, or a decision to deny it:

```sh
mkdir -p plugins/hello/hooks
cat > plugins/hello/hooks/before_tool <<'EOF'
#!/bin/sh
# Denies greet calls for Bob. Prints nothing to allow a call.
input=$(cat)
case "$input" in
  *'"name":"greet"'*'"name":"Bob"'*)
    echo '{"decision": "deny", "reason": "do not greet Bob"}' ;;
esac
EOF
chmod +x plugins/hello/hooks/before_tool
```

Try it by hand. arx sends compact JSON, with no spaces:

```sh
echo '{"tool":{"name":"greet","args":{"name":"Bob"}}}' | plugins/hello/hooks/before_tool
```

```
{"decision": "deny", "reason": "do not greet Bob"}
```

`arx check` now shows the hook and the plugin it comes from:
`hooks: before_tool(hello)`.

## 4. See them in a session

Write three model replies. The first calls `greet` for Ada, the second calls
it for Bob, and the third ends the task:

```sh
export FAKE_DIR="$PWD/fake"
mkdir -p fake
cat > fake/01.resp <<'EOF'
HTTP/1.1 200 OK

{"choices":[{"message":{"role":"assistant","tool_calls":[{"id":"c1","type":"function","function":{"name":"greet","arguments":"{\"name\":\"Ada\"}"}}]}}]}
EOF
cat > fake/02.resp <<'EOF'
HTTP/1.1 200 OK

{"choices":[{"message":{"role":"assistant","tool_calls":[{"id":"c2","type":"function","function":{"name":"greet","arguments":"{\"name\":\"Bob\"}"}}]}}]}
EOF
cat > fake/03.resp <<'EOF'
HTTP/1.1 200 OK

{"choices":[{"message":{"role":"assistant","content":"I greeted Ada. I may not greet Bob."}}]}
EOF
```

Run one task:

```sh
arx -p "Greet Ada and Bob"
```

```
● arx 0.1.0 · hello · test-model · session 20261107-143709-f81d
  ⏵ greet {"name":"Ada"}
    ↳ exit 0 · 0.0s · 12 B  Hello, Ada!
  ⏵ greet {"name":"Bob"}
  ⚑ hook before_tool: deny
    ↳ exit 0 · 0.0s · 0 B  denied by the before_tool hook: do not greet Bob
I greeted Ada. I may not greet Bob.
● done · 3 turns · 0 tokens · $0.00000 · 0.1s
```

The session folder has the full record. These are the tool results the model
got, and the hook events:

```sh
grep '"role":"tool"' .arx/sessions/last/transcript.jsonl
grep '"type":"hook"' .arx/sessions/last/events.jsonl
```

`fake/req-01.json` to `req-03.json` are the requests arx sent. Open
`req-01.json` to see the `greet` schema in the `tools` array.

## 5. Change it while it runs

arx checks the harness files before every model call. Edit `greet`, add a
file to `tools/`, or delete the hook, and the next turn uses the new version.
A tool the agent writes for itself loads the same way. There is no restart
and no registration.

## Next steps

- **Use it in every harness:** `arx plugin add --link ./plugins/hello` links
  the folder into your config folder, so every harness loads it. Without
  `--link`, arx copies it.
- **Start the next plugin faster:** `arx plugin new NAME` makes a folder with
  a `plugin.yaml` and an example tool.
- **Go further:** [Concepts](concepts.md) explains layers and load order. The
  [tool](tools.md) and [hook](hooks.md) pages give the full contracts and the
  common mistakes.
- **Use a real model:** run `arx setup`, then leave out `ARX_CURL`,
  `ARX_CONFIG_DIR` and the `endpoint:` line.
