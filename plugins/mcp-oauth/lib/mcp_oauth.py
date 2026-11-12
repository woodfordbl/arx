"""mcp_oauth: OAuth 2.1 sign-in for HTTP MCP servers, as the MCP spec asks.

`login` finds the authorization server from the MCP server itself (the 401
challenge, then RFC 9728 and RFC 8414 metadata), gets a client id, runs the
authorization code flow with PKCE and the `resource` parameter in the
browser, and saves the tokens. `credential` prints the bearer header and
refreshes the access token under a lock, since providers rotate refresh
tokens. Tokens live in $ARX_CONFIG_DIR/mcp-oauth/, one 0600 file for each
issuer and resource, and are never printed.
"""
import base64
import hashlib
import http.server
import json
import os
import secrets
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

# The Client ID Metadata Document. Its URL is the client id, so it must not
# change: a new URL makes every user consent again.
CLIENT_METADATA_URL = "https://arx-documentation.vercel.app/oauth/mcp-client.json"
CLIENT_NAME = "arx"
CALLBACK_PATH = "/callback"
# Refresh this many seconds before the access token expires.
REFRESH_MARGIN = 300
PROBE = {"jsonrpc": "2.0", "id": 1, "method": "server/discover",
         "params": {}}


class AuthError(Exception):
    """A failure only you can fix: sign in again, or allow a scope."""


class TryLater(Exception):
    """A failure that may go away by itself: the network, or a 5xx."""


def state_dir():
    """The folder of the token files."""
    folder = os.environ.get("ARX_MCP_OAUTH_DIR")
    if folder:
        return folder
    config = os.environ.get("ARX_CONFIG_DIR")
    if not config:
        xdg = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser(
            "~/.config")
        config = os.path.join(xdg, "arx")
    return os.path.join(config, "mcp-oauth")


def record_path(issuer, resource):
    """The token file for one issuer and resource."""
    key = hashlib.sha256(("%s\n%s" % (issuer, resource)).encode()).hexdigest()
    return os.path.join(state_dir(), key[:24] + ".json")


def write_private(path, text):
    """Writes `text` to `path` atomically, readable by the owner only."""
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def records():
    """Every saved sign-in, as (path, record)."""
    found = []
    try:
        names = sorted(os.listdir(state_dir()))
    except FileNotFoundError:
        return found
    for name in names:
        if not name.endswith(".json"):
            continue
        path = os.path.join(state_dir(), name)
        try:
            with open(path) as f:
                record = json.load(f)
        except (OSError, ValueError):
            continue
        if isinstance(record, dict):
            found.append((path, record))
    return found


def find(server=None, url=None):
    """The (path, record) for a server name or URL, or (None, None)."""
    for path, record in records():
        if (url and record.get("url") == url) or (
                server and not url and record.get("server") == server):
            return path, record
    return None, None


def save(record):
    """Writes a record to the file of its issuer and resource."""
    path = record_path(record["issuer"], record["resource"])
    write_private(path, json.dumps(record, indent=2) + "\n")
    return path


class Lock:
    """A lock on one token file across processes: mkdir is atomic. A lock
    older than `stale` seconds belonged to a process that died."""

    def __init__(self, path, stale=120, wait=90):
        self.path = path + ".lock"
        self.stale = stale
        self.wait = wait

    def __enter__(self):
        os.makedirs(os.path.dirname(self.path), mode=0o700, exist_ok=True)
        deadline = time.time() + self.wait
        while True:
            try:
                os.mkdir(self.path)
                return self
            except FileExistsError:
                pass
            try:
                if time.time() - os.stat(self.path).st_mtime > self.stale:
                    os.rmdir(self.path)
                    continue
            except FileNotFoundError:
                continue
            if time.time() > deadline:
                raise TryLater("another process holds %s" % self.path)
            time.sleep(0.05)

    def __exit__(self, *exc):
        try:
            os.rmdir(self.path)
        except FileNotFoundError:
            pass


