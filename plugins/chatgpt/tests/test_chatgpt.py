"""Tests for the chatgpt plugin: sign-in, refresh, ID tokens, the adapter.

Run with `python3 plugins/chatgpt/tests/test_chatgpt.py`; tests/credentials.sh
does. Nothing here reaches the network: `call` is replaced by fakes, and the
ID tokens are signed with a throwaway RSA key made here.
"""
import hashlib
import io
import json
import os
import random
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
import urllib.request
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
import chatgpt_auth as auth  # noqa: E402

_loader = SourceFileLoader(
    "responses", os.path.join(HERE, "..", "adapters", "responses"))
adapter = module_from_spec(spec_from_loader("responses", _loader))
_loader.exec_module(adapter)


def probable_prime(bits, rng):
    """A random prime of `bits` bits (Miller-Rabin, 32 rounds)."""
    while True:
        n = rng.getrandbits(bits) | (1 << (bits - 1)) | 1
        d, r = n - 1, 0
        while d % 2 == 0:
            d, r = d // 2, r + 1
        for _ in range(32):
            x = pow(rng.randrange(2, n - 1), d, n)
            if x in (1, n - 1):
                continue
            for _ in range(r - 1):
                x = pow(x, 2, n)
                if x == n - 1:
                    break
            else:
                break
        else:
            return n


def make_key(seed=7):
    """(public JWK, private exponent) of a 1024-bit RSA key."""
    rng = random.Random(seed)
    e = 65537
    while True:
        p, q = probable_prime(512, rng), probable_prime(512, rng)
        phi = (p - 1) * (q - 1)
        if p != q and phi % e:
            break
    n = p * q
    size = (n.bit_length() + 7) // 8
    jwk = {"kty": "RSA", "kid": "test-key",
           "n": auth.b64url(n.to_bytes(size, "big")),
           "e": auth.b64url(e.to_bytes(3, "big"))}
    return jwk, pow(e, -1, phi), n


JWK, PRIVATE, MODULUS = make_key()
JWKS = {"keys": [JWK]}


def sign(claims, alg="RS256", kid="test-key"):
    """An ID token for `claims`, signed with the test key."""
    head = auth.b64url(json.dumps({"alg": alg, "kid": kid}).encode())
    body = auth.b64url(json.dumps(claims).encode())
    signed = ("%s.%s" % (head, body)).encode()
    size = (MODULUS.bit_length() + 7) // 8
    digest = hashlib.sha256(signed).digest()
    pad = size - 3 - len(auth.SHA256_PREFIX) - len(digest)
    em = (b"\x00\x01" + b"\xff" * pad + b"\x00" + auth.SHA256_PREFIX + digest)
    s = pow(int.from_bytes(em, "big"), PRIVATE, MODULUS)
    return "%s.%s" % (head + "." + body, auth.b64url(s.to_bytes(size, "big")))


def claims(**over):
    """Valid ID token claims, with `over` on top."""
    base = {"iss": auth.ISSUER, "aud": "oaiapp_1", "sub": "user-1",
            "email": "me@example.com", "nonce": "n1",
            "exp": int(time.time()) + 600}
    base.update(over)
    return base


class FakeHttp:
    """Stands in for auth.call: answers each URL from a table and records
    the calls."""

    def __init__(self, answers):
        self.answers = answers
        self.calls = []

    def __call__(self, url, fields=None):
        self.calls.append((url, dict(fields or {})))
        answer = self.answers.get(url)
        if answer is None:
            raise AssertionError("unexpected request to %s" % url)
        if isinstance(answer, Exception):
            raise answer
        return answer(fields) if callable(answer) else answer


