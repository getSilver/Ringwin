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
import textwrap
import time
import unittest
import zipfile

import strategy_host
import strategy_instance
import strategy_package
import test_strategy_package_release as package_release
from test_strategy_package_release import DEFINITION, bundle_files, canonical, descriptor, write_bundle


ROOT = Path(__file__).resolve().parents[1]
MEMORY_ENFORCED = strategy_instance.memory_enforcement_available(sys.executable)


class HostManifestTests(unittest.TestCase):
    def test_aggregate_binds_complete_digests_and_exact_member_set(self):
        first = dict(binding=dict(strategy_identity="1" * 32, definition_identity="2" * 32,
            package_manifest_sha256="a" * 64, config_sha256="b" * 64, config_version=1),
            manifest=dict(state_schema=dict(identity="3" * 32, version=1)), checkpoint=None)
        second = json.loads(canonical(first))
        second["binding"]["strategy_identity"] = "4" * 32
        original = strategy_package.host_manifests([first, second])
        self.assertEqual(original, strategy_package.host_manifests([second, first]))
        self.assertNotEqual(original, strategy_package.host_manifests([first]))
        second["binding"]["package_manifest_sha256"] = "a" * 63 + "b"
        self.assertNotEqual(original[0], strategy_package.host_manifests([first, second])[0])
        second["checkpoint"] = dict(cursor=7, publication=2, content_identity="c" * 64)
        self.assertNotEqual(original[1], strategy_package.host_manifests([first, second])[1])
        with self.assertRaisesRegex(ValueError, "duplicate Host member"):
            strategy_package.host_manifests([first, first])


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

MANAGED_TRADER = OBSERVER + b'''
class Managed(Observer):
    def __init__(self, context, config):
        super().__init__(context, config)
        self.window = []
        self.cycle_target = 100
        self.deadline = 50
        self.risk_latched = True
    def on_event(self, event):
        self.events += 1
        self.window = (self.window + [event.sequence])[-self.required:]
        intent = OrderIntent(self.next_intent_sequence, 1, 2, 3, "buy", "gtc", False, 100, 50100000000)
        self.next_intent_sequence += 1
        return (intent,)
    def snapshot(self):
        return json.dumps(dict(events=self.events, next_intent_sequence=self.next_intent_sequence,
            window=self.window, cycle_target=self.cycle_target, deadline=self.deadline,
            risk_latched=self.risk_latched), sort_keys=True, separators=(",", ":")).encode()
    def restore(self, data):
        state = json.loads(data)
        self.events = state["events"]
        self.next_intent_sequence = state["next_intent_sequence"]
        self.cycle_target = state["cycle_target"]
        self.deadline = state["deadline"]
        self.risk_latched = state["risk_latched"]
        self.window = state["window"][-self.required:]
    def validate(self):
        super().validate()
        if len(self.window) > self.required:
            raise ValueError("restored configuration overwritten")

def create(context, config):
    return Managed(context, config)
'''

