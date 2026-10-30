"""Real candidate Host acceptance through the authenticated Web boundary."""

import hashlib
import concurrent.futures
import functools
import io
import json
import os
from pathlib import Path
import struct
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile

import strategy_host
import strategy_instance
import test_strategy_package_release as package_release
from test_strategy_package_release import DEFINITION, bundle_files, canonical, descriptor, write_bundle


ROOT = Path(__file__).resolve().parents[1]
MEMORY_ENFORCED = strategy_instance.memory_enforcement_available(sys.executable)


@functools.lru_cache(maxsize=1)
def windows_runtime():
    """Offline, self-contained interpreter fixture; no inherited conda/site path."""
    prefix = Path(sys.base_prefix)
    files = {"runtime/" + path.name: path.read_bytes() for path in prefix.glob("*.dll")}
    files["runtime/python.exe"] = Path(sys.executable).read_bytes()
    for path in (prefix / "DLLs").iterdir():
        if path.suffix in (".pyd", ".dll"):
            files["runtime/DLLs/" + path.name] = path.read_bytes()
    data = io.BytesIO()
    with zipfile.ZipFile(data, "w", compression=zipfile.ZIP_STORED) as archive:
        for root, directories, names in os.walk(prefix / "Lib"):
            directories[:] = sorted(d for d in directories if d not in (
                "site-packages", "__pycache__", "test", "tests", "idlelib", "tkinter", "ensurepip"))
            for name in sorted(names):
                path = Path(root) / name
                if path.suffix == ".py":
                    archive.writestr(zipfile.ZipInfo(path.relative_to(prefix / "Lib").as_posix()), path.read_bytes())
    version = f"python{sys.version_info.major}{sys.version_info.minor}"
    files[f"runtime/{version}.zip"] = data.getvalue()
    files[f"runtime/{version}._pth"] = f"{version}.zip\n.\nDLLs\n".encode("ascii")
    return files


OBSERVER = b'''import json
from strategy_api import OrderIntent, IntentGroup

def validate_config(data):
    config = json.loads(data)
    if set(config) != {"warmup_events"} or type(config["warmup_events"]) is not int or not 1 <= config["warmup_events"] <= 100:
        raise ValueError("invalid warmup_events")

class Observer:
    def __init__(self, context, config):
        self.required = json.loads(config)["warmup_events"]
        self.events = 0
        self.next_intent_sequence = 1
    def on_event(self, event):
        self.events += 1
        return ()
    def validate(self):
        if self.events < self.required:
            raise ValueError("warmup data insufficient")
    def snapshot(self):
        return json.dumps({"events": self.events, "next_intent_sequence": self.next_intent_sequence}, sort_keys=True, separators=(",", ":")).encode()
    def restore(self, data):
        state = json.loads(data)
        if (set(state) != {"events", "next_intent_sequence"}
                or any(type(v) is not int or not 0 <= v < 2**64 for v in state.values())
                or state["next_intent_sequence"] == 0):
            raise ValueError("invalid private state")
        self.events = state["events"]
        self.next_intent_sequence = state["next_intent_sequence"]

def create(context, config):
    return Observer(context, config)
'''


DECISION_OBSERVER = OBSERVER + b'''
class DecisionObserver(Observer):
    def __init__(self, context, config):
        super().__init__(context, config)
        self.decisions = []
    def on_event(self, event):
        self.events += 1
        intent = OrderIntent(self.next_intent_sequence, 1, 2, 3, "buy", "gtc", False, event.sequence, 100)
        self.next_intent_sequence += 1
        self.decisions.append(list(intent))
        return (intent,)
    def snapshot(self):
        return json.dumps(dict(events=self.events, next_intent_sequence=self.next_intent_sequence,
                               decisions=self.decisions), sort_keys=True, separators=(",", ":")).encode()
    def restore(self, data):
        state = json.loads(data)
        if set(state) != {"events", "next_intent_sequence", "decisions"}:
            raise ValueError("invalid decision trace state")
        decisions = state.pop("decisions")
        super().restore(json.dumps(state).encode())
        if len(decisions) != self.events or any(len(d) != 9 for d in decisions):
            raise ValueError("invalid decision trace")
        self.decisions = decisions

def create(context, config):
    return DecisionObserver(context, config)
'''

TRADER = OBSERVER.replace(b'return ()', b'''intent = OrderIntent(self.next_intent_sequence, 1, 2, 3, "buy", "gtc", False, 100, 50100000000)
        self.next_intent_sequence += 1
        return (intent,)''')

GROUP_TRADER = OBSERVER.replace(b'return ()', b'''first = OrderIntent(self.next_intent_sequence, 10, 20, 101, "buy", "gtc", False, 10, 10)
        second = first._replace(intent_sequence=self.next_intent_sequence + 1, exchange_account_identity=30, instrument_identity=102)
        self.next_intent_sequence += 2
        return (IntentGroup((first, second)),)''')


