"""Approved package Host; authority envelopes belong to the runtime adapter."""

import os
import sys

# -I -S excludes cwd, user/site packages and PYTHONPATH. Only the locked runtime
# directory is added; every file in it was authenticated by DeployRelease.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import hashlib
import importlib
import struct
from types import SimpleNamespace
from pathlib import Path

import strategy_api as api
import strategy_host as bridge
import strategy_package as package


def restrict(event, args):
    if event.startswith(("socket.", "subprocess.", "os.exec", "os.spawn", "os.posix_spawn",
                         "os.fork", "os.system", "os.startfile", "ctypes.dlopen")):
        raise PermissionError("candidate external action forbidden")
    if event == "open" and (isinstance(args[1], str) and any(c in args[1] for c in "wax+")
                            or args[2] & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC)):
        raise PermissionError("candidate filesystem is read-only")
    if event in ("os.remove", "os.rename", "os.rmdir", "os.mkdir", "os.chmod", "os.chown", "os.utime",
                 "os.link", "os.symlink", "os.truncate", "os.setxattr", "os.removexattr"):
        raise PermissionError("candidate filesystem is read-only")


def validated_snapshot(instance, manifest):
    expected_next = instance.next_intent_sequence
    state = instance.snapshot()
    package.require(type(state) is bytes and len(state) <= manifest["limits"]["max_private_state_bytes"],
                    "private state capacity or type")
    package.parse_json(state)
    package.require(instance.validate() is None and instance.snapshot() == state,
                    "validate changed private state")
    package.require(type(instance.next_intent_sequence) is int and instance.next_intent_sequence == expected_next,
                    "validate/snapshot changed IntentSequence")
    return state


def config_transition(root, manifest, old_binding, binding, method):
    """Only signed, explicit same-definition rules can authorize state reuse."""
    package.require(method in ("Keep", "Rebuild"), "unsupported transition; v1 rejects Migrate")
    contract = package.parse_json((root / manifest["config_schema"]["path"]).read_bytes())
    rules = contract.get("transitions", {}).get(method)
    package.fields(rules, {"mutable_config_fields", "rebuild_state_fields"})
    old = package.parse_json(old_binding["config_json"].encode("ascii"))
    new = package.parse_json(binding["config_json"].encode("ascii"))
    declared = {f["name"] for f in contract["fields"]}
    mutable, rebuilt = rules["mutable_config_fields"], rules["rebuild_state_fields"]
    package.require(type(mutable) is list and all(type(k) is str for k in mutable)
                    and len(set(mutable)) == len(mutable) and set(mutable) <= declared,
                    "invalid transition config dependency rules")
    package.require(type(old) is dict and type(new) is dict and old.keys() == new.keys() == declared,
                    "transition config dependencies mismatch")
    package.require(all(old[k] == new[k] for k in declared - set(mutable)), "incompatible config dependencies")
    state_contract = package.parse_json((root / manifest["state_schema"]["path"]).read_bytes())
    state_fields = {f["name"] for f in state_contract["fields"]}
    package.require(type(rebuilt) is list and all(type(k) is str for k in rebuilt)
                    and len(set(rebuilt)) == len(rebuilt) and set(rebuilt) <= state_fields,
                    "invalid rebuild state rules")
    package.require(set(rebuilt) <= {f["name"] for f in state_contract["fields"] if f.get("rebuildable") is True},
                    "Rebuild may change only explicitly rebuildable state")
    package.require(method != "Keep" or not rebuilt, "Keep cannot rebuild state")
    return state_fields, set(rebuilt)


