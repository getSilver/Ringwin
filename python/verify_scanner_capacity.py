"""Offline scanner throughput with production request pacing and native capture."""
import argparse
from collections import Counter
import io
import json
import math
from pathlib import Path
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlsplit
from unittest.mock import patch

from opportunity_scanner.scanner_runtime import PublicTransport, ScannerRuntime
from test_scanner_integration import DynamicHyperliquidTransport, DynamicOkxTransport, registered_assets, scope


class Clock:
    def __getitem__(self, index):
        return time.monotonic_ns() if index == 0 else time.time_ns()


class MarketFixture:
    def __init__(self, count):
        self.coins = [f"TOKEN{i}" for i in range(count)]
        self.okx = DynamicOkxTransport(Clock())
        self.hl = DynamicHyperliquidTransport(Clock())
        self.requests = Counter()
        self.responses = Counter()
        self.lock = threading.Lock()

    def open(self, request, timeout):
        url = request.full_url
        body = json.loads(request.data) if request.data else {}
        query = parse_qs(urlsplit(url).query)
        if body:
            operation = body["type"]
            if operation == "allMids":
                payload = dict.fromkeys(self.coins, "3000")
            elif operation == "meta":
                payload = json.loads(self.hl.request(url, body))
                payload["universe"] = [dict(payload["universe"][0], name=coin) for coin in self.coins]
            else:
                payload = json.loads(self.hl.request(url, dict(body, coin="ETH")))
                payload["coin"] = body["coin"]
        else:
            operation = urlsplit(url).path.rsplit("/", 1)[1]
            if operation == "tickers":
                payload = dict(code="0", data=[dict(instId=coin+"-USDT", bidPx="3000", askPx="3001")
                                                for coin in self.coins])
            else:
                payload = json.loads(self.okx.request(url))
                if operation == "instruments":
                    symbol = query.get("instId", [""])[0]
                    template = json.dumps(payload["data"][0])
                    payload["data"] = [json.loads(template.replace("ETH", coin)) for coin in self.coins
                                       if not symbol or symbol.split("-")[0] == coin]
        with self.lock:
            self.requests[("hyperliquid." if body else "okx.") + operation] += 1
            self.responses[200] += 1
        return io.BytesIO(json.dumps(payload).encode())

    def registry(self):
        registry = registered_assets()
        for venue in ("1", "21"):
            row = next(r for r in registry["bindings"] if r["venue"] == venue)
            registry["bindings"].extend(dict(row, asset=str(i), code=coin)
                                        for i, coin in enumerate(self.coins, 100))
        return registry


def bytes_on_disk(directory):
    return sum(path.stat().st_size for path in directory.rglob("*") if path.is_file())


def measure(selected, max_seconds, target_rounds):
    fixture = MarketFixture(selected // 2)
    transport = PublicTransport()
    transport.input_kind = "synthetic_protocol_fixture"
    transport.supports_batch_quotes = True
    with tempfile.TemporaryDirectory() as root, patch("urllib.request.build_opener", return_value=fixture):
        runtime = ScannerRuntime(root, transport=transport, asset_provider=fixture.registry, automatic=False)
        directory = Path(root)
        try:
            for venue, kind in ((1, "okx"), (21, "hyperliquid")):
                runtime.discover(dict(identity=str(venue).zfill(32), venue=str(venue), type=kind,
                                      environment="production", name=kind))
            runtime.console.configure(dict(expected_version="0", scopes=[scope(1), scope(21)]))
            before_bytes = bytes_on_disk(directory)
            before_requests, before_429 = fixture.requests.copy(), fixture.responses[429]
            runtime.console.start()
            started = time.monotonic()
            rounds, skews, coverage_samples, active_samples, backlog_samples = [], [], [], [], []
            last_samples = {}
            while True:
                cycle = time.monotonic()
                runtime.step(blocking=False)
                status = runtime.status()
                if status["capture_storage"]["faults"]:
                    raise ValueError(status["capture_storage"]["faults"])
                coverage = status["coverage"]
                if coverage["selected"] != selected or coverage["discovered"] != selected // 2:
                    raise ValueError("unexpected selection or route count")
                coverage_samples.append(coverage["fresh"] / coverage["discovered"])
                active_samples.append(status["active_subscriptions"])
                backlog_samples.append(coverage["backlog"])
                for route in coverage["routes"]:
                    key = tuple(map(tuple, route["pair"]))
                    if route["book_times_ns"] is None:
                        continue
                    a, z = map(int, route["book_times_ns"])
                    before_a, before_z = last_samples.get(key, (0, 0))
                    if a > before_a and z > before_z:
                        last_samples[key] = a, z
                        skews.append(abs(a-z))
                if coverage["completed_rounds"] > len(rounds):
                    rounds.append(int(coverage["full_round_ns"]) / 1e9)
                if len(rounds) >= target_rounds or time.monotonic() - started >= max_seconds:
                    break
                time.sleep(max(0, .5 - (time.monotonic() - cycle)))
        finally:
            runtime.close()
        elapsed = time.monotonic() - started
        growth = bytes_on_disk(directory) - before_bytes
        requests = fixture.requests - before_requests
        skews.sort()
        return dict(selected=selected, elapsed_s=elapsed, full_round_s=rounds,
            skew_samples=len(skews), skew_ms={str(p): skews[math.ceil(p*len(skews)/100)-1]/1e6
                                            if skews else None for p in (95, 99)},
            coverage_mean=sum(coverage_samples)/len(coverage_samples), coverage_peak=max(coverage_samples),
            max_active=max(active_samples), final_backlog=backlog_samples[-1],
            requests=dict(requests), request_count=sum(requests.values()),
            http_429=fixture.responses[429]-before_429, bytes_added=growth, bytes_per_day=int(growth / elapsed * 86400))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=float, default=150)
    parser.add_argument("--rounds", type=int, default=2)
    parser.add_argument("--selected", nargs="+", type=int, choices=(16, 64, 256), default=(16, 64, 256))
    args = parser.parse_args()
    for selected in args.selected:
        print(json.dumps(measure(selected, args.seconds, args.rounds)), flush=True)
