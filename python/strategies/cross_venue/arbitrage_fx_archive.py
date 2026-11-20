"""Durable cycle FX evidence from the committed native cash projection."""
from bisect import bisect_right
from dataclasses import replace
from fractions import Fraction
from itertools import groupby
import json
from pathlib import Path
import re

from opportunity_scanner.scanner_config import atomic_json, _object
from strategies.cross_venue import arbitrage_economics as e

MAX_BYTES = 256 * 1024


def read_fx_sample(path):
    """Read the node-published sample in the original UTC clock."""
    try:
        with Path(path).open("rb") as stream:
            raw = stream.read(2049)
        if len(raw) > 2048:
            return None
        row = json.loads(raw, object_pairs_hook=_object)
        if (type(row) is not dict or set(row) != {"at_ns", "source", "usdt_per_usdc"}
                or type(row["usdt_per_usdc"]) is not str
                or re.fullmatch(r"[0-9]{1,38}(?:[./][0-9]{1,38})?", row["usdt_per_usdc"]) is None
                or type(row["at_ns"]) is not str or re.fullmatch(r"[0-9]{1,20}", row["at_ns"]) is None):
            return None
        return e.FxRate(Fraction(row["usdt_per_usdc"]), int(row["at_ns"]), row["source"])
    except (OSError, ValueError, TypeError, OverflowError, ZeroDivisionError, RecursionError):
        return None


