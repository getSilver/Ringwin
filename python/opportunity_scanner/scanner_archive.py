"""Versioned, bounded data-only archive of canonical scanner inputs."""
from dataclasses import fields, is_dataclass
from fractions import Fraction
import json
import math

from strategies.cross_venue import arbitrage_baseline
from strategies.cross_venue import arbitrage_economics
from strategies.cross_venue import arbitrage_evaluation
from strategies.cross_venue import arbitrage_probability
from opportunity_scanner import arbitrage_scanner

MODULES = (arbitrage_baseline, arbitrage_economics, arbitrage_evaluation,
           arbitrage_probability, arbitrage_scanner)
TYPES = {module.__name__.rsplit(".", 1)[-1] + "." + name: cls for module in MODULES for name, cls in vars(module).items()
         if isinstance(cls, type) and is_dataclass(cls) and cls.__module__ == module.__name__}
MAX_BYTES = 16 * 1024 * 1024
OPTIONAL_PLAN_FIELDS = {"fee_version", "entry_base", "buy_notional_atoms"}


def freeze(value):
    if is_dataclass(value):
        name = type(value).__module__.rsplit(".", 1)[-1] + "." + type(value).__name__
        if name not in TYPES:
            raise ValueError("unregistered scanner archive type")
        return {"type": name, "fields": {f.name: freeze(getattr(value, f.name)) for f in fields(value)
                                       if not (type(value) is arbitrage_scanner.Plan and f.name in OPTIONAL_PLAN_FIELDS
                                               and getattr(value, f.name) is None)}}
    if type(value) is Fraction:
        return {"fraction": [str(value.numerator), str(value.denominator)]}
    if type(value) is bytes:
        return {"bytes": value.hex()}
    if type(value) is float:
        if not math.isfinite(value):
            raise ValueError("nonfinite scanner archive")
        return {"binary64": value.hex()}
    if type(value) is tuple:
        return {"tuple": [freeze(x) for x in value]}
    if type(value) is list:
        return [freeze(x) for x in value]
    if type(value) is dict:
        return {k: freeze(v) for k, v in value.items()}
    if value is None or type(value) in (str, bool, int):
        return value
    raise ValueError("unsupported scanner archive value")


def thaw(value, depth=0):
    if depth > 64:
        raise ValueError("scanner archive nesting")
    if type(value) is list:
        return [thaw(x, depth+1) for x in value]
    if type(value) is not dict:
        return value
    if set(value) == {"type", "fields"}:
        cls = TYPES.get(value["type"])
        names = set(value["fields"])
        optional = set()
        if cls is arbitrage_scanner.Plan:
            optional = OPTIONAL_PLAN_FIELDS
        if cls is arbitrage_scanner.Observation:
            optional = {"market_source", "market_error", "registered_assets"}
        if cls is arbitrage_economics.InstrumentRules:
            optional = {"quote_unit", "settlement", "registered_base"}
        expected = {f.name for f in fields(cls)} if cls is not None else set()
        if cls is None or not expected - optional <= names <= expected:
            raise ValueError("scanner archive type/fields")
        return cls(**{k: thaw(v, depth+1) for k, v in value["fields"].items()})
    if set(value) == {"tuple"}:
        return tuple(thaw(x, depth+1) for x in value["tuple"])
    if set(value) == {"fraction"}:
        return Fraction(*map(int, value["fraction"]))
    if set(value) == {"bytes"}:
        return bytes.fromhex(value["bytes"])
    if set(value) == {"binary64"}:
        result = float.fromhex(value["binary64"])
        if not math.isfinite(result):
            raise ValueError("nonfinite scanner archive")
        return result
    return {k: thaw(v, depth+1) for k, v in value.items()}


def load(content):
    if type(content) is not str or len(content.encode()) > MAX_BYTES:
        raise ValueError("scanner archive capacity")
    return thaw(json.loads(content))
