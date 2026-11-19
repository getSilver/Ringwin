"""Manual, persistent account/product/native-asset fee schedules (no clock TTL)."""
import copy
import json
import re
from fractions import Fraction
from pathlib import Path
from threading import RLock

from opportunity_scanner.scanner_config import atomic_json, _object, uint_text
from strategies.cross_venue.arbitrage_economics import FeeRule

MAX_BYTES = 2 * 1024 * 1024


def percent_ppm(value):
    if type(value) is not str or re.fullmatch(r"-?\d+(?:\.\d+)?", value) is None or len(value) > 64:
        raise ValueError("fee percentage must be decimal text")
    rate = Fraction(value) * 10000
    if not -1_000_000 <= rate <= 1_000_000:
        raise ValueError("fee percentage outside capacity")
    return rate


def validate(row):
    if type(row) is not dict or set(row) != {"venue", "account", "product", "fee_asset", "maker_percent", "taker_percent"}:
        raise ValueError("fee schedule fields")
    for key in ("venue", "account", "fee_asset"):
        uint_text(row[key], minimum=1)
    if row["product"] not in ("spot", "linear"):
        raise ValueError("fee schedule product")
    for key in ("maker_percent", "taker_percent"):
        percent_ppm(row[key])
    return tuple(row[k] for k in ("venue", "account", "product", "fee_asset"))


class FeeSchedules:
    def __init__(self, path):
        self.path, self.lock = Path(path), RLock()
        self.document = dict(schema="manual_fee_schedules_v1", version="0", revisions=[])
        if self.path.exists():
            with self.path.open("rb") as stream:
                raw = stream.read(MAX_BYTES + 1)
            if len(raw) > MAX_BYTES:
                raise ValueError("fee schedule capacity")
            doc = json.loads(raw, object_pairs_hook=_object)
            if type(doc) is not dict or set(doc) != set(self.document) or doc["schema"] != self.document["schema"]:
                raise ValueError("fee schedule schema")
            if type(doc["revisions"]) is not list or uint_text(doc["version"]) != len(doc["revisions"]):
                raise ValueError("fee schedule version")
            for rows in doc["revisions"]:
                self._validate_rows(rows)
            self.document = doc

    @staticmethod
    def _validate_rows(rows):
        if type(rows) is not list or len(rows) > 256:
            raise ValueError("fee schedule capacity")
        keys = [validate(row) for row in rows]
        if len(keys) != len(set(keys)):
            raise ValueError("duplicate fee schedule")
        # One payment asset per account/product; never guess between currencies.
        if len({key[:3] for key in keys}) != len(keys):
            raise ValueError("ambiguous fee asset")

    def view(self):
        with self.lock:
            return dict(version=self.document["version"], rows=copy.deepcopy(self.document["revisions"][-1] if self.document["revisions"] else []))

    def save(self, request):
        with self.lock:
            if type(request) is not dict or set(request) != {"expected_version", "rows"}:
                raise ValueError("fee schedule request fields")
            if request["expected_version"] != self.document["version"]:
                raise ValueError("fee schedule version conflict")
            self._validate_rows(request["rows"])
            if self.view()["rows"] == request["rows"]:
                return self.view()
            doc = copy.deepcopy(self.document)
            doc["revisions"].append(copy.deepcopy(request["rows"]))
            doc["version"] = str(len(doc["revisions"]))
            atomic_json(self.path, doc, MAX_BYTES)
            self.document = doc
            return self.view()

    def rule(self, observation, *, version=None):
        with self.lock:
            version = self.document["version"] if version is None else version
            if version == "0":
                raise ValueError("fees_missing_leg:" + ":".join(map(str, observation.identity)))
            index = uint_text(version, minimum=1)
            if index > len(self.document["revisions"]):
                raise ValueError("unknown fee version")
            row = next((r for r in self.document["revisions"][index-1]
                        if (r["venue"], r["account"], r["product"]) ==
                        (str(observation.venue), str(observation.account), observation.kind)), None)
            if row is None:
                raise ValueError("fees_missing_leg:" + ":".join(map(str, observation.identity)))
            # Admission never banks on an unconfirmed rebate. Actual fees/rebates
            # remain canonical execution facts in the core ledger.
            return FeeRule(observation.rules.instrument, observation.rules.version, int(row["fee_asset"]),
                           max(0, percent_ppm(row["taker_percent"])), max(0, percent_ppm(row["maker_percent"])),
                           0, (1 << 127)-1)

    def require_current(self, version):
        if version != self.view()["version"]:
            raise ValueError("fees_version_changed")
