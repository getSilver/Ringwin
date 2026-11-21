"""Exercise Web, Venue recovery and StrategyHost against one formal Writer."""
from contextlib import contextmanager
from dataclasses import replace
import hashlib
import json
import os
from pathlib import Path
import secrets
import select
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace

import owner_session
import strategy_host
import strategy_package
from venue_recovery import recover_market_inputs
from verify_production_strategy_web import child, receive, relay_strategy_reads, request
from verify_production_venue_recovery import read_committed, role


def approve_dual_ioc(state):
    import control_plane
    import control_plane_node
    import control_plane_web
    from opportunity_scanner.scanner_console import CanonicalSource, History, ScannerConsole
    from test_arbitrage_evaluation import T
    from verify_scanner_console import canonical_fixture

    observations, plan = canonical_fixture(environments=("simulation", "simulation"), mixed_stablecoins=True)

    class WriterPipe:
        def recv(self, size):
            return sys.stdin.buffer.read(size)

        def sendall(self, data):
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()

    frontend, relay = socket.socketpair()
    with frontend, relay:
        worker = threading.Thread(target=relay_strategy_reads, args=(relay, WriterPipe()),
                                  kwargs={"pair_approval": True}, daemon=True)
        worker.start()
        console = ScannerConsole(CanonicalSource(observations), History(clock=lambda: 1000), clock=lambda: T)
        commands = control_plane.CommandServer(b"offline" * 8)
        try:
            adapters = tuple(SimpleNamespace(settings=lambda venue=venue: dict(
                type=f"fixture-{venue}", label=f"Fixture {venue}", venue=str(venue),
                environments=["simulation"], products=["linear"])) for venue in (1, 21))
            app = control_plane_web.ControlPlaneApp(str(state), commands, scanner_console=console,
                scanner_adapters=adapters, engine_strategy_authority=control_plane_node.EngineStrategyAuthority(frontend))
            for version, venue in enumerate((1, 21)):
                app.exchange_settings_store.save(dict(expected_version=str(version), type=f"fixture-{venue}",
                                                      name=f"Fixture {venue}", environment="simulation"))
            rows = [dict(venue=str(venue), account=str(account), product="linear", fee_asset=str(asset),
                         maker_percent="0", taker_percent="0")
                    for venue, account, asset in ((1, 20, 1), (21, 30, 3))]
            password = secrets.token_urlsafe(24)
            assert app.setup(password)[0] == 200
            server = control_plane_web.serve(app)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                port = server.server_port
                status, login = request(port, "/login", credentials=dict(passphrase=password,
                    code=owner_session.totp_at(app.totp.read_secret(), int(time.time()))))
                assert status == 200, login
                status, saved = request(port, "/api/manual-fees", session=login,
                    credentials=dict(expected_version="0", rows=rows))
                assert status == 200, saved
                status, initial = request(port, "/api/strategy-instances", session=login)
                assert status == 200 and initial["instances"][0]["pair_trading_list"] == [], initial

                def scan(operation, payload=None):
                    credentials = {"operation": operation}
                    if payload is not None:
                        credentials["payload"] = payload
                    status, result = request(port, "/api/scanner", credentials=credentials, session=login)
                    assert status == 200, result
                    return result["result"]

                scopes = [dict(venue=str(o.venue), product=o.kind, environment=o.environment,
                    include_assets=[], exclude_assets=[], quote_asset=None, min_depth_atoms=None,
                    max_depth_atoms=None, new_instruments=False) for o in observations]
                scan("configure", dict(expected_version="0", scopes=scopes))
                session = scan("start")["session"]
                versioned_plan = replace(plan, fee_version="1")
                console.publish(session, 1, observations, (versioned_plan,), at_ns=T,
                    input_versions={plan.policy.scope: {str(plan.policy.original_base): {"fees": "1"}}})
                row, = [row for row in console.view()["snapshot"]["candidates"] if row["status"] == "evaluated"]
                receipt = scan("approve", dict(identity="98765", candidate_id=row["id"], strategy_identity="9",
                    portfolio_identity="10", expected_config_version="1", expected_core_version=None, enabled=True,
                    evaluation=dict(session=session, **{key: row[key] for key in
                        ("scenario_digest", "data_cutoff_ns", "valid_until_ns")})))
                assert receipt["status"] == "accepted", receipt
                assert [int(leg["account"], 16) for leg in receipt["pair"]["legs"]] == [20, 30], receipt
                print(f"dual_ioc_web: identity={receipt['identity']} writer_barrier={receipt['barrier']}", file=sys.stderr)
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=5)
        finally:
            console.close()
            commands.close()
            frontend.shutdown(socket.SHUT_RDWR)
            worker.join(timeout=5)


