# Credentials

A credential program is an executable that prints the headers and base URL
for model calls, so the key can come from somewhere other than a fixed API
key.

Write one when the key lives in a password manager, when it expires and must
be refreshed, or when a sign-in replaces the key altogether. For a fixed key,
keep `arx setup` or `endpoint.api_key_env`: they need no program.

**Status:** today. **Examples:**
[`plugins/op-key`](../../plugins/op-key) reads a key from 1Password, and
[`plugins/chatgpt`](../../plugins/chatgpt) signs in with ChatGPT.

## Contract

### Choose a credential program

`endpoint.credential` in the spec chooses the program:

| Value | What arx runs | Use it when |
|---|---|---|
| a name from `credentials:` | a program that the spec or a plugin names | a plugin ships the program |
| a path | an executable, relative to the spec folder | the program lives in your own harness |

A plugin names its programs in `plugin.yaml`, with paths relative to the
plugin folder. The spec then chooses one by name:

```yaml
# plugin.yaml
credentials: {op-key: credentials/op-key}
```

```yaml
# agent.yaml
endpoint: {base_url: https://openrouter.ai/api/v1, credential: op-key}
```

With `endpoint.credential`, the program is the only source of the key: arx
does not read `endpoint.api_key_env` or the key `arx setup` saved.
`endpoint.base_url` becomes optional, because the program can give it.

### When arx runs it

arx keeps the program's last output in memory and runs it again only when it
must:

| Reason | When |
|---|---|
| `start` | before the first model call of the process, and after the spec names another program |
| `expired` | before a model call, when less than 60 seconds are left before `expires_at` |
| `rejected` | after the endpoint answers 401 or 403; arx then retries the call at once, one time |

A second 401 or 403 in a row stops the run with exit code 4. Each subagent
is its own arx process, so it runs the program once at its start.

An MCP server with `credential` in its [`mcp_servers`](../spec.md#mcp_servers)
entry uses the same programs:

| Server | When arx runs the program | What it uses |
|---|---|---|
| stdio (`command`) | before each start of the server, with reason `start` | `api_key`, which goes in the `api_key_env` variable; `headers` are ignored |
| HTTP (`url`) | in the bridge: before its first request, when less than 60 seconds are left before `expires_at`, and after a 401 or 403 | `headers`, or `api_key` as a bearer token |

After a 401 or 403 the bridge repeats the request once. A second one ends
the request with an error for the model.

### Input and output

arx writes one line of JSON to the program's stdin:

```json
{"reason": "start", "model": "gpt-6.1-sol", "base_url": "https://x.dev/v1"}
```

For an MCP server the input names the server in place of the model:

```json
{"reason": "rejected", "server": "linear", "url": "https://mcp.linear.app/mcp",
 "base_url": "https://mcp.linear.app/mcp", "status": 401,
 "challenge": "Bearer resource_metadata=\"https://mcp.linear.app/.well-known/oauth-protected-resource\""}
```

| Field | When |
|---|---|
| `server` | always, for an MCP server |
| `url` | HTTP servers; `base_url` holds the same value, for programs written for model calls |
| `status`, `challenge` | reason `rejected`: the HTTP status (401 or 403) and the `WWW-Authenticate` value |

The program prints one JSON object on stdout. Every field is optional:

| Field | Type | What arx does with it |
|---|---|---|
| `headers` | object of strings | sends each header; one with the name of an `endpoint.headers` entry replaces it |
| `api_key` | string | sends `Authorization: Bearer <api_key>`, unless `headers` has `Authorization` |
| `base_url` | string | uses it in place of `endpoint.base_url` |
| `expires_at` | number | Unix seconds; arx runs the program again before this time. Without it, arx keeps the value for the whole process |

```json
{
  "headers": {"Authorization": "Bearer eyJ..."},
  "base_url": "https://api.openai.com/v1",
  "expires_at": 1794250000
}
```

Header names and values must fit on one line. arx refuses output that is
not a JSON object of these types, and stops the run with exit code 4.

### Exit codes

| Exit code | What arx does |
|---|---|
| `0` | uses the output |
| `75` | tries again later, with the same backoff as a network error and a `model.retry` event. Use it when the network or the identity provider is down |
| any other | stops the run with exit code 4, and shows the program's stderr |

A program that runs longer than 60 seconds counts as exit 75. Never start an
interactive sign-in from the program: runs are often headless. Print what the
user should run instead, such as `arx chatgpt login`, and exit 1.

### Where the value goes

The value stays in the arx process. It reaches `curl` in the same 0600
header file as a key from `arx setup`, never on a command line. Each run of
the program sends a `model.credential` event with `program`, `reason`,
`secs`, and `expires_in` or `error`. The event never holds the value.

The program runs in the folder `arx` runs in, with arx's environment. It
does not get the `ARX_*` variables of tools and hooks: find your files from
the script's own path.

## Write a credential program

This program reads the key from the 1Password CLI. It is the
[`op-key`](../../plugins/op-key) plugin, shortened:

```sh
#!/bin/sh
# credentials/op-key: prints the key that $ARX_OP_REF names in 1Password.
set -u
[ -n "${ARX_OP_REF:-}" ] || { echo "op-key: set ARX_OP_REF" >&2; exit 1; }
key=$(op read --no-newline "$ARX_OP_REF") || exit 1
printf '{"api_key": "%s"}\n' "$key"
```

Make it executable, name it in `plugin.yaml` as in
[Choose a credential program](#choose-a-credential-program), and check that
arx finds it:

```sh
arx check                     # prints "credential: op-key"
arx request --auth-source     # runs it: "the credential program op-key"
arx request /models           # one call to the endpoint with its value
```

For a token that expires, print `expires_at`, and refresh the token in the
program when less than a few minutes are left. If several arx processes
share one refresh token, take a lock before you refresh: a provider that
rotates refresh tokens accepts each one only once. The
[`chatgpt`](../../plugins/chatgpt) plugin shows both.

## Declare network hosts

A plugin lists the hosts its programs connect to in `hosts:`, so a run
behind an egress proxy can allow exactly those:

```yaml
# plugin.yaml
hosts: [auth.openai.com, api.openai.com]
```

`arx check --hosts` prints the hosts a run needs, one per line: the host of
`endpoint.base_url`, then `hosts:` from the spec and from each plugin in the
active list. Use a kit or a `plugins:` list to keep the list to the plugins
the run uses. See [Hosts](reference.md#hosts).

## Common mistakes

| Mistake | What happens | Fix |
|---|---|---|
| The program prints a debug line on stdout | the output is not JSON, and the run stops with exit code 4 | write debug lines to stderr |
| The program opens a browser to sign in | a headless run hangs until the 60-second timeout, then retries | tell the user what to run, and exit 1 |
| Two processes refresh one rotating token at the same time | the provider rejects the second refresh, and may revoke the sign-in | refresh under a lock, and read the token again after you get it |
| The program exits 1 when the network is down | the run stops, though waiting would have worked | exit 75 for problems that go away |
| `endpoint.credential` names a program from a plugin that is off | the spec is not valid: `not a name in credentials, and ... is not executable` | turn the plugin on, or use a path |

## Related

- [Adapters](adapters.md): translate the request for an endpoint that does
  not speak Chat Completions.
- [agent.yaml reference](../spec.md#endpoint): every `endpoint` key.
- [Plugin reference](reference.md#pluginyaml): the `credentials`, `adapters`
  and `hosts` keys of `plugin.yaml`.
