from datetime import datetime, timedelta, timezone
from typing import Optional
import hashlib
import hmac
import base64
import json
import os
import secrets

import jwt  # PyJWT

BASE       = os.path.dirname(os.path.abspath(__file__))
SECRET_F   = os.path.join(BASE, "secret.key")
USERS_F    = os.path.join(BASE, "users.json")
ALGORITHM  = "HS256"
TOKEN_DAYS = 7


def _secret():
    if os.path.exists(SECRET_F):
        with open(SECRET_F) as f:
            return f.read().strip()
    key = secrets.token_hex(32)
    with open(SECRET_F, "w") as f:
        f.write(key)
    return key


SECRET_KEY = _secret()


def hash_password(plain: str) -> str:
    salt = os.urandom(32)
    key  = hashlib.pbkdf2_hmac("sha256", plain.encode("utf-8"), salt, 600_000)
    return base64.b64encode(salt + key).decode("ascii")


def verify_password(plain: str, stored: str) -> bool:
    try:
        raw   = base64.b64decode(stored.encode("ascii"))
        salt  = raw[:32]
        key   = raw[32:]
        check = hashlib.pbkdf2_hmac("sha256", plain.encode("utf-8"), salt, 600_000)
        return hmac.compare_digest(key, check)
    except Exception:
        return False


def _default():
    return {
        "admin": {
            "password_hash": hash_password("admin123"),
            "display_name":  "Admin",
            "role":          "admin",
            "theme":         "#7c3aed",
        }
    }


def load_users() -> dict:
    if not os.path.exists(USERS_F):
        u = _default()
        save_users(u)
        return u
    with open(USERS_F, "r", encoding="utf-8") as f:
        return json.load(f)


def save_users(users: dict):
    with open(USERS_F, "w", encoding="utf-8") as f:
        json.dump(users, f, indent=2, ensure_ascii=False)


def create_token(username: str) -> str:
    exp = datetime.now(timezone.utc) + timedelta(days=TOKEN_DAYS)
    return jwt.encode({"sub": username, "exp": exp}, SECRET_KEY, algorithm=ALGORITHM)


def decode_token(token: str) -> Optional[str]:
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        return payload.get("sub")
    except jwt.PyJWTError:
        return None
