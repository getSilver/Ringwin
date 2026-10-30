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


def run(request_path):
    request = package.parse_json(Path(request_path).read_bytes())
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
    sys.path.insert(0, str(root / "code"))
    sys.addaudithook(restrict)
    module = importlib.import_module(manifest["entrypoint"].split(":")[0])
    package.require(os.path.commonpath((str(Path(module.__file__).resolve()), str(root / "code"))) == str(root / "code"),
                    "entrypoint resolved outside approved package")
    context = api.Context(binding["strategy_identity"], binding["definition_identity"], binding["config_version"],
                          binding["config_sha256"], binding["package_manifest_sha256"],
                          manifest["state_schema"]["identity"], manifest["state_schema"]["version"])
    for name in ("validate_config", "create"):
        package.require(callable(getattr(module, name, None)), "missing fixed API: " + name)
    kind, session, sequence, plan = bridge.read_frame(sys.stdin.buffer)
    package.require(kind == bridge.SESSION_PLAN and sequence == 1 and len(plan) == 176, "expected session plan")
    bridge.STRATEGY_MANIFEST = bytes.fromhex(binding["package_manifest_sha256"])
    bridge.CHECKPOINT_MANIFEST = bytes.fromhex(binding["config_sha256"])
    hello_session, hello = bridge.hello_payload(plan)
    package.require(hello_session == session, "plan session mismatch")
    bridge.write_frame(sys.stdout.buffer, bridge.HOST_HELLO, session, 1, hello)
    kind, actual, sequence, payload = bridge.read_frame(sys.stdin.buffer)
    package.require(kind == bridge.BEGIN_RECOVERY and actual == session and sequence == 2
                    and len(payload) >= 8, "expected initialization or checkpoint recovery")
    barrier = struct.unpack_from("<Q", payload)[0]
    package.require(module.validate_config(config) is None, "validate_config must return None")
    instance = module.create(context, config)
    for name in ("on_event", "snapshot", "restore", "validate"):
        package.require(callable(getattr(instance, name, None)), "missing fixed API: " + name)
    cursor = 0
    if request["recover"]:
        container = payload[8:]
        metadata, state = bridge.decode_payload_checkpoint(container)
        package.require(len(container) >= 192 and metadata == dict(
            schema_registry=bridge.SCHEMA_REGISTRY, strategy=int(context.strategy_identity, 16),
            definition=int(context.definition_identity, 16), state_schema=int(context.state_schema_identity, 16),
            state_schema_version=context.state_schema_version, config_version=context.config_version,
            cursor=metadata["cursor"], next_intent=metadata["next_intent"])
                        and metadata["cursor"] >= request["checkpoint_cursor"], "checkpoint identity mismatch")
        package.require(len(state) <= manifest["limits"]["max_private_state_bytes"], "private state capacity")
        package.parse_json(state)
        package.require(instance.restore(state) is None and instance.snapshot() == state
                        and type(instance.next_intent_sequence) is int
                        and instance.next_intent_sequence == metadata["next_intent"], "checkpoint restore mismatch")
        cursor = metadata["cursor"]
    else:
        package.require(len(payload) == 8 and instance.next_intent_sequence == 1
                        and type(instance.next_intent_sequence) is int, "new instance must start IntentSequence at one")
    package.require(cursor <= barrier, "checkpoint exceeds recovery barrier")
    bridge.write_frame(sys.stdout.buffer, bridge.HOST_HEARTBEAT, session, 2, struct.pack("<QQ", cursor, 0))
    batch, incoming, outgoing, callbacks, suppressed = 1, 3, 3, 0, 0
    subscriptions = {(s["event_type"], s["schema_version"]) for s in manifest["subscriptions"]}
    while cursor < barrier:
        kind, actual, sequence, payload = bridge.read_frame(sys.stdin.buffer)
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
    kind, actual, sequence, payload = bridge.read_frame(sys.stdin.buffer)
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
        kind, actual, sequence, payload = bridge.read_frame(sys.stdin.buffer)
        package.require(actual == session and sequence == incoming, "invalid runtime session or sequence")
        incoming += 1
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


if __name__ == "__main__":
    # argv is supplied by ManagedHost, never a Web-provided command line.
    try:
        package.require(sys.argv[1:3] == ["--mode", "candidate"] and len(sys.argv) == 4, "invalid Host arguments")
        run(sys.argv[3])
    except Exception as error:
        print(type(error).__name__ + ": " + str(error)[:512], file=sys.stderr, flush=True)
        raise SystemExit(1)
