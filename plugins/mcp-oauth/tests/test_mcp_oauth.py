"""Tests for the mcp-oauth plugin: discovery, the iss table, PKCE, client
ids, token refresh under the lock, and the credential program's exit codes.

Run with `python3 plugins/mcp-oauth/tests/test_mcp_oauth.py`;
tests/mcp-http.sh does. Nothing here reaches the network: a fake MCP server
and authorization server listen on 127.0.0.1.
"""
import base64
import hashlib
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
import urllib.request

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
import mcp_oauth as oauth  # noqa: E402

os.environ["no_proxy"] = os.environ["NO_PROXY"] = "127.0.0.1,localhost"
PROGRAM = os.path.join(HERE, "..", "credentials", "mcp-oauth")


class Fake(http.server.BaseHTTPRequestHandler):
    """One server that is the MCP server (/mcp) and its authorization
    server (/as). `self.server.mode` picks the behavior."""

    def reply(self, status, body=None, headers=None):
        raw = json.dumps(body).encode() if body is not None else b""
        self.send_response(status)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def metadata(self):
        base, mode = self.server.base, self.server.mode
        meta = {"issuer": base + "/as",
                "authorization_endpoint": base + "/as/authorize",
                "token_endpoint": base + "/as/token",
                "code_challenge_methods_supported": ["S256"]}
        if "cimd" in mode:
            meta["client_id_metadata_document_supported"] = True
        if "dcr" in mode:
            meta["registration_endpoint"] = base + "/as/register"
        if "iss" in mode:
            meta["authorization_response_iss_parameter_supported"] = True
        if "plain" in mode:
            meta["code_challenge_methods_supported"] = ["plain"]
        if "wrong-issuer" in mode:
            meta["issuer"] = "https://evil.example"
        return meta

    def do_GET(self):  # noqa: N802
        url = urllib.parse.urlsplit(self.path)
        base, mode = self.server.base, self.server.mode
        self.server.seen.append(url.path)
        if url.path == "/.well-known/oauth-protected-resource/mcp":
            self.reply(200, {"resource": base + "/mcp",
                             "authorization_servers": [base + "/as"],
                             "scopes_supported": ["read"]})
        elif (url.path == "/.well-known/oauth-authorization-server/as"
              and "oidc" not in mode):
            self.reply(200, self.metadata())
        elif url.path == "/.well-known/openid-configuration/as":
            self.reply(200, self.metadata())
        elif url.path == "/as/authorize":
            query = dict(urllib.parse.parse_qsl(url.query))
            self.server.authorize = query
            back = {"code": "code-1", "state": query.get("state", "")}
            if "send-iss" in mode:
                back["iss"] = base + "/as"
            if "bad-iss" in mode:
                back["iss"] = "https://evil.example"
            if "bad-state" in mode:
                back["state"] = "other"
            self.reply(302, headers={"Location": "%s?%s" % (
                query["redirect_uri"], urllib.parse.urlencode(back))})
        else:
            self.reply(404, {})

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode()
        base, mode = self.server.base, self.server.mode
        self.server.seen.append(self.path)
        if self.path == "/mcp":
            challenge = 'Bearer scope="read write"'
            if "no-pointer" not in mode:
                challenge += (', resource_metadata="%s/.well-known/'
                              'oauth-protected-resource/mcp"' % base)
            self.reply(401, {}, {"WWW-Authenticate": challenge})
        elif self.path == "/as/register":
            self.server.registration = json.loads(raw)
            self.reply(201, {"client_id": "dyn-1"})
        elif self.path == "/as/token":
            form = dict(urllib.parse.parse_qsl(raw))
            self.server.tokens.append(form)
            if "token-down" in mode:
                self.reply(503, {})
            elif "revoked" in mode:
                self.reply(400, {"error": "invalid_grant"})
            else:
                n = len(self.server.tokens)
                self.reply(200, {"access_token": "access-%d" % n,
                                 "refresh_token": "refresh-%d" % n,
                                 "expires_in": 3600, "scope": "read write"})
        else:
            self.reply(404, {})

    def log_message(self, *args):
        pass


def browser(url):
    """Stands in for the browser: follows the sign-in redirect."""
    def go():
        try:
            urllib.request.urlopen(url, timeout=10).read()
        except OSError:
            pass
    threading.Thread(target=go, daemon=True).start()