class NativeAuthorityTransportTests(unittest.TestCase):
    def test_stalled_reader_cannot_hold_native_pipe_beyond_write_deadline(self):
        process = subprocess.Popen([sys.executable, "-I", "-S", "-c", "import time; time.sleep(30)"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        authority = strategy_instance.NativeAuthority(process, timeout=0.1)
        try:
            started = time.monotonic()
            with self.assertRaisesRegex(ValueError, "write budget exhausted"):
                authority.request(dict(operation="unread", batch="a" * 200000))
            self.assertLess(time.monotonic() - started, 3)
            self.assertTrue(authority.failed)
            with self.assertRaisesRegex(ValueError, "connection failed"):
                authority.request(dict(operation="fault"))
        finally:
            process.kill()
            process.wait(timeout=5)
            authority.pipes.close()


def depth_batch(sequence=1):
    payload = strategy_host.encode_depth_snapshot(dict(instrument=3, rules_version=1, sequence=sequence,
        visible_at_ns=1, bids=((99, 1),), asks=((101, 1),), bids_truncated=False, asks_truncated=False))
    batch = bytearray(192 + len(payload))
    batch[:4] = b"QSHB"
    struct.pack_into("<HHII", batch, 4, 1, 128, 0, len(batch))
    batch[16:32] = strategy_host.SCHEMA_REGISTRY.to_bytes(16, "little")
    batch[32:48] = (4).to_bytes(16, "little")
    struct.pack_into("<Q", batch, 72, sequence)
    struct.pack_into("<QQqII", batch, 80, sequence, sequence, 0, 1, len(batch) - 128)
    struct.pack_into("<IIHHIQ", batch, 128, len(batch) - 128, len(payload), 7, 1, 0, sequence)
    batch[192:] = payload
    struct.pack_into("<I", batch, 124, strategy_host.crc32c(batch[:124] + batch[128:]))
    return bytes(batch)


@unittest.skipUnless(MEMORY_ENFORCED, "actual OS hard-memory enforcement unavailable; functional tests cannot establish qualification")
class WebInstanceTests(unittest.TestCase):
    deploy = package_release.PackageReleaseTests.deploy
    _windows_cleanup = package_release.PackageReleaseTests._windows_cleanup

    def setUp(self):
        package_release.PackageReleaseTests.setUp(self)
        default = ROOT / ("zig-out/bin/ringwin-strategy-candidate.exe" if os.name == "nt"
                          else ".scratch/build/candidate-linux/bin/ringwin-strategy-candidate")
        self.engine = Path(os.environ.get("RINGWIN_CANDIDATE_ENGINE", default))
        self.assertTrue(self.engine.is_file(), "build the native candidate engine before running this acceptance")
        self.assertGreater(self.engine.stat().st_size, 0)
        self.source = strategy_instance.CandidateSource(shard=1, decision_domain="0" * 31 + "4",
            portfolio_identity="0" * 31 + "1", scopes=[dict(venue="okx", exchange_account="0" * 31 + "2",
                                                         instrument="0" * 31 + "3")],
            risk_budget=100, batches=[depth_batch()])
        self.instances = strategy_instance.InstanceManager(self.root / "instances", self.manager, self.source)
        self.addCleanup(self.instances.close)
        self.app.instance_manager = self.instances

    def install(self, code=OBSERVER, limit_changes=None, state_fields=()):
        files, policy = bundle_files()
        runtime = {"ringwin": b"synthetic engine; this acceptance executes only the real candidate adapter and Host",
                   strategy_instance.CANDIDATE_PATH: self.engine.read_bytes()}
        runtime.update(windows_runtime() if os.name == "nt" else
                       {"runtime/python": Path(sys.executable).resolve().read_bytes()})
        for name in ("strategy_candidate_host.py", "strategy_api.py", "strategy_host.py", "strategy_package.py", "strategy_state.py"):
            runtime["runtime/" + name] = (ROOT / "python" / name).read_bytes()
        compatibility = dict(policy["compatibility"])
        compatibility.pop("runtime_lock_sha256")
        compatibility["python_abi"] = strategy_host.PYTHON_ABI
        lock = canonical(dict(format_version=1, compatibility=compatibility,
                              python_path="runtime/python.exe" if os.name == "nt" else "runtime/python",
                              host_path="runtime/strategy_candidate_host.py",
                              files=[descriptor(p, b) for p, b in sorted(runtime.items())]))
        compatibility = dict(compatibility, runtime_lock_sha256=hashlib.sha256(lock).hexdigest())
        name = f"strategies/{DEFINITION}/manifest.json"
        manifest = json.loads(files[name])
        manifest["compatibility"] = compatibility
        manifest["limits"].update(max_callback_ns=1000000000, max_warmup_ns=10000000000,
                                  max_input_record_bytes=1024, max_memory_bytes=268435456)
        manifest["limits"].update(limit_changes or {})
        manifest["subscriptions"] = [{"event_type": 7, "schema_version": 1}]
        manifest["output_kinds"] = ["intent_group", "order_intent"]
        files[f"strategies/{DEFINITION}/code/observer.py"] = code
        files[f"strategies/{DEFINITION}/contracts/config.json"] = canonical(dict(
            fields=[dict(name="warmup_events", type="u64", unit="canonical_events", minimum=1, maximum=100)],
            unknown_fields="reject", missing_fields="reject", encoding="canonical_json"))
        files[f"strategies/{DEFINITION}/contracts/state.json"] = canonical(dict(
            fields=[dict(name="events", type="u64", unit="canonical_events", minimum=0, maximum=2**64 - 1),
                    dict(name="next_intent_sequence", type="u64", unit="intent_sequence", minimum=1, maximum=2**64 - 1),
                    *state_fields],
            unknown_fields="reject", missing_fields="reject", encoding="portable_json_v1"))
        manifest["files"] = [descriptor(p[ len(f'strategies/{DEFINITION}/'):], b) for p, b in sorted(files.items())
                             if p.startswith(f"strategies/{DEFINITION}/") and p != name]
        files[name] = canonical(manifest)
        digest = hashlib.sha256(files[name]).hexdigest()
        files["strategy-index.json"] = canonical(dict(format_version=1, strategies=[dict(
            definition_identity=DEFINITION, manifest_path=name, package_manifest_sha256=digest)]))
        files = {p: b for p, b in files.items() if not p.startswith("runtime/") and p != "ringwin"}
        files.update(runtime)
        files["runtime-lock.json"] = lock
        self.manager.strategy_policy = dict(compatibility=compatibility, limits=manifest["limits"], subscriptions=manifest["subscriptions"])
        deployed = self.deploy(write_bundle(self.root, "candidate-a", files))
        self.assertEqual(deployed["status"], "activated", deployed)
        config = '{"warmup_events":1}'
        self.binding = dict(release_artifact="candidate-a", definition_identity=DEFINITION,
            package_manifest_sha256=digest, strategy_identity="0" * 30 + "10", initialization="new",
            config_version=1, config_json=config, config_sha256=hashlib.sha256(config.encode()).hexdigest(),
            **self.source.scope)

    def create(self, **changes):
        return self.client.call("POST", "/api/strategy-instances", dict(self.binding, **changes))

    def native_authority(self, *, group=False):
        self.app.clock = lambda: 1767225601
        status, login = self.client.call("POST", "/login", {
            "passphrase": "correct horse battery staple",
            "code": package_release.owner_session.totp_at(self.totp_secret, self.app.clock())})
        self.assertEqual(status, 200, login)
        self.client.csrf = login["csrf_token"]
        probe = self.engine.with_name("ringwin-strategy-authority-probe" + (".exe" if os.name == "nt" else ""))
        self.assertTrue(probe.is_file(), "zig build strategy-authority-probe is required")
        key = self.root / "node-control.key"
        key.write_bytes(self.command_server.key)
        process = subprocess.Popen([str(probe), str(key), *(["group"] if group else [])], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        # This first response includes cold fixture bootstrap, before node readiness.
        authority = strategy_instance.NativeAuthority(process, timeout=30)
        self.native_frames = []
        request = authority.request
        def capture(value):
            if value["operation"] == "output":
                self.native_frames.append(value["frame"])
            return request(value)
        authority.request = capture
        def close():
            process.kill()
            process.wait(timeout=5)
            authority.pipes.close()
        self.addCleanup(close)
        self.source.authority = authority
        self.source.fencing = 1
        self.source.scope["decision_domain"] = "0" * 31 + "1"
        if group:
            self.source.scope.update(portfolio_identity=f"{10:032x}", scopes=[
                dict(venue="bybit", exchange_account=f"{30:032x}", instrument=f"{102:032x}"),
                dict(venue="okx", exchange_account=f"{20:032x}", instrument=f"{101:032x}")])
        state = authority.request(dict(operation="status", strategy_identity=f"{9 if group else 16:032x}"))
        authority.timeout = 3
        self.source.batches = (self.node_batch(state["cursor"], 1),)
        return authority

    @staticmethod
    def node_batch(cursor, first):
        batch = bytearray(depth_batch(cursor))
        batch[32:48] = (1).to_bytes(16, "little")
        struct.pack_into("<Q", batch, 72, 1)
        struct.pack_into("<Q", batch, 80, first)
        struct.pack_into("<I", batch, 124, strategy_host.crc32c(batch[:124] + batch[128:]))
        return bytes(batch)

    def instance_command(self, kind, **changes):
        identity = self.binding["strategy_identity"]
        state = self.source.authority.request(dict(operation="status", strategy_identity=identity))
        command = dict(kind=kind, strategy_identity=identity, target_identity=1,
                       expected_version=state["operational_version"], command_identity=time.time_ns() % 2**62,
                       **changes)
        if kind == "enable_trading":
            status, warning = self.client.call("POST", "/risk-warning", command)
            self.assertEqual(status, 200, warning)
            command.update(risk_warning_acknowledged=True, risk_warning_identity=warning["warning_identity"])
        return self.client.call("POST", "/command", command)

    def test_native_first_unauthorized_batch_starts_at_one_without_publication_history(self):
        authority = self.native_authority()
        identity = "0" * 30 + "10"
        cursor = authority.request(dict(operation="status", strategy_identity=identity))["cursor"]
        command = authority.request(dict(operation="publish", strategy_identity=identity,
            evidence=dict(host_generation=1, cursor=0, next_input_batch=1), batch=self.node_batch(cursor, 1).hex()))
        batch = bytes.fromhex(command["host_command"]["batch"])
        self.assertEqual(int.from_bytes(batch[72:80], "little"), 1)
        self.assertFalse(authority.request(dict(operation="status", strategy_identity=identity))["trading_authorized"])

    def test_enable_applies_real_barrier_then_actual_package_output_reaches_native_core_and_pause_revokes(self):
        authority = self.native_authority()
        self.install(TRADER)
        ready = self.create()[1]["result"]
        self.assertEqual(ready["status"], "Ready", ready)
        self.assertFalse(ready["trading_authorized"])
        identity = self.binding["strategy_identity"]
        before = authority.request(dict(operation="status", strategy_identity=identity))
        self.assertEqual(before["orders"], 0)
        self.assertEqual(self.client.call("POST", "/command", dict(kind="enable_trading", strategy_identity=identity,
            target_identity=1, command_identity=999, expected_version=before["operational_version"]))[0], 403)
        catchup = authority.request(dict(operation="advance"))["cursor"]
        self.assertEqual(self.instance_command("enable_trading")[0], 400)
        self.assertEqual(self.instances.view()[0]["status"], "Ready")
        self.assertEqual(self.instances.deliver(identity, self.node_batch(catchup, ready["evidence"]["cursor"] + 1)), [])
        self.assertFalse(authority.request(dict(operation="status", strategy_identity=identity))["trading_authorized"])
        status, enabled = self.instance_command("enable_trading")
        self.assertEqual(status, 200, enabled)
        self.assertTrue(enabled["result"]["trading_authorized"])
        self.assertEqual(enabled["result"]["authority"]["orders"], 0)
        first = enabled["result"]["authority"]["cursor"] + 1
        cursor = authority.request(dict(operation="advance"))["cursor"]
        results = self.instances.deliver(identity, self.node_batch(cursor, first))
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]["orders"], 1, results)
        self.assertEqual(results[0]["commands"], 1, results)
        frame = bytes.fromhex(self.native_frames[0])
        self.assertEqual(int.from_bytes(frame[136:144], "little"), 3)
        for offset, value in ((48, 0), (108, 999)):
            with self.subTest(offset=offset):
                old = bytearray(frame)
                old[offset:offset + (8 if offset == 48 else 16)] = value.to_bytes(8 if offset == 48 else 16, "little")
                struct.pack_into("<I", old, 124, strategy_host.crc32c(old[:124] + old[128:]))
                result = authority.request(dict(operation="output", strategy_identity=identity, frame=old.hex()))
                self.assertEqual(result["orders"], 1)
        status, paused = self.instance_command("trading_pause")
        self.assertEqual(status, 200, paused)
        self.assertFalse(paused["result"]["trading_authorized"])
        self.assertFalse(authority.request(dict(operation="status", strategy_identity=identity))["trading_authorized"])
        dispatch = authority.request(dict(operation="dispatch"))
        self.assertEqual(dispatch, dict(dispatch="NotSent", attempts=0), dispatch)
        with self.assertRaisesRegex(ValueError, "not Ready or Trading"):
            self.instances.deliver(identity, self.node_batch(cursor, first))

    def test_complete_group_is_one_actual_frame_and_gateway_accepts_it_before_safety_revokes(self):
        authority = self.native_authority(group=True)
        self.install(GROUP_TRADER)
        self.binding["strategy_identity"] = f"{9:032x}"
        ready = self.create()[1]["result"]
        self.assertEqual(ready["status"], "Ready", ready)
        identity = self.binding["strategy_identity"]
        with self.assertRaisesRegex(ValueError, "NoHostActivation"):
            authority.request(dict(operation="applied", strategy_identity=identity, cursor=ready["evidence"]["cursor"]))
        status, enabled = self.instance_command("enable_trading")
        self.assertEqual(status, 200, enabled)
        first = enabled["result"]["authority"]["cursor"] + 1
        cursor = authority.request(dict(operation="advance"))["cursor"]
        results = self.instances.deliver(identity, self.node_batch(cursor, first))
        self.assertEqual(len(self.native_frames), 1)
        self.assertEqual(len(bytes.fromhex(self.native_frames[0])), 288)
        self.assertEqual(results[0]["orders"], 2, results)
        self.assertEqual(results[0]["commands"], 2, results)
        dispatch = authority.request(dict(operation="dispatch"))
        self.assertEqual(dispatch, dict(dispatch="accepted", attempts=1), dispatch)
        first_cursor = authority.request(dict(operation="advance"))["cursor"]
        last_cursor = authority.request(dict(operation="advance"))["cursor"]
        first_batch = self.node_batch(first_cursor, cursor + 1)
        second_batch = self.node_batch(last_cursor, first_cursor + 1)
        merged = bytearray(first_batch + second_batch[128:])
        struct.pack_into("<I", merged, 12, len(merged))
        struct.pack_into("<Q", merged, 88, last_cursor)
        struct.pack_into("<II", merged, 104, 2, len(merged) - 128)
        struct.pack_into("<I", merged, 124, strategy_host.crc32c(merged[:124] + merged[128:]))
        self.assertEqual(len(self.instances.deliver(identity, bytes(merged))), 2)
        self.assertEqual([int.from_bytes(bytes.fromhex(f)[136:144], "little") for f in self.native_frames], [3, 5, 7])
        authority.request(dict(operation="gate"))
        deadline = time.monotonic() + 3
        while True:
            record = self.instances.view()[0]
            if not record["trading_authorized"] or time.monotonic() >= deadline:
                break
            time.sleep(0.02)
        self.assertFalse(record["trading_authorized"])
        self.assertEqual(record["status"], "Stopped")
        self.assertIn("revoked", record["reason"])
        self.assertEqual(authority.request(dict(operation="dispatch")), dict(dispatch="NotSent", attempts=1))
        late = authority.request(dict(operation="output", strategy_identity=identity, frame=self.native_frames[0]))
        self.assertEqual(late["orders"], 2)

    def test_risk_warning_is_bound_to_instance_and_second_instance_cannot_gain_authority(self):
        self.native_authority()
        self.install(TRADER)
        self.assertEqual(self.create()[1]["result"]["status"], "Ready")
        identity = self.binding["strategy_identity"]
        state = self.source.authority.request(dict(operation="status", strategy_identity=identity))
        command = dict(kind="enable_trading", strategy_identity=identity, target_identity=1,
                       command_identity=888, expected_version=state["operational_version"])
        status, warning = self.client.call("POST", "/risk-warning", command)
        self.assertEqual(status, 200, warning)
        command.update(strategy_identity="0" * 30 + "11", risk_warning_acknowledged=True,
                       risk_warning_identity=warning["warning_identity"])
        self.assertEqual(self.client.call("POST", "/command", command)[0], 403)
        self.assertEqual(self.create(strategy_identity="0" * 30 + "11")[0], 400)
        self.assertFalse(self.source.authority.request(dict(operation="status", strategy_identity=identity))["trading_authorized"])

    def test_real_host_reaches_ready_without_authority_and_restart_does_not_recreate_it(self):
        self.install()
        status, body = self.create()
        self.assertEqual(status, 200, body)
        self.assertEqual(body["result"]["status"], "Ready", body)
        self.assertEqual(body["result"]["evidence"]["cursor"], 1)
        self.assertEqual(body["result"]["evidence"]["next_intent_sequence"], 1)
        self.assertEqual(body["result"]["evidence"]["state_digest"],
                         "7ecf4a316effc1272ef559c6b61c61db089219514c0a56b585255c2f263c4a53")
        self.assertFalse(body["result"]["trading_authorized"])
        self.assertEqual(self.create()[1], body)
        self.assertEqual(len(self.command_server._pending), 0)
        self.assertEqual(self.client.call("GET", "/api/strategy-instances")[1]["instances"], [body["result"]])
        self.assertEqual(self.create(config_sha256="f" * 64)[0], 400)
        restarted = strategy_instance.InstanceManager(self.root / "instances", self.manager, self.source)
        self.assertEqual(restarted.view()[0]["status"], "Stopped")
        self.assertFalse(restarted.view()[0]["trading_authorized"])
        print("real_candidate_ready=" + json.dumps(dict(
            package_manifest_sha256=self.binding["package_manifest_sha256"],
            config_sha256=self.binding["config_sha256"],
            evidence=body["result"]["evidence"], python_abi=strategy_host.PYTHON_ABI,
            scope=f"offline signed bundle + real {sys.platform} Host; synthetic canonical depth input"), sort_keys=True))

    def test_backend_rejects_unowned_scope_and_missing_csrf_before_launch(self):
        self.install()
        self.assertEqual(self.create(decision_domain="0" * 31 + "5")[0], 400)
        self.assertEqual(self.create(initialization="recover")[0], 400)
        csrf = self.client.csrf
        self.client.csrf = ""
        self.assertEqual(self.create()[0], 403)
        self.client.csrf = csrf
        self.assertEqual(self.instances.view(), [])

    def test_checkpoint_restart_replays_nonempty_tail_without_authority(self):
        self.install(DECISION_OBSERVER, state_fields=[dict(name="decisions", type="bounded_array", maximum=100,
                                                         items="OrderIntent_v1")])
        first = self.create()[1]["result"]
        self.assertEqual(first["status"], "Ready", first)
        self.assertIn("checkpoint", first)
        self.instances.close()
        # Node-owned log bytes survive the Host/manager; only its nonempty tail is supplied.
        tail = self.root / "canonical-tail.qshb"
        tail.write_bytes(depth_batch(2) + depth_batch(3))
        data = tail.read_bytes()
        length = len(depth_batch(2))
        self.source.batches = (data[:length], data[length:])
        restarted = strategy_instance.InstanceManager(self.root / "instances", self.manager, self.source)
        self.addCleanup(restarted.close)
        self.app.instance_manager = restarted
        status, body = self.client.call("POST", "/api/strategy-instances",
            dict(operation="recover", strategy_identity=self.binding["strategy_identity"]))
        self.assertEqual(status, 200, body)
        recovered = body["result"]
        self.assertEqual(recovered["status"], "Ready", recovered)
        self.assertEqual(recovered["binding"], first["binding"])
        self.assertGreater(recovered["evidence"]["host_generation"], first["evidence"]["host_generation"])
        self.assertEqual(recovered["evidence"]["cursor"], 3)
        self.assertEqual(recovered["evidence"]["next_intent_sequence"], 4)
        self.assertFalse(recovered["trading_authorized"])
        self.assertEqual(len(self.command_server._pending), 0)
        restarted.close()
        # Independently initialize the same identity in an isolated catalog for convergence.
        combined = bytearray(depth_batch() + depth_batch(2)[128:] + depth_batch(3)[128:])
        struct.pack_into("<I", combined, 12, len(combined))
        struct.pack_into("<Q", combined, 88, 3)
        struct.pack_into("<II", combined, 104, 3, len(combined) - 128)
        struct.pack_into("<I", combined, 124, strategy_host.crc32c(combined[:124] + combined[128:]))
        self.source.batches = (bytes(combined),)
        direct_manager = strategy_instance.InstanceManager(self.root / "direct", self.manager, self.source)
        self.addCleanup(direct_manager.close)
        self.app.instance_manager = direct_manager
        direct = self.create()[1]["result"]
        self.assertEqual(direct["status"], "Ready", direct)
        self.assertEqual(direct["evidence"]["state_digest"], recovered["evidence"]["state_digest"])
        self.assertEqual(direct["checkpoint"]["content_identity"], recovered["checkpoint"]["content_identity"])
        store = self.root / "direct" / (self.binding["strategy_identity"] + "-checkpoints")
        for path in store.iterdir():
            data = path.read_bytes()
            offset = data.find(b"QSSC")
            if offset >= 0:
                length = int.from_bytes(data[offset + 12:offset + 16], "little")
                _, payload = strategy_host.decode_payload_checkpoint(data[offset:offset + length])
                decisions = json.loads(payload)["decisions"]
                self.assertEqual(decisions, [[1, 1, 2, 3, "buy", "gtc", False, 1, 100],
                                             [2, 1, 2, 3, "buy", "gtc", False, 2, 100],
                                             [3, 1, 2, 3, "buy", "gtc", False, 3, 100]])
                break
        else:
            self.fail("committed decision trace absent")
        print("checkpoint_tail_recovery=" + json.dumps(dict(checkpoint=first["checkpoint"],
              recovered=recovered["evidence"], converged=direct["checkpoint"]), sort_keys=True))

    def recover(self):
        return self.client.call("POST", "/api/strategy-instances",
            dict(operation="recover", strategy_identity=self.binding["strategy_identity"]))

    def test_recovery_resolves_committed_publication_before_web_acknowledgment(self):
        self.install()
        self.assertEqual(self.create()[1]["result"]["status"], "Ready")
        for barrier in (2, 3, 4):
            self.instances.close()
            # Keep exactly the durable prefix preceding Web's Ready acknowledgment.
            records = [json.loads(line) for line in self.instances.path.read_bytes().splitlines()]
            cutoff = max(i for i, r in enumerate(records) if r["status"] == "Recovering")
            self.instances.path.write_bytes(b"".join(canonical(r) + b"\n" for r in records[:cutoff + 1]))
            self.source.batches = (tuple(depth_batch(n) for n in range(1, barrier + 1))
                                   if barrier == 3 else (depth_batch(barrier),))
            restarted = strategy_instance.InstanceManager(self.root / "instances", self.manager, self.source)
            self.addCleanup(restarted.close)
            self.instances = restarted
            self.app.instance_manager = restarted
            status, body = self.recover()
            self.assertEqual(status, 200, body)
            self.assertEqual(body["result"]["status"], "Ready", body)
            self.assertEqual(body["result"]["evidence"]["cursor"], barrier)
            # Observer's state counts each event once, including across the uncertain publication.
            expected = strategy_host.payload_state_digest(dict(schema_registry=strategy_host.SCHEMA_REGISTRY,
                strategy=int(self.binding["strategy_identity"], 16), definition=int(DEFINITION, 16),
                state_schema=int("22222222222222222222222222222222", 16), state_schema_version=1,
                config_version=1, cursor=barrier, next_intent=1),
                canonical(dict(events=barrier, next_intent_sequence=1))).hex()
            self.assertEqual(body["result"]["evidence"]["state_digest"], expected)
            self.assertEqual(body["result"]["evidence"]["host_generation"], barrier)

    def test_new_identity_does_not_reuse_shared_host_generation(self):
        self.install()
        first = self.create()[1]["result"]
        self.assertEqual(first["status"], "Ready", first)
        self.instances.close()
        second = self.create(strategy_identity="0" * 30 + "11")[1]["result"]
        self.assertEqual(second["status"], "Ready", second)
        self.assertGreater(second["evidence"]["host_generation"], first["evidence"]["host_generation"])

    def test_native_reopen_rejects_incompatible_checkpoint_schema(self):
        self.install()
        self.assertEqual(self.create()[1]["result"]["status"], "Ready")
        host = self.instances._hosts[self.binding["strategy_identity"]]
        request = json.loads((Path(host["temporary"].name) / "request.json").read_bytes())
        self.instances.close()
        request.update(recover=True, checkpoint_cursor=1, generation=2)
        request["manifest"]["state_schema"]["version"] += 1
        path = self.root / "incompatible-reopen.json"
        path.write_bytes(canonical(request))
        result = subprocess.run([str(self.engine), str(path)], capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"CheckpointMismatch", result.stderr)
        self.assertNotIn(b'"trading_authorized":true', result.stdout)

    def test_large_private_checkpoint_is_persisted_and_restored(self):
        code = OBSERVER.replace(b'{"events": self.events,', b'{"padding": "x" * 70000, "events": self.events,')
        code = code.replace(b'state = json.loads(data)',
                            b'state = json.loads(data)\n        if state.pop("padding") != "x" * 70000: raise ValueError("padding mismatch")')
        self.install(code, {"max_private_state_bytes": 131072, "max_callback_ns": 5000000000,
                            "max_warmup_ns": 30000000000},
                     state_fields=[dict(name="padding", type="string", maximum=70000)])
        # Exercise the public loader directly: this signed budget exceeds HTTP fixture's 10s timeout.
        first = self.instances.create(self.binding)
        self.assertEqual(first["status"], "Ready", first)
        self.instances.close()
        self.source.batches = (depth_batch(2),)
        result = self.instances.recover(self.binding["strategy_identity"])
        self.assertEqual(result["status"], "Ready", result)
        self.assertEqual(result["evidence"]["cursor"], 2)

    def test_missing_checkpoint_and_tail_gap_refuse_empty_restart(self):
        self.install()
        first = self.create()[1]["result"]
        self.assertEqual(first["status"], "Ready", first)
        self.instances.close()
        self.source.batches = (depth_batch(3),)
        status, failed = self.recover()
        self.assertEqual(status, 200, failed)
        self.assertEqual(failed["result"]["status"], "Stopped", failed)
        self.assertEqual(failed["result"]["checkpoint"], first["checkpoint"])
        self.assertTrue(failed["result"]["reason"])
        self.source.batches = (depth_batch(2),)
        store = self.root / "instances" / (self.binding["strategy_identity"] + "-checkpoints")
        store.rename(store.with_suffix(".unavailable"))
        status, failed = self.recover()
        self.assertEqual(status, 200, failed)
        self.assertEqual(failed["result"]["status"], "Stopped", failed)
        self.assertTrue(failed["result"]["reason"])
        self.assertEqual(self.create()[1]["result"]["status"], "Stopped")
        self.assertEqual(self.instances._hosts, {})

    def test_recovery_exception_keeps_only_previously_verified_checkpoint(self):
        code = OBSERVER.replace(b"self.events += 1", b'''self.events += 1
        if self.events == 2:
            raise ValueError("suspect recovery state")''')
        self.install(code)
        first = self.create()[1]["result"]
        self.assertEqual(first["status"], "Ready", first)
        self.instances.close()
        store = self.root / "instances" / (self.binding["strategy_identity"] + "-checkpoints")
        before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in store.iterdir() if p.is_file()}
        self.source.batches = (depth_batch(2),)
        status, failed = self.recover()
        self.assertEqual(status, 200, failed)
        self.assertEqual(failed["result"]["status"], "Stopped", failed)
        self.assertIn("suspect recovery state", failed["result"]["reason"])
        self.assertEqual(failed["result"]["checkpoint"], first["checkpoint"])
        self.assertEqual(before, {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                  for p in store.iterdir() if p.is_file()})
        self.assertFalse(failed["result"]["trading_authorized"])
        self.assertEqual(len(self.command_server._pending), 0)

    def test_committed_checkpoint_corruption_is_rejected(self):
        self.install()
        first = self.create()[1]["result"]
        self.assertEqual(first["status"], "Ready", first)
        self.instances.close()
        store = self.root / "instances" / (self.binding["strategy_identity"] + "-checkpoints")
        objects = [p for p in store.iterdir() if p.is_file() and b"QSSC" in p.read_bytes()]
        self.assertTrue(objects)
        for path in objects:
            data = bytearray(path.read_bytes())
            data[data.index(b"QSSC") + 192] ^= 1
            path.write_bytes(data)
        self.source.batches = (depth_batch(2),)
        status, failed = self.recover()
        self.assertEqual(status, 200, failed)
        self.assertEqual(failed["result"]["status"], "Stopped", failed)
        self.assertTrue(failed["result"]["reason"])
        self.assertEqual(failed["result"]["checkpoint"], first["checkpoint"])
        self.assertEqual(self.instances._hosts, {})

    def test_web_exposes_recovering_progress_before_ready(self):
        code = OBSERVER.replace(b"self.events += 1", b'''self.events += 1
        if self.events == 2:
            import time
            time.sleep(0.5)''')
        self.install(code)
        self.assertEqual(self.create()[1]["result"]["status"], "Ready")
        self.instances.close()
        self.source.batches = (depth_batch(2),)
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            pending = pool.submit(self.recover)
            seen = None
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and not pending.done():
                records = self.client.call("GET", "/api/strategy-instances")[1]["instances"]
                if records[0]["status"] == "Recovering":
                    seen = records[0]
                    break
                time.sleep(0.01)
            status, result = pending.result(timeout=10)
        self.assertIsNotNone(seen)
        self.assertEqual(seen["recovery"], dict(cursor=1, barrier=2))
        self.assertFalse(seen["trading_authorized"])
        self.assertEqual(status, 200, result)
        self.assertEqual(result["result"]["status"], "Ready", result)

    def test_warmup_insufficient_is_a_visible_failure(self):
        self.install()
        config = '{"warmup_events":2}'
        status, body = self.create(config_json=config, config_sha256=hashlib.sha256(config.encode()).hexdigest())
        self.assertEqual(status, 200, body)
        self.assertEqual(body["result"]["status"], "Stopped", body)
        self.assertIn("warmup data insufficient", body["result"]["reason"])

    def test_callback_hang_is_killed_by_external_budget(self):
        self.install(OBSERVER.replace(b"self.events += 1", b"while True: pass"), {"max_callback_ns": 100000000})
        status, body = self.create()
        self.assertEqual(status, 200, body)
        self.assertEqual(body["result"]["status"], "Stopped", body)
        self.assertIn("budget exhausted", body["result"]["reason"])
        self.assertEqual(self.instances._hosts, {})

    def test_candidate_intents_consume_sequence_but_cannot_enter_admission(self):
        code = OBSERVER.replace(b"return ()", b'''intent = OrderIntent(self.next_intent_sequence, 1, 2, 3, "buy", "gtc", False, 1, 100)
        self.next_intent_sequence += 1
        return (intent,)''')
        self.install(code)
        status, body = self.create()
        self.assertEqual(status, 200, body)
        self.assertEqual(body["result"]["status"], "Ready", body)
        self.assertEqual(body["result"]["evidence"]["next_intent_sequence"], 2)
        self.assertFalse(body["result"]["trading_authorized"])
        self.assertEqual(len(self.command_server._pending), 0)

    def test_partial_group_fails_closed(self):
        action = b'''intent = OrderIntent(1, 1, 2, 3, "buy", "gtc", False, 1, 100)
        self.next_intent_sequence = 2
        return (IntentGroup((intent,)),)'''
        self.install(OBSERVER.replace(b"return ()", action))
        status, body = self.create()
        self.assertEqual(status, 200, body)
        self.assertEqual(body["result"]["status"], "Stopped", body)
        self.assertIn("complete group", body["result"]["reason"])
        self.assertEqual(self.instances._hosts, {})

    def test_discontinuous_sequence_fails_closed(self):
        self.install(OBSERVER.replace(b"return ()", b"self.next_intent_sequence = 2\n        return ()"))
        status, body = self.create()
        self.assertEqual(status, 200, body)
        self.assertEqual(body["result"]["status"], "Stopped", body)
        self.assertIn("IntentSequence mismatch", body["result"]["reason"])

    def test_invalid_config_is_rejected_by_the_package_validator(self):
        self.install()
        config = '{"warmup_events":0}'
        status, body = self.create(config_json=config, config_sha256=hashlib.sha256(config.encode()).hexdigest())
        self.assertEqual(status, 200, body)
        self.assertIn("invalid warmup_events", body["result"]["reason"])
        self.assertEqual(body["result"]["status"], "Stopped")

    def test_dirty_parent_environment_and_import_path_do_not_reach_candidate(self):
        code = b'''import os, sys
assert "RINGWIN_TEST_SECRET" not in os.environ
assert all("unapproved-path" not in p for p in sys.path)
''' + OBSERVER
        self.install(code)
        from unittest.mock import patch
        with patch.dict(os.environ, {"RINGWIN_TEST_SECRET": "must not inherit", "PYTHONPATH": "/unapproved-path"}):
            status, body = self.create()
        self.assertEqual(status, 200, body)
        self.assertEqual(body["result"]["status"], "Ready", body)

    def test_installed_runtime_tampering_is_rejected_before_launch(self):
        self.install()
        runtime = self.root / "versions" / "candidate-a" / "runtime/strategy_api.py"
        if os.name == "nt":
            with self.assertRaises(PermissionError):
                runtime.write_bytes(b"unapproved")
            strategy_instance.windows.set_permissions(runtime, writable=True)
        runtime.chmod(0o640)
        runtime.write_bytes(b"raise RuntimeError('unapproved')")
        if os.name == "nt":
            strategy_instance.windows.set_permissions(runtime)
        status, body = self.create()
        self.assertEqual(status, 400, body)
        self.assertIn("differs from approved bytes", body["error"])
        self.assertEqual(self.instances._hosts, {})

    def test_warmup_event_budget_exhaustion_is_not_ready(self):
        self.install(limit_changes={"max_warmup_events": 1})
        self.source.batches = (depth_batch(1), depth_batch(2))
        status, body = self.create()
        self.assertEqual(status, 200, body)
        self.assertEqual(body["result"]["status"], "Stopped", body)
        self.assertIn("warmup event budget exhausted", body["result"]["reason"])

    def test_memory_budget_exhaustion_is_not_ready(self):
        self.install(limit_changes={"max_memory_bytes": 1048576})
        status, body = self.create()
        self.assertEqual(status, 200, body)
        self.assertEqual(body["result"]["status"], "Stopped", body)
        self.assertEqual(self.instances._hosts, {})

    def test_callback_allocation_over_the_hard_limit_stops_the_real_host(self):
        self.install(OBSERVER.replace(b"self.events += 1", b"self.events += 1\n        self.allocation = bytearray(512 * 1024 * 1024)"))
        status, body = self.create()
        self.assertEqual(status, 200, body)
        self.assertEqual(body["result"]["status"], "Stopped", body)
        self.assertIn("MemoryError", body["result"]["reason"])
        self.assertEqual(self.instances._hosts, {})

    def test_excessive_diagnostics_are_bounded_and_stop_the_host(self):
        code = OBSERVER.replace(b"import json", b"import json, sys").replace(
            b"self.events += 1", b"sys.stderr.write('x' * 70000)\n        sys.stderr.flush()\n        self.events += 1")
        self.install(code)
        status, body = self.create()
        self.assertEqual(status, 200, body)
        self.assertEqual(body["result"]["status"], "Stopped", body)
        self.assertLessEqual(len(body["result"]["reason"]), 2048)
        self.assertEqual(self.instances._hosts, {})

    def test_invalid_canonical_schema_is_not_ready(self):
        self.install()
        invalid = bytearray(depth_batch())
        struct.pack_into("<H", invalid, 138, 2)
        self.source.batches = (bytes(invalid),)
        status, body = self.create()
        self.assertEqual(status, 400, body)
        self.assertEqual(self.instances._hosts, {})

    def test_external_actions_are_rejected_inside_candidate(self):
        code = b'''import socket, os
for action in (socket.socket, lambda: os.system("true")):
    try:
        action()
    except PermissionError:
        pass
    else:
        raise ValueError("candidate external action was allowed")
''' + OBSERVER
        self.install(code)
        status, body = self.create()
        self.assertEqual(status, 200, body)
        self.assertEqual(body["result"]["status"], "Ready", body)
        self.assertFalse(body["result"]["trading_authorized"])

    def test_undeclared_transitive_import_file_is_rejected_before_launch(self):
        self.install(OBSERVER.replace(b"import json", b"import json, helper"))
        code = self.root / "versions" / "candidate-a" / "strategies" / DEFINITION / "code"
        if os.name == "nt":
            with self.assertRaises(PermissionError):
                (code / "helper.py").write_bytes(b"unsigned")
            strategy_instance.windows.set_permissions(code, writable=True)
        code.chmod(0o750)
        (code / "helper.py").write_bytes(b"UNSIGNED = True\n")
        (code / "helper.py").chmod(0o440)
        code.chmod(0o550)
        if os.name == "nt":
            strategy_instance.windows.set_permissions(code / "helper.py")
            strategy_instance.windows.set_permissions(code)
        status, body = self.create()
        self.assertEqual(status, 400, body)
        self.assertIn("undeclared", body["error"])
        self.assertEqual(self.instances._hosts, {})

    def test_same_canonical_stream_in_different_batches_has_same_ready_digest(self):
        self.install()
        first, second = depth_batch(1), depth_batch(2)
        self.source.batches = (first, second)
        status, split = self.create()
        self.assertEqual(status, 200, split)
        self.assertEqual(split["result"]["status"], "Ready", split)
        self.instances.close()
        combined = bytearray(first + second[128:])
        struct.pack_into("<I", combined, 12, len(combined))
        struct.pack_into("<Q", combined, 88, 2)
        struct.pack_into("<II", combined, 104, 2, len(combined) - 128)
        struct.pack_into("<I", combined, 124, strategy_host.crc32c(combined[:124] + combined[128:]))
        self.source.batches = (bytes(combined),)
        # An independent deployment/store, with identical signed package and binding.
        self.instances = strategy_instance.InstanceManager(self.root / "independent-instance-store", self.manager, self.source)
        self.addCleanup(self.instances.close)
        self.app.instance_manager = self.instances
        status, grouped = self.create()
        self.assertEqual(status, 200, grouped)
        self.assertEqual(grouped["result"]["status"], "Ready", grouped)
        for field in ("cursor", "next_intent_sequence", "state_digest"):
            self.assertEqual(split["result"]["evidence"][field], grouped["result"]["evidence"][field])

    def test_snapshot_progress_must_match_live_intent_sequence(self):
        code = OBSERVER.replace(b"return ()", b'''intent = OrderIntent(self.next_intent_sequence, 1, 2, 3, "buy", "gtc", False, 1, 100)
        self.next_intent_sequence += 1
        return (intent,)''').replace(b'"next_intent_sequence": self.next_intent_sequence', b'"next_intent_sequence": 1')
        self.install(code)
        status, body = self.create()
        self.assertEqual(status, 200, body)
        self.assertEqual(body["result"]["status"], "Stopped", body)
        self.assertIn("snapshot IntentSequence mismatch", body["result"]["reason"])

    def test_host_death_after_ready_is_visible_as_stopped(self):
        self.install()
        status, body = self.create()
        self.assertEqual(status, 200, body)
        self.assertEqual(body["result"]["status"], "Ready", body)
        os.kill(body["result"]["evidence"]["host_pid"], signal.SIGTERM if os.name == "nt" else signal.SIGKILL)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            status, view = self.client.call("GET", "/api/strategy-instances")
            if view["instances"][0]["status"] == "Stopped":
                break
            time.sleep(0.01)
        self.assertEqual(status, 200, view)
        self.assertEqual(view["instances"][0]["status"], "Stopped", view)
        self.assertFalse(view["instances"][0]["trading_authorized"])

    def test_restore_validation_cannot_mutate_intent_sequence(self):
        code = OBSERVER.replace(b"self.events = state[\"events\"]", b"self.events = state[\"events\"]\n        self.restored = True")
        code = code.replace(b"if self.events < self.required:", b"if getattr(self, 'restored', False):\n            self.next_intent_sequence += 1\n        if self.events < self.required:")
        self.install(code)
        status, body = self.create()
        self.assertEqual(status, 200, body)
        self.assertEqual(body["result"]["status"], "Stopped", body)
        self.assertIn("snapshot IntentSequence mismatch", body["result"]["reason"])

    def test_validate_cannot_repair_incomplete_warmup_state(self):
        code = OBSERVER.replace(b"if self.events < self.required:", b"self.events = self.required\n        if self.events < self.required:")
        self.install(code)
        config = '{"warmup_events":2}'
        status, body = self.create(config_json=config, config_sha256=hashlib.sha256(config.encode()).hexdigest())
        self.assertEqual(status, 200, body)
        self.assertEqual(body["result"]["status"], "Stopped", body)
        self.assertIn("validate changed private state", body["result"]["reason"])

    def test_backend_pipe_eof_stops_and_reaps_python_host(self):
        self.install()
        status, body = self.create()
        self.assertEqual(status, 200, body)
        self.assertEqual(body["result"]["status"], "Ready", body)
        pid = body["result"]["evidence"]["host_pid"]
        self.instances._hosts[self.binding["strategy_identity"]]["process"].stdin.close()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            status, view = self.client.call("GET", "/api/strategy-instances")
            if view["instances"][0]["status"] == "Stopped":
                break
            time.sleep(0.01)
        self.assertEqual(view["instances"][0]["status"], "Stopped", view)
        if os.name == "nt":
            import ctypes
            w = strategy_instance.windows
            open_process = w.api(w.kernel, "OpenProcess", w.w.HANDLE, w.w.DWORD, w.w.BOOL, w.w.DWORD)
            handle = open_process(0x100000, False, pid)
            if handle:
                wait = w.api(w.kernel, "WaitForSingleObject", w.w.DWORD, w.w.HANDLE, w.w.DWORD)
                try:
                    self.assertEqual(wait(handle, 5000), 0)
                finally:
                    w.close_handle(handle)
            else:
                self.assertEqual(ctypes.get_last_error(), 87)
        else:
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)

    @unittest.skipUnless(os.name == "nt", "Windows kernel job handle ownership")
    def test_real_backend_death_closes_job_and_reaps_host(self):
        evidence = self.root / "backend-ready.json"
        worker = f'''
import sys, tempfile, time
sys.path.insert(0, {str(ROOT / 'python')!r})
tempfile.tempdir = {str(self.root)!r}
import test_strategy_instance as acceptance
test = acceptance.WebInstanceTests()
test.setUp()
test.install()
status, result = test.create()
assert status == 200 and result['result']['status'] == 'Ready', result
acceptance.Path({str(evidence)!r}).write_text(acceptance.json.dumps(dict(
    root=str(test.root), result=result['result'])), encoding='utf-8')
while True:
    time.sleep(1)
'''
        w = strategy_instance.windows
        handle = None
        with (self.root / "backend-errors.log").open("w+b") as diagnostic:
            backend = subprocess.Popen([sys.executable, "-I", "-S", "-c", worker],
                stdin=subprocess.DEVNULL, stdout=diagnostic, stderr=diagnostic,
                env=dict(w.environment(), RINGWIN_CANDIDATE_ENGINE=str(self.engine)),
                creationflags=subprocess.CREATE_NO_WINDOW, close_fds=True)
            try:
                deadline = time.monotonic() + 60
                while not evidence.exists() and backend.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.05)
                if not evidence.exists():
                    diagnostic.seek(0)
                    self.fail(diagnostic.read(4096).decode('utf-8', 'replace'))
                ready = json.loads(evidence.read_text(encoding="utf-8"))
                pid = ready["result"]["evidence"]["host_pid"]
                open_process = w.api(w.kernel, "OpenProcess", w.w.HANDLE, w.w.DWORD, w.w.BOOL, w.w.DWORD)
                handle = w.checked(open_process(0x100000, False, pid))
                backend.kill()
                backend.wait(timeout=5)
                wait = w.api(w.kernel, "WaitForSingleObject", w.w.DWORD, w.w.HANDLE, w.w.DWORD)
                self.assertEqual(wait(handle, 5000), 0, "backend death left the Python Host alive")
                restarted = strategy_instance.InstanceManager(Path(ready["root"]) / "instances", self.manager, self.source)
                self.assertEqual(restarted.view()[0]["status"], "Stopped")
                self.assertFalse(restarted.view()[0]["trading_authorized"])
                print("windows_backend_death=Host terminated; restart=Stopped; trading_authorized=false")
            finally:
                if backend.poll() is None:
                    backend.kill()
                backend.wait(timeout=5)
                if handle:
                    w.close_handle(handle)


