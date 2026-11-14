"""Ciphertext inbox for native CredentialStore enrollment; never decrypts.

Header fields are untrusted hints until the node authenticates AEAD and checks
its configured binding. Importing a package never activates a credential.
"""
from __future__ import annotations

import base64
import binascii
import hashlib
import os
import struct
import tempfile
import threading

VENUES = {1: "okx", 2: "binance", 3: "bybit", 4: "hyperliquid"}
ENVIRONMENTS = {0: "demo", 1: "testnet", 2: "production"}
MAX_ENCRYPTED_BYTES = 780
MAX_REQUEST_BYTES = 2048


def inspect_package(encrypted: bytes) -> dict:
    if not 268 <= len(encrypted) <= MAX_ENCRYPTED_BYTES:
        raise ValueError("invalid encrypted package size")
    if encrypted[:4] != b"CRD4" or struct.unpack_from("<H", encrypted, 4)[0] != 2:
        raise ValueError("a venue-bound CRD4 v2 package is required")
    kind, state, capabilities, venue = encrypted[6:10]
    version, generation, expiry, account = struct.unpack_from("<QQQQ", encrypted, 10)
    environment, endpoint, id_len, node_len, ip_len = encrypted[42:47]
    payload_len = struct.unpack_from("<H", encrypted, 248)[0]
    if (venue not in VENUES or kind not in (0, 1) or state != 0 or generation != 1
            or version == 0 or account == 0 or expiry == 0
            or environment not in ENVIRONMENTS or endpoint != environment
            or (venue != 1 and environment == 0)
            or capabilities != (1 if kind == 0 else 3)
            or not 1 <= id_len <= 32 or not 1 <= node_len <= 64
            or not 1 <= ip_len <= 64 or payload_len > 512
            or len(encrypted) != 252 + payload_len + 16):
        raise ValueError("invalid staged credential binding")
    try:
        identity = encrypted[48:48 + id_len].decode("utf-8")
        node = encrypted[80:80 + node_len].decode("utf-8")
        egress_ip = encrypted[144:144 + ip_len].decode("utf-8")
    except UnicodeDecodeError:
        raise ValueError("invalid public metadata encoding") from None
    return {"venue": VENUES[venue], "kind": "observation" if kind == 0 else "execution",
            "account": str(account), "environment": ENVIRONMENTS[environment],
            "credential_id": identity, "node_id": node, "egress_ip": egress_ip,
            "version": str(version), "generation": "1", "expires_at_unix": str(expiry),
            "status": "pending_unlock", "authenticated": False, "trading_enabled": False}


class CredentialPackages:
    def __init__(self, directory: str):
        self.directory = os.path.abspath(directory)
        self.lock = threading.Lock()

    def import_package(self, request: dict, now: int) -> tuple[dict, bool]:
        if not isinstance(request, dict) or set(request) != {"encrypted_package"}:
            raise ValueError("only encrypted_package is accepted")
        encoded = request["encrypted_package"]
        if not isinstance(encoded, str) or len(encoded) > 1040:
            raise ValueError("invalid encrypted package encoding")
        try:
            encrypted = base64.b64decode(encoded, validate=True)
        except (binascii.Error, ValueError):
            raise ValueError("invalid encrypted package encoding") from None
        metadata = inspect_package(encrypted)
        if int(metadata["expires_at_unix"]) <= now:
            raise ValueError("credential package has expired")
        digest = hashlib.sha256(encrypted).hexdigest()
        metadata["package_sha256"] = digest
        os.makedirs(self.directory, mode=0o700, exist_ok=True)
        if os.name == "posix":
            os.chmod(self.directory, 0o700)
        destination = os.path.join(self.directory, digest + ".credential")
        descriptor, temporary = tempfile.mkstemp(dir=self.directory, suffix=".tmp")
        try:
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(encrypted)
                handle.flush()
                os.fsync(handle.fileno())
            try:
                # Exclusive publication: retries cannot overwrite old bytes.
                os.link(temporary, destination)
                created = True
            except FileExistsError:
                with open(destination, "rb") as handle:
                    if handle.read(MAX_ENCRYPTED_BYTES + 1) != encrypted:
                        raise ValueError("credential package identity conflict") from None
                created = False
            if os.name == "posix":
                directory_fd = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(directory_fd)
                finally:
                    os.close(directory_fd)
        finally:
            os.unlink(temporary)
        return metadata, created

    def list_packages(self) -> list[dict]:
        if not os.path.isdir(self.directory):
            return []
        packages = []
        for name in sorted(os.listdir(self.directory)):
            if len(name) != 75 or not name.endswith(".credential"):
                continue
            with open(os.path.join(self.directory, name), "rb") as handle:
                encrypted = handle.read(MAX_ENCRYPTED_BYTES + 1)
            if hashlib.sha256(encrypted).hexdigest() != name[:64]:
                raise ValueError("credential package digest mismatch")
            metadata = inspect_package(encrypted)
            metadata["package_sha256"] = name[:64]
            packages.append(metadata)
        return packages
