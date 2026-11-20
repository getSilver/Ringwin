"""Scope and restart checks for the native cycle FX reporting path."""
from dataclasses import replace
from fractions import Fraction
from pathlib import Path
from tempfile import TemporaryDirectory
import json
import sys
import unittest

from strategies.cross_venue.arbitrage_cycle import Cycle
from strategies.cross_venue.arbitrage_economics import FxRate
from strategies.cross_venue.arbitrage_fx_archive import CycleFxArchive
from test_arbitrage_cycle import T, facts, plan


def verify_committed(projection, expected):
    cutoff = max(row["at_ns"] for row in projection["flows"])
    first = projection["first_sequence"]
    frame = facts(cursor=projection["barrier"], at_ns=cutoff,
                  cycle_ref=f"cycle:9:{first}")
    current = Cycle(plan(first_sequence=first))
    current.start(cursor=1, at_ns=T)
    with TemporaryDirectory() as directory:
        evidence = Path(directory) / "fx.json"
        archive = CycleFxArchive(evidence, 9, first, max_age_ns=100_000_000)
        quote = FxRate(Fraction(998, 1000), min(row["at_ns"] for row in projection["flows"]), "USDC-USDT spot")
        rate_file = Path(directory) / "stablecoin-fx.json"
        rate_file.write_text(json.dumps(dict(quote.display(), usdt_per_usdc="0.998")), encoding="utf-8")
        class CommittedReply:
            def request(self, request):
                assert request == dict(operation="cycle_fx_projection", strategy_identity=f"{9:032x}",
                                       cycle_first_sequence=first)
                return projection
        action = archive.apply_from_authority(current, frame, CommittedReply(), rate_file)
        self_report = action.profit["actual_fx"]
        assert self_report["deviation_usdt"] == expected, self_report
        assert sum(row["rate"]["source"] == quote.source for row in self_report["records"]) >= 2
        saved = evidence.read_bytes()
        reopened = CycleFxArchive(evidence, 9, first, max_age_ns=100_000_000)
        assert current.profit_report(reopened.restore(frame)) == action.profit
        assert reopened.capture(frame, projection, quote) == reopened.restore(frame)
        assert evidence.read_bytes() == saved
        replayed = reopened.apply(current, frame, projection, quote)
        assert replayed.reason == "duplicate_cursor" and replayed.profit == action.profit
        closing = replace(frame, cursor=frame.cursor+1, at_ns=cutoff+1, closed_ref="core-closure")
        changed = FxRate(Fraction(997, 1000), cutoff+1, quote.source)
        closing_projection = dict(projection, barrier=closing.cursor, closed=True, closed_at_ns=closing.at_ns)
        closed = current.profit_report(reopened.capture(closing, closing_projection, changed))
        signed = "-3" if expected[0] == "-2" else "3"
        assert closed["actual_fx"]["deviation_usdt"] == [signed, "1"], closed
        later = replace(closing, cursor=closing.cursor+1, at_ns=cutoff+2)
        later_rate = FxRate(Fraction(996, 1000), cutoff+2, quote.source)
        archived = reopened.capture(later, dict(closing_projection, barrier=later.cursor, closed_at_ns=None), later_rate)
        assert current.profit_report(archived)["actual_fx"] == closed["actual_fx"]
        return self_report


class FxArchiveTests(unittest.TestCase):
    def test_signed_cash_reports_and_reopens(self):
        for atoms, expected in ((1_000_000_000, "-2"), (-1_000_000_000, "2")):
            projection = dict(strategy=9, first_sequence=1, barrier=5, complete=True, flows=[
                dict(account=30, asset=3, scale=6, atoms=atoms, at_ns=T+10, identity=72, kind="funding")])
            verify_committed(projection, [expected, "1"])

    def test_pending_evidence_and_contradictory_replay(self):
        with TemporaryDirectory() as directory:
            archive = CycleFxArchive(Path(directory) / "fx.json", 9, 1, max_age_ns=10)
            frame = facts(cursor=5, at_ns=T+11, cycle_ref="cycle:9:1")
            flow = dict(account=30, asset=3, scale=6, atoms=1_000_000_000, at_ns=T+10, identity=72, kind="funding")
            projection = dict(strategy=9, first_sequence=1, barrier=5, complete=False, flows=[flow, flow])
            current = Cycle(plan())
            current.start(cursor=1, at_ns=T)
            report = archive.apply(current, frame, projection).profit["actual_fx"]
            self.assertEqual(report["status"], "pending")
            self.assertEqual([row["identity"] for row in report["records"]].count("30:funding:72"), 1)
            with self.assertRaisesRegex(ValueError, "fact conflict"):
                archive.capture(frame, dict(projection, flows=[dict(flow, atoms=1)]))
            later = replace(frame, cursor=6, at_ns=T+12)
            report = archive.apply(current, later, dict(projection, barrier=6, flows=[]),
                FxRate(Fraction(997, 1000), T+12, "late")).profit["actual_fx"]
            self.assertEqual(report["status"], "pending")
            self.assertIsNone(report["deviation_usdt"])

    def test_archive_unavailability_then_same_core_cursor_recovers_reporting(self):
        with TemporaryDirectory() as directory:
            target = Path(directory) / "blocked"
            target.mkdir()
            archive = CycleFxArchive(target, 9, 1, max_age_ns=10)
            frame = facts(cursor=5, at_ns=T+10, cycle_ref="cycle:9:1")
            flow = dict(account=30, asset=3, scale=6, atoms=1_000_000_000, at_ns=T+10, identity=72, kind="funding")
            projection = dict(strategy=9, first_sequence=1, barrier=5, complete=True, flows=[flow])
            current = Cycle(plan())
            current.start(cursor=1, at_ns=T)
            rate = FxRate(Fraction(998, 1000), T+10, "USDC-USDT spot")
            self.assertEqual(archive.apply(current, frame, projection, rate).profit["actual_fx"]["status"], "pending")
            target.rmdir()
            retry = archive.apply(current, frame, projection, rate)
            self.assertEqual(retry.reason, "duplicate_cursor")
            self.assertEqual(retry.profit["actual_fx"]["deviation_usdt"], ["-2", "1"])


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--committed":
        verify_committed(json.load(sys.stdin), ["-2", "1"])
    else:
        unittest.main()
