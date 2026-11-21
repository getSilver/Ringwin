"""Exercise Web, Venue recovery and StrategyHost against one formal Writer."""
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import secrets
import select
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

import owner_session
import strategy_host
import strategy_package
from venue_recovery import recover_market_inputs
from verify_production_strategy_web import child, receive, relay_strategy_reads, request
from verify_production_venue_recovery import read_committed, role


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


def configure_host(core, root, cursor, *, bad_ack=False):
    runtime = Path(strategy_host.__file__).resolve().parent
    package_root = root / "package"
    code = package_root / "code"
    code.mkdir(parents=True, exist_ok=True)
    (code / "acceptance_strategy.py").write_text(FIXTURE)
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
        assert all(record[41] == 2 for record in records if record[4] & 1), records
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
    main(*map(os.path.abspath, sys.argv[1:]))
