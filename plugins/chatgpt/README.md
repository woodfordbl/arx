# chatgpt

The `chatgpt` plugin lets arx use your ChatGPT plan for model calls, through
OpenAI's Sign in with ChatGPT, instead of an API key.

It has three parts:

- **`arx chatgpt`**: a command that signs in, shows the status and signs
  out.
- **The `chatgpt` credential program**: prints the access token for each
  model call, and refreshes it before it expires. See
  [Credentials](../../docs/plugins/credentials.md).
- **The `responses` adapter**: translates arx's Chat Completions calls to
  the Responses API, which is the only API this sign-in works with. See
  [Adapters](../../docs/plugins/adapters.md).

## What OpenAI allows

OpenAI documents ChatGPT plan usage for open-source, locally hosted apps,
and arx follows that guide:
[developers.openai.com/siwc/token-sharing-open-source](https://developers.openai.com/siwc/token-sharing-open-source).

- **Who may use it**: the quickstart says plan usage "is available to all
  open-source partners". The open-source flow registers the app with
  `client_id=dynamic_agent_client` and needs no client secret, partner key
  or approval. Paid or remotely hosted apps must ask OpenAI first, with the
  [interest form](https://openai.com/form/sign-in-with-chatgpt-interest/).
- **Which plans**: ChatGPT Plus and Pro. On Plus, the five-hour usage limit
  is shared with every other app that uses your plan.
- **What it can call**: `POST https://api.openai.com/v1/responses`, with
  `store: false` and `stream: true`, and the models that
  `GET https://api.openai.com/v1/models` lists for your account. Settings
  such as `temperature` and `max_output_tokens` are not accepted. See
  [Preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations).
- **What it cannot see**: your ChatGPT conversations. You manage arx's
  access and limits in [ChatGPT settings](https://chatgpt.com/settings/usage).

## Sign in

Install the plugin, then sign in. The command opens your browser on
OpenAI's sign-in page, and waits for the redirect to `127.0.0.1`:

```sh
arx plugin add chatgpt      # installs the plugin and its command
arx chatgpt login           # sign in, and allow arx to use your plan
arx chatgpt status          # the account, and whether plan usage is on
```

The first sign-in asks you to name and allow the app. arx saves the sign-in
in `~/.config/arx/chatgpt/auth.json` (0600), or in `$ARX_CHATGPT_DIR`. No
command prints a token.

Then point the spec at it, and pick a model from the list:

```yaml
# agent.yaml
model: gpt-6.1-sol
endpoint:
  base_url: https://api.openai.com/v1
  credential: chatgpt
  adapter: responses
```

```sh
arx models                  # the models your plan can use
```

`arx chatgpt logout` revokes the sign-in. `--forget` also drops the saved
account, so the next sign-in registers arx again.

## Run it in containers

The sign-in needs a browser, so sign in on your machine and give containers
the state folder. arx allows two layouts:

- **Share one folder**: mount `~/.config/arx/chatgpt` into every container
  and set `ARX_CHATGPT_DIR` to it. Every process uses one sign-in, and a
  lock folder (`auth.json.lock`) makes sure only one of them refreshes the
  token at a time. Use this for parallel runs.
- **Copy the folder**: copy `auth.json` (not `host-id`) to the machine over
  SSH, as OpenAI's
  [self-hosted VMs](https://developers.openai.com/siwc/token-sharing-open-source/self-hosted-vms)
  guide says. The copy then owns refreshes. Run `arx chatgpt login` again on
  your own machine before you use it there, so the two never refresh the
  same token.

> [!WARNING]
> OpenAI rotates the refresh token on every refresh and accepts each one
> once. Two copies of `auth.json` that both refresh end with one of them
> signed out. Share the folder instead of copying it to several machines.

Behind an egress proxy, allow the hosts that `arx check --hosts` prints:
`auth.openai.com` for sign-in and refresh, and `api.openai.com` for model
calls. `urllib` and `curl` both use `$https_proxy`.

## How it maps to OpenAI's guide

| Guide step | Where |
|---|---|
| Host ID (`urn:uuid:`) chosen before the first sign-in | `host_id()`, in `host-id` next to `auth.json` |
| PKCE (S256), `state`, `nonce`, loopback redirect on `127.0.0.1` | `login()` |
| ID token: RS256 signature, issuer, audience, expiry, nonce | `verify_id_token()` |
| Check the `chatgpt.tokens.use.direct` scope before inference | `credential()` |
| Refresh near expiry, one process at a time, rotate the refresh token | `credential()`, `refresh()`, `Lock` |
| Unusable refresh token: clear tokens, sign in again | `refresh()` |
| Revoke on sign-out | `logout()` |
| Usage-limit errors point to ChatGPT settings | the adapter maps them to HTTP 429; `arx chatgpt status` links the page |

Everything is in [`lib/chatgpt_auth.py`](lib/chatgpt_auth.py) and
[`adapters/responses`](adapters/responses).
[`tests/test_chatgpt.py`](tests/test_chatgpt.py) checks each step with fake
OpenAI answers. Nothing in the tests reaches OpenAI.

## Limits

- **One account per state folder.** For a second account, use another
  `ARX_CHATGPT_DIR`.
- **No reasoning carried between turns.** With `store: false`, arx does not
  send the model's earlier reasoning back.
- **The tests use fake answers.** The flow was checked by hand against the
  live service on 2026-11-09: first sign-in, `arx models`, text and tool
  calls through the `responses` adapter, and a refresh that rotated the
  token.
