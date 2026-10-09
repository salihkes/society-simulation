"""Website accounts API: login with 2FA, registration by invite, invites, bans, 2FA settings and game tokens."""

import hmac
import io
import os
import time

from aiohttp import web

from accounts.auth import TOTP_BACKUP_CODE_COUNT, AuthManager
from net.sso import issue_sso_token
from web import roles
from web.reply import body, fail, ok, text
from web.session import SESSION, user

# A password-checked login waits this long for its second factor.
PENDING_2FA_TTL_SECONDS = 5 * 60
INVITE_DEFAULT_TTL_DAYS = 7
AUTH = web.AppKey("auth", AuthManager)


def env_flag(name):
    """True for 1/true/yes; anything else, unset included, is False."""
    raw = os.environ.get(name, "").strip().strip("\"'").lower()
    return raw in ("1", "true", "yes")


def registration_modes():
    passphrase = os.environ.get("DEV_REGISTRATION_PASSPHRASE", "").strip()
    require_invite = env_flag("REQUIRE_INVITE")
    return {
        "open_path_ok": env_flag("ENABLE_REGISTRATION") and not require_invite,
        "has_dev_passphrase": bool(passphrase),
        "require_invite": require_invite,
    }


def totp_available():
    try:
        import pyotp  # noqa: F401
    except ImportError:
        return False
    return True


def qr_svg(data):
    """The QR code for `data` as an <svg> string, or None without the qrcode package."""
    try:
        import qrcode
        from qrcode.image.svg import SvgPathImage
    except ImportError:
        return None
    qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M, box_size=8, border=2)
    qr.add_data(data)
    qr.make(fit=True)
    buf = io.BytesIO()
    qr.make_image(image_factory=SvgPathImage).save(buf)
    return buf.getvalue().decode("utf-8")


def public_url(request, path):
    """An absolute URL on the origin the browser used (the proxy passes X-Forwarded-Proto)."""
    scheme = request.headers.get("X-Forwarded-Proto", request.scheme)
    return f"{scheme}://{request.host}{path}"


def _auth(request):
    return request.app[AUTH]


def _login(request, username):
    request[SESSION].clear()
    request[SESSION]["user"] = username


async def session_info(request):
    name = user(request)
    pending = request[SESSION].get("pending_2fa_user")
    return ok(user=name, pending_2fa_user=pending,
              can_post=roles.can_post(name), can_admin=roles.can_admin(name),
              can_invite=roles.can_invite(name))


async def login(request):
    data = await body(request)
    username = text(data, "username")
    password = data.get("password") or ""
    if not username or not password:
        return fail(400, "Username and password are required")
    auth = _auth(request)
    success, result = auth.password_ok(username, password)
    if not success:
        return fail(401, result if isinstance(result, str) else "Invalid credentials")
    if auth.has_totp(username):
        request[SESSION].clear()
        request[SESSION]["pending_2fa_user"] = username
        request[SESSION]["pending_2fa_at"] = int(time.time())
        return ok(next="2fa")
    _login(request, username)
    return ok(next="done", user=username)


async def login_2fa(request):
    sess = request[SESSION]
    pending = sess.get("pending_2fa_user")
    if not pending or time.time() - sess.get("pending_2fa_at", 0) > PENDING_2FA_TTL_SECONDS:
        sess.pop("pending_2fa_user", None)
        sess.pop("pending_2fa_at", None)
        return fail(401, "Log in again: the two-factor step expired")
    data = await body(request)
    if not _auth(request).verify_totp(pending, text(data, "code")):
        return fail(401, "Invalid code. Try again, or use a backup code.")
    _login(request, pending)
    return ok(user=pending)


async def logout(request):
    request[SESSION].clear()
    return ok()


def _invite_info(auth, token):
    """(status, invite) for a registration invite token; (None, None) without one."""
    if not token:
        return None, None
    return auth.invite_status(token)


async def register_info(request):
    token = request.query.get("invite", "").strip()
    status, invite = _invite_info(_auth(request), token)
    return ok(invite_status=status, inviter=invite["inviter"] if invite else None,
              invite_path_ok=status == "ok", **registration_modes())


