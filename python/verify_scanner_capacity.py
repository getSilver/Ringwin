"""Offline scanner throughput with production request pacing and native capture."""
import argparse
from collections import Counter
import io
import json
import math
from pathlib import Path
from statistics import median
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlsplit
from unittest.mock import patch

from opportunity_scanner.scanner_runtime import NativeScannerAdapter, PublicTransport, ScannerRuntime
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
        self.first_book_request_ns = {}
        self.responses = Counter()
        self.metadata = Counter()
        self.worker = threading.local()
        self.opened = set()
        self.warmups = {}
        self.lock = threading.Lock()

    def open(self, request, timeout):
        url = request.full_url
        body = json.loads(request.data) if request.data else {}
        query = parse_qs(urlsplit(url).query)
        operation = body["type"] if body else urlsplit(url).path.rsplit("/", 1)[1]
        venue = "hyperliquid" if body else "okx"
        with self.lock:
            self.requests[venue + "." + operation] += 1
            if operation == "books":
                self.first_book_request_ns.setdefault(("okx", query["instId"][0]), time.monotonic_ns())
            elif operation == "l2Book":
                self.first_book_request_ns.setdefault(("hyperliquid", body["coin"]), time.monotonic_ns())
            if operation in ("meta", "instruments"):
                stage = getattr(self.worker, "stage", "catalogue")
                self.metadata[venue, stage] += 1
        if body:
            if operation == "allMids":
                payload = dict.fromkeys(self.coins, "3000")
            elif operation == "meta":
                payload = json.loads(self.hl.request(url, body))
                payload["universe"] = [dict(payload["universe"][0], name=coin) for coin in self.coins]
            else:
                payload = json.loads(self.hl.request(url, dict(body, coin="ETH")))
                payload["coin"] = body["coin"]
        else:
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
            self.responses[200] += 1
        return io.BytesIO(json.dumps(payload).encode())

    def registry(self):
        registry = registered_assets()
        for venue in ("1", "21"):
            row = next(r for r in registry["bindings"] if r["venue"] == venue)
            registry["bindings"].extend(dict(row, asset=str(i), code=coin)
                                        for i, coin in enumerate(self.coins, 100))
        return registry

    def measurement(self, initial_metadata, initial_requests):
        with self.lock:
            requests = self.requests - initial_requests
            metadata = {
                venue: dict(initial_catalogue=initial_metadata[venue, "catalogue"],
                            catalogue_refresh=self.metadata[venue, "catalogue"] - initial_metadata[venue, "catalogue"],
                            worker_warmup=self.metadata[venue, "warmup"], worker_refresh=self.metadata[venue, "refresh"])
                for venue in ("okx", "hyperliquid")
            }
            warmups = {
                venue: {kind: warmup_summary(self.warmups.get((venue, kind), ()))
                        for kind in ("first_open", "reopen")}
                for venue in (1, 21)
            }
            return requests, metadata, warmups, self.responses[429]

    def first_route_waits(self, started_ns):
        waits = []
        with self.lock:
            for coin in self.coins:
                okx = self.first_book_request_ns.get(("okx", coin+"-USDT"))
                hl = self.first_book_request_ns.get(("hyperliquid", coin))
                if okx is not None and hl is not None:
                    waits.append(max(okx, hl) - started_ns)
        return waits


def warmup_summary(attempts):
    durations = [attempt[0] for attempt in attempts if attempt]
    return dict(started=len(attempts), subscribed=len(durations),
                mean_ms=sum(durations) / len(durations) if durations else None,
                median_ms=median(durations) if durations else None,
                min_ms=min(durations, default=None), max_ms=max(durations, default=None))


class MeasuredScannerRuntime(ScannerRuntime):
    def __init__(self, root, fixture, transport, *, automatic=False):
        self.fixture = fixture
        self.latest_pair = {}
        self.pair_skews = []
        self.retry_count = 0
        super().__init__(root, transport=transport, asset_provider=fixture.registry, automatic=automatic)

    def _schedule_samples(self, **kwargs):
        if self.thread is None:
            return super()._schedule_samples(**kwargs)
        with self.console.lock, self.source.lock, self.lock:
            retries = self.skew_retried.copy()
            futures = super()._schedule_samples(**kwargs)
            self.retry_count += len(self.skew_retried - retries)
            return futures

    def _coverage(self, now, *, advance=False):
        metrics, routes = super()._coverage(now, advance=advance)
        if advance and self.thread is not None:
            for pair, _, _, books in routes:
                if books is None:
                    continue
                a, z = books
                previous_a, previous_z = self.latest_pair.get(pair, (0, 0))
                if a > previous_a and z > previous_z:
                    self.latest_pair[pair] = books
                    self.pair_skews.append(abs(a-z))
        return metrics, routes

    def _warm(self, identity, row, worker):
        self.fixture.worker.stage = "refresh"
        try:
            return super()._warm(identity, row, worker)
        finally:
            del self.fixture.worker.stage

    def _open(self, identity, *, row=None, discovery=False):
        if not discovery:
            fixture = self.fixture
            with fixture.lock:
                kind = "reopen" if identity in fixture.opened else "first_open"
                fixture.opened.add(identity)
                attempt = []
                fixture.warmups.setdefault((identity[0], kind), []).append(attempt)
                fixture.worker.attempt = attempt
                fixture.worker.started_ns = time.monotonic_ns()
                fixture.worker.stage = "warmup"
        return super()._open(identity, row=row, discovery=discovery)

    def _input(self, worker, operation, payload):
        result = super()._input(worker, operation, payload)
        if operation == "subscribe" and not result["failure"]:
            fixture = self.fixture
            with fixture.lock:
                fixture.worker.attempt.append((time.monotonic_ns() - fixture.worker.started_ns) / 1e6)
                fixture.worker.stage = "refresh"
        return result


