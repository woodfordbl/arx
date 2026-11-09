# Adapters

An adapter is an executable that arx puts in front of the `curl` command of
each model call, so it can translate the request and the reply for an
endpoint that does not speak Chat Completions.

arx itself sends OpenAI Chat Completions requests. Write an adapter when an
endpoint only takes another format, such as the OpenAI Responses API. For an
endpoint that takes Chat Completions, you need none.

**Status:** today. **Example:** the `responses` adapter in
[`plugins/chatgpt`](../../plugins/chatgpt).

## Contract

### Choose an adapter

`endpoint.adapter` in the spec chooses the adapter, the same way
`endpoint.credential` chooses a [credential program](credentials.md):

| Value | What arx runs | Use it when |
|---|---|---|
| a name from `adapters:` | an adapter that the spec or a plugin names | a plugin ships the adapter |
| a path | an executable, relative to the spec folder | the adapter lives in your own harness |

```yaml
# plugin.yaml
adapters: {responses: adapters/responses}
```

```yaml
# agent.yaml
endpoint: {base_url: https://api.openai.com/v1, adapter: responses}
```

### The command line

Without an adapter, arx runs `curl` like this for a model call:

```text
curl -sS -N --max-time 600 -D HEADERS -H @REQUEST_HEADERS \
  --data-binary @- URL
```

With an adapter, arx runs the adapter with that whole command as its
arguments:

```text
ADAPTER curl -sS -N --max-time 600 -D HEADERS -H @REQUEST_HEADERS \
  --data-binary @- URL
```

These parts of the command are fixed, so an adapter can rely on them:

- **The first argument** is the `curl` to run: `endpoint.curl`, `$ARX_CURL`
  or `curl`.
- **The last argument** is the URL: `<base_url>/chat/completions` for a
  model call. `arx request PATH` runs the adapter too, with
  `<base_url>/PATH`.
- **`-D HEADERS`** is the file where `curl` writes the response headers.
  arx reads the HTTP status and `Retry-After` from it after the adapter
  exits.
- **stdin** is the request body: a Chat Completions request with
  `"stream": true`.

Pass every other argument to `curl` unchanged. The request headers, with the
key, are in the 0600 file after `-H @`, so the adapter never sees the key on
its command line.

### Output and exit code

The adapter prints the reply on stdout as a Chat Completions stream: `data:`
lines with `choices[0].delta` chunks, a chunk with `finish_reason`, a chunk
with `usage`, then `data: [DONE]`. An error body that is not a stream passes
through as it is, and arx reads its `error.message`.

Exit with `curl`'s exit code. arx retries the exit codes it retries for
`curl` (timeouts, refused connections) and stops on the others.

To report a failure that arrives inside the stream, write the HTTP status it
means to the `-D` file after `curl` exits, such as `HTTP/1.1 429` for a
usage limit, and print a JSON error body. arx then retries, compacts or
stops as it would for that status. See
[Retries](../spec.md#endpoint) for what each status does.

### Map model settings

arx merges `model_settings` from the spec, the kit, `config.yaml` and
plugins into top-level Chat Completions fields before the adapter runs. The
adapter cannot tell which source set a field, and does not need to. For
each field, it does one of three things:

- **A field it knows**: it translates the field.
- **A native field that the provider takes**: it passes the field through.
- **A field that the provider rejects**: it drops the field, and does not
  fail the call. A setting from a plugin must not break a run on one
  provider.

List the mapping in the adapter's README. For the routes that arx supports:

| Field | No adapter (OpenAI, OpenRouter, vLLM, Ollama) | `responses` (ChatGPT plan) |
|---|---|---|
| `temperature`, `top_p` | passed | dropped: the route rejects it |
| `max_tokens`, `max_completion_tokens` | passed | dropped |
| `reasoning_effort` | passed | `reasoning.effort` |
| `verbosity` | passed | `text.verbosity` |
| `tool_choice` | passed | mapped |
| `parallel_tool_calls`, `reasoning`, `text`, `include`, `prompt_cache_key`, `service_tier` | passed | passed |
| any other field | passed | dropped |

Plugin authors use Chat Completions names. An adapter for another API writes
its own row: for the Anthropic Messages API, `max_tokens` would stay
`max_tokens`, `stop` would become `stop_sequences`, and
`parallel_tool_calls: false` would become
`tool_choice.disable_parallel_tool_use`.

## Write an adapter

An adapter that changes nothing shows the shape. It runs the command it is
given:

```sh
#!/bin/sh
# adapters/pass: logs the URL of each call, then runs curl unchanged.
for last; do :; done
echo "$(date +%T) $last" >>adapter.log
exec "$@"
```

A real adapter does three things:

1. **Rewrites the URL**: for example, `/chat/completions` becomes
   `/responses`.
2. **Translates the request** on stdin before it starts `curl`.
3. **Translates the reply**, line by line as it streams, so the terminal
   still shows text as it arrives.

The `responses` adapter in [`plugins/chatgpt`](../../plugins/chatgpt) does
this for the Responses API in under 300 lines of Python. It turns system
messages into `instructions`, tool calls into `function_call` items, and
tools into one `namespace`. It leaves out the settings that the ChatGPT plan
route rejects, such as `temperature` and `max_tokens`.

Check it with a run against a fake `curl`, the way
[`tests/credentials.sh`](../../tests/credentials.sh) does, before you point
it at a real endpoint.

## Common mistakes

| Mistake | What happens | Fix |
|---|---|---|
| The adapter changes or drops `-D HEADERS` | arx sees no HTTP status, and retries a reply that failed | pass it to `curl`, and write to it only after `curl` exits |
| The adapter writes the `-D` file while `curl` runs | `curl` writes the file again when it ends, over your status | wait for `curl` to exit first |
| The adapter buffers the whole reply | the terminal shows nothing until the reply ends | translate and flush each line |
| The adapter puts the key on `curl`'s command line | the key shows up in process listings | leave the headers in the `-H @` file |
| The adapter translates every URL | `arx request /models` breaks | translate only the URLs you know; run the rest unchanged |
| The adapter fails on a field it does not know | a setting from a plugin breaks every call on that route | drop the field, and list it in the README |

## Related

- [Credentials](credentials.md): where the key and base URL come from.
- [agent.yaml reference](../spec.md#endpoint): every `endpoint` key.
- [Hooks](hooks.md): `before_model` and `after_model` hooks see the request
  and reply in Chat Completions format, before the adapter translates them.