def verify_dual_ioc_fx(state):
    from fractions import Fraction
    from strategies.cross_venue.arbitrage_economics import FxRate, actual_fx_report
    from strategies.cross_venue.arbitrage_fx_archive import CycleFxArchive
    from test_arbitrage_cycle import facts

    projection = json.loads((state / "cycle-fx.json").read_text())
    first = projection["first_sequence"]
    frame = facts(cursor=projection["barrier"], at_ns=projection["closed_at_ns"],
                  cycle_ref=f"cycle:9:{first}", closed_ref="core-closure")
    archive = CycleFxArchive(state / "cycle-fx-archive.json", 9, first, max_age_ns=60_000_000_000)
    rate = FxRate(Fraction(998, 1000), min(row["at_ns"] for row in projection["flows"]), "offline fixture")
    attached = archive.capture(frame, projection, rate)
    assert attached.fx_complete, attached
    report = actual_fx_report(attached.fx_exposures)
    assert report["deviation_usdt"] == ["3", "250000000"], report
    assert archive.restore(frame).fx_exposures == attached.fx_exposures
    print("dual_ioc_fx: deviation_usdt=3/250000000", file=sys.stderr)


@contextmanager
def web(engine, core, state):
    python = Path(owner_session.__file__).resolve().parent
    state.mkdir()
    password = secrets.token_urlsafe(24)
    owner_session.PassphraseStore(str(state)).set(password)
    totp = owner_session.TotpStore(str(state)).initialize()
    frontend, controller = socket.socketpair()
    with frontend, controller:
        worker = threading.Thread(target=relay_strategy_reads, args=(controller, engine), daemon=True)
        worker.start()
        cmd = [sys.executable, str(python / "control_plane_node.py"), "--directory", str(state),
               "--core-directory", str(core), "--ui", str(python / "operator_ui.html"),
               "--port", "0", "--engine-authority-fd", str(frontend.fileno())]
        with child(cmd, stdout=subprocess.PIPE, text=True, pass_fds=(frontend.fileno(),)) as process:
            frontend.close()
            assert select.select([process.stdout], [], [], 15)[0], "Web startup timeout"
            line = process.stdout.readline().strip()
            assert line.startswith("Web control plane:"), line
            port = int(line.rsplit(":", 1)[1])
            status, login = request(port, "/login", credentials={
                "passphrase": password, "code": owner_session.totp_at(totp, int(time.time()))})
            assert status == 200, status
            yield lambda: request(port, "/api/strategy-instances", session=login)
        worker.join(timeout=5)
        assert not worker.is_alive()


def strategy_view(get_instances, expected_status):
    status, body = get_instances()
    assert status == 200, (status, body)
    instance, = body["instances"]
    assert instance["binding"]["strategy_identity"] == f"{9:032x}"
    assert instance["pair_trading_list"] == [] and instance["pair_trading_list_empty"] is True
    assert instance["trading_authorized"] is False
    assert instance["status"] == expected_status
    return instance


FIXTURE = '''
import json
import sys
from strategy_api import OrderIntent


def validate_config(config):
    assert config == b"{}"


def create(context, config):
    return Strategy()


class Strategy:
    def validate(self):
        assert self.next_intent_sequence >= 7

    def restore(self, state):
        saved = json.loads(state)
        self.next_intent_sequence = saved["next"]

    def snapshot(self):
        return json.dumps({"next": self.next_intent_sequence}, separators=(",", ":")).encode()

    def on_event(self, event):
        assert event.event_type == 7 and event.payload_bytes
        print(f"acceptance_strategy_event={event.sequence}", file=sys.stderr, flush=True)
        sequence = self.next_intent_sequence
        self.next_intent_sequence += 1
        return (OrderIntent(sequence, 10, 20, 101, "buy", "ioc", False, 1, 100),)
'''

