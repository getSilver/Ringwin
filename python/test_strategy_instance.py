"""Real candidate Host acceptance through the authenticated Web boundary."""

import hashlib
import json
import os
from pathlib import Path
import struct
import sys
import unittest

import strategy_host
import strategy_instance
import test_strategy_package_release as package_release
from test_strategy_package_release import DEFINITION, bundle_files, canonical, descriptor, write_bundle


ROOT = Path(__file__).resolve().parents[1]


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
        raise ValueError("new instance only")

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
    struct.pack_into("<QQqII", batch, 80, sequence, sequence, 0, 1, len(batch) - 128)
    struct.pack_into("<IIHHIQ", batch, 128, len(batch) - 128, len(payload), 7, 1, 0, sequence)
    batch[192:] = payload
    return bytes(batch)


@unittest.skipIf(os.name == "nt", "candidate Linux memory adapter is independently verified under WSL/Linux")
class WebInstanceTests(unittest.TestCase):
    deploy = package_release.PackageReleaseTests.deploy

    def setUp(self):
        package_release.PackageReleaseTests.setUp(self)
        self.engine = Path(os.environ.get("RINGWIN_CANDIDATE_ENGINE", ROOT / ".scratch/build/candidate-linux/bin/ringwin-strategy-candidate"))
        self.assertTrue(self.engine.is_file(), "build the Linux candidate engine before running this acceptance")
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
                   "runtime/ringwin-strategy-candidate": self.engine.read_bytes(),
                   "runtime/python": Path(sys.executable).resolve().read_bytes()}
        for name in ("strategy_candidate_host.py", "strategy_api.py", "strategy_host.py", "strategy_package.py", "strategy_state.py"):
            runtime["runtime/" + name] = (ROOT / "python" / name).read_bytes()
        compatibility = dict(policy["compatibility"])
        compatibility.pop("runtime_lock_sha256")
        compatibility["python_abi"] = strategy_host.PYTHON_ABI
        lock = canonical(dict(format_version=1, compatibility=compatibility,
                              python_path="runtime/python", host_path="runtime/strategy_candidate_host.py",
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
        self.assertEqual(self.deploy(write_bundle(self.root, "candidate-a", files))["status"], "activated")
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
            scope="offline signed bundle + real Linux Host; synthetic canonical depth input"), sort_keys=True))

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
        runtime.chmod(0o640)
        runtime.write_bytes(b"raise RuntimeError('unapproved')")
        status, body = self.create()
        self.assertEqual(status, 400, body)
        self.assertIn("differs from approved bytes", body["error"])
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


if __name__ == "__main__":
    unittest.main()