def call(url, form=None, body=None, headers=None):
    """GETs `url`, or POSTs `form` (form-encoded) or `body` (JSON).

    Returns (status, response headers in lower case, parsed JSON or {}).
    urllib uses $https_proxy, as curl does, so this works behind the same
    egress proxy as the model calls. It follows no redirect to another
    host's metadata by itself beyond what urllib does for GET.
    """
    data = None
    send = {"Accept": "application/json, text/event-stream",
            "User-Agent": "arx-mcp-oauth"}
    if form is not None:
        data = urllib.parse.urlencode(form).encode()
        send["Content-Type"] = "application/x-www-form-urlencoded"
    elif body is not None:
        data = json.dumps(body).encode()
        send["Content-Type"] = "application/json"
    send.update(headers or {})
    request = urllib.request.Request(url, data=data, headers=send)
    try:
        with urllib.request.urlopen(request, timeout=30) as r:
            status, raw, got = r.status, r.read(), r.headers
    except urllib.error.HTTPError as e:
        status, raw, got = e.code, e.read(), e.headers
    except (urllib.error.URLError, OSError) as e:
        host = urllib.parse.urlsplit(url).hostname
        raise TryLater("cannot reach %s: %s" % (host, getattr(e, "reason", e)))
    try:
        parsed = json.loads(raw or b"{}")
    except ValueError:
        parsed = {}
    return (status, {k.lower(): v for k, v in got.items()},
            parsed if isinstance(parsed, dict) else {})


def challenge_params(challenge):
    """The auth-params of a WWW-Authenticate value, as a dict."""
    params = {}
    rest = (challenge or "").partition(" ")[2]
    while rest:
        name, _, rest = rest.partition("=")
        name = name.strip(" ,")
        rest = rest.lstrip()
        if rest.startswith('"'):
            value, _, rest = rest[1:].partition('"')
        else:
            value, _, rest = rest.partition(",")
        if name:
            params[name.lower()] = value.strip()
    return params


def well_known(base, name):
    """The well-known URLs for `base`: with its path inserted (RFC 8414,
    RFC 9728), then at the root."""
    url = urllib.parse.urlsplit(base)
    root = "%s://%s" % (url.scheme, url.netloc)
    path = url.path.rstrip("/")
    urls = []
    if path:
        urls.append("%s/.well-known/%s%s" % (root, name, path))
    urls.append("%s/.well-known/%s" % (root, name))
    return urls


def protected_resource(url):
    """Finds the protected resource metadata of the MCP server at `url`.

    Returns (metadata, scope from the challenge). The server's 401 names the
    metadata URL; a server that sends none is asked at the well-known paths.
    """
    status, headers, _ = call(url, body=PROBE)
    params = challenge_params(headers.get("www-authenticate"))
    if status not in (401, 403) and not params:
        raise AuthError("%s answered %d without asking for a sign-in; it "
                        "may need no credential" % (url, status))
    candidates = []
    if params.get("resource_metadata"):
        candidates.append(params["resource_metadata"])
    candidates += well_known(url, "oauth-protected-resource")
    for candidate in candidates:
        status, _, metadata = call(candidate)
        if status == 200 and metadata.get("authorization_servers"):
            resource = metadata.get("resource") or url
            if not same_resource(resource, url):
                raise AuthError("%s describes %s, not %s" % (
                    candidate, resource, url))
            metadata["resource"] = resource
            return metadata, params.get("scope", "")
    raise AuthError("%s names no authorization server (no protected "
                    "resource metadata)" % url)


def same_resource(resource, url):
    """True when the metadata's `resource` covers the server's URL."""
    a, b = resource.rstrip("/"), url.rstrip("/")
    return a == b or b.startswith(a + "/")


def server_metadata(issuer):
    """The authorization server's metadata: RFC 8414, then OpenID Connect
    discovery. The `issuer` it states must be the one we asked for."""
    path = urllib.parse.urlsplit(issuer).path.rstrip("/")
    urls = well_known(issuer, "oauth-authorization-server")
    urls += well_known(issuer, "openid-configuration")
    if path:
        urls.append(issuer.rstrip("/") + "/.well-known/openid-configuration")
    for url in urls:
        status, _, metadata = call(url)
        if status != 200 or not metadata.get("authorization_endpoint"):
            continue
        if metadata.get("issuer", "").rstrip("/") != issuer.rstrip("/"):
            raise AuthError("%s says its issuer is %s, not %s" % (
                url, metadata.get("issuer"), issuer))
        if "S256" not in metadata.get("code_challenge_methods_supported", []):
            raise AuthError("%s does not support PKCE with S256, which MCP "
                            "requires" % issuer)
        return metadata
    raise AuthError("cannot find the metadata of the authorization server "
                    "%s" % issuer)