def instance_frames(request):
    binding, manifest = request["binding"], request["manifest"]
    root = Path(request["package_root"]).resolve()
    config = binding["config_json"].encode("ascii")
    package.parse_json(config)
    package.require(hashlib.sha256(config).hexdigest() == binding["config_sha256"], "config digest mismatch")
    compatibility = manifest["compatibility"]
    package.require(compatibility["python_abi"] == bridge.PYTHON_ABI
                    and int(compatibility["host_build"], 16) == bridge.HOST_BUILD
                    and int(compatibility["schema_registry"], 16) == bridge.SCHEMA_REGISTRY
                    and compatibility["host_protocol"] == bridge.PROTOCOL, "runtime compatibility mismatch")
    module = importlib.import_module(manifest["entrypoint"].split(":")[0])
    package.require(os.path.commonpath((str(Path(module.__file__).resolve()), str(root / "code"))) == str(root / "code"),
                    "entrypoint resolved outside approved package")
    context = api.Context(binding["strategy_identity"], binding["definition_identity"], binding["config_version"],
                          binding["config_sha256"], binding["package_manifest_sha256"],
                          manifest["state_schema"]["identity"], manifest["state_schema"]["version"])
    for name in ("validate_config", "create"):
        package.require(callable(getattr(module, name, None)), "missing fixed API: " + name)
    kind, session, sequence, plan = yield
    package.require(kind == bridge.SESSION_PLAN and sequence == 1 and len(plan) == 176, "expected session plan")
    bridge.STRATEGY_MANIFEST = bytes.fromhex(request["strategy_manifest"])
    bridge.CHECKPOINT_MANIFEST = bytes.fromhex(request["checkpoint_manifest"])
    hello_session, hello = bridge.hello_payload(plan)
    package.require(hello_session == session, "plan session mismatch")
    bridge.write_frame(sys.stdout.buffer, bridge.HOST_HELLO, session, 1, hello)
    kind, actual, sequence, payload = yield
    package.require(kind == bridge.BEGIN_RECOVERY and actual == session and sequence == 2
                    and len(payload) >= 8, "expected initialization or checkpoint recovery")
    barrier = struct.unpack_from("<Q", payload)[0]
    package.require(module.validate_config(config) is None, "validate_config must return None")
    instance = module.create(context, config)
    for name in ("on_event", "snapshot", "restore", "validate"):
        package.require(callable(getattr(instance, name, None)), "missing fixed API: " + name)
    cursor = 0
    transition = request.get("transition")
    state_fields, rebuilt = (set(), set())
    if transition:
        state_fields, rebuilt = config_transition(root, manifest, request["previous_binding"], binding, transition)
    if request["recover"]:
        container = payload[8:]
        metadata, state = bridge.decode_payload_checkpoint(container)
        package.require(len(container) >= 192 and metadata == dict(
            schema_registry=bridge.SCHEMA_REGISTRY, strategy=int(context.strategy_identity, 16),
            definition=int(context.definition_identity, 16), state_schema=int(context.state_schema_identity, 16),
            state_schema_version=context.state_schema_version,
            config_version=request["previous_binding"]["config_version"] if transition else context.config_version,
            cursor=metadata["cursor"], next_intent=metadata["next_intent"])
                        and metadata["cursor"] >= request["checkpoint_cursor"], "checkpoint identity mismatch")
        package.require(len(state) <= manifest["limits"]["max_private_state_bytes"], "private state capacity")
        package.parse_json(state)
        package.require(instance.restore(state) is None and type(instance.next_intent_sequence) is int
                        and instance.next_intent_sequence == metadata["next_intent"], "checkpoint restore mismatch")
        restored_state = instance.snapshot()
        if transition == "Rebuild":
            old_state, new_state = package.parse_json(state), package.parse_json(restored_state)
            package.require(type(old_state) is dict and type(new_state) is dict
                            and old_state.keys() == new_state.keys() == state_fields,
                            "Rebuild state contract mismatch")
            package.require(all(old_state[k] == new_state[k] for k in state_fields - rebuilt),
                            "Rebuild lost management progress")
        else:
            package.require(restored_state == state, "checkpoint restore mismatch")
        cursor = metadata["cursor"]
    else:
        package.require(len(payload) == 8 and instance.next_intent_sequence == 1
                        and type(instance.next_intent_sequence) is int, "new instance must start IntentSequence at one")
    package.require(cursor <= barrier, "checkpoint exceeds recovery barrier")
    bridge.write_frame(sys.stdout.buffer, bridge.HOST_HEARTBEAT, session, 2, struct.pack("<QQ", cursor, 0))
    batch, incoming, outgoing, callbacks, suppressed = 1, 3, 3, 0, 0
    subscriptions = {(s["event_type"], s["schema_version"]) for s in manifest["subscriptions"]}
    while cursor < barrier:
        kind, actual, sequence, payload = yield
        package.require(kind == bridge.INPUT_BATCH and actual == session and sequence == incoming,
                        "invalid candidate input")
        records, last = bridge.decode_component_batch(payload, session, batch, cursor)
        package.require(last <= barrier and len(records) <= 1, "candidate requires bounded single-event batches")
        for record in records:
            package.require(len(record.payload) <= manifest["limits"]["max_input_record_bytes"], "input capacity exceeded")
            if (record.event_type, record.schema_version) not in subscriptions:
                continue
            before = instance.next_intent_sequence
            outputs = instance.on_event(api.Event(record.shard_sequence, record.event_type,
                                                  record.schema_version, record.payload))
            suppressed += api.validate_outputs(outputs, before, instance.next_intent_sequence, manifest, binding)
            callbacks += 1
            package.require(callbacks <= manifest["limits"]["max_warmup_events"], "warmup event budget exhausted")
        cursor, batch, incoming = last, batch + 1, incoming + 1
        bridge.write_frame(sys.stdout.buffer, bridge.HOST_HEARTBEAT, session, outgoing,
                           struct.pack("<QQ", cursor, suppressed))
        outgoing += 1
    expected_next = instance.next_intent_sequence
    state = validated_snapshot(instance, manifest)
    restored = module.create(context, config)
    package.require(restored.restore(state) is None and restored.snapshot() == state,
                    "private state restore roundtrip mismatch")
    package.require(restored.validate() is None
                    and type(restored.next_intent_sequence) is int
                    and restored.next_intent_sequence == expected_next, "snapshot IntentSequence mismatch")
    package.require(restored.snapshot() == state and restored.next_intent_sequence == expected_next,
                    "private state restore roundtrip mismatch")
    instance = restored
    # Use the existing StrategyStateDigest domain for the verified private bytes.
    recovered = bytearray(96)
    recovered[:16] = int(context.strategy_identity, 16).to_bytes(16, "little")
    struct.pack_into("<Q", recovered, 16, context.config_version)
    recovered[24:40] = int(context.state_schema_identity, 16).to_bytes(16, "little")
    struct.pack_into("<I4xQQ", recovered, 40, context.state_schema_version, cursor, instance.next_intent_sequence)
    recovered[64:] = bridge.payload_state_digest(dict(
        schema_registry=bridge.SCHEMA_REGISTRY, strategy=int(context.strategy_identity, 16),
        definition=int(context.definition_identity, 16), state_schema=int(context.state_schema_identity, 16),
        state_schema_version=context.state_schema_version, config_version=context.config_version,
        cursor=cursor, next_intent=instance.next_intent_sequence), state)
    bridge.write_frame(sys.stdout.buffer, bridge.STRATEGY_RECOVERED, session, outgoing, recovered)
    outgoing += 1
    kind, actual, sequence, payload = yield
    package.require(kind == bridge.REQUEST_CHECKPOINT and actual == session and sequence == incoming
                    and len(payload) == 16, "expected checkpoint request")
    checkpoint_request, checkpoint_cursor = struct.unpack("<QQ", payload)
    package.require(checkpoint_request > 0 and checkpoint_cursor == cursor, "checkpoint cursor mismatch")
    # The validated roundtrip above owns these exact bytes and sequence.
    container = bridge.encode_payload_checkpoint(dict(
        schema_registry=bridge.SCHEMA_REGISTRY, strategy=int(context.strategy_identity, 16),
        definition=int(context.definition_identity, 16), state_schema=int(context.state_schema_identity, 16),
        state_schema_version=context.state_schema_version, config_version=context.config_version,
        cursor=cursor, next_intent=expected_next), state)
    bridge.write_frame(sys.stdout.buffer, bridge.CHECKPOINT_CONTENT, session, outgoing,
                       struct.pack("<Q", checkpoint_request) + container)
    incoming, outgoing = incoming + 1, outgoing + 1
    activation, activation_barrier = 0, None
    while True:
        kind, actual, sequence, payload = yield
        package.require(actual == session and sequence == incoming, "invalid runtime session or sequence")
        incoming += 1
        if kind == bridge.REQUEST_CHECKPOINT:
            package.require(len(payload) == 16, "invalid checkpoint request")
            checkpoint_request, checkpoint_cursor = struct.unpack("<QQ", payload)
            package.require(checkpoint_request > 0 and checkpoint_cursor == cursor, "checkpoint cursor mismatch")
            state = validated_snapshot(instance, manifest)
            container = bridge.encode_payload_checkpoint(dict(
                schema_registry=bridge.SCHEMA_REGISTRY, strategy=int(context.strategy_identity, 16),
                definition=int(context.definition_identity, 16), state_schema=int(context.state_schema_identity, 16),
                state_schema_version=context.state_schema_version, config_version=context.config_version,
                cursor=cursor, next_intent=instance.next_intent_sequence), state)
            bridge.write_frame(sys.stdout.buffer, bridge.CHECKPOINT_CONTENT, session, outgoing,
                               struct.pack("<Q", checkpoint_request) + container)
            outgoing += 1
            continue
        if kind == bridge.SHUTDOWN:
            bridge.write_frame(sys.stdout.buffer, bridge.SHUTDOWN_ACK, session, outgoing)
            return
        if kind == bridge.ACTIVATE_STRATEGY:
            package.require(activation == 0 and len(payload) == 72
                            and int.from_bytes(payload[:16], "little") == int(context.strategy_identity, 16)
                            and int.from_bytes(payload[16:32], "little") > 0 and any(payload[40:]),
                            "invalid activation")
            activation = int.from_bytes(payload[16:32], "little")
            activation_barrier = struct.unpack_from("<Q", payload, 32)[0]
            package.require(activation_barrier > cursor, "activation barrier must follow Ready")
            continue
        package.require(kind == bridge.INPUT_BATCH, "invalid runtime input")
        records, last = bridge.decode_component_batch(payload, session, batch, cursor)
        package.require(len(records) <= 1, "runtime requires bounded single-event batches")
        frames = []
        for record in records:
            package.require(len(record.payload) <= manifest["limits"]["max_input_record_bytes"], "input capacity exceeded")
            if (record.event_type, record.schema_version) not in subscriptions:
                continue
            before = instance.next_intent_sequence
            outputs = instance.on_event(api.Event(record.shard_sequence, record.event_type,
                                                  record.schema_version, record.payload))
            api.validate_outputs(outputs, before, instance.next_intent_sequence, manifest, binding)
            if activation == 0 or record.shard_sequence <= activation_barrier:
                continue
            for output in outputs:
                members = (output,) if type(output) is api.OrderIntent else output.members
                encoded = []
                for member in members:
                    args = SimpleNamespace(strategy_identity=str(int(context.strategy_identity, 16)),
                        activation_identity=str(activation), config_version=context.config_version,
                        intent_sequence=member.intent_sequence, portfolio_identity=member.portfolio_identity,
                        exchange_account_identity=member.exchange_account_identity,
                        instrument_identity=member.instrument_identity, side=member.side,
                        time_in_force=member.time_in_force, portfolio_reduce_only=member.portfolio_reduce_only,
                        quantity=member.quantity, limit_price=member.limit_price)
                    encoded.append(bridge.output_frame(payload, args, session))
                frame = bytearray(encoded[0][:128] + b"".join(e[128:] for e in encoded))
                struct.pack_into("<I", frame, 12, len(frame))
                struct.pack_into("<HII", frame, 98, 1 if len(members) == 1 else 2, len(members), 80 * len(members))
                struct.pack_into("<I", frame, 124, bridge.crc32c(frame[:124] + frame[128:]))
                frames.append(bytes(frame))
        cursor, batch = last, batch + 1
        if activation == 0:
            validated_snapshot(instance, manifest)
        bridge.write_frame(sys.stdout.buffer, bridge.HOST_HEARTBEAT, session, outgoing,
                           struct.pack("<QQ", cursor, len(frames)))
        outgoing += 1
        for frame in frames:
            bridge.write_frame(sys.stdout.buffer, bridge.STRATEGY_OUTPUT, session, outgoing, frame)
            outgoing += 1


