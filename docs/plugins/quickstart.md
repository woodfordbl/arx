# Plugin quickstart

Write a plugin with one tool and one hook, check it, and watch both run in a
session. It takes about five minutes, and by the end you'll have a plugin you
can put in a kit or install in every harness.

A fake model plays back replies from files, so you need no API key and spend
nothing. You need an arx checkout, a C compiler, `make` and `python3`.

## 1. Build arx and make a test folder

From the root of your arx checkout, build arx and point it at the fake model:

```sh
make                                     # builds ./arx
export PATH="$PWD:$PATH"                 # `arx` is now this build
export ARX_CURL="$PWD/tests/fake-curl"   # model replies come from files
export ARX_CONFIG_DIR="$(mktemp -d)"     # an empty config folder, so your own plugins stay out
cd "$(mktemp -d)"
```

`tests/fake-curl` is the stand-in for `curl` that `make test` uses. It answers
model call N with the file `$FAKE_DIR/0N.resp`.

Write a minimal spec. `NO_KEY` names an environment variable that is not set,
so arx sends no API key:

```sh
cat > agent.yaml <<'EOF'
name: hello
model: test-model
endpoint: {base_url: "http://fake.invalid/v1", api_key_env: NO_KEY}
EOF
```

## 2. Write a tool

A plugin is a folder with a `plugin.yaml`. A plugin folder in `plugins/`, next
to `agent.yaml`, belongs to this harness only and loads without an install
step. Create one called `hello`:

```sh
mkdir -p plugins/hello/tools
cat > plugins/hello/plugin.yaml <<'EOF'
name: hello
version: 0.1.0
description: A greet tool and a hook that guards it.
EOF
```

A tool is an executable in `tools/`, and its file name is the tool name.
Called with `--schema`, it prints its description. Called without it, it reads
its arguments as JSON on stdin and prints the result. Write a `greet` tool:

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

```text
Hello, Ada!
```

Then check the harness. `arx check` lists every tool, hook and plugin, and
any problems:

```sh
arx check
```

```text
ok: agent.yaml (model test-model at http://fake.invalid/v1)
tools: greet
hooks:
plugins: hello
```

`greet` is the only tool, because the empty config folder has no `shell`
plugin. With your own config, `arx setup` turns that plugin on, and the agent
also gets `bash` and `edit`. To see the tools as the model sees them, run
`arx tools`.

## 3. Write a hook

A hook is an executable in `hooks/`, named after its hook point. A
`before_tool` hook runs before each tool call and gets the call as JSON on
stdin: `{"id", "name", "args"}`. It prints nothing to let the call run, or a
decision to deny it. Write one that refuses to greet Bob:

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
echo '{"id":"c2","name":"greet","args":{"name":"Bob"}}' | plugins/hello/hooks/before_tool
```

```text
{"decision": "deny", "reason": "do not greet Bob"}
```

Run `arx check` again. It now shows the hook and the plugin it comes from:
`hooks: before_tool(hello)`.

A hook can also change the call, or the request and the reply around the
model call. [Hooks](hooks.md) covers every hook point.

## 4. See them in a session

Write three model replies for the fake model. The first calls `greet` for
Ada, the second calls it for Bob, and the third ends the task:

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

arx runs `greet` for Ada, and your hook denies the call for Bob:

```text
● arx 0.1.0 · hello · test-model · session 20261107-143709-f81d
  ⏵ greet {"name":"Ada"}
    ↳ exit 0 · 0.0s · 12 B  Hello, Ada!
  ⏵ greet {"name":"Bob"}
  ⚑ hook before_tool: deny
    ↳ exit 0 · 0.0s · 0 B  denied: do not greet Bob
I greeted Ada. I may not greet Bob.
● done · 3 turns · 0 tokens · $0.00000 · 0.1s
```

The session folder holds the full record. Print the tool results the model
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
There is no restart and no registration step. A tool the agent writes for
itself loads the same way.

## 6. Put it in a kit

A kit chooses the plugins of a run, in order, and has no code. A kit in
`kits/`, next to `agent.yaml`, loads without an install step. Make one that
runs only the `hello` plugin:

```sh
mkdir -p kits/greeter
cat > kits/greeter/kit.yaml <<'EOF'
name: greeter
version: 0.1.0
description: An agent that greets people.
plugins: [hello]
EOF
arx check --kit greeter
```

```text
ok: agent.yaml (model test-model at http://fake.invalid/v1)
kit: greeter (from --kit)
tools: greet
hooks: before_tool(hello)
plugins: hello
```

Only the plugins the kit lists load. `arx --kit greeter` runs with the kit,
and the agent cannot change the kit of that run.

## Take the plugin past the test folder

Your plugin works in this folder. To use it for real:

- **Use it in every harness**: `arx plugin add --link ./plugins/hello` links
  the folder into your config folder, so every harness loads it. Without
  `--link`, arx copies it.
- **Use a real model**: open a new terminal, so the exports are gone, run
  `arx setup`, and delete the `model:` and `endpoint:` lines of
  `agent.yaml`.
- **Start the next plugin faster**: `arx plugin new NAME` makes a folder with
  a `plugin.yaml` and an example tool.
- **Use a shipped kit**: `arx kit add coding` installs the coding kit and its
  plugins, and `arx --kit coding` runs with it.

## Next steps

- [Plugin concepts](concepts.md): learn how layers and load order decide
  which part wins.
- [Tools](tools.md) and [Hooks](hooks.md): read the full contracts and the
  common mistakes.
- [Kits](kits.md): build the active list of a run and pin it.
