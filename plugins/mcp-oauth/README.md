# mcp-oauth

The `mcp-oauth` plugin signs arx in to HTTP MCP servers with OAuth 2.1, so
their calls carry a bearer token. Use it for any `url:` server that answers
401 without a token.

It has two parts:

- **`arx mcp-oauth`**: a command that signs in, shows the status and signs
  out.
- **The `mcp-oauth` credential program**: prints the access token for the
  server's requests, and refreshes it before it expires. See
  [Credentials](../../docs/plugins/credentials.md).

A stdio server needs neither. It gets its key from its environment, with
`credential` and `api_key_env`. See [MCP servers](../../docs/mcp.md).

## Sign in

1. Install the plugin:

   ```bash
   arx plugin add mcp-oauth
   ```

2. Name its program in the server's entry:

   ```yaml
   # agent.yaml
   mcp_servers:
     linear:
       url: https://mcp.linear.app/mcp
       credential: mcp-oauth
   ```

3. Run the login from the folder of your spec:

   ```bash
   arx mcp-oauth login linear
   ```

   Your browser opens the server's sign-in page. On a machine without a
   browser, add `--no-browser` and open the link that arx prints on the
   same machine: the answer comes back to `http://127.0.0.1:<port>/callback`.

4. Check the result:

   ```bash
   arx mcp-oauth status
   ```

   ```text
   linear	https://mcp.linear.app/mcp	token for 59 min	read write
   ```

The agent can now call the server's tools. arx never prints a token, and
the agent process never holds one: the HTTP bridge runs the credential
program.

## Commands

| Command | What it does |
|---|---|
| `arx mcp-oauth login SERVER` | Signs in to a server of `mcp_servers` that has a `url`. |
| `arx mcp-oauth login SERVER --scope "a b"` | Asks for these scopes too. |
| `arx mcp-oauth login SERVER --no-browser` | Prints the link and waits. |
| `arx mcp-oauth login SERVER --client-id ID` | Uses a client id you registered with the server. `ARX_MCP_OAUTH_CLIENT_ID` does the same. |
| `arx mcp-oauth logout SERVER` | Drops the server's tokens. |
| `arx mcp-oauth status` | Lists the servers you're signed in to. |

## How the login finds the server

The login follows the MCP authorization spec, in this order:

1. It sends one request with no token and reads `resource_metadata` and
   `scope` from the `WWW-Authenticate` header of the 401.
2. It fetches the protected resource metadata (RFC 9728). A server that
   names no URL is asked at `/.well-known/oauth-protected-resource`.
3. It fetches the authorization server's metadata: RFC 8414 first, then
   OpenID Connect discovery. The `issuer` must match, and the server must
   support PKCE with `S256`.
4. It gets a client id: the one you gave, else the Client ID Metadata
   Document at `https://arx-documentation.vercel.app/oauth/mcp-client.json`
   when the server accepts one, else dynamic registration as a native app.
5. It runs the authorization code flow with PKCE and the `resource`
   parameter, and checks `state` and `iss` (RFC 9207) on the answer.

`client-metadata.json` in this folder is the document that the arx site
serves at that URL. The URL is the client id, so it never changes.

## Where the tokens live

Tokens are in `$ARX_CONFIG_DIR/mcp-oauth/`, in one file with mode 0600 for
each issuer and resource. Set `ARX_MCP_OAUTH_DIR` to move them.

The credential program refreshes the access token when less than 5 minutes
are left, under a lock, because providers rotate refresh tokens. Two arx
processes that refresh at once would lose the sign-in without it.

## Common mistakes

| Symptom | Cause | Fix |
|---|---|---|
| `not signed in to linear` | No tokens for this server's URL. | Run `arx mcp-oauth login linear`. |
| `linear needs more access (admin)` | The server answered 403 with `insufficient_scope`. | Run the login line that the message prints. It adds the scope. |
| `takes neither a Client ID Metadata Document nor dynamic registration` | The server wants a client you registered. | Register arx with the server, then pass `--client-id`. |
| The login waits forever with `--no-browser` | The link was opened on another machine. | Open it on the machine that runs arx, or forward the port. |
| Calls fail in a sandbox with a network list | The authorization server is another host. | Add its host to `hosts:` in your spec. |

> [!WARNING]
> A token lets its holder act as you on that server. Keep the token folder
> out of the folders your agent can read, and sign out of servers you no
> longer use.

## Related

- [MCP servers](../../docs/mcp.md): add a server and give the agent its
  tools.
- [Credentials](../../docs/plugins/credentials.md): the contract this
  program follows.