def _pick_inviter(modes, invite_ok, invite, dev_pass):
    """(ok, inviter or None, error); the order is: invite, dev passphrase, open registration."""
    if invite_ok:
        return True, invite["inviter"], None
    if modes["has_dev_passphrase"] and dev_pass:
        expected = os.environ.get("DEV_REGISTRATION_PASSPHRASE", "").strip()
        if not hmac.compare_digest(dev_pass.encode(), expected.encode()):
            return False, None, "Invalid dev passphrase"
        return True, None, None
    if modes["open_path_ok"]:
        return True, None, None
    return False, None, "Registration requires an invite."


async def register(request):
    if user(request):
        return fail(409, "Already logged in")
    data = await body(request)
    username = text(data, "username")
    password = data.get("password") or ""
    if not username or not password:
        return fail(400, "Username and password are required")
    if password != (data.get("confirm_password") or ""):
        return fail(400, "Passwords do not match")
    auth = _auth(request)
    token = text(data, "invite")
    status, invite = _invite_info(auth, token)
    allowed, inviter, error = _pick_inviter(registration_modes(), status == "ok", invite,
                                            data.get("dev_passphrase") or "")
    if not allowed:
        return fail(403, error)
    success, message = auth.register_user(username, password, invited_by=inviter)
    if not success:
        return fail(400, message)
    if status == "ok":
        auth.consume_invite(token, username)
    _login(request, username)
    return ok(user=username)


def _invite_row(request, auth, invite):
    status, _ = auth.invite_status(invite["token"])
    return {
        "token": invite["token"],
        "created_at": invite.get("created_at"),
        "expires_at": invite.get("expires_at"),
        "max_uses": invite["max_uses"],
        "uses_remaining": max(invite["max_uses"] - len(invite.get("used_by", [])), 0),
        "status": status,
        "url": public_url(request, f"/register?invite={invite['token']}"),
    }


def _number(data, key, default, kind):
    try:
        return kind(data.get(key, default))
    except (TypeError, ValueError):
        return default


async def invites_list(request):
    name = user(request)
    if not name:
        return fail(401, "not authenticated")
    if not roles.can_invite(name):
        return fail(403, "your account is not permitted to create invites.")
    auth = _auth(request)
    return ok(invites=[_invite_row(request, auth, i) for i in auth.invites_by(name)])


async def invites_create(request):
    name = user(request)
    if not name:
        return fail(401, "not authenticated")
    if not roles.can_invite(name):
        return fail(403, "not permitted to invite")
    data = await body(request)
    max_uses = max(_number(data, "max_uses", 1, int), 1)
    ttl_days = _number(data, "ttl_days", INVITE_DEFAULT_TTL_DAYS, float)
    ttl_seconds = int(ttl_days * 86400) if ttl_days > 0 else None
    success, message, invite = _auth(request).create_invite(name, max_uses=max_uses,
                                                            ttl_seconds=ttl_seconds)
    if not success:
        return fail(400, message)
    url = public_url(request, f"/register?invite={invite['token']}")
    return ok(token=invite["token"], url=url, qr_svg=qr_svg(url),
              expires_at=invite.get("expires_at"), max_uses=invite["max_uses"])


async def invites_revoke(request):
    name = user(request)
    if not name:
        return fail(401, "not authenticated")
    token = text(await body(request), "token")
    if not token:
        return fail(400, "token required")
    auth = _auth(request)
    invite = auth.get_invite(token)
    if not invite:
        return fail(404, "invite not found")
    if invite["inviter"] != name and not roles.can_admin(name):
        return fail(403, "not permitted")
    success, message = auth.revoke_invite(token, by=name)
    return ok(message=message) if success else fail(400, message)


def _admin_or_error(request):
    """(admin name, None) or (None, error response)."""
    name = user(request)
    if not name:
        return None, fail(401, "not authenticated")
    if not roles.can_admin(name):
        return None, fail(403, "not permitted")
    return name, None


async def admin_users(request):
    name, error = _admin_or_error(request)
    if error:
        return error
    r = roles.load_roles()
    return ok(tree=_auth(request).user_tree(), admins=r["admins"], posters=r["posters"],
              current_admin=name)


