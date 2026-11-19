"""Read-only code bindings from activated AssetDefinitions, never symbol aliases."""
import hashlib
import json

from opportunity_scanner.scanner_config import uint_text


class AssetBindings:
    def __init__(self, document, *, allow_fixture=False):
        if (type(document) is not dict or set(document) != {"schema", "bindings"}
                or type(document["schema"]) is not int or document["schema"] != 1):
            raise ValueError("scanner asset bindings schema")
        rows = document["bindings"]
        if type(rows) is not list or len(rows) > 4096:
            raise ValueError("scanner asset bindings capacity")
        self.by_code = {}
        units, labels = {}, {}
        for row in rows:
            if type(row) is not dict or set(row) != {"asset", "atomic_scale", "version", "barrier",
                    "source_identity", "source_digest", "source_kind", "venue", "environment", "code"}:
                raise ValueError("scanner asset binding fields")
            for name in ("asset", "version", "barrier", "venue"):
                uint_text(row[name], minimum=1)
            source = row["source_identity"]
            if (type(source) is not str or not source.isascii() or not source.isdecimal()
                    or str(int(source)) != source or not 0 < int(source) < 1 << 128):
                raise ValueError("scanner asset source identity")
            code, scale = row["code"], row["atomic_scale"]
            if (type(code) is not str or not 1 <= len(code) <= 16 or not code.isascii()
                    or any(not (c.isalnum() or c in "-_") for c in code)
                    or type(scale) is not int or not 0 <= scale <= 18
                    or row["environment"] not in ("simulation", "production", "demo", "testnet")
                    or type(row["source_digest"]) is not str or len(row["source_digest"]) != 64):
                raise ValueError("scanner asset binding units/source")
            digest = bytes.fromhex(row["source_digest"])
            if digest.hex() != row["source_digest"] or not any(digest):
                raise ValueError("scanner asset binding digest")
            if row["source_kind"] not in (("venue_economic_fields", "test_fixture") if allow_fixture else ("venue_economic_fields",)):
                raise ValueError("scanner asset source kind")
            key = row["venue"], row["environment"], code
            unit = row["environment"], row["asset"]
            definition = scale, row["version"], row["source_identity"], row["source_digest"], row["source_kind"]
            if unit in units and units[unit] != definition:
                raise ValueError("scanner asset definition conflict")
            units[unit] = definition
            known = self.by_code.get(key)
            if known is not None and {k:v for k,v in known.items() if k != "barrier"} != {
                    k:v for k,v in row.items() if k != "barrier"}:
                raise ValueError("scanner asset binding conflict")
            self.by_code[key] = dict(row, barrier=str(min(int(row["barrier"]), int(known["barrier"])))) if known else dict(row)
            labels.setdefault(unit, set()).add(code)
        self.labels = {k: min(v) for k, v in labels.items()}
        self.digest = hashlib.sha256(json.dumps(sorted(self.by_code.values(),
            key=lambda r: (r["venue"], r["environment"], r["code"])),
            sort_keys=True, separators=(",", ":")).encode()).hexdigest()

    def resolve(self, venue, environment, code):
        row = self.by_code.get((str(venue), environment, code))
        return dict(row) if row is not None else None

    def label(self, binding):
        return self.labels[binding["environment"], binding["asset"]]
