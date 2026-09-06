"""OwnerSession authentication core for the control plane.

Pure standard library: scrypt passphrase hashing, RFC 6238 TOTP with a ±1
step window and consumed-step replay protection, single-active limited
sessions, and login rate limiting. All time comes from an injectable clock so
acceptance tests can fast-forward expiry without sleeping.

Storage layout under one runtime directory:
  passphrase.json  {salt, n, r, p, hash} hex fields (scrypt)
  totp.secret      base32 secret (created on first initialization)
  session.json     {token_hash, expires_at} of the single active session
"""

import base64
import hashlib
import hmac
import json
import os
import secrets
import struct
import time

SCRYPT_N = 2 ** 14
SCRYPT_R = 8
SCRYPT_P = 1
TOTP_STEP = 30
TOTP_DIGITS = 6
TOTP_WINDOW_STEPS = 1
SESSION_TTL_SECONDS = 900
RATE_LIMIT_MAX_FAILURES = 5
RATE_LIMIT_COOLDOWN_SECONDS = 60


def default_clock() -> int:
    return int(time.time())


class PassphraseStore:
    def __init__(self, directory: str):
        self.path = os.path.join(directory, "passphrase.json")

    def exists(self) -> bool:
        return os.path.exists(self.path)

    def set(self, passphrase: str) -> None:
        if self.exists():
            raise PermissionError("passphrase already initialized")
        if len(passphrase) < 12:
            raise ValueError("passphrase must be at least 12 characters")
        salt = secrets.token_bytes(16)
        digest = hashlib.scrypt(passphrase.encode(), salt=salt,
                                n=SCRYPT_N, r=SCRYPT_R, p=SCRYPT_P, dklen=64)
        payload = {
            "salt": salt.hex(),
            "n": SCRYPT_N, "r": SCRYPT_R, "p": SCRYPT_P,
            "hash": digest.hex(),
        }
        with open(self.path, "w") as handle:
            json.dump(payload, handle)

    def verify(self, passphrase: str, clock=default_clock) -> bool:
        if not self.exists():
            return False
        with open(self.path) as handle:
            payload = json.load(handle)
        digest = hashlib.scrypt(passphrase.encode(),
                                salt=bytes.fromhex(payload["salt"]),
                                n=payload["n"], r=payload["r"],
                                p=payload["p"], dklen=64)
        return hmac.compare_digest(digest.hex(), payload["hash"])


def generate_totp_secret() -> str:
    """160-bit random secret, base32 for manual entry or QR rendering."""
    return base64.b32encode(secrets.token_bytes(20)).decode("ascii").rstrip("=")


class TotpStore:
    def __init__(self, directory: str):
        self.path = os.path.join(directory, "totp.secret")
        self.consumed_path = os.path.join(directory, "totp.consumed")

    def initialize(self) -> str:
        if os.path.exists(self.path):
            raise PermissionError("totp already initialized")
        secret = generate_totp_secret()
        self._write_secret(secret)
        return secret

    def _write_secret(self, secret: str) -> None:
        with open(self.path, "w") as handle:
            handle.write(secret)

    def read_secret(self) -> str:
        with open(self.path) as handle:
            return handle.read().strip()

    def verify(self, code: str, clock=default_clock) -> bool:
        if not os.path.exists(self.path) or not code.isdigit():
            return False
        code = code.zfill(TOTP_DIGITS)
        now = clock()
        consumed = self._read_consumed(now)
        for offset in range(-TOTP_WINDOW_STEPS, TOTP_WINDOW_STEPS + 1):
            counter = (now // TOTP_STEP) + offset
            if counter in consumed:
                continue
            expected = hotp(self.read_secret(), counter)
            if hmac.compare_digest(expected.zfill(TOTP_DIGITS), code):
                consumed.add(counter)
                self._write_consumed(consumed, now)
                return True
        return False

    def _read_consumed(self, now: int) -> set[int]:
        if not os.path.exists(self.consumed_path):
            return set()
        with open(self.consumed_path) as handle:
            return {int(line) for line in handle.read().split() if line}

    def _write_consumed(self, counters: set[int], now: int) -> None:
        cutoff = (now // TOTP_STEP) - 10 * 60
        kept = sorted(counter for counter in counters
                      if counter >= cutoff - TOTP_WINDOW_STEPS)
        with open(self.consumed_path, "w") as handle:
            handle.write("\n".join(str(counter) for counter in kept))


def hotp(base32_secret: str, counter: int) -> str:
    """RFC 4226 HOTP over SHA-1; matches authenticator app defaults."""
    key = base64.b32decode(base32_secret + "=" * ((-len(base32_secret)) % 8))
    message = struct.pack(">Q", counter)
    digest = hmac.new(key, message, hashlib.sha1).digest()
    offset = digest[-1] & 0xF
    truncated = (struct.unpack(">I", digest[offset:offset + 4])[0]
                 & 0x7FFFFFFF)
    return str(truncated % (10 ** TOTP_DIGITS))


class SessionManager:
    """Single active OwnerSession; new logins revoke the previous token."""

    def __init__(self, directory: str, ttl_seconds: int = SESSION_TTL_SECONDS):
        self.path = os.path.join(directory, "session.json")
        self.ttl_seconds = ttl_seconds

    def issue(self, clock=default_clock) -> str:
        token = secrets.token_urlsafe(32)
        payload = {"token_hash": hashlib.sha256(token.encode()).hexdigest(),
                   "expires_at": clock() + self.ttl_seconds}
        with open(self.path, "w") as handle:
            json.dump(payload, handle)
        return token

    def validate(self, token: str, clock=default_clock) -> bool:
        if not token or not os.path.exists(self.path):
            return False
        with open(self.path) as handle:
            payload = json.load(handle)
        if clock() >= payload["expires_at"]:
            return False
        return hmac.compare_digest(
            hashlib.sha256(token.encode()).hexdigest(), payload["token_hash"])

    def renew(self, token: str, clock=default_clock) -> bool:
        if not self.validate(token, clock):
            return False
        with open(self.path) as handle:
            payload = json.load(handle)
        payload["expires_at"] = clock() + self.ttl_seconds
        with open(self.path, "w") as handle:
            json.dump(payload, handle)
        return True

    def revoke(self) -> None:
        if os.path.exists(self.path):
            os.remove(self.path)


class RateLimiter:
    """Locks an identity out after repeated consecutive failures."""

    def __init__(self, max_failures: int = RATE_LIMIT_MAX_FAILURES,
                 cooldown_seconds: int = RATE_LIMIT_COOLDOWN_SECONDS):
        self.max_failures = max_failures
        self.cooldown_seconds = cooldown_seconds
        self._failures: dict[str, int] = {}
        self._locked_until: dict[str, int] = {}

    def check(self, identity: str, clock=default_clock) -> bool:
        until = self._locked_until.get(identity)
        if until is not None and clock() < until:
            return False
        return True

    def record_failure(self, identity: str, clock=default_clock) -> None:
        count = self._failures.get(identity, 0) + 1
        self._failures[identity] = count
        if count >= self.max_failures:
            self._locked_until[identity] = clock() + self.cooldown_seconds
            self._failures[identity] = 0

    def record_success(self, identity: str) -> None:
        self._failures.pop(identity, None)
        self._locked_until.pop(identity, None)


def totp_at(secret: str, unix_time: int) -> str:
    """Test helper: the valid TOTP at an explicit unix time."""
    return hotp(secret, unix_time // TOTP_STEP)