async def admin_ban(request):
    name, error = _admin_or_error(request)
    if error:
        return error
    data = await body(request)
    target = text(data, "username")
    if not target:
        return fail(400, "username required")
    # Demoting an admin in roles.yaml first keeps admins from racing to ban each other.
    if roles.can_admin(target):
        return fail(403, f"cannot ban another admin ({target}). remove from roles.yaml first.")
    success, message = _auth(request).ban_user(target, by=name, reason=text(data, "reason"))
    return ok(message=message) if success else fail(400, message)


async def admin_unban(request):
    name, error = _admin_or_error(request)
    if error:
        return error
    target = text(await body(request), "username")
    if not target:
        return fail(400, "username required")
    success, message = _auth(request).unban_user(target, by=name)
    return ok(message=message) if success else fail(400, message)


async def twofa_status(request):
    name = user(request)
    if not name:
        return fail(401, "not authenticated")
    auth = _auth(request)
    return ok(has_totp=auth.has_totp(name), backup_remaining=auth.backup_codes_remaining(name),
              backup_total=TOTP_BACKUP_CODE_COUNT, totp_available=totp_available())


async def twofa_enroll_start(request):
    """Mint a secret into the session (not the account) and return what the app scans."""
    name = user(request)
    if not name:
        return fail(401, "not authenticated")
    if _auth(request).has_totp(name):
        return fail(409, "2FA is already enabled")
    if not totp_available():
        return fail(503, "2FA is unavailable: the server has no pyotp package")
    secret = AuthManager.generate_totp_secret()
    request[SESSION]["pending_totp_secret"] = secret
    uri = AuthManager.totp_provisioning_uri(secret, name)
    return ok(secret=secret, provisioning_uri=uri, qr_svg=qr_svg(uri), account=name)


async def twofa_enroll_confirm(request):
    name = user(request)
    if not name:
        return fail(401, "not authenticated")
    secret = request[SESSION].get("pending_totp_secret")
    if not secret:
        return fail(400, "start the enrollment again")
    data = await body(request)
    success, message, codes = _auth(request).confirm_totp_enrollment(
        name, data.get("password") or "", secret, text(data, "code"))
    if not success:
        return fail(400, message)
    request[SESSION].pop("pending_totp_secret", None)
    return ok(codes=codes)


async def twofa_disable(request):
    name = user(request)
    if not name:
        return fail(401, "not authenticated")
    data = await body(request)
    success, message = _auth(request).disable_totp(name, data.get("password") or "")
    return ok(message=message) if success else fail(400, message)


async def game_token(request):
    """A single sign-on token the game client hands to the game server."""
    name = user(request)
    if not name:
        return fail(401, "User not authenticated")
    # A user banned mid-session must not keep minting tokens off an old cookie.
    banned, ancestor = _auth(request).is_effectively_banned(name)
    if banned:
        request[SESSION].clear()
        cascade = f" (cascade from {ancestor})" if ancestor != name else ""
        return fail(403, "Account banned" + cascade)
    return ok(username=name, token=issue_sso_token(name))


def add_routes(app):
    r = app.router
    r.add_get("/api/session", session_info)
    r.add_post("/api/login", login)
    r.add_post("/api/login/2fa", login_2fa)
    r.add_post("/api/logout", logout)
    r.add_get("/api/register", register_info)
    r.add_post("/api/register", register)
    r.add_get("/api/invites", invites_list)
    r.add_post("/api/invites/create", invites_create)
    r.add_post("/api/invites/revoke", invites_revoke)
    r.add_get("/api/admin/users", admin_users)
    r.add_post("/api/admin/ban", admin_ban)
    r.add_post("/api/admin/unban", admin_unban)
    r.add_get("/api/settings/2fa", twofa_status)
    r.add_post("/api/settings/2fa/enroll", twofa_enroll_start)
    r.add_post("/api/settings/2fa/confirm", twofa_enroll_confirm)
    r.add_post("/api/settings/2fa/disable", twofa_disable)
    r.add_get("/api/game-token", game_token)