class Case(unittest.TestCase):
    """A fake server and an empty state folder for each test."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        os.environ["ARX_MCP_OAUTH_DIR"] = self.dir.name
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fake)
        self.server.base = "http://127.0.0.1:%d" % self.server.server_port
        self.server.mode = "cimd"
        self.server.seen, self.server.tokens = [], []
        self.server.authorize = self.server.registration = None
        threading.Thread(target=self.server.serve_forever,
                         daemon=True).start()
        self.url = self.server.base + "/mcp"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.dir.cleanup()

    def login(self, mode="cimd", **options):
        self.server.mode = mode
        return oauth.login("linear", self.url, browser, timeout=10, **options)

    def seed(self, **fields):
        record = {"server": "linear", "url": self.url,
                  "issuer": self.server.base + "/as", "resource": self.url,
                  "client_id": "c", "scopes": ["read"],
                  "token_endpoint": self.server.base + "/as/token",
                  "access_token": "old", "refresh_token": "r0",
                  "expires_at": int(time.time()) + 3600}
        record.update(fields)
        return oauth.save(record)

    def program(self, request):
        return subprocess.run([sys.executable, PROGRAM],
                              input=json.dumps(request), text=True,
                              capture_output=True)


class Discovery(Case):
    def test_challenge_then_rfc9728_then_rfc8414(self):
        record = self.login()
        self.assertEqual(record["issuer"], self.server.base + "/as")
        self.assertEqual(record["resource"], self.url)
        self.assertIn("/.well-known/oauth-authorization-server/as",
                      self.server.seen)
        self.assertNotIn("/.well-known/openid-configuration/as",
                         self.server.seen)

    def test_openid_discovery_is_the_fallback(self):
        self.login("cimd,oidc")
        self.assertIn("/.well-known/openid-configuration/as",
                      self.server.seen)

    def test_well_known_path_without_a_pointer(self):
        record = self.login("cimd,no-pointer")
        self.assertEqual(record["access_token"], "access-1")

    def test_the_issuer_must_match(self):
        with self.assertRaisesRegex(oauth.AuthError, "issuer"):
            self.login("cimd,wrong-issuer")

    def test_s256_is_required(self):
        with self.assertRaisesRegex(oauth.AuthError, "S256"):
            self.login("cimd,plain")

    def test_challenge_params(self):
        params = oauth.challenge_params(
            'Bearer error="insufficient_scope", scope="a b", realm=x')
        self.assertEqual(params, {"error": "insufficient_scope",
                                  "scope": "a b", "realm": "x"})


class Flow(Case):
    def test_pkce_resource_and_scopes(self):
        self.login(scope="extra")
        asked, token = self.server.authorize, self.server.tokens[0]
        digest = hashlib.sha256(token["code_verifier"].encode()).digest()
        self.assertEqual(asked["code_challenge"],
                         base64.urlsafe_b64encode(digest).rstrip(b"=").decode())
        self.assertEqual(asked["code_challenge_method"], "S256")
        self.assertEqual(asked["resource"], self.url)
        self.assertEqual(token["resource"], self.url)
        self.assertEqual(asked["scope"], "read write extra")
        self.assertTrue(asked["redirect_uri"].startswith("http://127.0.0.1:"))
        self.assertTrue(asked["redirect_uri"].endswith("/callback"))
        self.assertEqual(token["redirect_uri"], asked["redirect_uri"])

    def test_tokens_are_saved_private(self):
        record = self.login()
        path = oauth.record_path(record["issuer"], record["resource"])
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        self.assertEqual(oauth.find("linear")[1]["refresh_token"], "refresh-1")

    def test_client_id_order(self):
        self.assertEqual(self.login("cimd,dcr", preset="mine")["client_id"],
                         "mine")
        self.assertEqual(self.login("cimd,dcr")["client_id"],
                         oauth.CLIENT_METADATA_URL)
        self.assertEqual(self.login("dcr")["client_id"], "dyn-1")
        self.assertEqual(self.server.registration["application_type"],
                         "native")
        self.assertEqual(
            self.server.registration["token_endpoint_auth_method"], "none")
        with self.assertRaisesRegex(oauth.AuthError, "--client-id"):
            self.login("")

    def test_state_must_match(self):
        with self.assertRaisesRegex(oauth.AuthError, "state"):
            self.login("cimd,bad-state")

    def test_iss_table(self):
        meta = {"issuer": "https://as.example"}
        says = dict(meta, authorization_response_iss_parameter_supported=True)
        ok = {"code": "c", "state": "s"}
        named = dict(ok, iss="https://as.example")
        wrong = dict(ok, iss="https://evil.example")
        self.assertEqual(oauth.check_callback(ok, "s", meta), "c")
        self.assertEqual(oauth.check_callback(named, "s", meta), "c")
        self.assertEqual(oauth.check_callback(named, "s", says), "c")
        for query, metadata in ((wrong, meta), (wrong, says), (ok, says)):
            with self.assertRaises(oauth.AuthError):
                oauth.check_callback(query, "s", metadata)

    def test_iss_in_the_flow(self):
        self.assertTrue(self.login("cimd,iss,send-iss")["access_token"])
        with self.assertRaisesRegex(oauth.AuthError, "issuer"):
            self.login("cimd,iss")
        with self.assertRaisesRegex(oauth.AuthError, "evil"):
            self.login("cimd,bad-iss")


class Credential(Case):
    def test_a_fresh_token_is_used_as_it_is(self):
        self.seed()
        value = oauth.credential({"server": "linear", "url": self.url})
        self.assertEqual(value["headers"], {"Authorization": "Bearer old"})
        self.assertGreater(value["expires_at"], time.time())
        self.assertEqual(self.server.tokens, [])

    def test_refresh_before_expiry_and_rotation(self):
        self.seed(expires_at=int(time.time()) + 60)
        value = oauth.credential({"server": "linear", "url": self.url})
        self.assertEqual(value["headers"]["Authorization"], "Bearer access-1")
        self.assertEqual(self.server.tokens[0]["refresh_token"], "r0")
        self.assertEqual(self.server.tokens[0]["resource"], self.url)
        self.assertEqual(oauth.find("linear")[1]["refresh_token"], "refresh-1")

    def test_rejected_refreshes_a_token_that_looks_fresh(self):
        self.seed()
        value = oauth.credential({"server": "linear", "url": self.url,
                                  "reason": "rejected", "status": 401})
        self.assertEqual(value["headers"]["Authorization"], "Bearer access-1")

    def test_one_refresh_under_the_lock(self):
        self.seed(expires_at=int(time.time()) + 60)
        request = {"server": "linear", "url": self.url}
        values = []
        threads = [threading.Thread(
            target=lambda: values.append(oauth.credential(request)))
            for _ in range(4)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(len(self.server.tokens), 1)
        self.assertEqual({v["headers"]["Authorization"] for v in values},
                         {"Bearer access-1"})

    def test_exit_1_without_a_sign_in(self):
        done = self.program({"reason": "start", "server": "linear",
                             "url": self.url})
        self.assertEqual(done.returncode, 1)
        self.assertIn("arx mcp-oauth login linear", done.stderr)
        self.assertEqual(done.stdout, "")

    def test_exit_1_for_insufficient_scope_names_the_scopes(self):
        self.seed()
        done = self.program({
            "reason": "rejected", "server": "linear", "url": self.url,
            "status": 403,
            "challenge": 'Bearer error="insufficient_scope", scope="admin"'})
        self.assertEqual(done.returncode, 1)
        self.assertIn('arx mcp-oauth login linear --scope "read admin"',
                      done.stderr)

    def test_exit_1_when_the_refresh_token_is_revoked(self):
        self.seed(expires_at=1)
        self.server.mode = "revoked"
        done = self.program({"server": "linear", "url": self.url})
        self.assertEqual(done.returncode, 1)
        self.assertIn("arx mcp-oauth login linear", done.stderr)
        self.assertNotIn("refresh_token", oauth.find("linear")[1])

    def test_exit_75_for_the_network_and_5xx(self):
        self.seed(expires_at=1)
        self.server.mode = "token-down"
        done = self.program({"server": "linear", "url": self.url})
        self.assertEqual(done.returncode, 75)
        self.seed(expires_at=1, token_endpoint="http://127.0.0.1:9/token")
        done = self.program({"server": "linear", "url": self.url})
        self.assertEqual(done.returncode, 75)

    def test_exit_0_prints_the_header(self):
        self.seed()
        done = self.program({"server": "linear", "url": self.url})
        self.assertEqual(done.returncode, 0)
        self.assertEqual(json.loads(done.stdout)["headers"],
                         {"Authorization": "Bearer old"})

    def test_logout(self):
        self.seed()
        self.assertTrue(oauth.logout("linear"))
        self.assertFalse(oauth.logout("linear"))
        self.assertEqual(oauth.records(), [])


if __name__ == "__main__":
    unittest.main()