def client_id(metadata, redirect_uri, preset=None):
    """A client id, in the MCP spec's order: a pre-registered id, the
    Client ID Metadata Document, then dynamic registration."""
    if preset:
        return preset
    if metadata.get("client_id_metadata_document_supported"):
        return CLIENT_METADATA_URL
    endpoint = metadata.get("registration_endpoint")
    if not endpoint:
        raise AuthError(
            "%s takes neither a Client ID Metadata Document nor dynamic "
            "registration. Register arx there, then run login with "
            "--client-id ID" % metadata.get("issuer"))
    status, _, body = call(endpoint, body={
        "client_name": CLIENT_NAME,
        "application_type": "native",
        "redirect_uris": [redirect_uri],
        "grant_types": ["authorization_code", "refresh_token"],
        "response_types": ["code"],
        "token_endpoint_auth_method": "none"})
    if status not in (200, 201) or not body.get("client_id"):
        raise AuthError("%s refused to register arx (HTTP %d: %s)" % (
            metadata.get("issuer"), status, body.get("error", "")))
    return body["client_id"]


def b64url(data):
    """URL-safe base64 without padding."""
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def pkce():
    """A (verifier, S256 challenge) pair."""
    verifier = b64url(secrets.token_bytes(48))
    return verifier, b64url(hashlib.sha256(verifier.encode()).digest())


def check_callback(query, state, metadata):
    """Checks the redirect's query and returns the code. `iss` (RFC 9207)
    must be the issuer when the server sends it, and must be there when the
    server says it sends it."""
    if query.get("error"):
        raise AuthError("the sign-in was refused: %s %s" % (
            query["error"], query.get("error_description", "")))
    if not query.get("code") or query.get("state") != state:
        raise AuthError("the sign-in answer does not match this login "
                        "(state); try again")
    issuer = metadata.get("issuer", "")
    must = metadata.get("authorization_response_iss_parameter_supported")
    if "iss" in query and query["iss"].rstrip("/") != issuer.rstrip("/"):
        raise AuthError("the sign-in answer came from %s, not %s" % (
            query["iss"], issuer))
    if must and "iss" not in query:
        raise AuthError("the sign-in answer does not name its issuer (iss), "
                        "which %s says it sends" % issuer)
    return query["code"]


class _Callback(http.server.BaseHTTPRequestHandler):
    """Takes the one redirect back from the browser."""

    def do_GET(self):  # noqa: N802 (the name http.server calls)
        url = urllib.parse.urlsplit(self.path)
        if url.path != CALLBACK_PATH:
            self.send_error(404)
            return
        self.server.query = dict(urllib.parse.parse_qsl(url.query))
        done = "error" not in self.server.query
        page = ("<p>arx: you can close this tab and go back to the "
                "terminal.</p>" if done else
                "<p>arx: sign-in did not finish. See the terminal.</p>")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(page.encode())

    def log_message(self, *args):
        pass  # the query holds the authorization code: never log it


def wait_for_callback(server, timeout):
    """The callback's query, or an AuthError after `timeout` seconds."""
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    deadline = time.time() + timeout
    try:
        while server.query is None:
            if time.time() > deadline:
                raise AuthError("sign-in timed out; run the login again")
            time.sleep(0.05)
        return server.query
    finally:
        server.shutdown()
        server.server_close()


def apply_tokens(record, body):
    """Puts a token response into the record."""
    record["access_token"] = body["access_token"]
    if body.get("refresh_token"):
        record["refresh_token"] = body["refresh_token"]
    if body.get("scope"):
        record["scopes"] = body["scope"].split()
    expires = body.get("expires_in")
    record["expires_at"] = int(time.time() + float(expires)) if expires else 0


def server_url(server):
    """The URL of `server` in the spec, from `arx mcp list --json`."""
    arx = os.environ.get("ARX_BIN", "arx")
    try:
        out = subprocess.run([arx, "mcp", "list", "--json"], check=True,
                             capture_output=True, text=True).stdout
        servers = json.loads(out)
    except (OSError, subprocess.CalledProcessError, ValueError) as e:
        raise AuthError("cannot read the servers of the spec: %s" % e)
    for entry in servers:
        if entry.get("name") == server:
            if not entry.get("url"):
                raise AuthError("%s is a stdio server; OAuth is for `url:` "
                                "servers" % server)
            return entry["url"]
    raise AuthError("no server called %s in mcp_servers (%s)" % (
        server, ", ".join(e.get("name", "") for e in servers) or "none"))