MANAGED_FIELDS = [dict(name="window", type="bounded_array", maximum=100, items="u64", rebuildable=True),
                  dict(name="cycle_target", type="u64", unit="quantity", minimum=1, maximum=100),
                  dict(name="deadline", type="u64", unit="canonical_events", minimum=1, maximum=50),
                  dict(name="risk_latched", type="bool", unit="latch")]


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
        # Bundle verification and up to two Host warmups precede the HTTP result.
        self.client.timeout = 30
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

    def install(self, code=OBSERVER, limit_changes=None, state_fields=(), transitions=None, definition=DEFINITION, artifact="candidate-a",
                extra_definitions=None, runtime_marker=b""):
        files, policy = bundle_files()
        if definition != DEFINITION:
            files = {p.replace(DEFINITION, definition): b for p, b in files.items()}
        runtime = {"ringwin": b"synthetic engine; this acceptance executes only the real candidate adapter and Host",
                   strategy_instance.CANDIDATE_PATH: self.engine.read_bytes()}
        runtime.update(windows_runtime() if os.name == "nt" else
                       {"runtime/python": Path(sys.executable).resolve().read_bytes()})
        for name in ("strategy_candidate_host.py", "strategy_api.py", "strategy_host.py", "strategy_package.py", "strategy_state.py"):
            runtime["runtime/" + name] = (ROOT / "python" / name).read_bytes()
        runtime["runtime/strategy_api.py"] += runtime_marker
        compatibility = dict(policy["compatibility"])
        compatibility.pop("runtime_lock_sha256")
        compatibility["python_abi"] = strategy_host.PYTHON_ABI
        lock = canonical(dict(format_version=1, compatibility=compatibility,
                              python_path="runtime/python.exe" if os.name == "nt" else "runtime/python",
                              host_path="runtime/strategy_candidate_host.py",
                              files=[descriptor(p, b) for p, b in sorted(runtime.items())]))
        compatibility = dict(compatibility, runtime_lock_sha256=hashlib.sha256(lock).hexdigest())
        name = f"strategies/{definition}/manifest.json"
        manifest = json.loads(files[name])
        manifest["definition_identity"] = definition
        manifest["compatibility"] = compatibility
        manifest["limits"].update(max_callback_ns=1000000000, max_warmup_ns=10000000000,
                                  max_input_record_bytes=1024, max_memory_bytes=268435456)
        manifest["limits"].update(limit_changes or {})
        manifest["subscriptions"] = [{"event_type": 7, "schema_version": 1}]
        manifest["output_kinds"] = ["intent_group", "order_intent"]
        files[f"strategies/{definition}/code/observer.py"] = code
        files[f"strategies/{definition}/contracts/config.json"] = canonical(dict(
            fields=[dict(name="warmup_events", type="u64", unit="canonical_events", minimum=1, maximum=100)],
            unknown_fields="reject", missing_fields="reject", encoding="canonical_json"))
        if transitions is not None:
            contract = json.loads(files[f"strategies/{definition}/contracts/config.json"])
            contract["transitions"] = transitions
            files[f"strategies/{definition}/contracts/config.json"] = canonical(contract)
        files[f"strategies/{definition}/contracts/state.json"] = canonical(dict(
            fields=[dict(name="events", type="u64", unit="canonical_events", minimum=0, maximum=2**64 - 1),
                    dict(name="next_intent_sequence", type="u64", unit="intent_sequence", minimum=1, maximum=2**64 - 1),
                    *state_fields],
            unknown_fields="reject", missing_fields="reject", encoding="portable_json_v1"))
        manifest["files"] = [descriptor(p[ len(f'strategies/{definition}/'):], b) for p, b in sorted(files.items())
                             if p.startswith(f"strategies/{definition}/") and p != name]
        files[name] = canonical(manifest)
        digest = hashlib.sha256(files[name]).hexdigest()
        files["strategy-index.json"] = canonical(dict(format_version=1, strategies=[dict(
            definition_identity=definition, manifest_path=name, package_manifest_sha256=digest)]))
        if extra_definitions:
            index = json.loads(files["strategy-index.json"])
            for extra, extra_code in sorted(extra_definitions.items()):
                prefix = f"strategies/{extra}/"
                for path, content in list(files.items()):
                    if path.startswith(f"strategies/{definition}/"):
                        files[path.replace(definition, extra)] = content
                extra_manifest = dict(manifest, definition_identity=extra)
                files[prefix + "code/observer.py"] = extra_code
                extra_manifest["files"] = [descriptor(path[len(prefix):], content)
                    for path, content in sorted(files.items()) if path.startswith(prefix) and path != prefix + "manifest.json"]
                files[prefix + "manifest.json"] = canonical(extra_manifest)
                index["strategies"].append(dict(definition_identity=extra, manifest_path=prefix + "manifest.json",
                    package_manifest_sha256=hashlib.sha256(files[prefix + "manifest.json"]).hexdigest()))
            index["strategies"].sort(key=lambda r: r["definition_identity"])
            files["strategy-index.json"] = canonical(index)
        files = {p: b for p, b in files.items() if not p.startswith("runtime/") and p != "ringwin"}
        files.update(runtime)
        files["runtime-lock.json"] = lock
        self.manager.strategy_policy = dict(compatibility=compatibility, limits=manifest["limits"], subscriptions=manifest["subscriptions"])
        deployed = self.deploy(write_bundle(self.root, artifact, files), identity=str(time.time_ns() % 2**62), expected=self.manager.active_artifact())
        self.assertEqual(deployed["status"], "activated", deployed)
        config = '{"warmup_events":1}'
        self.binding = dict(release_artifact=artifact, definition_identity=definition,
            package_manifest_sha256=digest, strategy_identity="0" * 30 + "10", initialization="new",
            config_version=1, config_json=config, config_sha256=hashlib.sha256(config.encode()).hexdigest(),
            **self.source.scope)

    def create(self, **changes):
        return self.client.call("POST", "/api/strategy-instances", dict(self.binding, **changes))

    @unittest.skipUnless(os.name == "nt", "shared aggregate Job memory qualification is Windows-specific")
    def test_two_instances_share_host_and_recover_without_authority(self):
        self.install()
        self.source.batches = (depth_batch(), depth_batch(2))
        status, first = self.create()
        self.assertEqual(status, 200, first)
        config = '{"warmup_events":2}'
        status, second = self.create(strategy_identity="0" * 30 + "11", config_json=config,
                                    config_sha256=hashlib.sha256(config.encode()).hexdigest())
        self.assertEqual(status, 200, second)
        records = {r["binding"]["strategy_identity"]: r for r in self.instances.view()}
        self.assertEqual([r["status"] for r in records.values()], ["Ready", "Ready"], records)
        self.assertEqual(len({r["evidence"]["host_pid"] for r in records.values()}), 1)
        self.assertEqual(len({r["checkpoint_directory"] for r in records.values()}), 2)
        self.assertTrue(all(not r["trading_authorized"] for r in records.values()))
        self.assertEqual(records[second["result"]["binding"]["strategy_identity"]]["binding"]["config_json"], config)
        placement = records[self.binding["strategy_identity"]]["host_placement"]
        self.assertEqual(placement["members"], sorted(records))
        self.assertEqual(placement["memory_budget_bytes"], 2 * 268435456)
        self.assertEqual(len(placement["strategy_manifest"]), 64)
        self.assertNotEqual(placement["strategy_manifest"], self.binding["package_manifest_sha256"])
        before = {i: r["evidence"]["next_intent_sequence"] for i, r in records.items()}
        host = self.instances._hosts[self.binding["strategy_identity"]]
        host["job"].terminate()
        deadline = time.monotonic() + 5
        while any(r["status"] != "Stopped" for r in self.instances.view()) and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(all(r["status"] == "Stopped" and not r["trading_authorized"] for r in self.instances.view()))
        for i in sorted(records):
            self.assertEqual(self.instances.recover(i)["status"], "Ready")
        recovered = self.instances.view()
        self.assertEqual(len({r["evidence"]["host_pid"] for r in recovered}), 1)
        for r in recovered:
            self.assertEqual(r["evidence"]["next_intent_sequence"], before[r["binding"]["strategy_identity"]])
            self.assertGreater(r["host_generation"], records[r["binding"]["strategy_identity"]]["host_generation"])
            self.assertFalse(r["trading_authorized"])

    @unittest.skipUnless(os.name == "nt", "shared aggregate Job memory qualification is Windows-specific")
    def test_shared_host_keeps_same_module_names_in_different_packages_separate(self):
        other = "b" * 32
        self.install(extra_definitions={other: OBSERVER.replace(b"self.events += 1", b"self.events += 10")})
        self.assertEqual(self.create()[1]["result"]["status"], "Ready")
        registration = next(r for r in self.manager._registrations() if r["definition_identity"] == other)
        status, body = self.create(strategy_identity="0" * 30 + "11", definition_identity=other,
                                  package_manifest_sha256=registration["package_manifest_sha256"])
        self.assertEqual(status, 200, body)
        self.assertTrue(body["ok"], body)
        records = self.instances.view()
        self.assertEqual(len({r["evidence"]["host_pid"] for r in records}), 1)
        self.assertEqual(len({r["evidence"]["state_digest"] for r in records}), 2)
        for r in records:
            snapshot, _ = self.instances._exchange(r["binding"]["strategy_identity"], dict(checkpoint=True))
            self.assertEqual(snapshot["state_digest"], r["evidence"]["state_digest"])

    def create_other_domain(self, definition):
        scope = dict(self.source.scope, decision_domain=f"{5:032x}")
        self.source.placements += (scope,)
        batch = bytearray(depth_batch())
        batch[32:48] = (5).to_bytes(16, "little")
        struct.pack_into("<I", batch, 124, strategy_host.crc32c(batch[:124] + batch[128:]))
        previous = self.source.batches
        self.source.batches = (bytes(batch),)
        try:
            registration = next(r for r in self.manager._registrations() if r["definition_identity"] == definition)
            status, body = self.create(strategy_identity=f"{99:032x}", definition_identity=definition,
                package_manifest_sha256=registration["package_manifest_sha256"], **scope)
            self.assertEqual(status, 200, body)
            self.assertTrue(body["ok"], body)
            return body["result"]
        finally:
            self.source.batches = previous

    @unittest.skipUnless(os.name == "nt", "shared aggregate Job memory qualification is Windows-specific")
    def test_shared_memory_failure_stops_all_members_and_leaves_other_host_ready(self):
        code = OBSERVER.replace(b"self.events += 1", b"self.events += 1\n        if self.events > 1: self.allocation = bytearray(1024 * 1024 * 1024)")
        self.install(code, extra_definitions={"b" * 32: OBSERVER})
        self.assertTrue(self.create()[1]["ok"])
        self.assertTrue(self.create(strategy_identity=f"{17:032x}")[1]["ok"])
        independent = self.create_other_domain("b" * 32)
        self.source.batches = (depth_batch(), depth_batch(2))
        status, body = self.create(strategy_identity=f"{18:032x}")
        self.assertEqual(status, 200, body)
        self.assertFalse(body["ok"], body)
        records = {r["binding"]["strategy_identity"]: r for r in self.instances.view()}
        for identity in (16, 17, 18):
            self.assertEqual(records[f"{identity:032x}"]["status"], "Stopped", records)
            self.assertFalse(records[f"{identity:032x}"]["trading_authorized"])
        self.assertIn("MemoryError", body["result"]["reason"])
        self.assertEqual(records[f"{99:032x}"]["status"], "Ready")
        self.assertEqual(records[f"{99:032x}"]["evidence"]["host_pid"], independent["evidence"]["host_pid"])

    @unittest.skipUnless(os.name == "nt", "shared aggregate Job memory qualification is Windows-specific")
    def test_callback_timeout_does_not_hold_other_hosts_or_web_view(self):
        code = OBSERVER.replace(b"def snapshot(self):", b"def snapshot(self):\n        self.snapshot_calls = getattr(self, 'snapshot_calls', 0) + 1\n        if self.snapshot_calls > 2:\n            while True: pass")
        self.install(code, extra_definitions={"b" * 32: OBSERVER})
        self.assertTrue(self.create()[1]["ok"])
        independent = self.create_other_domain("b" * 32)
        with concurrent.futures.ThreadPoolExecutor() as executor:
            pending = executor.submit(self.create, strategy_identity=f"{17:032x}")
            deadline = time.monotonic() + 0.7
            while not pending.done() and time.monotonic() < deadline:
                status, body = self.client.call("GET", "/api/strategy-instances")
                self.assertEqual(status, 200, body)
                if any(r["binding"]["strategy_identity"] == f"{17:032x}" for r in body["instances"]):
                    break
                time.sleep(0.01)
            self.assertFalse(pending.done(), "view was blocked until callback timeout")
            healthy = next(r for r in body["instances"] if r["binding"]["strategy_identity"] == f"{99:032x}")
            self.assertEqual(healthy["status"], "Ready")
            self.assertEqual(healthy["evidence"]["host_pid"], independent["evidence"]["host_pid"])
            status, failed = pending.result(timeout=5)
        self.assertEqual(status, 400, failed)
        self.assertIn("budget exhausted", failed["error"])

    def native_authority(self, *, group=False, multiple=False, hyperliquid=False):
        group = group or multiple or hyperliquid
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
        process = subprocess.Popen([str(probe), str(key), *(["multiple" if multiple else "hyperliquid" if hyperliquid else "group"] if group else [])], stdin=subprocess.PIPE,
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

    def bounded_instance_worker(self, body):
        worker = f'''import sys
sys.path.insert(0, {str(ROOT / 'python')!r})
import test_strategy_instance as acceptance
test = acceptance.WebInstanceTests()
test.setUp()
try:
{textwrap.indent(textwrap.dedent(body), '    ')}
finally:
    test.doCleanups()
'''
        result = subprocess.run([sys.executable, "-I", "-S", "-c", worker], capture_output=True, timeout=60,
            env=dict(strategy_instance.windows.environment(), RINGWIN_CANDIDATE_ENGINE=str(self.engine)))
        self.assertEqual(result.returncode, 0, (result.stdout + result.stderr).decode("utf-8", "replace"))

    @unittest.skipUnless(os.name == "nt", "Windows bounded concurrent Host regression")
    def test_two_management_writes_during_checkpoint_wait_finish_without_deadlock(self):
        self.bounded_instance_worker('''
            import concurrent.futures, time
            code = acceptance.OBSERVER.replace(b"def snapshot(self):", b"def snapshot(self):\\n        self.snapshot_calls = getattr(self, 'snapshot_calls', 0) + 1\\n        if self.snapshot_calls > 2:\\n            while True: pass")
            test.install(code)
            assert test.create()[1]["ok"]
            with concurrent.futures.ThreadPoolExecutor() as executor:
                first = executor.submit(test.create, strategy_identity=f"{17:032x}")
                deadline = time.monotonic() + 10
                while len(test.instances.view()) < 2 and time.monotonic() < deadline:
                    time.sleep(0.01)
                second = executor.submit(test.create, strategy_identity=f"{18:032x}")
                assert first.result(timeout=10)[0] == 400
                status, body = second.result(timeout=15)
                assert status == 200 and body["ok"], body
        ''')

    @unittest.skipUnless(os.name == "nt", "Windows bounded concurrent Host regression")
    def test_other_host_delivers_input_while_replacement_candidate_times_out(self):
        self.bounded_instance_worker('''
            import concurrent.futures, time
            authority = test.native_authority(multiple=True)
            scope = dict(test.source.scope, portfolio_identity=f"{11:032x}")
            test.source.placements = (scope,)
            test.install()
            test.binding["strategy_identity"] = f"{9:032x}"
            old = dict(test.binding)
            assert test.create()[1]["ok"]
            test.install(definition="b" * 32, artifact="candidate-b", runtime_marker=b"\\n# runtime B\\n")
            peer = test.create(strategy_identity=f"{19:032x}", **scope)[1]["result"]
            assert peer["status"] == "Ready", peer
            test.binding = peer["binding"]
            assert test.instance_command("enable_trading")[1]["ok"]
            state = authority.request(dict(operation="status", strategy_identity=f"{19:032x}"))
            test.source.batches = (test.node_batch(state["cursor"], 1),)
            hanging = acceptance.OBSERVER.replace(b"self.events += 1", b"while True: pass\\n        self.events += 1")
            test.install(hanging, definition="c" * 32, artifact="candidate-c", runtime_marker=b"\\n# runtime B\\n",
                         limit_changes=dict(max_callback_ns=4_000_000_000))
            request = test.replacement(old)
            with concurrent.futures.ThreadPoolExecutor() as executor:
                pending = executor.submit(test.client.call, "POST", "/api/strategy-instances", request)
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    record = next(r for r in test.instances.view() if r["binding"]["strategy_identity"] == old["strategy_identity"])
                    if record.get("successor_transition", {}).get("status") == "validating":
                        break
                    time.sleep(0.01)
                assert not pending.done(), "candidate wait held the parent manager lock"
                state = authority.request(dict(operation="advance"))
                host = test.instances._hosts[f"{19:032x}"]
                assert test.instances.deliver(f"{19:032x}", test.node_batch(state["cursor"], host["cursor"] + 1)) == []
                assert not pending.done(), "other Host waited for the failed candidate"
                status, failed = pending.result(timeout=15)
            assert status == 200 and not failed["ok"], failed
            assert "budget exhausted" in failed["result"]["successor_transition"]["reason"], failed
            assert authority.request(dict(operation="status", strategy_identity=f"{19:032x}"))["trading_authorized"]
        ''')

    @unittest.skipUnless(os.name == "nt", "Windows bounded concurrent Host regression")
    def test_disable_during_config_candidate_wait_cannot_restore_old_trading_projection(self):
        self.bounded_instance_worker('''
            import concurrent.futures, time
            authority = test.native_authority()
            code = acceptance.OBSERVER.replace(b"    config = json.loads(data)",
                b"    config = json.loads(data)\\n    if config['warmup_events'] == 2:\\n        while True: pass", 1)
            test.install(code, transitions={"Keep": {"mutable_config_fields": ["warmup_events"], "rebuild_state_fields": []}},
                         limit_changes=dict(max_callback_ns=4_000_000_000))
            assert test.create()[1]["ok"]
            assert test.instance_command("enable_trading")[1]["ok"]
            identity = test.binding["strategy_identity"]
            state = authority.request(dict(operation="status", strategy_identity=identity))
            test.source.batches = (test.node_batch(state["cursor"], 1),)
            with concurrent.futures.ThreadPoolExecutor() as executor:
                pending = executor.submit(test.update_config, config='{"warmup_events":2}')
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    record = test.instances.view()[0]
                    if record.get("config_transition", {}).get("status") == "validating":
                        break
                    time.sleep(0.01)
                assert not pending.done()
                deadline = time.monotonic() + 2
                while True:
                    status, stopped = test.instance_command("trading_pause")
                    if status == 200 or time.monotonic() >= deadline:
                        break
                    assert stopped["error"] == "Host callback in progress", stopped
                    time.sleep(0.02)
                assert status == 200 and stopped["ok"], stopped
                status, failed = pending.result(timeout=15)
            assert status == 200 and not failed["ok"], failed
            record = test.instances.view()[0]
            assert record["status"] == "Stopped" and not record["trading_authorized"], record
            assert identity not in test.instances._hosts
            reopened = acceptance.strategy_instance.InstanceManager(test.instances.directory, test.manager, test.source)
            assert reopened.view()[0]["status"] == "Stopped"
            reopened.close()
        ''')

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

    @unittest.skipUnless(os.name == "nt", "shared aggregate Job memory qualification is Windows-specific")
    def test_shared_host_two_node_bindings_enable_independently_and_fault_together(self):
        authority = self.native_authority(multiple=True)
        second_scope = dict(self.source.scope, portfolio_identity=f"{11:032x}")
        self.source.placements = (second_scope,)
        self.install()
        self.binding["strategy_identity"] = f"{9:032x}"
        self.assertEqual(self.create()[1]["result"]["status"], "Ready")
        status, body = self.create(strategy_identity=f"{19:032x}", **second_scope)
        self.assertEqual(status, 200, body)
        self.assertTrue(body["ok"], body)
        for identity in (9, 19):
            self.binding["strategy_identity"] = f"{identity:032x}"
            current = authority.request(dict(operation="status", strategy_identity=self.binding["strategy_identity"]))
            host = self.instances._hosts[self.binding["strategy_identity"]]
            if current["cursor"] > host["cursor"]:
                self.instances.deliver(self.binding["strategy_identity"], self.node_batch(current["cursor"], host["cursor"] + 1))
            status, body = self.instance_command("enable_trading")
            self.assertEqual(status, 200, body)
            self.assertTrue(body["ok"], body)
        records = self.instances.view()
        self.assertTrue(all(r["trading_authorized"] for r in records), records)
        self.assertEqual(len({r["evidence"]["host_pid"] for r in records}), 1)
        self.instances._hosts[f"{9:032x}"]["job"].terminate()
        deadline = time.monotonic() + 5
        while any(r["status"] != "Stopped" for r in self.instances.view()) and time.monotonic() < deadline:
            time.sleep(0.02)
        for identity in (9, 19):
            state = authority.request(dict(operation="status", strategy_identity=f"{identity:032x}"))
            self.assertFalse(state["trading_authorized"], state)
        self.source.batches = (self.node_batch(state["cursor"], 1),)
        for identity in (9, 19):
            recovered = self.instances.recover(f"{identity:032x}")
            self.assertEqual(recovered["status"], "Ready", recovered)
            self.assertFalse(recovered["trading_authorized"])

    @unittest.skipUnless(os.name == "nt", "shared aggregate Job memory qualification is Windows-specific")
    def test_secondary_member_successor_preserves_primary_node_binding(self):
        authority = self.native_authority(multiple=True)
        secondary_scope = dict(self.source.scope, portfolio_identity=f"{11:032x}")
        self.source.placements = (secondary_scope,)
        self.install()
        self.binding["strategy_identity"] = f"{9:032x}"
        primary = self.create()[1]["result"]
        secondary = self.create(strategy_identity=f"{19:032x}", **secondary_scope)[1]["result"]
        self.assertEqual(secondary["status"], "Ready", secondary)
        self.install(definition="b" * 32, artifact="candidate-b")
        status, body = self.client.call("POST", "/api/strategy-instances", self.replacement(secondary["binding"]))
        self.assertEqual(status, 200, body)
        self.assertTrue(body["ok"], body)
        successor = body["result"]
        self.assertEqual(successor["binding"]["portfolio_identity"], f"{11:032x}")
        records = {r["binding"]["strategy_identity"]: r for r in self.instances.view()}
        self.assertEqual(records[f"{9:032x}"]["binding"], primary["binding"])
        self.assertFalse(authority.request(dict(operation="status", strategy_identity=f"{9:032x}"))["trading_authorized"])
        self.assertEqual(authority.request(dict(operation="status", strategy_identity=f"{9:032x}"))["config_version"], 1)
        self.assertFalse(authority.request(dict(operation="status", strategy_identity=successor["binding"]["strategy_identity"]))["trading_authorized"])

    @unittest.skipUnless(os.name == "nt", "shared aggregate Job memory qualification is Windows-specific")
    def test_shared_members_emit_their_own_complete_groups_and_late_output_is_rejected(self):
        authority = self.native_authority(multiple=True)
        scope = dict(self.source.scope, portfolio_identity=f"{11:032x}")
        self.source.placements = (scope,)
        code = GROUP_TRADER.replace(b"self.required =", b"self.portfolio = 11 if int(context.strategy_identity, 16) == 19 else 10\n        self.required =")
        code = code.replace(b"self.next_intent_sequence, 10, 20", b"self.next_intent_sequence, self.portfolio, 20")
        self.install(code)
        self.binding["strategy_identity"] = f"{9:032x}"
        self.assertTrue(self.create()[1]["ok"])
        self.assertTrue(self.create(strategy_identity=f"{19:032x}", **scope)[1]["ok"])
        for identity in (9, 19):
            self.binding["strategy_identity"] = f"{identity:032x}"
            state = authority.request(dict(operation="status", strategy_identity=self.binding["strategy_identity"]))
            host = self.instances._hosts[self.binding["strategy_identity"]]
            if state["cursor"] > host["cursor"]:
                self.instances.deliver(self.binding["strategy_identity"], self.node_batch(state["cursor"], host["cursor"] + 1))
            status, enabled = self.instance_command("enable_trading")
            self.assertEqual(status, 200, enabled)
            self.assertTrue(enabled["ok"], enabled)
        authority.request(dict(operation="advance"))
        for identity, orders in ((9, 2), (19, 4)):
            name = f"{identity:032x}"
            state = authority.request(dict(operation="status", strategy_identity=name))
            host = self.instances._hosts[name]
            result = self.instances.deliver(name, self.node_batch(state["cursor"], host["cursor"] + 1))
            self.assertEqual(result[0]["orders"], orders, result)
            self.assertEqual(int.from_bytes(bytes.fromhex(self.native_frames[-1])[64:80], "little"), identity)
        self.instances._hosts[f"{9:032x}"]["job"].terminate()
        deadline = time.monotonic() + 5
        while any(r["trading_authorized"] for r in self.instances.view()) and time.monotonic() < deadline:
            time.sleep(0.02)
        late = authority.request(dict(operation="output", strategy_identity=f"{19:032x}", frame=self.native_frames[-1]))
        self.assertEqual(late["orders"], 4)
        self.assertFalse(late["trading_authorized"])

    @unittest.skipUnless(os.name == "nt", "shared aggregate Job memory qualification is Windows-specific")
    def test_secondary_config_keep_changes_only_target_and_peers_recover_from_original_repositories(self):
        authority = self.native_authority(multiple=True)
        scope = dict(self.source.scope, portfolio_identity=f"{11:032x}")
        self.source.placements = (scope,)
        self.install(transitions={"Keep": {"mutable_config_fields": ["warmup_events"], "rebuild_state_fields": []}})
        self.binding["strategy_identity"] = f"{9:032x}"
        self.assertTrue(self.create()[1]["ok"])
        primary_binding = dict(self.binding)
        secondary = self.create(strategy_identity=f"{19:032x}", **scope)[1]["result"]
        self.assertEqual(secondary["status"], "Ready", secondary)
        self.binding = secondary["binding"]
        status, body = self.update_config()
        self.assertEqual(status, 200, body)
        self.assertTrue(body["ok"], body)
        self.assertEqual(body["result"]["binding"]["strategy_identity"], f"{19:032x}")
        for identity, version in ((9, 1), (19, 2)):
            state = authority.request(dict(operation="status", strategy_identity=f"{identity:032x}"))
            self.assertEqual(state["config_version"], version)
            self.assertFalse(state["trading_authorized"])
        self.source.batches = (self.node_batch(state["cursor"], 1),)
        primary = self.instances.recover(f"{9:032x}")
        self.assertEqual(primary["status"], "Ready", primary)
        self.assertEqual(primary["binding"], primary_binding)
        records = self.instances.view()
        self.assertTrue(all(r["status"] == "Ready" for r in records), records)
        self.assertEqual(len({r["evidence"]["host_pid"] for r in records}), 1)

    def test_native_first_unauthorized_batch_starts_at_one_without_publication_history(self):
        authority = self.native_authority()
        identity = "0" * 30 + "10"
        cursor = authority.request(dict(operation="status", strategy_identity=identity))["cursor"]
        command = authority.request(dict(operation="publish", strategy_identity=identity,
            evidence=dict(host_generation=1, cursor=0, next_input_batch=1), batch=self.node_batch(cursor, 1).hex()))
        batch = bytes.fromhex(command["host_command"]["batch"])
        self.assertEqual(int.from_bytes(batch[72:80], "little"), 1)
        self.assertFalse(authority.request(dict(operation="status", strategy_identity=identity))["trading_authorized"])

    def test_web_keep_updates_same_instance_and_requires_explicit_enable(self):
        authority = self.native_authority()
        self.install(transitions={"Keep": {"mutable_config_fields": ["warmup_events"],
                                           "rebuild_state_fields": []}})
        self.assertEqual(self.create()[1]["result"]["status"], "Ready")
        identity = self.binding["strategy_identity"]
        self.assertEqual(self.instance_command("enable_trading")[0], 200)
        first = authority.request(dict(operation="status", strategy_identity=identity))["cursor"] + 1
        cursor = authority.request(dict(operation="advance"))["cursor"]
        self.instances.deliver(identity, self.node_batch(cursor, first))
        # The node owns complete authoritative coverage, including activation facts.
        cursor = authority.request(dict(operation="status", strategy_identity=identity))["cursor"]
        self.source.batches = (self.node_batch(cursor, 1),)
        config = '{"warmup_events":2}'
        request = dict(operation="update_config", strategy_identity=identity, expected_config_version=1,
                       config_version=2, config_json=config,
                       config_sha256=hashlib.sha256(config.encode()).hexdigest(), transition="Keep")
        status, body = self.client.call("POST", "/api/strategy-instances", request)
        self.assertEqual(status, 200, body)
        result = body["result"]
        self.assertEqual(result["status"], "Ready", result)
        self.assertFalse(result["trading_authorized"])
        self.assertEqual(result["binding"]["strategy_identity"], identity)
        self.assertEqual(result["binding"]["definition_identity"], DEFINITION)
        self.assertEqual(result["binding"]["config_version"], 2)
        self.assertEqual(result["evidence"]["next_intent_sequence"], 1)
        self.assertEqual(result["config_transition"]["status"], "completed")
        state = authority.request(dict(operation="status", strategy_identity=identity))
        self.assertEqual(state["config_version"], 2)
        self.assertFalse(state["trading_authorized"])
        self.assertEqual(self.client.call("POST", "/api/strategy-instances", request), (200, body))
        self.assertEqual(self.instance_command("enable_trading")[0], 200)

    def replacement(self, old, operation="replace"):
        return dict(operation=operation, operation_identity=f"{time.time_ns():032x}", strategy_identity=old["strategy_identity"],
                    expected_definition_identity=old["definition_identity"], **{k: self.binding[k] for k in
                    ("release_artifact", "definition_identity", "package_manifest_sha256")})

    @unittest.skipUnless(os.name == "nt", "shared aggregate Job memory qualification is Windows-specific")
    def test_replacing_one_shared_member_preserves_other_binding_and_reports_restart_scope(self):
        authority = self.native_authority()
        self.install()
        old = dict(self.binding)
        first = self.create()[1]["result"]
        self.assertEqual(first["status"], "Ready", first)
        peer = self.create(strategy_identity=f"{17:032x}")[1]["result"]
        self.assertEqual(peer["status"], "Ready", peer)
        peer_binding = dict(peer["binding"])
        self.install(definition="b" * 32, artifact="candidate-b")
        status, body = self.client.call("POST", "/api/strategy-instances", self.replacement(old))
        self.assertEqual(status, 200, body)
        self.assertTrue(body["ok"], body)
        result = body["result"]
        self.assertEqual(result["successor_transition"]["affected_instances"], sorted([old["strategy_identity"], peer_binding["strategy_identity"]]))
        records = {r["binding"]["strategy_identity"]: r for r in self.instances.view()}
        self.assertEqual(records[peer_binding["strategy_identity"]]["binding"], peer_binding)
        self.assertEqual(records[peer_binding["strategy_identity"]]["status"], "Stopped")
        self.assertFalse(records[peer_binding["strategy_identity"]]["trading_authorized"])
        cursor = authority.request(dict(operation="status", strategy_identity=result["binding"]["strategy_identity"]))["cursor"]
        self.source.batches = (self.node_batch(cursor, 1),)
        recovered = self.instances.recover(peer_binding["strategy_identity"])
        self.assertEqual(recovered["status"], "Ready", recovered)
        self.assertEqual(recovered["binding"], peer_binding)
        self.assertFalse(recovered["trading_authorized"])

    def test_successor_rejects_candidate_failure_without_revoking_current_host(self):
        authority = self.native_authority()
        self.install()
        old = dict(self.binding)
        self.assertEqual(self.create()[1]["result"]["status"], "Ready")
        self.assertEqual(self.instance_command("enable_trading")[0], 200)
        cursor = authority.request(dict(operation="status", strategy_identity=old["strategy_identity"]))["cursor"]
        self.source.batches = (self.node_batch(cursor, 1),)
        self.install(OBSERVER.replace(b'return Observer(context, config)', b'raise ValueError("bad successor")'),
                     definition="b" * 32, artifact="candidate-b")
        status, body = self.client.call("POST", "/api/strategy-instances", self.replacement(old))
        self.assertEqual(status, 200, body)
        self.assertFalse(body["ok"], body)
        self.assertEqual(body["result"]["successor_transition"]["status"], "rejected")
        self.assertTrue(authority.request(dict(operation="status", strategy_identity=old["strategy_identity"]))["trading_authorized"])

    def test_successor_live_order_rejection_does_not_close_or_clear_the_order(self):
        authority = self.native_authority()
        self.install(TRADER)
        old = dict(self.binding)
        self.assertEqual(self.create()[1]["result"]["status"], "Ready")
        self.assertEqual(self.instance_command("enable_trading")[0], 200)
        first = authority.request(dict(operation="status", strategy_identity=old["strategy_identity"]))["cursor"] + 1
        cursor = authority.request(dict(operation="advance"))["cursor"]
        self.instances.deliver(old["strategy_identity"], self.node_batch(cursor, first))
        before = authority.request(dict(operation="status", strategy_identity=old["strategy_identity"]))
        self.source.batches = (self.node_batch(before["cursor"], 1),)
        self.install(definition="b" * 32, artifact="candidate-b")
        status, body = self.client.call("POST", "/api/strategy-instances", self.replacement(old))
        self.assertEqual(status, 200, body)
        self.assertFalse(body["ok"], body)
        self.assertEqual(body["result"]["successor_transition"]["status"], "rejected")
        self.assertIn("SuccessorResponsibilityOpen", body["result"]["successor_transition"]["reason"])
        after = authority.request(dict(operation="status", strategy_identity=old["strategy_identity"]))
        self.assertEqual(after["orders"], before["orders"])
        self.assertEqual(after["commands"], before["commands"])

    def test_replacement_and_forward_rollback_create_fresh_successors_and_recover_without_authority(self):
        authority = self.native_authority()
        self.install()
        original = dict(self.binding)
        self.assertEqual(self.create()[1]["result"]["status"], "Ready")
        self.assertEqual(self.instance_command("enable_trading")[0], 200)
        cursor = authority.request(dict(operation="status", strategy_identity=original["strategy_identity"]))["cursor"]
        self.source.batches = (self.node_batch(cursor, 1),)
        self.install(OBSERVER + b'\n# replacement definition\n', definition="b" * 32, artifact="candidate-b")
        request = self.replacement(original)
        status, body = self.client.call("POST", "/api/strategy-instances", request)
        self.assertEqual(status, 200, body)
        self.assertTrue(body["ok"], body)
        result = body["result"]
        successor = result["binding"]["strategy_identity"]
        self.assertNotEqual(successor, original["strategy_identity"])
        self.assertEqual(result["binding"]["portfolio_identity"], original["portfolio_identity"])
        self.assertEqual(result["status"], "Ready")
        self.assertEqual(result["evidence"]["next_intent_sequence"], 1)
        self.assertFalse(authority.request(dict(operation="status", strategy_identity=successor))["trading_authorized"])
        self.assertEqual(self.client.call("POST", "/api/strategy-instances", request), (200, body))
        self.assertEqual(self.client.call("POST", "/api/strategy-instances", dict(request, definition_identity="c" * 32))[0], 400)
        self.assertEqual(self.client.call("POST", "/api/strategy-instances", dict(operation="recover", strategy_identity=original["strategy_identity"]))[0], 400)
        with self.assertRaisesRegex(ValueError, "StrategyIdentityMismatch"):
            authority.request(dict(operation="status", strategy_identity=original["strategy_identity"]))
        self.binding = result["binding"]
        self.assertEqual(self.instance_command("enable_trading")[0], 200)
        old = result["binding"]
        cursor = authority.request(dict(operation="status", strategy_identity=successor))["cursor"]
        self.source.batches = (self.node_batch(cursor, 1),)
        # Existing signed release rollback installs old content; the instance still advances.
        manifest = self.root / "candidate-a.json"
        rollback = self.deploy(manifest, identity=str(time.time_ns() % 2**62), expected="candidate-b", kind="forward_rollback")
        self.assertEqual(rollback["status"], "activated")
        self.binding = original
        status, body = self.client.call("POST", "/api/strategy-instances", self.replacement(old, "forward_rollback"))
        self.assertTrue(body["ok"], body)
        restored = body["result"]
        self.assertNotIn(restored["binding"]["strategy_identity"], (successor, original["strategy_identity"]))
        self.assertEqual(restored["binding"]["definition_identity"], original["definition_identity"])
        self.assertEqual(restored["evidence"]["next_intent_sequence"], 1)
        self.instances._stop(restored["binding"]["strategy_identity"])
        self.source.batches = (self.node_batch(restored["evidence"]["cursor"], 1),)
        recovered = self.instances.recover(restored["binding"]["strategy_identity"])
        self.assertEqual(recovered["status"], "Ready", recovered)
        self.assertEqual(recovered["binding"], restored["binding"])
        self.assertFalse(recovered["trading_authorized"])
        reopened = strategy_instance.InstanceManager(self.instances.directory, self.manager, self.source)
        self.addCleanup(reopened.close)
        self.assertEqual(reopened.replace(request), result)

    def test_successor_lost_commit_ack_stops_and_reopen_cannot_restore_predecessor(self):
        authority = self.native_authority()
        self.install()
        old = dict(self.binding)
        self.assertEqual(self.create()[1]["result"]["status"], "Ready")
        self.assertEqual(self.instance_command("enable_trading")[0], 200)
        cursor = authority.request(dict(operation="status", strategy_identity=old["strategy_identity"]))["cursor"]
        self.source.batches = (self.node_batch(cursor, 1),)
        self.install(definition="b" * 32, artifact="candidate-b")
        request = self.replacement(old)
        exchange = authority.request
        def lose_ack(value):
            response = exchange(value)
            if value["operation"] == "commit_successor":
                raise OSError("commit ACK lost")
            return response
        authority.request = lose_ack
        status, body = self.client.call("POST", "/api/strategy-instances", request)
        self.assertEqual(status, 200, body)
        self.assertFalse(body["ok"], body)
        progress = body["result"]["successor_transition"]
        self.assertEqual(progress["status"], "unknown")
        self.assertEqual(body["result"]["status"], "Stopped")
        self.assertFalse(self.instances._hosts)
        self.assertFalse(exchange(dict(operation="status", strategy_identity=progress["to_instance"]))["trading_authorized"])
        reopened = strategy_instance.InstanceManager(self.instances.directory, self.manager, self.source)
        self.addCleanup(reopened.close)
        with self.assertRaisesRegex(ValueError, "successor cutover"):
            reopened.recover(old["strategy_identity"])
        retry = reopened.replace(request)
        self.assertEqual(retry["successor_transition"]["status"], "unknown")
        self.assertFalse(reopened._hosts)

    def update_config(self, version=2, config='{"warmup_events":1}', method="Keep", expected=1):
        return self.client.call("POST", "/api/strategy-instances", dict(operation="update_config",
            strategy_identity=self.binding["strategy_identity"], expected_config_version=expected,
            config_version=version, config_json=config, config_sha256=hashlib.sha256(config.encode()).hexdigest(),
            transition=method))

    @staticmethod
    def checkpoint_state(record):
        for path in Path(record["checkpoint_directory"]).iterdir():
            if path.is_file():
                content = path.read_bytes()
                offset = content.find(b"QSSC")
                while offset >= 0:
                    size = int.from_bytes(content[offset + 12:offset + 16], "little")
                    container = content[offset:offset + size]
                    offset = content.find(b"QSSC", offset + 4)
                    if len(container) < 192:
                        continue
                    try:
                        metadata, payload = strategy_host.decode_payload_checkpoint(container)
                    except ValueError:
                        continue
                    if (metadata["config_version"] == record["binding"]["config_version"]
                            and metadata["cursor"] == record["checkpoint"]["cursor"]):
                        return json.loads(payload)
        raise AssertionError("published private state absent")

    def test_rebuild_retains_sequence_cycle_deadline_and_latch_and_recovers_new_config(self):
        authority = self.native_authority()
        self.install(MANAGED_TRADER, state_fields=MANAGED_FIELDS,
            transitions={"Rebuild": {"mutable_config_fields": ["warmup_events"], "rebuild_state_fields": ["window"]}})
        config = '{"warmup_events":3}'
        cursor = authority.request(dict(operation="status", strategy_identity=self.binding["strategy_identity"]))["cursor"]
        parts = []
        for n, sequence in enumerate(range(cursor - 2, cursor + 1), 1):
            part = bytearray(self.node_batch(sequence, 1 if n == 1 else sequence))
            struct.pack_into("<Q", part, 72, n)
            struct.pack_into("<I", part, 124, strategy_host.crc32c(part[:124] + part[128:]))
            parts.append(bytes(part))
        self.source.batches = tuple(parts)
        initial = self.create(config_json=config, config_sha256=hashlib.sha256(config.encode()).hexdigest())[1]["result"]
        self.assertEqual(initial["status"], "Ready", initial)
        self.assertEqual(initial["evidence"]["next_intent_sequence"], 4)
        status, body = self.update_config(method="Rebuild")
        self.assertEqual(status, 200, body)
        self.assertTrue(body["ok"], body)
        result = body["result"]
        self.assertEqual(result["evidence"]["next_intent_sequence"], 4)
        state = self.checkpoint_state(result)
        self.assertEqual(state, dict(events=3, next_intent_sequence=4, window=[cursor], cycle_target=100,
                                     deadline=50, risk_latched=True))
        self.assertFalse(authority.request(dict(operation="status", strategy_identity=self.binding["strategy_identity"]))["trading_authorized"])
        self.instances.close()
        self.source.batches = (self.node_batch(result["evidence"]["cursor"], 1),)
        self.instances = strategy_instance.InstanceManager(self.root / "instances", self.manager, self.source)
        self.addCleanup(self.instances.close)
        self.app.instance_manager = self.instances
        recovered = self.recover()[1]["result"]
        self.assertEqual(recovered["status"], "Ready", recovered)
        self.assertEqual(recovered["binding"]["config_version"], 2)
        self.assertEqual(recovered["evidence"]["next_intent_sequence"], 4)

    def test_config_rejections_preserve_active_host_and_bind_version_content(self):
        authority = self.native_authority()
        self.install(transitions={"Keep": {"mutable_config_fields": [], "rebuild_state_fields": []}})
        self.assertEqual(self.create()[1]["result"]["status"], "Ready")
        self.assertEqual(self.instance_command("enable_trading")[0], 200)
        identity = self.binding["strategy_identity"]
        cursor = authority.request(dict(operation="status", strategy_identity=identity))["cursor"]
        self.source.batches = (self.node_batch(cursor, 1),)
        for method in ("Migrate", "bogus"):
            self.assertEqual(self.update_config(method=method)[0], 400)
        for method, config in (("Keep", '{"warmup_events":2}'), ("Rebuild", '{"warmup_events":1}')):
            status, body = self.update_config(version=2 if method == "Keep" else 3, config=config, method=method)
            self.assertEqual(status, 200, body)
            self.assertFalse(body["ok"], body)
            self.assertEqual(body["result"]["status"], "Trading", body)
            self.assertEqual(body["result"]["binding"]["config_version"], 1)
            self.assertEqual(body["result"]["config_transition"]["status"], "rejected")
            self.assertTrue(authority.request(dict(operation="status", strategy_identity=identity))["trading_authorized"])
        self.assertEqual(self.update_config(version=2, config='{"warmup_events":3}')[0], 400)

    def test_new_config_validate_rejects_insufficient_warmup_without_revocation(self):
        authority = self.native_authority()
        self.install(transitions={"Keep": {"mutable_config_fields": ["warmup_events"], "rebuild_state_fields": []}})
        self.assertEqual(self.create()[1]["result"]["status"], "Ready")
        status, body = self.update_config(config='{"warmup_events":2}')
        self.assertEqual(status, 200, body)
        self.assertFalse(body["ok"])
        self.assertEqual(body["result"]["status"], "Ready")
        self.assertIn("warmup data insufficient", body["result"]["config_transition"]["reason"])
        self.assertEqual(authority.request(dict(operation="status", strategy_identity=self.binding["strategy_identity"]))["config_version"], 1)

    def test_rebuild_cannot_reset_intent_sequence(self):
        self.native_authority()
        self.install(MANAGED_TRADER.replace(b'self.next_intent_sequence = state["next_intent_sequence"]',
            b'self.next_intent_sequence = 1 if self.required == 2 else state["next_intent_sequence"]'),
            state_fields=MANAGED_FIELDS,
            transitions={"Rebuild": {"mutable_config_fields": ["warmup_events"], "rebuild_state_fields": ["window"]}})
        self.assertEqual(self.create()[1]["result"]["status"], "Ready")
        status, body = self.update_config(config='{"warmup_events":2}', method="Rebuild")
        self.assertEqual(status, 200, body)
        self.assertFalse(body["ok"])
        self.assertEqual(body["result"]["status"], "Ready")
        self.assertEqual(body["result"]["binding"]["config_version"], 1)

    def test_live_order_blocks_cutover_and_revokes_without_clearing_history(self):
        authority = self.native_authority()
        self.install(TRADER, transitions={"Keep": {"mutable_config_fields": ["warmup_events"], "rebuild_state_fields": []}})
        self.assertEqual(self.create()[1]["result"]["status"], "Ready")
        self.assertEqual(self.instance_command("enable_trading")[0], 200)
        identity = self.binding["strategy_identity"]
        first = authority.request(dict(operation="status", strategy_identity=identity))["cursor"] + 1
        cursor = authority.request(dict(operation="advance"))["cursor"]
        self.assertEqual(self.instances.deliver(identity, self.node_batch(cursor, first))[0]["orders"], 1)
        cursor = authority.request(dict(operation="status", strategy_identity=identity))["cursor"]
        self.source.batches = (self.node_batch(cursor, 1),)
        status, body = self.update_config()
        self.assertEqual(status, 200, body)
        self.assertFalse(body["ok"])
        self.assertEqual(body["result"]["status"], "Stopped", body)
        self.assertIn("CutoverDrainIncomplete", body["result"]["reason"])
        native = authority.request(dict(operation="status", strategy_identity=identity))
        self.assertFalse(native["trading_authorized"])
        self.assertEqual(native["config_version"], 1)
        self.assertEqual(native["orders"], 1)
        self.assertEqual(self.recover()[0], 400)

    def test_rebuild_cannot_clear_retained_management_latch(self):
        self.native_authority()
        self.install(MANAGED_TRADER.replace(b'self.risk_latched = state["risk_latched"]',
            b'self.risk_latched = False if self.required == 2 else state["risk_latched"]'),
            state_fields=MANAGED_FIELDS,
            transitions={"Rebuild": {"mutable_config_fields": ["warmup_events"], "rebuild_state_fields": ["window"]}})
        self.assertEqual(self.create()[1]["result"]["status"], "Ready")
        status, body = self.update_config(config='{"warmup_events":2}', method="Rebuild")
        self.assertEqual(status, 200, body)
        self.assertFalse(body["ok"])
        self.assertEqual(body["result"]["status"], "Ready")
        self.assertIn("Rebuild lost management progress", body["result"]["config_transition"]["reason"])

    def test_interrupted_cutover_cannot_recover_the_old_config_as_current(self):
        self.native_authority()
        self.install()
        original = self.create()[1]["result"]
        self.assertEqual(original["status"], "Ready")
        self.instances.close()
        interrupted = dict(original, config_transition=dict(status="committing", to_version=2))
        with self.instances.path.open("ab") as handle:
            handle.write(canonical(interrupted) + b"\n")
        self.instances = strategy_instance.InstanceManager(self.root / "instances", self.manager, self.source)
        self.addCleanup(self.instances.close)
        self.app.instance_manager = self.instances
        status, body = self.client.call("GET", "/api/strategy-instances")
        self.assertEqual(status, 200, body)
        self.assertEqual(body["instances"][0]["config_transition"]["status"], "unknown")
        self.assertEqual(self.recover()[0], 400)

    def test_stale_candidate_barrier_does_not_revoke_the_active_host(self):
        authority = self.native_authority()
        self.install(transitions={"Keep": {"mutable_config_fields": ["warmup_events"], "rebuild_state_fields": []}})
        self.assertEqual(self.create()[1]["result"]["status"], "Ready")
        self.assertEqual(self.instance_command("enable_trading")[0], 200)
        identity = self.binding["strategy_identity"]
        old_cursor = authority.request(dict(operation="status", strategy_identity=identity))["cursor"]
        self.source.batches = (self.node_batch(old_cursor, 1),)
        authority.request(dict(operation="advance"))
        status, body = self.update_config()
        self.assertEqual(status, 200, body)
        self.assertFalse(body["ok"])
        self.assertEqual(body["result"]["status"], "Trading", body)
        self.assertEqual(body["result"]["config_transition"]["status"], "rejected")
        self.assertTrue(authority.request(dict(operation="status", strategy_identity=identity))["trading_authorized"])

    def test_current_host_checkpoint_failure_revokes_instead_of_preserving_trading(self):
        authority = self.native_authority()
        code = OBSERVER.replace(b'    def snapshot(self):', b'''    def snapshot(self):
        if self.events > 1:
            raise ValueError("checkpoint callback failed")''')
        self.install(code, transitions={"Keep": {"mutable_config_fields": ["warmup_events"], "rebuild_state_fields": []}})
        self.assertEqual(self.create()[1]["result"]["status"], "Ready")
        self.assertEqual(self.instance_command("enable_trading")[0], 200)
        identity = self.binding["strategy_identity"]
        first = authority.request(dict(operation="status", strategy_identity=identity))["cursor"] + 1
        cursor = authority.request(dict(operation="advance"))["cursor"]
        self.instances.deliver(identity, self.node_batch(cursor, first))
        self.source.batches = (self.node_batch(cursor, 1),)
        status, body = self.update_config()
        self.assertEqual(status, 200, body)
        self.assertFalse(body["ok"])
        self.assertEqual(body["result"]["status"], "Stopped", body)
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
        self.assert_complete_group()

    def test_hyperliquid_uses_existing_web_package_host_authority_and_revocation(self):
        self.assert_complete_group(hyperliquid=True)

    def assert_complete_group(self, hyperliquid=False):
        authority = self.native_authority(group=True, hyperliquid=hyperliquid)
        code = GROUP_TRADER.replace(b"False, 10, 10", b"False, 1, 10000") if hyperliquid else GROUP_TRADER
        self.install(code)
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

    def test_risk_warning_and_node_placement_still_reject_unbound_instance_authority(self):
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
        status, body = self.create(strategy_identity="0" * 30 + "11")
        if os.name == "nt":
            self.assertEqual(status, 200, body)
            self.assertEqual(body["result"]["status"], "Ready", body)
            self.binding["strategy_identity"] = "0" * 30 + "11"
            with self.assertRaisesRegex(ValueError, "StrategyIdentityMismatch"):
                self.instance_command("enable_trading")
        else:
            self.assertEqual(status, 400, body)
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
    def test_aggregate_job_limit_counts_all_member_processes(self):
        w = strategy_instance.windows
        job = w.Job(128 * 1024 * 1024, aggregate=True)
        processes = []
        try:
            for index in range(2):
                process = job.start([sys.executable, "-I", "-S", "-c",
                    "import sys\ntry:\n allocation=bytearray(80*1024*1024)\nexcept MemoryError:\n raise SystemExit(77)\nprint('allocated',flush=True)\nsys.stdin.read(1)"],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    env=w.environment(), close_fds=True)
                processes.append(process)
                if index == 0:
                    pipes = strategy_instance.CandidatePipes(process, job.terminate)
                    self.assertEqual(pipes.read(5), b"allocated\r\n")
                else:
                    self.assertEqual(process.wait(timeout=5), 77)
        finally:
            job.close()
            for process in processes:
                process.wait(timeout=5)
            if processes:
                pipes.close()
            for process in processes:
                process.close()

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