DUAL_IOC = '''
import json
from dataclasses import replace
from strategy_host import decode_market_trade
from strategies.cross_venue.arbitrage_cycle import Action, Cycle, Intent
from test_arbitrage_cycle import with_price_units
from test_strategy_cycle_recovery import CORE_UTC, core_plan


def validate_config(config):
    assert config == b"{}"


def create(context, config):
    return Strategy()


class Strategy:
    def validate(self):
        assert self.next_intent_sequence >= 7

    def restore(self, state):
        saved = json.loads(state)
        self.next_intent_sequence = saved["next"]
        self.step = saved.get("step", 0)

    def snapshot(self):
        return json.dumps({"next": self.next_intent_sequence, "step": self.step}, separators=(",", ":")).encode()

    def on_event(self, event):
        assert event.event_type == 8
        self.step += 1
        trigger = decode_market_trade(event.payload_bytes)["trade_identity"]
        reducing = trigger == 4
        assert self.step == (2 if reducing else 1), "fee rejection advanced private state"
        plan = core_plan()
        legs = tuple(replace(leg, rules=replace(leg.rules, version=2)) for leg in plan.legs)
        plan = replace(plan, legs=legs, first_sequence=self.next_intent_sequence, entry_limits=(100, 100))
        if reducing:
            action = Action(plan, event.sequence, "fixture_exit",
                tuple(Intent(self.next_intent_sequence + index, index, 10_000, 100, True)
                      for index in range(2)))
        else:
            action = Cycle(plan).start(cursor=event.sequence, at_ns=CORE_UTC)
        self.next_intent_sequence += len(action.intents)
        return (with_price_units(action, base_scale=4).package_output(fee_version=None if reducing else str(trigger)),)
'''


def configure_host(core, root, cursor, *, bad_ack=False, dual_ioc=False):
    runtime = Path(strategy_host.__file__).resolve().parent
    package_root = root / "package"
    code = package_root / "code"
    code.mkdir(parents=True, exist_ok=True)
    (code / "acceptance_strategy.py").write_text(DUAL_IOC if dual_ioc else FIXTURE)
    state_schema = f"{61:032x}"
    request_file = root / "host-request.json"
    checkpoint_path = root / "checkpoint.bin"
    checkpoint = strategy_host.encode_payload_checkpoint(dict(
        schema_registry=strategy_host.SCHEMA_REGISTRY, strategy=9, definition=42, state_schema=61,
        state_schema_version=1, config_version=1, cursor=cursor, next_intent=7), b'{"next":7}')
    checkpoint_path.write_bytes(checkpoint)
    binding = dict(strategy_identity=f"{9:032x}", definition_identity=f"{42:032x}",
                   decision_domain=f"{1:032x}", portfolio_identity=f"{10:032x}", config_version=1,
                   package_manifest_sha256="cc" * 32, config_json="{}",
                   config_sha256=hashlib.sha256(b"{}").hexdigest(),
                   scopes=[dict(exchange_account=f"{20:032x}", instrument=f"{101:032x}")])
    if dual_ioc:
        binding["scopes"].append(dict(exchange_account=f"{30:032x}", instrument=f"{102:032x}"))
    manifest = dict(entrypoint="acceptance_strategy:create",
                    compatibility=dict(python_abi=strategy_host.PYTHON_ABI,
                                       host_build=f"{strategy_host.HOST_BUILD:032x}",
                                       schema_registry=f"{strategy_host.SCHEMA_REGISTRY:032x}",
                                       host_protocol=strategy_host.PROTOCOL),
                    state_schema=dict(identity=state_schema, version=1),
                    subscriptions=[dict(event_type=7, schema_version=1)], output_kinds=["order_intent"],
                    limits=dict(max_private_state_bytes=2048, max_input_record_bytes=16384,
                                max_output_frame_bytes=512, max_output_frames_per_event=1,
                                max_warmup_events=100))
    if dual_ioc:
        manifest.update(subscriptions=[dict(event_type=8, schema_version=1)], output_kinds=["intent_group"])
        checkpoint = strategy_host.encode_payload_checkpoint(dict(
            schema_registry=strategy_host.SCHEMA_REGISTRY, strategy=9, definition=42, state_schema=61,
            state_schema_version=1, config_version=1, cursor=cursor, next_intent=7), b'{"next":7,"step":0}')
        checkpoint_path.write_bytes(checkpoint)
    spec = dict(binding=binding, manifest=manifest, package_root=str(package_root), recover=True,
                checkpoint_cursor=cursor, checkpoint=dict(cursor=cursor, sha256=hashlib.sha256(checkpoint).hexdigest()))
    spec["strategy_manifest"], spec["checkpoint_manifest"] = strategy_package.host_manifests([spec])
    request_file.write_bytes(strategy_package.canonical(spec))
    script = runtime / "strategy_candidate_host.py"
    if bad_ack:
        script = root / "bad_ack.py"
        script.write_text(f'''import struct, sys
sys.path.insert(0, {str(runtime)!r})
import strategy_candidate_host as host
read_frame = host.bridge.read_frame
write_frame = host.bridge.write_frame
activating = False

def read(*args):
    global activating
    frame = read_frame(*args)
    activating |= frame[0] == host.bridge.ACTIVATE_STRATEGY
    return frame

def write(stream, kind, session, sequence, payload=b""):
    if activating and kind == host.bridge.HOST_HEARTBEAT:
        cursor, outputs = struct.unpack("<QQ", payload)
        payload = struct.pack("<QQ", cursor - 1, outputs)
    return write_frame(stream, kind, session, sequence, payload)

host.bridge.read_frame = read
host.bridge.write_frame = write
host.run(sys.argv[3], tuple(map(int, sys.argv[5:])))
''')
    config_path = core / "engine.json"
    config = json.loads(config_path.read_text())
    config["strategy_host"] = dict(python=sys.executable, script=str(script), request=str(request_file),
                                   checkpoint=str(checkpoint_path), checkpoint_sha256=hashlib.sha256(checkpoint).hexdigest())
    if dual_ioc:
        from opportunity_scanner.fee_schedules import FeeSchedules
        path = root / "manual-fees.json"
        config["strategy_host"]["manual_fees"] = str(path)
        fees = FeeSchedules(path)
        rows = [dict(account=str(account), venue=str(venue), product="linear", fee_asset=str(asset),
                     maker_percent="0", taker_percent="0")
                for account, venue, asset in ((20, 1, 1), (30, 21, 3))]
        assert fees.view() == dict(version="1", rows=rows), fees.view()
        shutil.copyfile(path, root / "fees-1.json")
        for index, revision in enumerate((rows[:1], rows), 1):
            fees.save(dict(expected_version=str(index), rows=revision))
            shutil.copyfile(path, root / f"fees-{index + 1}.json")
        shutil.copyfile(root / "fees-1.json", path)
    config_path.write_bytes(strategy_package.canonical(config))