def login(server, url, show_url, scope="", preset=None, timeout=300):
    """Signs in to the MCP server at `url` and saves the tokens.

    `show_url` opens or prints the authorization URL. Returns the record.
    """
    resource_meta, asked = protected_resource(url)
    issuer = resource_meta["authorization_servers"][0]
    metadata = server_metadata(issuer)
    listener = http.server.HTTPServer(("127.0.0.1", 0), _Callback)
    listener.query = None
    redirect_uri = "http://127.0.0.1:%d%s" % (
        listener.server_address[1], CALLBACK_PATH)
    try:
        client = client_id(metadata, redirect_uri, preset)
    except Exception:
        listener.server_close()
        raise
    verifier, challenge = pkce()
    state = b64url(secrets.token_bytes(24))
    scopes = " ".join(dict.fromkeys(
        (asked or " ".join(resource_meta.get("scopes_supported", []))).split()
        + scope.split()))
    params = {"response_type": "code", "client_id": client,
              "redirect_uri": redirect_uri, "state": state,
              "code_challenge": challenge, "code_challenge_method": "S256",
              "resource": resource_meta["resource"]}
    if scopes:
        params["scope"] = scopes
    joiner = "&" if "?" in metadata["authorization_endpoint"] else "?"
    show_url(metadata["authorization_endpoint"] + joiner +
             urllib.parse.urlencode(params, quote_via=urllib.parse.quote))
    code = check_callback(wait_for_callback(listener, timeout), state,
                          metadata)
    status, _, body = call(metadata["token_endpoint"], form={
        "grant_type": "authorization_code", "code": code,
        "redirect_uri": redirect_uri, "client_id": client,
        "code_verifier": verifier, "resource": resource_meta["resource"]})
    if status != 200 or not body.get("access_token"):
        raise AuthError("%s gave no token (HTTP %d: %s)" % (
            issuer, status, body.get("error_description") or
            body.get("error", "")))
    record = {"server": server, "url": url, "issuer": issuer,
              "resource": resource_meta["resource"], "client_id": client,
              "token_endpoint": metadata["token_endpoint"],
              "scopes": scopes.split()}
    apply_tokens(record, body)
    save(record)
    return record


def login_line(server, scope=""):
    """The command that signs in."""
    return "arx mcp-oauth login %s%s" % (
        server, ' --scope "%s"' % scope if scope else "")


def refresh(record):
    """Trades the refresh token for new tokens and saves them."""
    if not record.get("refresh_token"):
        raise AuthError("the sign-in to %s expired: run `%s`" % (
            record.get("server"), login_line(record.get("server"))))
    status, _, body = call(record["token_endpoint"], form={
        "grant_type": "refresh_token",
        "refresh_token": record["refresh_token"],
        "client_id": record["client_id"], "resource": record["resource"]})
    if status >= 500 or status == 429:
        raise TryLater("%s answered %d" % (record["issuer"], status))
    if status != 200 or not body.get("access_token"):
        record.pop("access_token", None)
        record.pop("refresh_token", None)
        save(record)
        raise AuthError("the sign-in to %s is no longer valid (%s): run "
                        "`%s`" % (record.get("server"),
                                  body.get("error", "HTTP %d" % status),
                                  login_line(record.get("server"))))
    apply_tokens(record, body)
    save(record)


def is_fresh(record):
    """True when the access token has more than the margin left."""
    expires = record.get("expires_at") or 0
    return bool(record.get("access_token")) and (
        not expires or time.time() < expires - REFRESH_MARGIN)


def credential(request):
    """The credential value for arx: the bearer header and its expiry.

    `request` is what arx gives the program: reason, server, url, and for
    reason `rejected` the status and the WWW-Authenticate challenge. This
    never opens a browser.
    """
    server = request.get("server") or "SERVER"
    path, record = find(server, request.get("url"))
    if not record or not (record.get("access_token") or
                          record.get("refresh_token")):
        raise AuthError("not signed in to %s: run `%s`" % (
            server, login_line(server)))
    rejected = request.get("reason") == "rejected"
    params = challenge_params(request.get("challenge"))
    if rejected and params.get("error") == "insufficient_scope":
        wanted = " ".join(dict.fromkeys(
            record.get("scopes", []) + params.get("scope", "").split()))
        raise AuthError("%s needs more access (%s): run `%s`" % (
            server, params.get("scope", "another scope"),
            login_line(server, wanted)))
    if rejected or not is_fresh(record):
        seen = record.get("access_token")
        with Lock(path):
            _, record = find(server, request.get("url"))
            # Another process may have refreshed while we waited.
            if not is_fresh(record) or record.get("access_token") == seen:
                refresh(record)
    value = {"headers": {"Authorization": "Bearer " + record["access_token"]}}
    if record.get("expires_at"):
        value["expires_at"] = record["expires_at"]
    return value


def logout(server):
    """Drops the tokens of `server`. Returns True when there were any."""
    path, _ = find(server)
    if not path:
        return False
    os.remove(path)
    return True
