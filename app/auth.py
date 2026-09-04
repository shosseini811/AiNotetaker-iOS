"""Lightweight auth: password login with signed cookies, plus a bearer token.

There are no user accounts — this is a single-user private app.
  • APP_PASSWORD  → web app login (sets a signed, HTTP-only cookie)
  • API_TOKEN     → `Authorization: Bearer ...` for the iOS app
Either secret is accepted in either place, so one value is enough.
If neither is set, the app is open (fine for localhost / a private network).
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import time

from .config import settings

COOKIE_NAME = "ainotetaker_session"
MAX_AGE_SECONDS = 60 * 60 * 24 * 30  # 30 days


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def _unb64(text: str) -> bytes:
    padding = "=" * (-len(text) % 4)
    return base64.urlsafe_b64decode(text + padding)


def _sign(payload: str) -> str:
    digest = hmac.new(settings.secret_key.encode(), payload.encode(), hashlib.sha256).digest()
    return _b64(digest)


def create_session_token() -> str:
    """Create a signed token whose payload is the issue time (seconds)."""
    payload = _b64(str(int(time.time())).encode())
    return f"{payload}.{_sign(payload)}"


def verify_token(token: str) -> bool:
    if not token or "." not in token:
        return False
    payload, _, signature = token.partition(".")
    if not hmac.compare_digest(signature, _sign(payload)):
        return False
    try:
        issued_at = int(_unb64(payload).decode())
    except (ValueError, UnicodeDecodeError):
        return False
    return (time.time() - issued_at) <= MAX_AGE_SECONDS


def _secrets() -> list[str]:
    return [s for s in (settings.app_password, settings.api_token) if s]


def check_password(password: str) -> bool:
    """Constant-time check against APP_PASSWORD or API_TOKEN. True when auth is off."""
    if not settings.auth_required:
        return True
    given = password or ""
    return any(hmac.compare_digest(given, s) for s in _secrets())


def check_bearer(token: str) -> bool:
    """Constant-time check of a bearer token against API_TOKEN or APP_PASSWORD."""
    if not settings.auth_required:
        return True
    given = (token or "").strip()
    if not given:
        return False
    return any(hmac.compare_digest(given, s) for s in _secrets())