class CycleFxArchive:
    """Single cycle owner. Capture before publishing its strategy report."""

    def __init__(self, path, strategy, first_sequence, *, max_age_ns):
        self.path = Path(path)
        self.strategy = e.integer(strategy, 1)
        self.first_sequence = e.integer(first_sequence, 1)
        self.cycle = f"cycle:{self.strategy}:{self.first_sequence}"
        self.max_age_ns = e.integer(max_age_ns, 1)

    def apply_from_authority(self, cycle, facts, authority, rate_file, **options):
        """Read at the strategy cutoff over the node's existing private authority."""
        try:
            projection = authority.request(dict(operation="cycle_fx_projection",
                strategy_identity=f"{self.strategy:032x}", cycle_first_sequence=self.first_sequence))
        except (OSError, ValueError):
            projection = {}
        rate = read_fx_sample(rate_file)
        if rate is not None and rate.at_ns > facts.at_ns:
            rate = None
        return self.apply(cycle, facts, projection, rate, **options)

    def apply(self, cycle, facts, projection, rate=None, **options):
        """Capture report evidence without making FX an order permission."""
        if (f"cycle:{cycle.plan.strategy}:{cycle.plan.first_sequence}" != self.cycle
                or cycle.cycle_ref not in (None, self.cycle)):
            raise ValueError("cycle FX strategy scope")
        try:
            projected = self.capture(facts, projection, rate)
        except (OSError, ValueError, KeyError, TypeError, ZeroDivisionError, RecursionError):
            projected = replace(facts, fx_exposures=(), fx_complete=False)
        return cycle.apply(projected, **options)

    def _load(self):
        try:
            with self.path.open("rb") as stream:
                data = stream.read(MAX_BYTES+1)
        except FileNotFoundError:
            return None
        if len(data) > MAX_BYTES:
            raise ValueError("cycle FX archive capacity")
        document = json.loads(data, object_pairs_hook=_object)
        if (document["schema"], document["cycle"], document["max_age_ns"]) != (1, self.cycle, self.max_age_ns):
            raise ValueError("cycle FX archive scope")
        return document

    def capture(self, facts, projection, rate=None):
        """Attach native facts at the same committed cutoff used by the strategy."""
        if (facts.cycle_ref != self.cycle or
                f"cycle:{projection['strategy']}:{projection['first_sequence']}" != self.cycle
                or projection["barrier"] != facts.cursor or type(projection["complete"]) is not bool):
            raise ValueError("cycle FX projection scope")
        if rate is not None and (not isinstance(rate, e.FxRate) or rate.at_ns > facts.at_ns
                or rate.market_at_ns not in (None, rate.at_ns)):
            raise ValueError("cycle FX sample cutoff")
        prior = self._load()
        if prior and (facts.cursor < prior["cursor"] or facts.at_ns < prior["at_ns"]):
            raise ValueError("cycle FX projection order")
        flows = {} if prior is None else dict(prior["flows"])
        current = set()
        for flow in e.bounded(projection["flows"]):
            if flow["kind"] not in ("fill", "funding", "fee_adjustment"):
                raise ValueError("cycle FX fact kind")
            identity = f"{e.integer(flow['account'], 1)}:{flow['kind']}:{e.integer(flow['identity'], 1)}"
            e.integer(flow["asset"], 1)
            e.integer(flow["atoms"], -e.MAX_INTEGER)
            if e.integer(flow["scale"]) > 18 or not 0 < e.integer(flow["at_ns"]) <= facts.at_ns:
                raise ValueError("cycle FX fact units")
            if identity in flows and flows[identity] != flow:
                raise ValueError("cycle FX fact conflict")
            current.add(identity)
            flows[identity] = flow
        if projection["complete"] and flows.keys() != current:
            raise ValueError("cycle FX projection omitted facts")
        rates = {} if prior is None else dict(prior["rates"])
        if rate is not None:
            key, sample = str(rate.at_ns), rate.display()
            if key in rates and rates[key] != sample:
                raise ValueError("cycle FX sample conflict")
            if key not in rates and rates and rate.at_ns < max(map(int, rates)):
                raise ValueError("cycle FX sample order")
            rates[key] = sample
        closed_at = None if prior is None else prior["closed_at_ns"]
        closed = projection.get("closed", False)
        observed_close = projection.get("closed_at_ns")
        complete = projection["complete"]
        if type(closed) is not bool or closed != (facts.closed_ref is not None):
            raise ValueError("cycle FX closure scope")
        if observed_close is not None:
            if not closed or not 0 < e.integer(observed_close) <= facts.at_ns or closed_at not in (None, observed_close):
                raise ValueError("cycle FX closure time")
            closed_at = observed_close
        if closed and closed_at is None:
            complete = False
        document = dict(schema=1, cycle=self.cycle, max_age_ns=self.max_age_ns, closed_at_ns=closed_at,
            closed=closed, cursor=facts.cursor, at_ns=facts.at_ns, complete=complete, flows=flows, rates=rates)
        projected = self._attach(facts, document)
        if prior != document:
            atomic_json(self.path, document, MAX_BYTES)
        return projected

    def restore(self, facts):
        document = self._load()
        if document is None or (facts.cycle_ref, facts.cursor, facts.at_ns) != (
                self.cycle, document["cursor"], document["at_ns"]):
            raise ValueError("cycle FX archive cutoff")
        return self._attach(facts, document)

    @staticmethod
    def _attach(facts, document):
        rates = sorted((e.FxRate(Fraction(*map(int, row["usdt_per_usdc"])), int(row["at_ns"]), row["source"])
                        for row in document["rates"].values()), key=lambda rate: rate.at_ns)
        times = [rate.at_ns for rate in rates]
        closed_at = document["closed_at_ns"]
        if document["closed"] and closed_at is None:
            return replace(facts, fx_exposures=(), fx_complete=False)
        events = [(row["at_ns"], identity, Fraction(row["atoms"], 10**row["scale"]))
                  for identity, row in document["flows"].items()]
        events.extend((rate.at_ns, f"sample:{rate.at_ns}", Fraction(0)) for index, rate in enumerate(rates)
                      if (closed_at is None or rate.at_ns <= closed_at)
                      and (index == 0 or rate.usdt_per_usdc != rates[index-1].usdt_per_usdc))
        cutoff = facts.at_ns if closed_at is None else closed_at
        events.append((cutoff, "cutoff", Fraction(0)))
        held, exposures = Fraction(0), []
        for at, group in groupby(sorted(events), key=lambda row: row[0]):
            i = bisect_right(times, at)-1
            rate = rates[i] if i >= 0 and at-times[i] < document["max_age_ns"] else None
            for _, identity, amount in group:
                held = (Fraction(0) if closed_at is not None and (at > closed_at or identity == "cutoff")
                        else e.exact(held + amount))
                exposures.append(e.FxExposure(identity, at, amount, held, rate))
        e.bounded(exposures)
        return replace(facts, fx_exposures=tuple(exposures), fx_complete=document["complete"])
