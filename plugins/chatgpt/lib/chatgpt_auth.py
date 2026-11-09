"""chatgpt_auth: Sign in with ChatGPT for arx.

The credential program and `arx chatgpt` share this module. It follows
OpenAI's guide for open-source apps that use a ChatGPT plan:
https://developers.openai.com/siwc/token-sharing-open-source

The sign-in record lives in one 0600 file, auth.json, in the state folder:
$ARX_CHATGPT_DIR, else the arx config folder's chatgpt/. Every process that
shares the folder shares the record, and a lock makes sure that only one of
them uses the refresh token, because OpenAI rotates it on every refresh.
Nothing here prints a token.
"""

import base64
import hashlib
import hmac
import http.server
import json
import os
import secrets
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

ISSUER = "https://auth.openai.com"
AUTHORIZE_URL = ISSUER + "/api/accounts/authorize"
TOKEN_URL = ISSUER + "/api/accounts/oauth/token"
DISCOVERY_URL = ISSUER + "/.well-known/openid-configuration"
RESOURCE = "https://api.openai.com/v1"
SCOPES = ("openid profile email offline_access resource.invoke "
          "chatgpt.tokens.use.direct")
PLAN_SCOPE = "chatgpt.tokens.use.direct"
APP_NAME = "arx"
USAGE_URL = "https://chatgpt.com/settings/usage"
CALLBACK_PATH = "/auth/callback"
FIRST_PORT = 1455
# Refresh when less than this many seconds of the access token are left.
REFRESH_MARGIN = 300
# A refresh this recent already answered a rejected token.
RECENT_REFRESH = 60
# Refresh errors that mean the refresh token cannot be used again.
UNUSABLE = {"invalid_grant", "invalid_refresh_token", "token_expired",
            "refresh_token_expired", "refresh_token_invalidated",
            "refresh_token_reused"}
# DigestInfo prefix of a SHA-256 hash in an RSASSA-PKCS1-v1_5 signature.
SHA256_PREFIX = bytes.fromhex("3031300d060960864801650304020105000420")


class AuthError(Exception):
    """A failure that the user fixes, usually by signing in again."""


class TryLater(Exception):
    """A failure that may go away by itself: the network, or a 5xx."""


def state_dir():
    """The folder of auth.json and host-id."""
    folder = os.environ.get("ARX_CHATGPT_DIR")
    if folder:
        return folder
    config = os.environ.get("ARX_CONFIG_DIR")
    if not config:
        xdg = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser(
            "~/.config")
        config = os.path.join(xdg, "arx")
    return os.path.join(config, "chatgpt")


def auth_path():
    """The sign-in record."""
    return os.path.join(state_dir(), "auth.json")


def write_private(path, text):
    """Writes `text` to `path` atomically, readable by the owner only."""
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def load():
    """The sign-in record, or {} before the first sign-in."""
    try:
        with open(auth_path()) as f:
            record = json.load(f)
    except FileNotFoundError:
        return {}
    except ValueError:
        raise AuthError("%s is not valid JSON" % auth_path())
    return record if isinstance(record, dict) else {}


def save(record):
    """Replaces the sign-in record."""
    write_private(auth_path(), json.dumps(record, indent=2) + "\n")


def host_id():
    """This host's ext_agent_host_id, made once per state folder.

    OpenAI lets the app define a host. For arx it is a state folder, so
    containers that share the folder are one host, and a folder copied to
    another machine keeps that machine's own host-id file.
    """
    path = os.path.join(state_dir(), "host-id")
    try:
        with open(path) as f:
            value = f.read().strip()
        if value:
            return value
    except FileNotFoundError:
        pass
    value = "urn:uuid:" + str(uuid.uuid4())
    write_private(path, value + "\n")
    return value


class Lock:
    """A lock on the record across processes and containers.

    mkdir is atomic on every file system a bind mount uses. A lock older
    than `stale` seconds belonged to a process that died.
    """

    def __init__(self, stale=120, wait=90):
        self.path = auth_path() + ".lock"
        self.stale = stale
        self.wait = wait

    def __enter__(self):
        os.makedirs(state_dir(), mode=0o700, exist_ok=True)
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
            time.sleep(0.1)

    def __exit__(self, *exc):
        try:
            os.rmdir(self.path)
        except FileNotFoundError:
            pass