def run(request_path):
    request = package.parse_json(Path(request_path).read_bytes())
    requests = request.get("instances", [request])
    package.require(1 <= len(requests) <= 16, "Host instance capacity exceeded")
    strategy_manifest, checkpoint_manifest = package.host_manifests(requests)
    # Package-local module tables are switched with the callback, including lazy imports.
    # This is trusted-code organization, not a hostile-plugin security boundary.
    baseline = dict(sys.modules)
    runtime_path = list(sys.path)
    sessions = {}
    sys.addaudithook(restrict)
    for item in requests:
        package.require(item["strategy_manifest"] == strategy_manifest
                        and item["checkpoint_manifest"] == checkpoint_manifest, "Host aggregate manifest mismatch")
        session = (item["fencing"], item["shard"], item["generation"])
        package.require(session not in sessions, "duplicate Host session")
        sessions[session] = (instance_frames(item), {}, item)
    while sessions:
        frame = bridge.read_frame(sys.stdin.buffer)
        package.require(frame[1] in sessions, "unknown Host session")
        coroutine, modules, item = sessions[frame[1]]
        for name in set(sys.modules) - baseline.keys():
            del sys.modules[name]
        sys.modules.update(modules)
        sys.path[:] = [str(Path(item["package_root"]) / "code"), *runtime_path]
        try:
            if frame[0] == bridge.SESSION_PLAN:
                package.require(not modules, "duplicate session plan")
                next(coroutine)
            coroutine.send(frame)
        except StopIteration:
            del sessions[frame[1]]
        finally:
            modules.update((k, v) for k, v in sys.modules.items() if k not in baseline)


if __name__ == "__main__":
    # argv is supplied by ManagedHost, never a Web-provided command line.
    try:
        package.require(sys.argv[1:3] == ["--mode", "candidate"] and len(sys.argv) == 4, "invalid Host arguments")
        run(sys.argv[3])
    except Exception as error:
        print(type(error).__name__ + ": " + str(error)[:512], file=sys.stderr, flush=True)
        raise SystemExit(1)