def bytes_on_disk(directory):
    return sum(path.stat().st_size for path in directory.rglob("*") if path.is_file())


def percentiles_ms(samples):
    ordered = sorted(samples)
    return {str(p): ordered[math.ceil(p*len(ordered)/100)-1]/1e6 if ordered else None for p in (95, 99)}


def measure(selected, max_seconds, target_rounds, worker_executable=None, *, automatic=False):
    fixture = MarketFixture(selected // 2)
    transport = PublicTransport()
    transport.input_kind = "synthetic_protocol_fixture"
    transport.supports_batch_quotes = True
    with (tempfile.TemporaryDirectory() as root, patch("urllib.request.build_opener", return_value=fixture),
          patch.object(NativeScannerAdapter, "executable", worker_executable or NativeScannerAdapter.executable)):
        runtime = MeasuredScannerRuntime(root, fixture, transport, automatic=automatic)
        directory = Path(root)
        try:
            for venue, kind in ((1, "okx"), (21, "hyperliquid")):
                runtime.discover(dict(identity=str(venue).zfill(32), venue=str(venue), type=kind,
                                      environment="production", name=kind))
            runtime.console.configure(dict(expected_version="0", scopes=[scope(1), scope(21)]))
            before_bytes = bytes_on_disk(directory)
            initial_metadata = fixture.metadata.copy()
            before_requests, before_429 = fixture.requests.copy(), fixture.responses[429]
            started_ns = time.monotonic_ns()
            started = started_ns / 1e9
            runtime.console.start()
            next_sample = started + .5
            skipped_samples = 0
            max_sample_lag_ms = 0
            rounds, skews, coverage_samples, active_samples, backlog_samples = [], [], [], [], []
            last_samples = {}
            while True:
                cycle = time.monotonic()
                if automatic:
                    time.sleep(max(0, next_sample - cycle))
                else:
                    runtime.step(blocking=False)
                with runtime.poll_lock:
                    status = runtime.status()
                    if automatic:
                        max_sample_lag_ms = max(max_sample_lag_ms, (time.monotonic()-next_sample)*1000)
                        skews = runtime.pair_skews.copy()
                        retries = runtime.retry_count
                if status["capture_storage"]["faults"]:
                    raise ValueError(status["capture_storage"]["faults"])
                coverage = status["coverage"]
                if coverage["selected"] != selected or coverage["discovered"] != selected // 2:
                    raise ValueError("unexpected selection or route count")
                coverage_samples.append(coverage["fresh"] / coverage["discovered"])
                active_samples.append(status["active_subscriptions"])
                backlog_samples.append(coverage["backlog"])
                if not automatic:
                    for route in coverage["routes"]:
                        if route["book_times_ns"] is None:
                            continue
                        key = tuple(map(tuple, route["pair"]))
                        a, z = map(int, route["book_times_ns"])
                        before_a, before_z = last_samples.get(key, (0, 0))
                        if a > before_a and z > before_z:
                            last_samples[key] = a, z
                            skews.append(abs(a-z))
                if coverage["completed_rounds"] > len(rounds):
                    rounds.append(int(coverage["full_round_ns"]) / 1e9)
                if len(rounds) >= target_rounds or time.monotonic() - started >= max_seconds:
                    requests, metadata, warmups, http_429 = fixture.measurement(initial_metadata, before_requests)
                    if automatic:
                        waits = fixture.first_route_waits(started_ns)
                    break
                if automatic:
                    next_sample += .5
                    now = time.monotonic()
                    if now >= next_sample:
                        missed = int((now-next_sample)/.5)+1
                        next_sample += missed*.5
                        skipped_samples += missed
                else:
                    time.sleep(max(0, .5 - (time.monotonic() - cycle)))
        finally:
            runtime.close()
        elapsed = time.monotonic() - started
        growth = bytes_on_disk(directory) - before_bytes
        automatic_metrics = (dict(route_wait_samples=len(waits), route_wait_ms=percentiles_ms(waits),
                                  skew_retries=retries, skew_over_1s=sum(skew > 1e9 for skew in skews),
                                  coverage_samples=len(coverage_samples), coverage_skipped_samples=skipped_samples,
                                  coverage_max_sample_lag_ms=round(max_sample_lag_ms, 1),
                                  incomplete_target_rounds=target_rounds-len(rounds)) if automatic else {})
        return dict(selected=selected, discovered_routes=coverage["discovered"], elapsed_s=elapsed, full_round_s=rounds,
            skew_samples=len(skews), skew_ms=percentiles_ms(skews),
            coverage_mean=sum(coverage_samples)/len(coverage_samples), coverage_peak=max(coverage_samples),
            max_active=max(active_samples), final_backlog=backlog_samples[-1],
            requests=dict(requests), request_count=sum(requests.values()),
            metadata_requests=metadata, worker_warmup=warmups, http_429=http_429-before_429,
            bytes_added=growth, bytes_per_day=int(growth / elapsed * 86400), **automatic_metrics)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=float, default=150)
    parser.add_argument("--rounds", type=int, default=2)
    parser.add_argument("--selected", nargs="+", type=int, choices=(16, 64, 256), default=(16, 64, 256))
    parser.add_argument("--worker", type=lambda path: Path(path).resolve(strict=True))
    parser.add_argument("--automatic", action="store_true", help="Use the service loop and measure paired dispatches")
    args = parser.parse_args()
    for selected in args.selected:
        print(json.dumps(measure(selected, args.seconds, args.rounds, args.worker, automatic=args.automatic)), flush=True)