@contextmanager
def logged_role(binary, core, control, path):
    try:
        with path.open("w") as log, role(binary, "engine", core, control, stderr=log) as pair:
            try:
                yield pair
            except EOFError:
                print(f"engine exited with {pair[0].wait(timeout=15)}", file=sys.stderr)
                raise
    except BaseException:
        print(path.read_text(), file=sys.stderr)
        raise


def capture_host_log(path, expected, *, invalid=False):
    result = path.read_text()
    assert expected in result, result
    assert ("InvalidBatchAck" in result) is invalid, result
    if invalid:
        assert "strategy_host_activation:" not in result, result
    print(result.strip())


def ingest_live_capture(binary, provision, feed, feed_socket, engine, activation):
    subprocess.run([provision, "--append-capture", str(feed)], check=True, timeout=30)
    with role(binary, "market_feed", feed, feed_socket) as (_, market):
        market.sendall(b"U")
        assert struct.unpack("<QQQQ", receive(market, 32)) == (3, 1, 77, 9000)
        frames = []
        while True:
            size, = struct.unpack("<I", receive(market, 4))
            if not size:
                break
            assert size < 16 * 1024, size
            frames.append(receive(market, size))
        cursor = activation
        assert len(frames) > 3
        for frame in frames[3:]:
            engine.sendall(b"I" + struct.pack("<I", len(frame)) + frame)
            committed, extra = struct.unpack("<QI", receive(engine, 12))
            assert extra == 0 and committed >= cursor
            cursor = committed
        assert cursor > activation
        barrier, records = read_committed(engine, activation)
        assert barrier == cursor
        inputs = [record for record in records if record[4] & 1]
        assert any(record[41] == 2 for record in inputs), inputs
        assert any(record[41] != 2 for record in inputs), "live Host output never reached the Writer"
        return barrier