@unittest.skipIf(os.name == "nt" or MEMORY_ENFORCED, "requires an installed Linux adapter on a kernel that ignores RLIMIT_AS")
class UnsupportedMemoryKernelTests(unittest.TestCase):
    setUp = WebInstanceTests.setUp
    install = WebInstanceTests.install
    deploy = WebInstanceTests.deploy
    create = WebInstanceTests.create

    def test_signed_package_cannot_load_when_the_kernel_ignores_the_memory_limit(self):
        self.install()
        status, body = self.create()
        self.assertEqual(status, 400, body)
        self.assertIn("hard address-space limit enforcement is unavailable or unverified", body["error"])
        self.assertEqual(self.instances.view(), [])
        self.assertEqual(self.instances._hosts, {})


class InstanceContractTests(unittest.TestCase):
    def test_fixed_api_rejects_a_partial_group(self):
        from strategy_api import IntentGroup, OrderIntent, validate_outputs
        intent = OrderIntent(1, 1, 2, 3, "buy", "gtc", False, 1, 100)
        with self.assertRaisesRegex(ValueError, "complete group"):
            validate_outputs((IntentGroup((intent,)),), 1, 2,
                             {"output_kinds": ["intent_group"], "limits": {
                                 "max_output_frames_per_event": 1, "max_output_frame_bytes": 512}},
                             {"portfolio_identity": "0" * 31 + "1", "scopes": [
                                 {"venue": "okx", "exchange_account": "0" * 31 + "2",
                                  "instrument": "0" * 31 + "3"}]})