class StateTest(unittest.TestCase):
    """Each test gets its own state folder, and the real `call` back."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        os.environ["ARX_CHATGPT_DIR"] = self.dir
        self.call = auth.call

    def tearDown(self):
        auth.call = self.call

    def fake(self, answers):
        auth.call = FakeHttp(answers)
        return auth.call

    def signed_in(self, **over):
        record = {"client_id": "oaiapp_1", "subject": "user-1",
                  "email": "me@example.com", "access_token": "access-1",
                  "refresh_token": "refresh-1",
                  "expires_at": int(time.time()) + 3600, "refreshed_at": 0,
                  "scopes": sorted(auth.SCOPES.split())}
        record.update(over)
        auth.save(record)
        return record


class IdTokenTest(unittest.TestCase):
    def test_valid(self):
        got = auth.verify_id_token(sign(claims()), "oaiapp_1", "n1", JWKS)
        self.assertEqual(got["sub"], "user-1")

    def test_audience_list(self):
        token = sign(claims(aud=["other", "oaiapp_1"]))
        auth.verify_id_token(token, "oaiapp_1", "n1", JWKS)

    def test_rejected(self):
        bad = {
            "nonce": sign(claims(nonce="other")),
            "audience": sign(claims(aud="other")),
            "issuer": sign(claims(iss="https://evil.example.com")),
            "expired": sign(claims(exp=int(time.time()) - 3600)),
            "algorithm": sign(claims(), alg="HS256"),
            "key": sign(claims(), kid="unknown"),
            "malformed": "not-a-token",
        }
        for what, token in bad.items():
            with self.subTest(what), self.assertRaises(auth.AuthError):
                auth.verify_id_token(token, "oaiapp_1", "n1", JWKS)

    def test_tampered(self):
        head, body, sig = sign(claims()).split(".")
        other = auth.b64url(json.dumps(claims(sub="user-2")).encode())
        with self.assertRaises(auth.AuthError):
            auth.verify_id_token("%s.%s.%s" % (head, other, sig), "oaiapp_1",
                                 "n1", JWKS)


class CredentialTest(StateTest):
    def refreshed(self, fields):
        self.assertEqual(fields, {
            "grant_type": "refresh_token", "client_id": "oaiapp_1",
            "refresh_token": "refresh-1", "resource": auth.RESOURCE})
        return 200, {"access_token": "access-2", "refresh_token": "refresh-2",
                     "expires_in": 3600, "scope": auth.SCOPES}

    def test_fresh_token_is_used_as_it_is(self):
        self.signed_in()
        fake = self.fake({})
        value = auth.credential("start")
        self.assertEqual(value["headers"],
                         {"Authorization": "Bearer access-1"})
        self.assertEqual(value["base_url"], "https://api.openai.com/v1")
        self.assertEqual(fake.calls, [])

    def test_expiring_token_is_refreshed_and_rotated(self):
        self.signed_in(expires_at=int(time.time()) + 60)
        self.fake({auth.TOKEN_URL: self.refreshed})
        value = auth.credential("expired")
        self.assertEqual(value["headers"]["Authorization"], "Bearer access-2")
        saved = auth.load()
        self.assertEqual(saved["refresh_token"], "refresh-2")
        self.assertGreater(saved["expires_at"], time.time() + 3000)
        self.assertEqual(os.stat(auth.auth_path()).st_mode & 0o777, 0o600)
        self.assertFalse(os.path.exists(auth.auth_path() + ".lock"))

    def test_rejected_token_is_refreshed(self):
        self.signed_in(refreshed_at=int(time.time()) - 600)
        self.fake({auth.TOKEN_URL: self.refreshed})
        self.assertEqual(auth.credential("rejected")["headers"]
                         ["Authorization"], "Bearer access-2")

    def test_rejected_right_after_a_refresh_is_not_refreshed_again(self):
        self.signed_in(refreshed_at=int(time.time()))
        fake = self.fake({})
        auth.credential("rejected")
        self.assertEqual(fake.calls, [])

    def test_unusable_refresh_token_signs_out(self):
        self.signed_in(expires_at=0)
        self.fake({auth.TOKEN_URL: (400, {"error": "invalid_grant"})})
        with self.assertRaises(auth.AuthError) as e:
            auth.credential("expired")
        self.assertIn("arx chatgpt login", str(e.exception))
        saved = auth.load()
        self.assertNotIn("refresh_token", saved)
        self.assertEqual(saved["client_id"], "oaiapp_1")

    def test_server_trouble_is_try_later(self):
        self.signed_in(expires_at=0)
        self.fake({auth.TOKEN_URL: (503, {})})
        with self.assertRaises(auth.TryLater):
            auth.credential("expired")
        self.assertEqual(auth.load()["refresh_token"], "refresh-1")

    def test_network_trouble_is_try_later(self):
        self.signed_in(expires_at=0)
        self.fake({auth.TOKEN_URL: auth.TryLater("no network")})
        with self.assertRaises(auth.TryLater):
            auth.credential("expired")

    def test_not_signed_in(self):
        with self.assertRaises(auth.AuthError):
            auth.credential("start")

    def test_plan_usage_not_allowed(self):
        self.signed_in(scopes=["email", "openid", "profile"])
        with self.assertRaises(auth.AuthError) as e:
            auth.credential("start")
        self.assertIn("not allowed", str(e.exception))

    def test_stale_lock_is_taken_over(self):
        self.signed_in()
        os.mkdir(auth.auth_path() + ".lock")
        old = time.time() - 600
        os.utime(auth.auth_path() + ".lock", (old, old))
        with auth.Lock():
            pass
        self.assertFalse(os.path.exists(auth.auth_path() + ".lock"))

    def test_host_id_is_made_once(self):
        first = auth.host_id()
        self.assertTrue(first.startswith("urn:uuid:"))
        self.assertEqual(auth.host_id(), first)


class LoginTest(StateTest):
    def setUp(self):
        super().setUp()
        self.port = auth.FIRST_PORT
        auth.FIRST_PORT = 0  # any free port, so tests never collide

    def tearDown(self):
        auth.FIRST_PORT = self.port
        super().tearDown()

    def browser(self, extra=None, state=None):
        """A show_url that checks the URL, then follows the redirect as a
        browser would after the user allows arx."""
        def show(url):
            parts = urllib.parse.urlsplit(url)
            self.params = dict(urllib.parse.parse_qsl(parts.query))
            query = {"code": "code-1",
                     "state": state or self.params["state"]}
            query.update(extra or {})
            target = self.params["redirect_uri"] + "?" + \
                urllib.parse.urlencode(query)
            threading.Thread(target=lambda: urllib.request.urlopen(
                target, timeout=10).read(), daemon=True).start()
        return show

    def token_endpoint(self, **over):
        def answer(fields):
            self.exchange = fields
            token = sign(claims(nonce=self.params["nonce"], **over))
            return 200, {"access_token": "access-1",
                         "refresh_token": "refresh-1", "id_token": token,
                         "expires_in": 3600, "scope": auth.SCOPES}
        return answer

    def test_first_sign_in_registers_arx(self):
        self.fake({auth.TOKEN_URL: self.token_endpoint()})
        record, first = auth.login(
            self.browser({"client_id": "oaiapp_1"}), timeout=10, jwks=JWKS)
        p = self.params
        self.assertEqual(p["client_id"], "dynamic_agent_client")
        self.assertEqual(p["agent_name_hint"], "arx")
        self.assertTrue(p["ext_agent_host_id"].startswith("urn:uuid:"))
        self.assertEqual(p["code_challenge_method"], "S256")
        self.assertIn(auth.PLAN_SCOPE, p["scope"].split())
        self.assertEqual(p["resource"], auth.RESOURCE)
        self.assertTrue(p["redirect_uri"].startswith("http://127.0.0.1:"))
        self.assertTrue(p["redirect_uri"].endswith("/auth/callback"))
        x = self.exchange
        self.assertEqual(x["grant_type"], "authorization_code")
        self.assertEqual(x["client_id"], "oaiapp_1")
        self.assertEqual(x["redirect_uri"], p["redirect_uri"])
        challenge = auth.b64url(hashlib.sha256(
            x["code_verifier"].encode()).digest())
        self.assertEqual(challenge, p["code_challenge"])
        self.assertTrue(first)
        self.assertEqual(record["client_id"], "oaiapp_1")
        self.assertEqual(auth.load()["subject"], "user-1")

    def test_second_sign_in_reuses_the_client(self):
        self.signed_in(plan_notice_shown=True)
        self.fake({auth.TOKEN_URL: self.token_endpoint()})
        record, first = auth.login(self.browser(), timeout=10, jwks=JWKS)
        self.assertEqual(self.params["client_id"], "oaiapp_1")
        self.assertNotIn("agent_name_hint", self.params)
        self.assertEqual(self.params["login_hint"], "me@example.com")
        self.assertFalse(first)

    def test_another_account_changes_nothing(self):
        self.signed_in()
        self.fake({auth.TOKEN_URL: self.token_endpoint(sub="user-2")})
        with self.assertRaises(auth.AuthError):
            auth.login(self.browser(), timeout=10, jwks=JWKS)
        self.assertEqual(auth.load()["access_token"], "access-1")

    def test_wrong_state_is_refused(self):
        self.fake({})
        with self.assertRaises(auth.AuthError):
            auth.login(self.browser({"client_id": "oaiapp_1"}, state="x"),
                       timeout=10, jwks=JWKS)
        self.assertEqual(auth.load(), {})

    def test_declined_consent(self):
        self.fake({})
        with self.assertRaises(auth.AuthError) as e:
            auth.login(self.browser({"error": "access_denied"}), timeout=10,
                       jwks=JWKS)
        self.assertIn("access_denied", str(e.exception))

    def test_registration_without_client_id(self):
        self.fake({})
        with self.assertRaises(auth.AuthError):
            auth.login(self.browser(), timeout=10, jwks=JWKS)


class LogoutTest(StateTest):
    def test_logout_revokes_and_keeps_the_registration(self):
        self.signed_in()
        fake = self.fake({
            auth.DISCOVERY_URL: (200, {"revocation_endpoint":
                                       "https://auth.example/revoke"}),
            "https://auth.example/revoke": (200, {}),
        })
        self.assertTrue(auth.logout())
        self.assertEqual(fake.calls[-1][1], {
            "token": "refresh-1", "token_type_hint": "refresh_token",
            "client_id": "oaiapp_1"})
        saved = auth.load()
        self.assertNotIn("access_token", saved)
        self.assertEqual(saved["client_id"], "oaiapp_1")

    def test_forget_drops_everything(self):
        self.signed_in()
        self.fake({auth.DISCOVERY_URL: auth.TryLater("offline")})
        self.assertFalse(auth.logout(forget=True))
        self.assertEqual(auth.load(), {})


class AdapterTest(unittest.TestCase):
    def test_request(self):
        out = adapter.to_responses({
            "model": "m", "temperature": 0.2, "max_tokens": 9,
            "stream": True, "stream_options": {"include_usage": True},
            "reasoning_effort": "low",
            "messages": [
                {"role": "system", "content": "be brief"},
                {"role": "user", "content": "hi"},
                {"role": "assistant", "content": None, "tool_calls": [{
                    "id": "call_1", "type": "function",
                    "function": {"name": "bash", "arguments": "{}"}}]},
                {"role": "tool", "tool_call_id": "call_1", "content": "ok"},
            ],
            "tools": [{"type": "function", "function": {
                "name": "bash", "description": "run",
                "parameters": {"type": "object"}}}],
        })
        self.assertEqual(out["instructions"], "be brief")
        self.assertIs(out["store"], False)
        self.assertIs(out["stream"], True)
        self.assertEqual(out["reasoning"], {"effort": "low"})
        for gone in ("temperature", "max_tokens", "stream_options",
                     "messages"):
            self.assertNotIn(gone, out)
        self.assertEqual(out["input"], [
            {"role": "user", "content": "hi"},
            {"type": "function_call", "call_id": "call_1", "name": "bash",
             "arguments": "{}", "namespace": "arx"},
            {"type": "function_call_output", "call_id": "call_1",
             "output": "ok"}])
        self.assertEqual(out["tools"][0]["type"], "namespace")
        self.assertEqual(out["tools"][0]["tools"][0]["name"], "bash")
        # The history goes last, so a request starts with the bytes of the
        # one before it (see to_responses).
        self.assertEqual(list(out)[-1], "input")

    def test_settings(self):
        out = adapter.to_responses({
            "model": "m", "messages": [], "verbosity": "low",
            "temperature": 0.2, "top_p": 0.5, "max_completion_tokens": 9,
            "parallel_tool_calls": True, "service_tier": "flex",
            "seed": 7,
        })
        self.assertEqual(out["text"], {"verbosity": "low"})
        self.assertIs(out["parallel_tool_calls"], True)
        self.assertEqual(out["service_tier"], "flex")
        for gone in ("verbosity", "temperature", "top_p",
                     "max_completion_tokens", "seed"):
            self.assertNotIn(gone, out)
        out = adapter.to_responses({
            "model": "m", "messages": [], "verbosity": "low",
            "text": {"verbosity": "high", "format": {"type": "text"}},
        })
        self.assertEqual(out["text"],
                         {"verbosity": "high", "format": {"type": "text"}})

    def translate(self, events, headers_file=None):
        out = io.StringIO()
        t = adapter.Translator(out, headers_file)
        for e in events:
            t.feed(("data: %s\n" % json.dumps(e)).encode())
        t.report()
        return [json.loads(line[6:]) for line in out.getvalue().splitlines()
                if line.startswith("data: {")], out.getvalue()

    def test_stream(self):
        item = {"type": "function_call", "id": "fc_1", "call_id": "call_1",
                "name": "bash", "arguments": ""}
        chunks, raw = self.translate([
            {"type": "response.output_text.delta", "delta": "Hel"},
            {"type": "response.output_item.added", "item": item},
            {"type": "response.function_call_arguments.delta",
             "item_id": "fc_1", "delta": "{}"},
            {"type": "response.output_item.done",
             "item": dict(item, arguments="{}")},
            {"type": "response.completed", "response": {
                "usage": {"input_tokens": 5, "output_tokens": 2}}},
        ])
        self.assertEqual(chunks[0]["choices"][0]["delta"], {"content": "Hel"})
        call = chunks[1]["choices"][0]["delta"]["tool_calls"][0]
        self.assertEqual((call["id"], call["function"]["name"]),
                         ("call_1", "bash"))
        self.assertEqual(len(chunks), 5)  # no second copy of the arguments
        self.assertEqual(chunks[3]["choices"][0]["finish_reason"],
                         "tool_calls")
        self.assertEqual(chunks[4]["usage"],
                         {"prompt_tokens": 5, "completion_tokens": 2})
        self.assertTrue(raw.endswith("data: [DONE]\n\n"))

    def test_cached_tokens(self):
        chunks, _ = self.translate([
            {"type": "response.output_text.delta", "delta": "hi"},
            {"type": "response.completed", "response": {"usage": {
                "input_tokens": 900, "output_tokens": 2,
                "input_tokens_details": {"cached_tokens": 768}}}},
        ])
        self.assertEqual(chunks[-1]["usage"], {
            "prompt_tokens": 900, "completion_tokens": 2,
            "prompt_tokens_details": {"cached_tokens": 768}})

    def test_failure_becomes_a_status(self):
        path = os.path.join(tempfile.mkdtemp(), "headers")
        _, raw = self.translate([{"type": "response.failed", "response": {
            "error": {"code": "subscription_sharing_usage_limit_exceeded",
                      "message": "limit"}}}], path)
        with open(path) as f:
            self.assertTrue(f.read().startswith("HTTP/1.1 429 "))
        self.assertIn('"message": "limit"', raw)


if __name__ == "__main__":
    unittest.main()
