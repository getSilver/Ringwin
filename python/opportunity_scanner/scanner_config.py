"""Current observational scanner scope; no history, requests or trading authority."""
import json
import os
from pathlib import Path
import tempfile

from opportunity_scanner.arbitrage_scanner import Scope

MAX_CONFIG_BYTES = 2*1024*1024


def uint_text(value, *, minimum=0):
    if type(value) is not str or not value.isascii() or not value.isdecimal() or str(int(value)) != value:
        raise ValueError("canonical decimal string required")
    result = int(value)
    if not minimum <= result < 1 << 127:
        raise ValueError("integer outside capacity")
    return result


def _validate(config):
    if type(config) is not dict or set(config) != {"version", "scopes", "registered", "statistics"}:
        raise ValueError("saved scanner config fields")
    version = uint_text(config["version"])
    if type(config["scopes"]) is not list or len(config["scopes"]) > 64:
        raise ValueError("saved scanner scope capacity")
    keys = set()
    for row in config["scopes"]:
        fields = {"venue", "product", "environment", "include_assets", "exclude_assets", "quote_asset",
                  "min_depth_atoms", "max_depth_atoms", "new_instruments"}
        if type(row) is not dict or set(row) != fields or type(row["new_instruments"]) is not bool:
            raise ValueError("saved scanner scope fields")
        key = row["venue"], row["product"], row["environment"]
        if key in keys:
            raise ValueError("duplicate scanner subscription")
        keys.add(key)
        for field in ("include_assets", "exclude_assets"):
            if type(row[field]) is not list or len(row[field]) > 256:
                raise ValueError("saved scanner asset capacity")
        Scope(max(1, version), (uint_text(row["venue"], minimum=1),), (row["product"],),
            tuple(uint_text(x, minimum=1) for x in row["include_assets"]),
            tuple(uint_text(x, minimum=1) for x in row["exclude_assets"]),
            uint_text(row["quote_asset"], minimum=1) if row["quote_asset"] is not None else None,
            uint_text(row["min_depth_atoms"]) if row["min_depth_atoms"] is not None else None,
            uint_text(row["max_depth_atoms"]) if row["max_depth_atoms"] is not None else None, environment=row["environment"])
    if type(config["registered"]) is not list or len(config["registered"]) > 64:
        raise ValueError("saved scanner catalogue capacity")
    identities = set()
    for identity in config["registered"]:
        if type(identity) is not list or len(identity) != 3:
            raise ValueError("saved scanner catalogue identity")
        value = tuple(uint_text(x, minimum=1) for x in identity)
        if value in identities:
            raise ValueError("duplicate scanner catalogue identity")
        identities.add(value)
    statistics = config["statistics"]
    if (type(statistics) is not dict or set(statistics) != {"version", "min_profit_atoms", "min_probability_ppm"}
            or type(statistics["min_probability_ppm"]) is not int or not 0 <= statistics["min_probability_ppm"] <= 1_000_000):
        raise ValueError("saved scanner statistics policy")
    uint_text(statistics["version"], minimum=1)
    uint_text(statistics["min_profit_atoms"])


def _object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate saved scanner config field")
        result[key] = value
    return result


class ConfigStore:
    def __init__(self, path):
        self.path = Path(path)

    def load(self):
        try:
            with self.path.open("rb") as source:
                contents = source.read(MAX_CONFIG_BYTES+1)
        except FileNotFoundError:
            return None
        if len(contents) > MAX_CONFIG_BYTES:
            raise ValueError("saved scanner config capacity")
        document = json.loads(contents, object_pairs_hook=_object)
        if type(document) is not dict or set(document) != {"schema", "config"} or document["schema"] != "scanner_config_v1":
            raise ValueError("saved scanner config schema")
        _validate(document["config"])
        return document["config"]

    def save(self, config):
        _validate(config)
        data = json.dumps(dict(schema="scanner_config_v1", config=config), sort_keys=True,
                          separators=(",", ":"), allow_nan=False).encode()
        if len(data) > MAX_CONFIG_BYTES:
            raise ValueError("saved scanner config capacity")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=self.path.parent, prefix=".scanner-config-", suffix=".tmp", delete=False) as target:
                temporary = Path(target.name)
                target.write(data)
                target.flush()
                os.fsync(target.fileno())
            os.replace(temporary, self.path)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