def main(binary, provision):
    with tempfile.TemporaryDirectory(prefix="rw07-chain-") as directory:
        state = Path(directory)
        core, feed = state / "core", state / "feed"
        for path in (core, feed):
            path.mkdir()
        engine_socket, feed_socket = state / "engine.sock", state / "market.sock"
        setup = subprocess.run([provision, str(core), "--with-recovery"],
                               stderr=subprocess.PIPE, text=True, check=True, timeout=30)
        start = int(setup.stderr.strip().split("=")[-1])
        configure_host(core, state, start)
        with role(binary, "engine", core, engine_socket) as (process, engine):
            assert read_committed(engine, start) == (start, [])
            with web(engine, core, state / "web-before") as get_instances:
                strategy_view(get_instances, "Stopped")
                subprocess.run([provision, "--capture", str(feed)], check=True, timeout=30)
                assert read_committed(engine, start) == (start, [])
                process.kill()
                process.wait(timeout=15)
                assert get_instances()[0] == 503

        with role(binary, "market_feed", feed, feed_socket) as (market_process, market):
            accepted = state / "accepted.log"
            with logged_role(binary, core, engine_socket, accepted) as (process, engine):
                assert recover_market_inputs(engine, market) == (2, b"R")
                committed, records = read_committed(engine, start)
                assert committed == start + 4, (committed, start)
                assert len([record for record in records if record[4] & 1 and record[41] == 2]) == 3
                with web(engine, core, state / "web-after") as get_instances:
                    strategy_view(get_instances, "Ready")
                process.kill()
                process.wait(timeout=15)
            capture_host_log(accepted, f"generation=2 committed={committed} ack={committed} outputs_before_ack=0")
            assert f"checkpoint={start} replay_through={committed - 1} subscribed_events=1 next_intent=8" in accepted.read_text()

            configure_host(core, state, start, bad_ack=True)
            failed = state / "failed.log"
            with logged_role(binary, core, engine_socket, failed) as (process, engine):
                try:
                    recover_market_inputs(engine, market)
                except EOFError:
                    assert process.wait(timeout=15) != 0
                else:
                    raise AssertionError("engine accepted a stale activation receipt")
            capture_host_log(failed, "InvalidBatchAck", invalid=True)

            configure_host(core, state, start)
            rebuilt = state / "rebuilt.log"
            with logged_role(binary, core, engine_socket, rebuilt) as (process, engine):
                barrier, prefix = read_committed(engine, start)
                assert prefix[:len(records)] == records
                # Startup revoked generation 2. Generation 3 committed an
                # activation and revoked it when its acknowledgment failed.
                assert barrier == committed + 3, (barrier, committed)
                assert recover_market_inputs(engine, market) == (2, b"R")
                assert read_committed(engine, barrier)[0] == barrier + 1
                with web(engine, core, state / "web-rebuilt") as get_instances:
                    strategy_view(get_instances, "Ready")
                # Release the market role lock before appending to its test store.
                market.close()
                market_process.kill()
                market_process.wait(timeout=15)
                live_barrier = ingest_live_capture(binary, provision, feed, feed_socket, engine, barrier + 1)
                engine.sendall(b"D")
                assert receive(engine, 1) == b"G"
                with web(engine, core, state / "web-drained") as get_instances:
                    strategy_view(get_instances, "Stopped")
                engine.sendall(b"S")
                assert receive(engine, 1) == b"T"
                assert process.wait(timeout=15) == 0
            capture_host_log(rebuilt, f"generation=4 committed={barrier + 1} ack={barrier + 1} outputs_before_ack=0")
            assert any(f"acceptance_strategy_event={sequence}\n" in rebuilt.read_text()
                       for sequence in range(barrier + 2, live_barrier + 1))
        print(f"formal_strategy_chain: checkpoint={start} recovery_raw=2 recovery_canonical=3 first_host_ack={committed} "
              f"rebuilt_host_ack={barrier + 1} live_writer={live_barrier} stale_ack=rejected writer_prefix=identical web=empty disconnect=503")


if __name__ == "__main__":
    if sys.argv[1:2] == ["--approve-dual-ioc"]:
        approve_dual_ioc(Path(sys.argv[2]))
    elif sys.argv[1:2] == ["--prepare-dual-ioc"]:
        state = Path(sys.argv[2]).resolve()
        configure_host(state, state, int(sys.argv[3]), dual_ioc=True)
    elif sys.argv[1:2] == ["--verify-dual-ioc-fx"]:
        verify_dual_ioc_fx(Path(sys.argv[2]))
    else:
        main(*map(os.path.abspath, sys.argv[1:]))
