"""The website's JSON API: accounts, invites, bans, 2FA, game tokens, community boards and decals."""
import base64
import hashlib
import hmac
import io
import os
import struct
import sys
import tempfile
import time
import types
import unittest
from pathlib import Path
from unittest.mock import patch

TMP = tempfile.TemporaryDirectory()
os.environ["GAME_DATA_DIR"] = TMP.name
sys.path.insert(0, str(Path(__file__).parents[1]))

import aiohttp  # noqa: E402
from aiohttp.test_utils import TestClient, TestServer  # noqa: E402

from accounts.auth import AuthManager  # noqa: E402
from net import sso  # noqa: E402
from web import community, roles  # noqa: E402
from web.app import build_app  # noqa: E402
from world import textures  # noqa: E402

ADMIN = "admin_a"
POSTER = "poster_p"
PASSWORD = "pw-123456"
PNG = b"\x89PNG\r\n\x1a\n" + b"\0" * 64


def _totp_code(secret, at=None):
    """RFC 6238 code (SHA-1, 6 digits, 30 s), as authenticator apps compute it."""
    key = base64.b32decode(secret + "=" * (-len(secret) % 8))
    counter = int((at or time.time()) // 30)
    digest = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    value = struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF
    return f"{value % 1000000:06d}"


def _stub_pyotp():
    """A stand-in for pyotp when the venv lacks it: the same TOTP maths, stdlib only."""
    class TOTP:
        def __init__(self, secret):
            self.secret = secret

        def now(self):
            return _totp_code(self.secret)

        def verify(self, code, valid_window=0):
            t = time.time()
            return any(_totp_code(self.secret, t + 30 * w) == code
                       for w in range(-valid_window, valid_window + 1))

        def provisioning_uri(self, name, issuer_name):
            return f"otpauth://totp/{issuer_name}:{name}?secret={self.secret}&issuer={issuer_name}"

    module = types.ModuleType("pyotp")
    module.TOTP = TOTP
    module.totp = types.SimpleNamespace(TOTP=TOTP)
    module.random_base32 = lambda: base64.b32encode(os.urandom(20)).decode()
    return module


try:
    import pyotp  # noqa: F401
except ImportError:
    sys.modules["pyotp"] = _stub_pyotp()


class WebApiTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        (root / "roles.yaml").write_text(f"posters:\n  - {POSTER}\nadmins:\n  - {ADMIN}\n")
        for target, value in ((roles, ("ROLES_PATH", root / "roles.yaml")),
                              (community, ("DATA_PATH", root / "community.json")),
                              (textures, ("USER_TEXTURE_DIR", root / "textures"))):
            p = patch.object(target, value[0], str(value[1]))
            p.start()
            self.addCleanup(p.stop)
        env = patch.dict(os.environ, {"ENABLE_REGISTRATION": "1", "ENABLE_GUEST": "1"})
        env.start()
        self.addCleanup(env.stop)
        self.auth = AuthManager(db_path=str(root / "user_database.json"))
        for name in (ADMIN, POSTER, "plain_u"):
            self.auth.register_user(name, PASSWORD)
        self.server = TestServer(build_app(self.auth, secret=b"test-secret"))
        await self.server.start_server()
        self.addAsyncCleanup(self.server.close)

    async def client(self, username=None):
        """A browser of its own (cookie jar), logged in as `username` when given."""
        jar = aiohttp.CookieJar(unsafe=True, treat_as_secure_origin=str(self.server.make_url("/")))
        c = TestClient(self.server, cookie_jar=jar)
        await c.start_server()
        self.addAsyncCleanup(c.session.close)
        if username:
            r = await c.post("/api/login", json={"username": username, "password": PASSWORD})
            self.assertEqual((await r.json())["next"], "done")
        return c

    async def post(self, c, path, data):
        r = await c.post(path, json=data)
        return r.status, await r.json()

    async def get(self, c, path):
        r = await c.get(path)
        return r.status, await r.json()

    async def test_register_via_invite(self):
        inviter = await self.client(POSTER)
        status, invite = await self.post(inviter, "/api/invites/create", {"max_uses": 1})
        self.assertEqual(status, 200)
        token = invite["token"]
        self.assertTrue(invite["url"].endswith(f"/register?invite={token}"))
        with patch.dict(os.environ, {"ENABLE_REGISTRATION": "0"}):
            guest = await self.client()
            status, info = await self.get(guest, f"/api/register?invite={token}")
            self.assertTrue(info["invite_path_ok"])
            self.assertEqual(info["inviter"], POSTER)
            status, _ = await self.post(guest, "/api/register", {
                "username": "nobody", "password": "x", "confirm_password": "x"})
            self.assertEqual(status, 403)
            status, reply = await self.post(guest, "/api/register", {
                "username": "newbie", "password": "pw", "confirm_password": "pw",
                "invite": token})
            self.assertEqual(status, 200, reply)
            _, s = await self.get(guest, "/api/session")
            self.assertEqual(s["user"], "newbie")
            self.assertEqual(self.auth.get_user_data("newbie")["invited_by"], POSTER)
            self.assertEqual(self.auth.invite_status(token)[0], "exhausted")
            other = await self.client()
            status, _ = await self.post(other, "/api/register", {
                "username": "second", "password": "pw", "confirm_password": "pw",
                "invite": token})
            self.assertEqual(status, 403)

    async def test_login_and_logout(self):
        c = await self.client()
        status, reply = await self.post(c, "/api/login", {"username": ADMIN, "password": "wrong"})
        self.assertEqual(status, 401)
        status, reply = await self.post(c, "/api/login", {"username": ADMIN, "password": PASSWORD})
        self.assertEqual(reply["next"], "done")
        _, s = await self.get(c, "/api/session")
        self.assertEqual(s["user"], ADMIN)
        self.assertTrue(s["can_admin"])
        await self.post(c, "/api/logout", {})
        _, s = await self.get(c, "/api/session")
        self.assertIsNone(s["user"])

    async def test_forged_cookie_is_ignored(self):
        c = await self.client()
        body = base64.urlsafe_b64encode(b'{"user": "admin_a", "iat": 9999999999}').decode()
        c.session.cookie_jar.update_cookies({"session": f"{body}.00"}, self.server.make_url("/"))
        _, s = await self.get(c, "/api/session")
        self.assertIsNone(s["user"])

    async def test_two_factor_login(self):
        c = await self.client(POSTER)
        status, start = await self.post(c, "/api/settings/2fa/enroll", {})
        self.assertEqual(status, 200, start)
        secret = start["secret"]
        self.assertTrue(start["provisioning_uri"].startswith("otpauth://"))
        status, done = await self.post(c, "/api/settings/2fa/confirm",
                                       {"code": _totp_code(secret), "password": PASSWORD})
        self.assertEqual(status, 200, done)
        self.assertEqual(len(done["codes"]), 8)

        fresh = await self.client()
        _, step = await self.post(fresh, "/api/login", {"username": POSTER, "password": PASSWORD})
        self.assertEqual(step["next"], "2fa")
        _, s = await self.get(fresh, "/api/session")
        self.assertIsNone(s["user"])
        self.assertEqual(s["pending_2fa_user"], POSTER)
        status, _ = await self.post(fresh, "/api/login/2fa", {"code": "000000"})
        self.assertEqual(status, 401)
        status, _ = await self.post(fresh, "/api/login/2fa", {"code": done["codes"][0]})
        self.assertEqual(status, 200)
        _, s = await self.get(fresh, "/api/session")
        self.assertEqual(s["user"], POSTER)
        status, _ = await self.get(fresh, "/api/game-token")
        self.assertEqual(status, 200)

    async def test_game_token_verified_by_game_server(self):
        status, _ = await self.get(await self.client(), "/api/game-token")
        self.assertEqual(status, 401)
        c = await self.client("plain_u")
        status, reply = await self.get(c, "/api/game-token")
        self.assertEqual(status, 200)
        self.assertEqual(reply["username"], "plain_u")
        name, stamp, _ = base64.b64decode(reply["token"]).decode().split(":")
        self.assertEqual(name, "plain_u")
        self.assertLessEqual(abs(int(stamp) - time.time()), 2)
        self.assertEqual(sso.validate_sso_token(reply["token"]), "plain_u")
        self.assertIsNone(sso.validate_sso_token(reply["token"]))

    async def test_banned_user_gets_no_token(self):
        c = await self.client("plain_u")
        self.auth.ban_user("plain_u", by=ADMIN)
        status, reply = await self.get(c, "/api/game-token")
        self.assertEqual(status, 403)
        _, s = await self.get(c, "/api/session")
        self.assertIsNone(s["user"])

    async def test_invite_permissions(self):
        owner = await self.client("plain_u")
        _, invite = await self.post(owner, "/api/invites/create", {})
        token = invite["token"]
        status, _ = await self.post(await self.client(), "/api/invites/create", {})
        self.assertEqual(status, 401)
        status, _ = await self.post(await self.client(POSTER), "/api/invites/revoke",
                                    {"token": token})
        self.assertEqual(status, 403)
        status, _ = await self.post(await self.client(ADMIN), "/api/invites/revoke",
                                    {"token": token})
        self.assertEqual(status, 200)
        self.assertEqual(self.auth.invite_status(token)[0], "revoked")
        _, mine = await self.get(owner, "/api/invites")
        self.assertEqual(mine["invites"][0]["status"], "revoked")
        Path(roles.ROLES_PATH).write_text(f"admins:\n  - {ADMIN}\ninviters:\n  - {ADMIN}\n")
        status, _ = await self.post(owner, "/api/invites/create", {})
        self.assertEqual(status, 403)

    async def test_ban_permissions(self):
        admin = await self.client(ADMIN)
        poster = await self.client(POSTER)
        status, _ = await self.post(poster, "/api/admin/ban", {"username": "plain_u"})
        self.assertEqual(status, 403)
        status, _ = await self.get(poster, "/api/admin/users")
        self.assertEqual(status, 403)
        Path(roles.ROLES_PATH).write_text(f"admins:\n  - {ADMIN}\n  - {POSTER}\n")
        status, reply = await self.post(admin, "/api/admin/ban", {"username": POSTER})
        self.assertEqual(status, 403)
        self.assertIn("cannot ban another admin", reply["message"])
        status, _ = await self.post(admin, "/api/admin/ban",
                                    {"username": "plain_u", "reason": "spam"})
        self.assertEqual(status, 200)
        self.assertTrue(self.auth.is_effectively_banned("plain_u")[0])
        _, tree = await self.get(admin, "/api/admin/users")
        node = next(n for n in tree["tree"] if n["username"] == "plain_u")
        self.assertTrue(node["banned"])
        status, _ = await self.post(admin, "/api/admin/unban", {"username": "plain_u"})
        self.assertEqual(status, 200)
        self.assertFalse(self.auth.is_effectively_banned("plain_u")[0])

    async def test_board_create_admin_only(self):
        status, _ = await self.post(await self.client(POSTER), "/api/r",
                                    {"name": "news", "title": "News"})
        self.assertEqual(status, 403)
        status, reply = await self.post(await self.client(ADMIN), "/api/r",
                                        {"name": "News", "title": "News"})
        self.assertEqual((status, reply["name"]), (200, "news"))
        _, boards = await self.get(await self.client(), "/api/r")
        self.assertIn("news", [b["name"] for b in boards["subreddits"]])
        self.assertIn(boards["default"], [b["name"] for b in boards["subreddits"]])

    async def test_posting_comments_and_votes(self):
        _, boards = await self.get(await self.client(), "/api/r")
        board = boards["default"]
        status, _ = await self.post(await self.client("plain_u"), f"/api/r/{board}/posts",
                                    {"title": "hi"})
        self.assertEqual(status, 403)
        status, _ = await self.post(await self.client(), f"/api/r/{board}/posts", {"title": "x"})
        self.assertEqual(status, 401)
        status, made = await self.post(await self.client(POSTER), f"/api/r/{board}/posts",
                                       {"title": "patch notes", "body": "text"})
        self.assertEqual(status, 200)
        post_id = made["post"]["id"]

        reader = await self.client("plain_u")
        status, c1 = await self.post(reader, f"/api/r/{board}/posts/{post_id}/comments",
                                     {"body": "nice"})
        self.assertEqual(status, 200)
        status, _ = await self.post(reader, f"/api/r/{board}/posts/{post_id}/comments",
                                    {"body": "reply", "parent_id": c1["comment"]["id"]})
        self.assertEqual(status, 200)
        status, vote = await self.post(reader, "/api/vote",
                                       {"kind": "post", "id": post_id, "value": -1})
        self.assertEqual((status, vote["score"], vote["user_vote"]), (200, 0, -1))
        status, _ = await self.post(reader, "/api/vote", {"kind": "post", "id": post_id,
                                                          "value": 5})
        self.assertEqual(status, 404)

        _, view = await self.get(await self.client(), f"/api/r/{board}/posts/{post_id}")
        self.assertEqual(view["post"]["score"], 0)
        self.assertNotIn("votes", view["post"])
        self.assertEqual(view["comments"][0]["children"][0]["body"], "reply")
        _, listing = await self.get(reader, f"/api/r/{board}?sort=top")
        self.assertEqual(listing["posts"][0]["comment_count"], 2)
        self.assertEqual(listing["posts"][0]["user_vote"], -1)

    async def test_wiki_edit_admin_only(self):
        _, boards = await self.get(await self.client(), "/api/r")
        board = boards["default"]
        status, _ = await self.post(await self.client(POSTER), f"/api/r/{board}/wiki",
                                    {"body": "no"})
        self.assertEqual(status, 403)
        status, _ = await self.post(await self.client(ADMIN), f"/api/r/{board}/wiki",
                                    {"body": "# rules"})
        self.assertEqual(status, 200)
        _, view = await self.get(await self.client(), f"/api/r/{board}")
        self.assertEqual(view["subreddit"]["wiki"], "# rules")

    async def _upload(self, c, data, filename="d.png", character_type="humanoid"):
        form = aiohttp.FormData()
        form.add_field("file", io.BytesIO(data), filename=filename, content_type="image/png")
        form.add_field("character_type", character_type)
        r = await c.post("/api/upload-decal", data=form)
        return r.status, await r.json()

    async def test_decal_upload_validation(self):
        status, _ = await self._upload(await self.client(), PNG)
        self.assertEqual(status, 401)
        c = await self.client("plain_u")
        self.assertEqual((await self._upload(c, PNG, filename="d.jpg"))[0], 400)
        self.assertEqual((await self._upload(c, PNG, character_type="robot"))[0], 400)
        big = PNG + b"\0" * textures.MAX_DECAL_BYTES
        status, reply = await self._upload(c, big)
        self.assertEqual(status, 400)
        self.assertIn("too large", reply["message"])
        status, reply = await self._upload(c, b"\0" * (textures.MAX_DECAL_BYTES * 2))
        self.assertEqual(status, 413)
        self.assertFalse(reply["success"])
        status, reply = await self._upload(c, PNG, character_type="countryball")
        self.assertEqual(status, 200, reply)
        saved = Path(textures.USER_TEXTURE_DIR) / "plain_u_countryball.png"
        self.assertEqual(saved.read_bytes(), PNG)

    async def test_pages_and_redirects(self):
        c = await self.client()
        r = await c.get("/game/index.html", allow_redirects=False)
        self.assertEqual((r.status, r.headers["Location"]), (302, "/play/index.html"))
        r = await c.get("/play", allow_redirects=False)
        self.assertEqual(r.headers["Location"], "/play/")
        status, reply = await self.get(c, "/api/nothing-here")
        self.assertEqual((status, reply["success"]), (404, False))
        r = await c.get("/../server/config/identity.json")
        self.assertEqual(r.status, 404)
        _, ident = await self.get(c, "/api/identity")
        self.assertTrue(ident["product_name"])


if __name__ == "__main__":
    unittest.main()
