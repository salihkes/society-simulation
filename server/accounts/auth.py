"""User accounts shared by the website and the game: passwords, bans, invites and 2FA."""

import hashlib
import hmac
import json
import os
import secrets
import time
import uuid

from core import identity
from core import paths

# The website (web/accounts.py) and the game share this file.
DEFAULT_DB_PATH = paths.data("user_database.json")

# The bootstrap admin, who can never be banned.
ROOT_USER = identity.get("root_user")

INVITE_DEFAULT_TTL_SECONDS = 7 * 24 * 60 * 60
INVITE_DEFAULT_MAX_USES = 1

# 2FA backup codes are one-time and stored as salted hashes.
TOTP_BACKUP_CODE_COUNT = 8
TOTP_BACKUP_CODE_LENGTH = 10  # base32 chars


class AuthManager:
    """The user database, reloaded whenever another process has changed the file."""

    def __init__(self, db_path=None):
        self.db_path = db_path if db_path is not None else DEFAULT_DB_PATH
        self.users = {}
        self._last_modified = 0
        # The ban log and invites sit beside the db so the website and game share them.
        db_dir = os.path.dirname(os.path.abspath(self.db_path)) or "."
        self.bans_log_path = os.path.join(db_dir, "bans.log.jsonl")
        self.invites_path = os.path.join(db_dir, "invites.json")
        self._invites_mtime = 0
        self.invites = {}
        self.load_database()
        self._load_invites()

    def _get_file_mtime(self):
        try:
            return os.path.getmtime(self.db_path)
        except OSError:
            return 0

    def _check_reload(self):
        current_mtime = self._get_file_mtime()
        if current_mtime > self._last_modified:
            print(f"[AuthManager] Database file changed, reloading...")
            self.load_database()

    def load_database(self):
        """Read the database (creating it when missing) and add fields older records lack."""
        if os.path.exists(self.db_path):
            try:
                with open(self.db_path, 'r') as f:
                    self.users = json.load(f)
                self._last_modified = self._get_file_mtime()
                print(f"[AuthManager] Loaded {len(self.users)} users from database")
            except json.JSONDecodeError:
                print(f"[AuthManager] Error loading database, creating new one")
                self.users = {}
        else:
            self.users = {}
            self.save_database()
        if self.users and self._migrate_user_records():
            self.save_database()

    def _migrate_user_records(self):
        """Add missing ban/invite/2FA fields to user records; True if any record changed."""
        changed = False
        for user in self.users.values():
            if "invited_by" not in user:
                user["invited_by"] = None
                changed = True
            if "banned" not in user:
                user["banned"] = False
                user["banned_at"] = None
                user["banned_by"] = None
                user["ban_reason"] = None
                changed = True
            if "totp_secret" not in user:
                user["totp_secret"] = None
                user["totp_enrolled_at"] = None
                user["backup_codes"] = []  # list of {hash, salt, used_at}
                changed = True
        return changed

    def save_database(self):
        with open(self.db_path, 'w') as f:
            json.dump(self.users, f, indent=4)

    def hash_password(self, password, salt=None):
        """{"hash", "salt"}: SHA-256 of password + salt, with a new salt when none is given."""
        if salt is None:
            salt = uuid.uuid4().hex

        hashed = hashlib.sha256((password + salt).encode()).hexdigest()
        return {"hash": hashed, "salt": salt}

    def register_user(self, username, password, invited_by=None):
        """Create an account; returns (ok, message); invited_by joins the ban-cascade chain, None makes a root."""
        self._check_reload()
        if username.lower() in [u.lower() for u in self.users.keys()]:
            return False, "Username already exists"

        # A banned inviter must not be able to bring in new accounts.
        if invited_by is not None:
            if invited_by not in self.users:
                return False, "Inviter not found"
            banned, _ = self.is_effectively_banned(invited_by)
            if banned:
                return False, "Inviter account is banned"

        password_data = self.hash_password(password)
        self.users[username] = {
            "password_hash": password_data["hash"],
            "salt": password_data["salt"],
            "display_name": username,
            "created_at": str(uuid.uuid1()),  # a time-based UUID string, not a timestamp
            "invited_by": invited_by,
            "banned": False,
            "banned_at": None,
            "banned_by": None,
            "ban_reason": None,
            "totp_secret": None,
            "totp_enrolled_at": None,
            "backup_codes": [],
        }
        self.save_database()
        return True, "User registered successfully"

    def password_ok(self, username, password):
        """(True, user record) when the password matches and the account is not banned; checks no 2FA."""
        self._check_reload()
        if username not in self.users:
            return False, "Invalid username or password"
        user_data = self.users[username]
        attempt = self.hash_password(password, user_data["salt"])
        if attempt["hash"] != user_data["password_hash"]:
            return False, "Invalid username or password"
        # A banned user is told so, not "wrong password", so they can appeal.
        banned, ancestor = self.is_effectively_banned(username)
        if banned:
            if ancestor == username:
                return False, "This account is banned."
            return False, f"This account is banned (cascade from {ancestor})."
        return True, user_data

    def authenticate_user(self, username, password, totp_code=None):
        """Log in: password_ok plus a TOTP or backup code with 2FA; (True, user), (False, "2FA required") or (False, error)."""
        ok, result = self.password_ok(username, password)
        if not ok:
            return ok, result
        if result.get("totp_secret"):
            if not totp_code:
                return False, "2FA required"
            if not self.verify_totp(username, totp_code):
                return False, "Invalid 2FA code"
        return True, result

    def get_user_data(self, username):
        """A copy of the user record without password hash and salt, or None."""
        self._check_reload()
        if username in self.users:
            user_data = self.users[username].copy()
            if "password_hash" in user_data:
                del user_data["password_hash"]
            if "salt" in user_data:
                del user_data["salt"]
            return user_data
        return None

    # Bans live only on the directly banned user; invitees inherit through the chain, so an unban is one write.

    def is_effectively_banned(self, username):
        """(banned, the user whose direct ban causes it, or None), up the invite chain."""
        self._check_reload()
        seen = set()
        cur = username
        while cur and cur not in seen:
            seen.add(cur)
            user = self.users.get(cur)
            if not user:
                return False, None
            if user.get("banned"):
                return True, cur
            cur = user.get("invited_by")
        return False, None

    def ban_user(self, target, by, reason=""):
        """Ban a user directly; returns (ok, message); who may ban whom is the caller's check."""
        self._check_reload()
        if target not in self.users:
            return False, "User not found"
        if target == ROOT_USER:
            return False, f"Cannot ban root user ({ROOT_USER})"
        if target == by:
            return False, "Cannot ban yourself"
        user = self.users[target]
        if user.get("banned"):
            return False, "User is already banned"
        user["banned"] = True
        user["banned_at"] = int(time.time())
        user["banned_by"] = by
        user["ban_reason"] = reason or ""
        self.save_database()
        self._append_audit("ban", target, by, reason)
        return True, "User banned"

    def unban_user(self, target, by):
        """Clear a user's direct ban, which also clears it for everyone they invited."""
        self._check_reload()
        if target not in self.users:
            return False, "User not found"
        user = self.users[target]
        if not user.get("banned"):
            return False, "User is not directly banned"
        user["banned"] = False
        user["banned_at"] = None
        user["banned_by"] = None
        user["ban_reason"] = None
        self.save_database()
        self._append_audit("unban", target, by, "")
        return True, "User unbanned"

    def user_tree(self):
        """The invite forest for the admin page: sorted root nodes with ban fields, cascade_from and sorted children."""
        self._check_reload()
        children_map = {}
        for u, data in self.users.items():
            parent = data.get("invited_by")
            if parent and parent not in self.users:
                parent = None
            children_map.setdefault(parent, []).append(u)

        def build(username, seen):
            if username in seen:
                return None  # cycle guard
            seen = seen | {username}
            user = self.users[username]
            eff, anc = self.is_effectively_banned(username)
            cascade = anc if (eff and anc != username) else None
            kids = []
            for child in sorted(children_map.get(username, [])):
                node = build(child, seen)
                if node is not None:
                    kids.append(node)
            return {
                "username": username,
                "invited_by": user.get("invited_by"),
                "banned": bool(user.get("banned")),
                "banned_at": user.get("banned_at"),
                "banned_by": user.get("banned_by"),
                "ban_reason": user.get("ban_reason"),
                "created_at": user.get("created_at"),
                "effective_banned": eff,
                "cascade_from": cascade,
                "children": kids,
            }

        roots = []
        for u in sorted(children_map.get(None, [])):
            node = build(u, set())
            if node is not None:
                roots.append(node)
        return roots

    def _append_audit(self, action, target, by, reason):
        """Append a line to the ban log; a failure to write is ignored."""
        try:
            with open(self.bans_log_path, "a", encoding="utf-8") as f:
                f.write(json.dumps({
                    "ts": int(time.time()),
                    "action": action,
                    "target": target,
                    "by": by,
                    "reason": reason or "",
                }) + "\n")
        except OSError:
            pass

    # Invites live in invites.json by random token: inviter, expiry, max uses, users; using one sets invited_by.

    def _load_invites(self):
        if not os.path.exists(self.invites_path):
            self.invites = {}
            return
        try:
            mtime = os.path.getmtime(self.invites_path)
            if mtime <= self._invites_mtime and self.invites:
                return  # already up to date
            with open(self.invites_path, "r", encoding="utf-8") as f:
                self.invites = json.load(f)
            self._invites_mtime = mtime
        except (OSError, json.JSONDecodeError):
            self.invites = {}

    def _save_invites(self):
        tmp = self.invites_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.invites, f, indent=2)
        os.replace(tmp, self.invites_path)
        try:
            self._invites_mtime = os.path.getmtime(self.invites_path)
        except OSError:
            pass

    def create_invite(self, inviter, max_uses=INVITE_DEFAULT_MAX_USES,
                      ttl_seconds=INVITE_DEFAULT_TTL_SECONDS):
        """Create an invite owned by `inviter`; returns (ok, message, invite); permission is the caller's check."""
        self._check_reload()
        self._load_invites()
        if inviter not in self.users:
            return False, "Inviter not found", None
        banned, _ = self.is_effectively_banned(inviter)
        if banned:
            return False, "Inviter account is banned", None
        if max_uses < 1:
            return False, "max_uses must be at least 1", None
        token = secrets.token_urlsafe(24)  # ~192 bits, URL-safe
        now = int(time.time())
        invite = {
            "token": token,
            "inviter": inviter,
            "created_at": now,
            "expires_at": now + int(ttl_seconds) if ttl_seconds else None,
            "max_uses": int(max_uses),
            "used_by": [],   # list of {username, ts}
            "revoked": False,
        }
        self.invites[token] = invite
        self._save_invites()
        return True, "Invite created", invite

    def get_invite(self, token):
        """Return the raw invite dict (or None). Does not validate freshness."""
        self._load_invites()
        return self.invites.get(token)

    def invite_status(self, token):
        """(status, invite or None); status: ok, unknown, revoked, expired, exhausted or inviter_banned."""
        invite = self.get_invite(token)
        if not invite:
            return "unknown", None
        if invite.get("revoked"):
            return "revoked", invite
        exp = invite.get("expires_at")
        if exp is not None and time.time() > exp:
            return "expired", invite
        if len(invite.get("used_by", [])) >= invite.get("max_uses", 1):
            return "exhausted", invite
        # An inviter banned after issuing it must not still bring people in.
        banned, _ = self.is_effectively_banned(invite["inviter"])
        if banned:
            return "inviter_banned", invite
        return "ok", invite

    def consume_invite(self, token, new_username):
        """Mark `token` as used by `new_username`. Returns (ok, message, inviter)."""
        self._load_invites()
        status, invite = self.invite_status(token)
        if status != "ok":
            return False, f"Invite is {status}", None
        invite["used_by"].append({
            "username": new_username,
            "ts": int(time.time()),
        })
        self._save_invites()
        return True, "Invite consumed", invite["inviter"]

    def revoke_invite(self, token, by):
        """Revoke an outstanding invite. Caller checks ownership/permission."""
        self._load_invites()
        invite = self.invites.get(token)
        if not invite:
            return False, "Invite not found"
        if invite.get("revoked"):
            return False, "Already revoked"
        invite["revoked"] = True
        invite["revoked_at"] = int(time.time())
        invite["revoked_by"] = by
        self._save_invites()
        return True, "Invite revoked"

    def invites_by(self, inviter):
        """List all invites (active + spent + revoked) created by `inviter`."""
        self._load_invites()
        out = [inv for inv in self.invites.values() if inv.get("inviter") == inviter]
        out.sort(key=lambda i: i.get("created_at", 0), reverse=True)
        return out

    def has_totp(self, username):
        self._check_reload()
        u = self.users.get(username) or {}
        return bool(u.get("totp_secret"))

    @staticmethod
    def generate_totp_secret():
        """Return a fresh base32 TOTP secret. Not persisted."""
        try:
            import pyotp  # type: ignore
        except ImportError as e:
            raise RuntimeError("pyotp is required for 2FA — pip install pyotp") from e
        return pyotp.random_base32()

    @staticmethod
    def totp_provisioning_uri(secret, username, issuer=identity.get("product_name")):
        import pyotp  # type: ignore
        return pyotp.totp.TOTP(secret).provisioning_uri(
            name=username, issuer_name=issuer)

    def confirm_totp_enrollment(self, username, password, secret, code):
        """Enable 2FA after re-checking the password and a first code; returns (ok, message, backup codes shown once)."""
        ok, _ = self.password_ok(username, password)
        if not ok:
            return False, "Password re-auth failed", None
        try:
            import pyotp  # type: ignore
        except ImportError:
            return False, "pyotp not installed on server", None
        totp = pyotp.TOTP(secret)
        if not totp.verify(code, valid_window=1):
            return False, "Invalid 2FA code", None
        plaintext = [self._mint_backup_code() for _ in range(TOTP_BACKUP_CODE_COUNT)]
        hashed = []
        for raw in plaintext:
            h = self.hash_password(raw)
            hashed.append({"hash": h["hash"], "salt": h["salt"], "used_at": None})
        user = self.users[username]
        user["totp_secret"] = secret
        user["totp_enrolled_at"] = int(time.time())
        user["backup_codes"] = hashed
        self.save_database()
        return True, "2FA enabled", plaintext

    def disable_totp(self, username, password):
        """Turn 2FA off after re-checking the password; logged in the ban log."""
        ok, _ = self.password_ok(username, password)
        if not ok:
            return False, "Password re-auth failed"
        user = self.users.get(username)
        if not user:
            return False, "User not found"
        if not user.get("totp_secret"):
            return False, "2FA is not enabled"
        user["totp_secret"] = None
        user["totp_enrolled_at"] = None
        user["backup_codes"] = []
        self.save_database()
        self._append_audit("totp_disabled", username, username, "")
        return True, "2FA disabled"

    def verify_totp(self, username, code):
        """True for a current TOTP code or an unused backup code (which is then used up)."""
        self._check_reload()
        user = self.users.get(username)
        if not user or not user.get("totp_secret"):
            return False
        code = (code or "").strip().replace(" ", "").upper()
        if not code:
            return False
        # One 30 s step either side tolerates clock skew.
        try:
            import pyotp  # type: ignore
            if pyotp.TOTP(user["totp_secret"]).verify(code, valid_window=1):
                return True
        except ImportError:
            pass    # without pyotp only the backup codes can still let the owner in
        for entry in user.get("backup_codes", []):
            if entry.get("used_at"):
                continue
            attempt = self.hash_password(code, entry["salt"])
            if hmac.compare_digest(attempt["hash"], entry["hash"]):
                entry["used_at"] = int(time.time())
                self.save_database()
                return True
        return False

    def backup_codes_remaining(self, username):
        u = self.users.get(username) or {}
        return sum(1 for c in u.get("backup_codes", []) if not c.get("used_at"))

    @staticmethod
    def _mint_backup_code():
        """A random code without the look-alike characters 0, O, 1 and I."""
        alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return "".join(secrets.choice(alphabet) for _ in range(TOTP_BACKUP_CODE_LENGTH))