@unittest.skipUnless(os.name == "nt", "Windows atomic job assignment")
class WindowsProcessOwnershipTests(unittest.TestCase):
    def test_backend_death_during_creation_reaps_the_suspended_process(self):
        w = strategy_instance.windows
        with tempfile.TemporaryDirectory(prefix="ringwin-suspended-") as directory:
            evidence = Path(directory) / "suspended-pid.json"
            worker = f'''
import sys, time
sys.path.insert(0, {str(ROOT / 'python')!r})
import strategy_windows as w
create_process = w.create_process
def pause(*args):
    w.checked(create_process(*args))
    info = w.c.cast(args[-1], w.c.POINTER(w.ProcessInfo)).contents
    with open({str(evidence)!r}, 'w') as handle:
        handle.write(str(info.pid))
    while True:
        time.sleep(1)
w.create_process = pause
job = w.Job(128 * 1024 * 1024)
job.start([sys.executable, '-I', '-S', '-c', 'import time; time.sleep(60)'],
    stdin=w.subprocess.DEVNULL, stdout=w.subprocess.DEVNULL, stderr=w.subprocess.DEVNULL,
    env=w.environment(), close_fds=True)
'''
            backend = subprocess.Popen([sys.executable, "-I", "-S", "-c", worker],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                env=w.environment(), creationflags=subprocess.CREATE_NO_WINDOW, close_fds=True)
            handle = None
            try:
                deadline = time.monotonic() + 10
                while (not evidence.exists() or not evidence.stat().st_size) and backend.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(evidence.exists(), "backend did not reach suspended process creation")
                pid = int(evidence.read_text())
                open_process = w.api(w.kernel, "OpenProcess", w.w.HANDLE, w.w.DWORD, w.w.BOOL, w.w.DWORD)
                handle = w.checked(open_process(0x100000, False, pid))
                self.assertEqual(w.wait_process(handle, 0), 258, "child should still be suspended")
                backend.kill()
                backend.wait(timeout=5)
                self.assertEqual(w.wait_process(handle, 5000), 0, "startup left an unowned suspended process")
                print("windows_backend_death_during_create=created process terminated by kernel job ownership")
            finally:
                if backend.poll() is None:
                    backend.kill()
                backend.wait(timeout=5)
                if handle:
                    w.close_handle(handle)


if __name__ == "__main__":
    unittest.main()
