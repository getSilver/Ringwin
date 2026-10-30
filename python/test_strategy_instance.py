"""Real candidate Host acceptance through the authenticated Web boundary."""

import hashlib
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

    def install(self, code=OBSERVER, limit_changes=None):
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
                    dict(name="next_intent_sequence", type="u64", unit="intent_sequence", minimum=1, maximum=2**64 - 1)],
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
