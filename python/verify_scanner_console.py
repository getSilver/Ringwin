"""Offline scanner/Web/core acceptance. Never opens a Venue transport.

--serve-ui PATH serves the built RingwinUi against deterministic canonical input
and the real offline Zig authority probe. All state and login material are temporary.
"""
from dataclasses import fields, is_dataclass, replace
from fractions import Fraction as F
import argparse
import http.client
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time

import arbitrage_evaluation as v
import arbitrage_scanner as s
import control_plane
import control_plane_web
import owner_session
from scanner_console import ScannerConsole, CanonicalSource
from scanner_history import History
import strategy_instance
from test_arbitrage_scanner import fixture
from test_arbitrage_evaluation import T, estimator_for
from test_arbitrage_probability import calibration

ROOT = Path(__file__).resolve().parents[1]
PASSPHRASE = "scanner-offline-acceptance-only"


def canonical_fixture():
    old, plan = fixture()
    rules = tuple(replace(o.rules, instrument=101+i, version=2, base_asset=0x425443,
                          base_atoms_per_lot=F(100_000_000), tick_quote_atoms_per_base_atom=F(1, 1000))
                  for i, o in enumerate(old))
    def book(payload):
        item = s.decode_depth_snapshot(payload)
        item.update(instrument={1: 101, 2: 102}.get(item["instrument"], item["instrument"]), rules_version=2)
        return v.encode_depth_snapshot(item)
    def scenario(item):
        return replace(item, markets=tuple(replace(m, books=tuple(book(b) for b in m.books)) for m in item.markets))
    position = replace(plan.scenarios[0].entry, legs=tuple(replace(leg, account=(20, 30)[i], rules=rules[i],
        exit_fee=replace(leg.exit_fee, instrument=101+i, rules_version=2)) for i, leg in enumerate(plan.scenarios[0].entry.legs)))
    paths = tuple(scenario(replace(item, entry=position)) for item in plan.scenarios)
    observations = tuple(s.Observation((1, 21)[i], (20, 30)[i], "linear", rules[i], paths[0].markets[0].books[i], True)
                         for i in range(2))
    pair = tuple(o.identity for o in observations)
    policy = replace(plan.policy, scope=s.candidate_id(pair, 1, "taker_taker", None), base_asset=0x425443,
                     original_base=F(100_000_000))
    estimator = estimator_for(paths, policy)
    estimator = replace(estimator, rows=tuple(replace(row, scenarios=tuple(scenario(item) for item in row.scenarios)) for row in estimator.rows))
    simulation_hash = estimator.probability_model_hash(policy)
    estimator = replace(estimator, rows=tuple(replace(row, calibration=replace(row.calibration, simulation_hash=simulation_hash)) for row in estimator.rows))
    artifact = calibration(scope=v.probability_scope(policy, 8_000_000, policy.original_base, T),
        margin=F(7, 100), model_hash=policy.model_hash, simulation_hash=simulation_hash)
    return observations, replace(plan, pair=pair, policy=policy, scenarios=paths, estimator=estimator, calibration=artifact)


def browser_inputs(observations, plan, scale):
    """Retain the offline economics with human-operable, consistently scaled time.

    Rebind model/calibration identities after scaling; never extend a result's
    TTL alone or disable the browser's expiry checks.
    """
    def retime(value, field=""):
        if field.endswith("_ns") and type(value) is int:
            return value*scale
        if isinstance(value, bytes) and len(value) == 704:
            book = s.decode_depth_snapshot(value)
            return v.encode_depth_snapshot({key: retime(item, key) for key, item in book.items()})
        if is_dataclass(value):
            return replace(value, **{item.name: retime(getattr(value, item.name), item.name) for item in fields(value)})
        if isinstance(value, tuple):
            return tuple(retime(item, field) for item in value)
        return value
    observations, scaled = retime(observations), retime(plan)
    policy = replace(scaled.policy, model_hash=scaled.estimator.model_hash)
    scopes = {}
    for old, new in zip(plan.scenarios, scaled.scenarios):
        target = 8_000_000
        scopes[v.Context(old.entry, old.markets[0], target, plan.policy).scope] = v.Context(new.entry, new.markets[0], target, policy).scope
    estimator = replace(scaled.estimator, rows=tuple(replace(row, scope=scopes[row.scope],
        calibration=replace(row.calibration, scope=scopes[row.scope], model_hash=policy.model_hash)) for row in scaled.estimator.rows))
    simulation_hash = estimator.probability_model_hash(policy)
    estimator = replace(estimator, rows=tuple(replace(row, calibration=replace(row.calibration, simulation_hash=simulation_hash)) for row in estimator.rows))
    artifact = replace(scaled.calibration, model_hash=policy.model_hash, simulation_hash=simulation_hash,
        scope=v.probability_scope(policy, 8_000_000, policy.original_base, policy.at_ns))
    return observations, replace(scaled, policy=policy, estimator=estimator, calibration=artifact)