def _parse(raw):
    """A response body as a dict, or {}."""
    try:
        body = json.loads(raw or b"{}")
    except ValueError:
        return {}
    return body if isinstance(body, dict) else {}


def call(url, fields=None):
    """GETs `url`, or POSTs `fields` form-encoded. Returns (status, body).

    urllib uses $https_proxy, as curl does, so this works behind the same
    egress proxy as the model calls.
    """
    data = urllib.parse.urlencode(fields).encode() if fields else None
    headers = {"Accept": "application/json", "User-Agent": "arx-chatgpt"}
    if data:
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    req = urllib.request.Request(url, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, _parse(r.read())
    except urllib.error.HTTPError as e:
        return e.code, _parse(e.read())
    except (urllib.error.URLError, OSError) as e:
        host = urllib.parse.urlsplit(url).hostname
        raise TryLater("cannot reach %s: %s" % (host, getattr(e, "reason", e)))


def error_code(body):
    """(code, message) of an OAuth or OpenAI error body."""
    error = body.get("error")
    if isinstance(error, dict):
        return (str(error.get("code") or error.get("type") or ""),
                str(error.get("message") or ""))
    return str(error or ""), str(body.get("error_description") or "")


def discovery():
    """OpenAI's OpenID configuration: jwks_uri, revocation_endpoint, ..."""
    status, body = call(DISCOVERY_URL)
    if status != 200:
        raise TryLater("%s answered HTTP %d" % (DISCOVERY_URL, status))
    return body


def b64url_decode(text):
    """Decodes base64url without padding."""
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def b64url(data):
    """Encodes base64url without padding."""
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def rs256_valid(signed, signature, jwk):
    """True when `signature` is an RS256 signature of `signed` by `jwk`."""
    n = int.from_bytes(b64url_decode(jwk["n"]), "big")
    e = int.from_bytes(b64url_decode(jwk["e"]), "big")
    size = (n.bit_length() + 7) // 8
    s = int.from_bytes(signature, "big")
    if len(signature) != size or s >= n:
        return False
    digest = hashlib.sha256(signed).digest()
    padding = size - 3 - len(SHA256_PREFIX) - len(digest)
    if padding < 8:
        return False
    expected = (b"\x00\x01" + b"\xff" * padding + b"\x00" + SHA256_PREFIX +
                digest)
    return hmac.compare_digest(pow(s, e, n).to_bytes(size, "big"), expected)


def verify_id_token(token, client_id, nonce, jwks=None):
    """Checks an ID token's signature, issuer, audience, expiry and nonce.

    Returns its claims. `jwks` is fetched from OpenAI when not given.
    """
    try:
        head, payload, signature = token.split(".")
        header = json.loads(b64url_decode(head))
        claims = json.loads(b64url_decode(payload))
    except (ValueError, AttributeError):
        raise AuthError("the ID token is malformed")
    if header.get("alg") != "RS256":
        raise AuthError("the ID token uses %s, not RS256" % header.get("alg"))
    if jwks is None:
        status, jwks = call(discovery()["jwks_uri"])
        if status != 200:
            raise TryLater("cannot get OpenAI's signing keys")
    keys = [k for k in jwks.get("keys", [])
            if k.get("kty") == "RSA" and k.get("kid") == header.get("kid")]
    signed = ("%s.%s" % (head, payload)).encode()
    if not any(rs256_valid(signed, b64url_decode(signature), k) for k in keys):
        raise AuthError("the ID token's signature is not valid")
    audience = claims.get("aud")
    audiences = audience if isinstance(audience, list) else [audience]
    if claims.get("iss") != ISSUER or client_id not in audiences:
        raise AuthError("the ID token is for another issuer or client")
    if claims.get("exp", 0) < time.time() - 60:
        raise AuthError("the ID token has expired")
    if not hmac.compare_digest(str(claims.get("nonce", "")), nonce):
        raise AuthError("the ID token's nonce does not match this sign-in")
    if not claims.get("sub"):
        raise AuthError("the ID token has no subject")
    return claims


def apply_tokens(record, body):
    """Stores a token response in `record`: the access token, the rotated
    refresh token, the expiry and the granted scopes, together."""
    now = time.time()
    record["access_token"] = body["access_token"]
    if body.get("refresh_token"):
        record["refresh_token"] = body["refresh_token"]
    if body.get("id_token"):
        record["id_token"] = body["id_token"]
    if body.get("scope"):
        record["scopes"] = sorted(body["scope"].split())
    record["token_type"] = body.get("token_type", "Bearer")
    record["expires_at"] = int(now + int(body.get("expires_in", 3600)))
    record["refreshed_at"] = int(now)
    record["saved_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
    return record


def clear_tokens(record):
    """Drops the tokens, and keeps the client ID, account and host ID for
    the next sign-in."""
    for key in ("access_token", "refresh_token", "id_token", "expires_at",
                "refreshed_at", "token_type"):
        record.pop(key, None)
    return record


def refresh(record):
    """Refreshes the access token. Call it while holding Lock()."""
    status, body = call(TOKEN_URL, {
        "grant_type": "refresh_token",
        "client_id": record["client_id"],
        "refresh_token": record["refresh_token"],
        "resource": RESOURCE,
    })
    if status == 200 and body.get("access_token"):
        return apply_tokens(record, body)
    code, message = error_code(body)
    if status == 429 or status >= 500:
        raise TryLater("the token refresh answered HTTP %d %s" % (status, code))
    if code in UNUSABLE or status in (400, 401):
        save(clear_tokens(record))
        raise AuthError("the ChatGPT sign-in has expired or was revoked (%s):"
                        " run `arx chatgpt login`" % (code or status))
    raise AuthError("the token refresh failed: HTTP %d %s %s"
                    % (status, code, message))


def needs_refresh(record):
    """True when the access token is missing or about to expire."""
    return (not record.get("access_token") or
            time.time() >= record.get("expires_at", 0) - REFRESH_MARGIN)


def credential(reason):
    """The value for arx: the bearer header, base URL and expiry.

    `reason` is what arx sent: start, expired or rejected. A rejected token
    is refreshed unless another process refreshed it a moment ago.
    """
    record = load()
    if not record.get("refresh_token"):
        raise AuthError("not signed in to ChatGPT: run `arx chatgpt login`")
    if PLAN_SCOPE not in record.get("scopes", []):
        raise AuthError("ChatGPT plan usage is not allowed for arx: run "
                        "`arx chatgpt login` and allow it")
    if reason == "rejected" or needs_refresh(record):
        with Lock():
            record = load()  # another process may have refreshed already
            recent = time.time() - record.get("refreshed_at", 0)
            forced = reason == "rejected" and recent > RECENT_REFRESH
            if forced or needs_refresh(record):
                if not record.get("refresh_token"):
                    raise AuthError("not signed in to ChatGPT: run "
                                    "`arx chatgpt login`")
                save(refresh(record))
    return {
        "headers": {"Authorization": "Bearer " + record["access_token"]},
        "base_url": RESOURCE,
        "expires_at": record["expires_at"],
    }


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


def listen():
    """A loopback server for the callback: on 127.0.0.1:1455, as OpenAI's
    guide shows, else on any free port."""
    for port in (FIRST_PORT, 0):
        try:
            server = http.server.HTTPServer(("127.0.0.1", port), _Callback)
            server.query = None
            return server
        except OSError:
            continue
    raise AuthError("cannot listen on 127.0.0.1 for the sign-in callback")


def authorize_url(record, redirect_uri, state, nonce, challenge):
    """The URL that starts sign-in: a new registration of arx with
    dynamic_agent_client, or a sign-in with the saved client ID."""
    params = {
        "client_id": record.get("client_id") or "dynamic_agent_client",
        "ext_agent_host_id": host_id(),
        "response_type": "code",
        "redirect_uri": redirect_uri,
        "scope": SCOPES,
        "resource": RESOURCE,
        "state": state,
        "nonce": nonce,
        "code_challenge_method": "S256",
        "code_challenge": challenge,
    }
    if not record.get("client_id"):
        params["agent_name_hint"] = APP_NAME
    if record.get("email"):
        params["login_hint"] = record["email"]
    return AUTHORIZE_URL + "?" + urllib.parse.urlencode(
        params, quote_via=urllib.parse.quote)


def wait_for_callback(server, timeout):
    """The callback's query, or an AuthError after `timeout` seconds."""
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    deadline = time.time() + timeout
    try:
        while server.query is None:
            if time.time() > deadline:
                raise AuthError("sign-in timed out; run `arx chatgpt login` "
                                "again")
            time.sleep(0.1)
        return server.query
    finally:
        server.shutdown()
        server.server_close()


def login(show_url, timeout=300, jwks=None):
    """Signs in with ChatGPT and saves the record. `show_url(url)` opens or
    prints the authorization URL. Returns (record, first), where `first` is
    true the first time this folder has plan usage enabled."""
    old = load()
    server = listen()
    redirect_uri = "http://127.0.0.1:%d%s" % (server.server_address[1],
                                              CALLBACK_PATH)
    state, nonce = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
    verifier = secrets.token_urlsafe(64)
    challenge = b64url(hashlib.sha256(verifier.encode()).digest())
    show_url(authorize_url(old, redirect_uri, state, nonce, challenge))
    query = wait_for_callback(server, timeout)
    if not hmac.compare_digest(query.get("state", ""), state):
        raise AuthError("the callback's state does not match; nothing changed")
    if query.get("error"):
        raise AuthError("sign-in stopped: %s %s" % (
            query["error"], query.get("error_description", "")))
    client_id = old.get("client_id")
    issued = query.get("client_id")
    if not client_id:
        if not issued or issued == "dynamic_agent_client":
            raise AuthError("registration did not finish: OpenAI sent no "
                            "client ID; run `arx chatgpt login` again")
        client_id = issued
    elif issued and issued != client_id:
        raise AuthError("the callback named another client ID; nothing "
                        "changed")
    status, body = call(TOKEN_URL, {
        "grant_type": "authorization_code",
        "client_id": client_id,
        "code": query.get("code", ""),
        "code_verifier": verifier,
        "redirect_uri": redirect_uri,
        "resource": RESOURCE,
    })
    if status != 200 or not body.get("access_token"):
        code, message = error_code(body)
        raise AuthError("the sign-in code was not accepted (HTTP %d %s %s); "
                        "run `arx chatgpt login` again"
                        % (status, code, message))
    claims = verify_id_token(body.get("id_token", ""), client_id, nonce, jwks)
    if old.get("subject") and old.get("client_id") == client_id and \
            claims["sub"] != old["subject"]:
        raise AuthError("you signed in to another ChatGPT account than the "
                        "saved one; nothing changed. `arx chatgpt logout "
                        "--forget` drops the saved one first")
    record = dict(old, issuer=ISSUER, subject=claims["sub"],
                  email=claims.get("email", old.get("email", "")),
                  client_id=client_id, ext_agent_host_id=host_id())
    apply_tokens(record, body)
    first = PLAN_SCOPE in record.get("scopes", []) and \
        not old.get("plan_notice_shown")
    if first:
        record["plan_notice_shown"] = True
    save(record)
    return record, first


def logout(forget=False):
    """Revokes the refresh token and drops the tokens. Returns True when
    OpenAI confirmed the revocation. `forget` also drops the client ID and
    account, so the next sign-in registers arx again."""
    record = load()
    confirmed = False
    if record.get("refresh_token") and record.get("client_id"):
        try:
            endpoint = discovery().get("revocation_endpoint")
            if endpoint:
                status, _ = call(endpoint, {
                    "token": record["refresh_token"],
                    "token_type_hint": "refresh_token",
                    "client_id": record["client_id"],
                })
                confirmed = status == 200
        except TryLater:
            pass
    if forget:
        try:
            os.remove(auth_path())
        except FileNotFoundError:
            pass
    elif record:
        save(clear_tokens(record))
    return confirmed
