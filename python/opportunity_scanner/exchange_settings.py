"""Saved Venue/environment selection; contains no credentials or trading authority."""
import copy
import json
from pathlib import Path
import re
import secrets
from threading import RLock

from opportunity_scanner.scanner_config import atomic_json, uint_text, _object

MAX_BYTES = 65536
ADAPTER_TYPES = (
    dict(type="okx", label="OKX", venue="1", environments=["production", "demo"], products=["spot", "linear"]),
    dict(type="hyperliquid", label="Hyperliquid", venue="21", environments=["production", "testnet"], products=["linear"]),
)


def validate_row(row):
    if type(row) is not dict or set(row) != {"identity", "venue", "type", "name", "environment"}:
        raise ValueError("exchange settings fields")
    adapter = next((a for a in ADAPTER_TYPES if a["type"] == row["type"]), None)
    if adapter is None or row["venue"] != adapter["venue"] or row["environment"] not in adapter["environments"]:
        raise ValueError("unsupported exchange type/environment")
    if type(row["name"]) is not str or not row["name"].strip() or row["name"] != row["name"].strip() or len(row["name"]) > 128:
        raise ValueError("exchange name is required (maximum 128 characters)")
    if type(row["identity"]) is not str or re.fullmatch(r"[0-9a-f]{32}", row["identity"]) is None:
        raise ValueError("exchange setting identity")


class ExchangeSettings:
    def __init__(self, path):
        self.path, self.lock = Path(path), RLock()
        self.document = dict(schema="exchange_settings_v1", version="0", exchanges=[])
        try:
            with self.path.open("rb") as source:
                data = source.read(MAX_BYTES+1)
        except FileNotFoundError:
            return
        try:
            if len(data) > MAX_BYTES:
                raise ValueError("capacity")
            document = json.loads(data, object_pairs_hook=_object)
            if (type(document) is not dict or set(document) != {"schema", "version", "exchanges"}
                    or document["schema"] != "exchange_settings_v1"):
                raise ValueError("schema")
            uint_text(document["version"], minimum=1)
            rows = document["exchanges"]
            if type(rows) is not list or len(rows) > 32:
                raise ValueError("capacity")
            identities, sources = set(), set()
            for row in rows:
                validate_row(row)
                key = row["venue"], row["environment"]
                if row["identity"] in identities or key in sources:
                    raise ValueError("duplicate source")
                identities.add(row["identity"])
                sources.add(key)
            self.document = document
        except (ValueError, TypeError, KeyError) as error:
            raise ValueError("saved exchange settings invalid: "+str(error)) from error

    def view(self):
        with self.lock:
            return copy.deepcopy(dict(self.document, types=ADAPTER_TYPES))

    def save(self, request):
        with self.lock:
            if type(request) is dict and request.get("operation") == "delete":
                if set(request) != {"operation", "identity", "expected_version"}:
                    raise ValueError("exchange settings delete fields")
                if request["expected_version"] != self.document["version"]:
                    raise ValueError("exchange settings version conflict")
                rows = [r for r in self.document["exchanges"] if r["identity"] != request["identity"]]
                if len(rows) == len(self.document["exchanges"]):
                    raise ValueError("unknown exchange setting")
                return self._commit(rows)
            fields = {"expected_version", "type", "name", "environment"}
            if type(request) is not dict or set(request) - {"identity"} != fields:
                raise ValueError("exchange settings request fields")
            if request["expected_version"] != self.document["version"]:
                raise ValueError("exchange settings version conflict")
            adapter = next((a for a in ADAPTER_TYPES if a["type"] == request["type"]), None)
            if adapter is None:
                raise ValueError("unsupported exchange type")
            identity = request.get("identity")
            previous = next((r for r in self.document["exchanges"] if r["identity"] == identity), None)
            if "identity" in request and previous is None:
                raise ValueError("unknown exchange setting")
            row = dict(identity=identity if previous else secrets.token_hex(16), venue=adapter["venue"],
                       type=request["type"], name=request["name"].strip() if type(request["name"]) is str else request["name"],
                       environment=request["environment"])
            validate_row(row)
            rows = [r for r in self.document["exchanges"] if r["identity"] != row["identity"]]
            if any((r["venue"], r["environment"]) == (row["venue"], row["environment"]) for r in rows):
                raise ValueError("duplicate exchange source")
            rows.append(row)
            if len(rows) > 32:
                raise ValueError("exchange settings capacity")
            return self._commit(rows)

    def _commit(self, rows):
        candidate = dict(schema="exchange_settings_v1", version=str(uint_text(self.document["version"])+1), exchanges=rows)
        uint_text(candidate["version"])
        atomic_json(self.path, candidate, MAX_BYTES)
        self.document = candidate
        return self.view()