class Fixture:
    def __init__(self, directory, ui_path=None):
        self.directory = Path(directory)
        self.now = T
        self.wall_offset_ms = 0
        self.owner_offset = 0
        self.channel = control_plane.CommandServer(b"s"*32)
        key = self.directory / "offline-control.key"
        key.write_bytes(self.channel.key)
        probe = ROOT / "zig-out/bin" / ("ringwin-strategy-authority-probe" + (".exe" if os.name == "nt" else ""))
        self.process = subprocess.Popen([str(probe), str(key), "scanner"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.authority = strategy_instance.NativeAuthority(self.process, timeout=30)
        self.authority.request(dict(operation="status", strategy_identity=f"{9:032x}"))
        self.drop_next_pair_ack = False
        request = self.authority.request
        def transport(value):
            result = request(value)
            if value["operation"] == "pair_authorize" and self.drop_next_pair_ack:
                self.drop_next_pair_ack = False
                raise TimeoutError("offline injected lost core acknowledgement")
            return result
        self.authority.request = transport
        observations, self.plan = canonical_fixture()
        self.time_scale = 10_000_000_000 if ui_path else 1
        if ui_path:
            observations, self.plan = browser_inputs(observations, self.plan, self.time_scale)
            self.now *= self.time_scale
        self.observations = observations
        self.source = CanonicalSource(observations, assets=(dict(identity="1", code="USDT", atomic_scale=6),
                                                          dict(identity=str(0x425443), code="BTC", atomic_scale=8)))
        self.console = self.new_console()
        self.app = control_plane_web.ControlPlaneApp(directory, self.channel, scanner_console=self.console, ui_path=ui_path,
            clock=lambda: int(time.time())+self.owner_offset)
        self.app.setup(PASSPHRASE)
        self.server = control_plane_web.serve(self.app)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.closing = threading.Event()
        self.publisher = threading.Thread(target=self._publish, daemon=True)
        self.publisher.start()

    def wall_clock(self):
        return time.time_ns()//1_000_000+self.wall_offset_ms

    def new_console(self):
        return ScannerConsole(self.source, History(clock=self.wall_clock), clock=lambda: self.now,
            wall_clock=self.wall_clock, authority=self.authority, max_age_ns=1000*self.time_scale,
            max_skew_ns=10*self.time_scale, config_path=self.directory/"scanner-config.json",
            trading_bindings=(dict(strategy_identity="9", portfolio_identity="10", activation="1", config_version="1"),))

    def restart_console(self):
        self.console.close()
        self.console = self.new_console()
        self.app.scanner_console = self.console

    def _publish(self):
        while not self.closing.wait(.02):
            console = self.console
            with console.lock:
                if console is self.console and console.desired == "running" and console.cursor == 0:
                    self.source.deliver(self.observations, (self.plan,), cursor=1, at_ns=T*self.time_scale)

    def call(self, operation, payload=None, headers=None):
        body = dict(operation=operation)
        if payload is not None:
            body["payload"] = payload
        client = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=35)
        client.request("POST", "/api/scanner", json.dumps(body), headers=headers or self.headers)
        response = client.getresponse()
        result = response.status, json.loads(response.read())
        client.close()
        return result

    def login(self):
        status, body = self.app.login(PASSPHRASE, owner_session.totp_at(self.app.totp.read_secret(), self.app.clock()), "offline-fixture")
        assert status == 200, body
        self.headers = {"Cookie": "owner_session=" + body["session_token"], "X-Owner-CSRF": body["csrf_token"]}
        return body

    def close(self):
        self.closing.set()
        self.publisher.join(timeout=2)
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.console.close()
        self.channel.close()
        self.process.kill()
        self.process.wait(timeout=5)
        self.authority.pipes.close()


def verify(fixture):
    fixture.login()
    scopes = [dict(venue=str(o.venue), product=o.kind, environment=o.environment, include_assets=[], exclude_assets=[],
                   quote_asset="1", min_depth_atoms="0", max_depth_atoms=None, new_instruments=False) for o in fixture.observations]
    status, result = fixture.call("configure", dict(expected_version="0", scopes=scopes))
    assert status == 200, result
    assert fixture.call("start")[0] == 200
    deadline = time.monotonic()+10
    while fixture.console.cursor == 0 and time.monotonic() < deadline:
        time.sleep(.02)
    state = fixture.console.view()
    candidate = next(row for row in state["snapshot"]["candidates"] if row["recommended"])
    request = dict(identity="16001", candidate_id=candidate["id"], strategy_identity="9", portfolio_identity="10",
                   expected_config_version="1", expected_core_version="0", enabled=True)
    status, response = fixture.call("approve", request)
    assert status == 200 and response["result"]["status"] == "accepted", response
    assert response["result"]["core_version"] == "1" and response["result"]["barrier"], response
    assert fixture.call("approve", request)[1] == response
    forged = dict(request, identity="16002", portfolio_identity="99")
    assert fixture.call("approve", forged)[0] == 400
    conflict = dict(request, identity="16003", expected_core_version="0")
    assert fixture.call("approve", conflict)[1]["result"]["status"] == "rejected"
    revoke = dict(request, identity="16004", expected_core_version="1", enabled=False)
    assert fixture.call("approve", revoke)[1]["result"]["status"] == "accepted"
    fixture.drop_next_pair_ack = True
    lost = dict(request, identity="16005", expected_core_version="2")
    assert fixture.call("approve", lost)[1]["result"]["status"] == "unknown"
    confirmed = fixture.call("approval_status", "16005")[1]["result"]
    assert confirmed["status"] == "accepted" and confirmed["core_version"] == "3", confirmed
    fixture.call("stop")
    assert fixture.console.view()["snapshot"]["candidates"] == []
    assert fixture.call("approval_status", "16001")[1]["result"]["status"] == "accepted"
    assert fixture.console.history.query("events")
    assert not (fixture.directory / "scanner.sqlite").exists()
    print("scanner_web_core_offline=passed; authority=actual_Zig; real_market=not_run; trading=false", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serve-ui")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="ringwin-scanner-16-") as directory:
        fixture = Fixture(directory, args.serve_ui)
        try:
            if args.serve_ui:
                print(json.dumps(dict(port=fixture.server.server_port, passphrase=PASSPHRASE,
                    totp=owner_session.totp_at(fixture.app.totp.read_secret(), fixture.app.clock()))), flush=True)
                import sys
                for line in sys.stdin:
                    if line.strip() == "expire":
                        fixture.now = (T+1001)*fixture.time_scale
                    elif line.strip() == "reset":
                        fixture.now = T*fixture.time_scale
                    elif line.strip() == "advance_day":
                        fixture.wall_offset_ms += 86_400_001
                    elif line.strip() == "restart_console":
                        fixture.restart_console()
                    elif line.strip() == "login_code":
                        fixture.owner_offset += owner_session.TOTP_STEP
                        print(json.dumps(dict(totp=owner_session.totp_at(fixture.app.totp.read_secret(), fixture.app.clock()))), flush=True)
                    elif line.strip() == "drop_next_pair_ack":
                        fixture.drop_next_pair_ack = True
                    elif line.strip() == "quit":
                        break
            else:
                verify(fixture)
        finally:
            fixture.close()


if __name__ == "__main__":
    main()
