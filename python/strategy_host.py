"""Minimal StrategyHost lifecycle process. Trading logic arrives in later tickets."""

import argparse
import ctypes
import gc
import hashlib
import json
import struct
import sys
import time

MAGIC = b"QSHC"
HEADER_LEN = 64
PROTOCOL = 1
SCHEMA_REGISTRY = 0x0102030405060708090A0B0C0D0E0F10
HOST_BUILD = 0x1112131415161718191A1B1C1D1E1F20
STRATEGY_MANIFEST = b"\x31" * 32
CHECKPOINT_MANIFEST = b"\x42" * 32
PYTHON_ABI = (sys.version_info.major << 16) | (sys.version_info.minor << 8)

SESSION_PLAN = 1
BEGIN_RECOVERY = 2
ACTIVATE_STRATEGY = 3
SHUTDOWN = 6
HOST_HELLO = 101
STRATEGY_RECOVERED = 102
STRATEGY_FAULTED = 103
RECOVERY_REQUIRED = 104
HOST_HEARTBEAT = 106
SHUTDOWN_ACK = 107
QSH_OK = 0
QSH_EMPTY = 1
QSH_FULL = 2
QSH_STALE = 3


class RecoveryNeeded(RuntimeError):
    def __init__(self, reason, last_batch=0, last_cursor=0):
        super().__init__(f"recovery required: {reason}")
        self.reason = reason
        self.last_batch = last_batch
        self.last_cursor = last_cursor


class QshBuffer(ctypes.Structure):
    _fields_ = [
        ("data", ctypes.POINTER(ctypes.c_ubyte)),
        ("len", ctypes.c_uint32),
        ("reserved", ctypes.c_uint32),
    ]


def crc32c(data):
    crc = 0xFFFFFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ (0x82F63B78 if crc & 1 else 0)
    return crc ^ 0xFFFFFFFF


def read_exact(stream, size):
    chunks = bytearray()
    while len(chunks) != size:
        chunk = stream.read(size - len(chunks))
        if not chunk:
            raise EOFError
        chunks.extend(chunk)
    return bytes(chunks)


def read_frame(stream):
    frame_len = struct.unpack("<I", read_exact(stream, 4))[0]
    if frame_len < HEADER_LEN or frame_len > HEADER_LEN + 65_536:
        raise ValueError("invalid control frame length")
    frame = read_exact(stream, frame_len)
    if frame[:4] != MAGIC:
        raise ValueError("invalid control magic")
    version, header_len, _, schema_version = struct.unpack_from("<HHHH", frame, 4)
    flags, total_len, payload_len = struct.unpack_from("<III", frame, 12)
    if (
        version != PROTOCOL
        or header_len != HEADER_LEN
        or schema_version != 1
        or flags != 0
        or total_len != frame_len
        or payload_len != frame_len - HEADER_LEN
        or struct.unpack_from("<I", frame, 36)[0] != 0
        or crc32c(frame[HEADER_LEN:]) != struct.unpack_from("<I", frame, 56)[0]
        or crc32c(frame[:60]) != struct.unpack_from("<I", frame, 60)[0]
    ):
        raise ValueError("invalid control frame")
    session = (
        struct.unpack_from("<Q", frame, 24)[0],
        struct.unpack_from("<I", frame, 32)[0],
        struct.unpack_from("<Q", frame, 40)[0],
    )
    return struct.unpack_from("<H", frame, 8)[0], session, struct.unpack_from("<Q", frame, 48)[0], frame[64:]


def write_frame(stream, message_type, session, sequence, payload=b""):
    frame = bytearray(HEADER_LEN + len(payload))
    frame[:4] = MAGIC
    struct.pack_into("<HHHHIII", frame, 4, PROTOCOL, HEADER_LEN, message_type, 1, 0, len(frame), len(payload))
    struct.pack_into("<QIIQQ", frame, 24, session[0], session[1], 0, session[2], sequence)
    struct.pack_into("<I", frame, 56, crc32c(payload))
    struct.pack_into("<I", frame, 60, crc32c(frame[:60]))
    frame[64:] = payload
    stream.write(struct.pack("<I", len(frame)))
    stream.write(frame)
    stream.flush()


def hello_payload(plan_payload):
    session = (
        struct.unpack_from("<Q", plan_payload, 48)[0],
        struct.unpack_from("<I", plan_payload, 56)[0],
        struct.unpack_from("<Q", plan_payload, 64)[0],
    )
    payload = bytearray(160)
    payload[0:16] = HOST_BUILD.to_bytes(16, "little")
    payload[16:32] = SCHEMA_REGISTRY.to_bytes(16, "little")
    struct.pack_into("<QIHHQI", payload, 32, session[0], session[1], PROTOCOL, 0, session[2], PYTHON_ABI)
    payload[64:96] = STRATEGY_MANIFEST
    payload[96:128] = CHECKPOINT_MANIFEST
    payload[128:160] = hashlib.sha256(plan_payload).digest()
    return session, bytes(payload)


def output_frame(batch, args, session, intent_sequence=None):
    source_batch = struct.unpack_from("<Q", batch, 72)[0]
    strategy_cursor = struct.unpack_from("<Q", batch, 88)[0]
    schema_registry = int.from_bytes(batch[16:32], "little")
    strategy_identity = int(args.strategy_identity, 0)
    activation_identity = int(args.activation_identity, 0)
    frame = bytearray(208)
    frame[:4] = b"QSHO"
    struct.pack_into("<HHII", frame, 4, 1, 128, 0, len(frame))
    frame[16:32] = schema_registry.to_bytes(16, "little")
    struct.pack_into("<QIIQ", frame, 32, session[0], session[1], 0, session[2])
    struct.pack_into("<Q", frame, 56, source_batch)
    frame[64:80] = strategy_identity.to_bytes(16, "little")
    struct.pack_into("<QQHHII", frame, 80, strategy_cursor, args.config_version, 1, 1, 1, 80)
    frame[108:124] = activation_identity.to_bytes(16, "little")
    struct.pack_into("<HBBBBH", frame, 128, 1, 1, 1, 1, 0, 0)
    struct.pack_into("<Q", frame, 136, args.intent_sequence if intent_sequence is None else intent_sequence)
    frame[144:160] = (1).to_bytes(16, "little")
    frame[160:176] = (2).to_bytes(16, "little")
    frame[176:192] = (3).to_bytes(16, "little")
    struct.pack_into("<qq", frame, 192, args.quantity, args.limit_price)
    struct.pack_into("<I", frame, 124, crc32c(frame[:124] + frame[128:]))
    return bytes(frame)


def benchmark_frame(batch, session, callbacks, disabled, checksum):
    payload = struct.pack("<IIIq", callbacks, disabled, 0, checksum)
    frame = bytearray(128 + len(payload))
    frame[:4] = b"QSHO"
    struct.pack_into("<HHII", frame, 4, 1, 128, 0, len(frame))
    frame[16:32] = int.from_bytes(batch[16:32], "little").to_bytes(16, "little")
    struct.pack_into("<QIIQ", frame, 32, session[0], session[1], 0, session[2])
    struct.pack_into("<Q", frame, 56, struct.unpack_from("<Q", batch, 72)[0])
    frame[64:80] = (1).to_bytes(16, "little")
    struct.pack_into("<QQHHII", frame, 80, struct.unpack_from("<Q", batch, 88)[0], 1, 2, 1, 1, len(payload))
    frame[108:124] = (0).to_bytes(16, "little")
    frame[128:] = payload
    struct.pack_into("<I", frame, 124, crc32c(frame[:124] + frame[128:]))
    return bytes(frame)


def open_trade_bridge(args, session):
    if not args.bridge:
        raise ValueError("trade mode requires --bridge")
    bridge = ctypes.CDLL(args.bridge)
    bridge.qsh_open_v1.argtypes = [
        ctypes.c_size_t,
        ctypes.c_size_t,
        ctypes.c_uint64,
        ctypes.c_uint32,
        ctypes.c_uint64,
        ctypes.POINTER(ctypes.c_void_p),
    ]
    bridge.qsh_open_v1.restype = ctypes.c_int32
    bridge.qsh_read_input_v1.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_ubyte),
        ctypes.c_uint32,
        ctypes.POINTER(ctypes.c_uint32),
    ]
    bridge.qsh_read_input_v1.restype = ctypes.c_int32
    bridge.qsh_publish_many_v1.argtypes = [ctypes.c_void_p, ctypes.POINTER(QshBuffer), ctypes.c_uint32]
    bridge.qsh_publish_many_v1.restype = ctypes.c_int32
    bridge.qsh_close_v1.argtypes = [ctypes.c_void_p]

    handle = ctypes.c_void_p()
    status = bridge.qsh_open_v1(
        int(args.input_mapping),
        int(args.output_mapping),
        session[0],
        session[1],
        session[2],
        ctypes.byref(handle),
    )
    if status != QSH_OK:
        raise RuntimeError(f"qsh_open_v1={status}")
    return bridge, handle


def read_input(bridge, handle):
    storage = bytearray(1_048_576)
    view = (ctypes.c_ubyte * len(storage)).from_buffer(storage)
    length = ctypes.c_uint32()
    while True:
        status = bridge.qsh_read_input_v1(handle, view, len(storage), ctypes.byref(length))
        if status == QSH_OK:
            return bytes(storage[: length.value])
        if status != QSH_EMPTY:
            raise RecoveryNeeded(1 if status == QSH_STALE else 2)
        time.sleep(0)


def publish_intent(bridge, handle, frame):
    frame_storage = ctypes.create_string_buffer(frame)
    descriptor = QshBuffer(
        ctypes.cast(frame_storage, ctypes.POINTER(ctypes.c_ubyte)),
        len(frame),
        0,
    )
    status = bridge.qsh_publish_many_v1(handle, ctypes.byref(descriptor), 1)
    if status == QSH_FULL:
        raise RecoveryNeeded(3)
    if status != QSH_OK:
        raise RecoveryNeeded(2)


def validate_batch_schema(batch):
    if int.from_bytes(batch[16:32], "little") != SCHEMA_REGISTRY:
        raise RecoveryNeeded(2)
    offset = 128
    while offset < len(batch):
        record_len, _, event_type, schema_version = struct.unpack_from("<IIHH", batch, offset)
        if event_type not in range(1, 7) or schema_version != 1:
            raise RecoveryNeeded(2)
        offset += record_len


def trade_once(args, session, bridge, handle):
    try:
        for index in range(args.trade_batches):
            batch = read_input(bridge, handle)
            validate_batch_schema(batch)
            frame = output_frame(batch, args, session, args.intent_sequence + index)
            try:
                publish_intent(bridge, handle, frame)
            except RecoveryNeeded as failure:
                failure.last_batch = struct.unpack_from("<Q", batch, 72)[0]
                failure.last_cursor = struct.unpack_from("<Q", batch, 88)[0]
                raise
    finally:
        bridge.qsh_close_v1(handle)


def benchmark_once(args, session, bridge, handle):
    states = [index + 1 for index in range(args.benchmark_strategies)]
    active = [True] * args.benchmark_strategies
    storage = bytearray(1_048_576)
    view = (ctypes.c_ubyte * len(storage)).from_buffer(storage)
    length = ctypes.c_uint32()
    try:
        for batch_index in range(args.benchmark_batches):
            empty_polls = 0
            while True:
                status = bridge.qsh_read_input_v1(handle, view, len(storage), ctypes.byref(length))
                if status == QSH_OK:
                    break
                if status != QSH_EMPTY:
                    raise RecoveryNeeded(1 if status == QSH_STALE else 2)
                empty_polls += 1
                if empty_polls % 16 == 0:
                    time.sleep(0)
            batch = memoryview(storage)[: length.value]
            validate_batch_schema(batch)
            callbacks = 0
            event_count = struct.unpack_from("<I", batch, 104)[0]
            if args.benchmark_perturbed and args.benchmark_scenario == "gc_exception":
                if batch_index % 250 == 0:
                    gc.collect()
                if batch_index == 50:
                    try:
                        raise RuntimeError("representative strategy failure")
                    except RuntimeError:
                        active[0] = False
            for event_index in range(event_count):
                for index, enabled in enumerate(active):
                    if not enabled:
                        continue
                    value = states[index]
                    value = (
                        value * 1_103_515_245 + batch_index + event_index + index
                    ) & 0x7FFFFFFF
                    if args.benchmark_perturbed and args.benchmark_scenario == "recovery":
                        for replay in range(8):
                            value = (value * 33 + replay) & 0x7FFFFFFF
                    states[index] = value
                    callbacks += 1
            if args.benchmark_perturbed and args.benchmark_scenario == "slow":
                value = states[-1]
                for spin in range(20_000):
                    value = (value * 33 + spin) & 0x7FFFFFFF
                states[-1] = value
            publish_intent(
                bridge,
                handle,
                benchmark_frame(batch, session, callbacks, active.count(False), sum(states)),
            )
    finally:
        bridge.qsh_close_v1(handle)


def decode_checkpoint(container):
    if (
        len(container) < 192
        or len(container) > 192 + 8 * 1024 * 1024
        or container[:4] != b"QSSC"
        or struct.unpack_from("<HHII", container, 4) != (1, 192, 0, len(container))
        or struct.unpack_from("<HH", container, 84) != (1, 0)
        or struct.unpack_from("<I", container, 112)[0] != len(container) - 192
        or any(container[152:188])
        or crc32c(container[:188]) != struct.unpack_from("<I", container, 188)[0]
    ):
        raise ValueError("invalid checkpoint header")
    payload = container[192:]
    if (
        crc32c(payload) != struct.unpack_from("<I", container, 116)[0]
        or hashlib.sha256(container[:120] + payload).digest() != container[120:152]
    ):
        raise ValueError("invalid checkpoint content")
    state = json.loads(payload)
    if (
        not isinstance(state, dict)
        or list(state) != ["accumulator", "event_count"]
        or isinstance(state["accumulator"], bool)
        or not isinstance(state["accumulator"], int)
        or not -(1 << 63) <= state["accumulator"] < (1 << 63)
        or isinstance(state["event_count"], bool)
        or not isinstance(state["event_count"], int)
        or not 0 <= state["event_count"] < (1 << 64)
    ):
        raise ValueError("invalid portable state")
    canonical = (
        f'{{"accumulator":{state["accumulator"]},"event_count":{state["event_count"]}}}'.encode()
    )
    if canonical != payload:
        raise ValueError("non-canonical portable state")
    metadata = {
        "schema_registry": int.from_bytes(container[16:32], "little"),
        "strategy": int.from_bytes(container[32:48], "little"),
        "definition": int.from_bytes(container[48:64], "little"),
        "state_schema": int.from_bytes(container[64:80], "little"),
        "state_schema_version": struct.unpack_from("<I", container, 80)[0],
        "config_version": struct.unpack_from("<Q", container, 88)[0],
        "cursor": struct.unpack_from("<Q", container, 96)[0],
        "next_intent": struct.unpack_from("<Q", container, 104)[0],
    }
    if metadata["next_intent"] == 0:
        raise ValueError("invalid next intent sequence")
    return metadata, state


def state_digest(metadata, state):
    payload = f'{{"accumulator":{state["accumulator"]},"event_count":{state["event_count"]}}}'.encode()
    body = bytearray(b"QSSD\x01")
    for key in ("schema_registry", "strategy", "definition", "state_schema"):
        body.extend(metadata[key].to_bytes(16, "little"))
    body.extend(struct.pack(
        "<IQQQI",
        metadata["state_schema_version"],
        metadata["config_version"],
        metadata["cursor"],
        metadata["next_intent"],
        len(payload),
    ))
    body.extend(payload)
    return hashlib.sha256(body).digest()


def apply_replay_batch(batch, metadata, state, allow_output):
    validate_batch_schema(batch)
    first, last = struct.unpack_from("<QQ", batch, 80)
    if first != metadata["cursor"] + 1:
        raise ValueError("strategy cursor gap")
    offset = 128
    output_sequences = []
    previous_sequence = None
    while offset < len(batch):
        record_len, payload_len, event_type, schema_version = struct.unpack_from("<IIHH", batch, offset)
        sequence = struct.unpack_from("<Q", batch, offset + 16)[0]
        payload = batch[offset + 64 : offset + 64 + payload_len]
        if (
            event_type not in range(1, 7)
            or schema_version != 1
            or payload_len != 9
            or sequence < first
            or sequence > last
            or (previous_sequence is not None and sequence <= previous_sequence)
        ):
            raise ValueError("invalid replay event")
        delta = struct.unpack_from("<q", payload)[0]
        emits = payload[8]
        if emits not in (0, 1):
            raise ValueError("invalid replay event")
        accumulator = state["accumulator"] + delta
        event_count = state["event_count"] + 1
        if not -(1 << 63) <= accumulator < (1 << 63) or event_count >= 1 << 64:
            raise OverflowError("portable state overflow")
        state["accumulator"] = accumulator
        state["event_count"] = event_count
        previous_sequence = sequence
        if emits:
            if metadata["next_intent"] == (1 << 64) - 1:
                raise OverflowError("intent sequence overflow")
            if allow_output:
                output_sequences.append(metadata["next_intent"])
            metadata["next_intent"] += 1
        offset += record_len
    if offset != len(batch):
        raise ValueError("invalid replay coverage")
    metadata["cursor"] = last
    return output_sequences


def recovery_once(args, session, bridge, handle, control_sequence, fault_strategy):
    try:
        message_type, received_session, sequence, payload = read_frame(sys.stdin.buffer)
        if message_type != BEGIN_RECOVERY or received_session != session or sequence != 2 or len(payload) < 200:
            raise ValueError("expected BeginRecovery v1")
        barrier = struct.unpack_from("<Q", payload)[0]
        metadata, state = decode_checkpoint(payload[8:])
        if (
            metadata["schema_registry"] != SCHEMA_REGISTRY
            or metadata["strategy"] != int(args.strategy_identity, 0)
            or metadata["config_version"] != args.config_version
        ):
            raise ValueError("checkpoint identity mismatch")
        while metadata["cursor"] < barrier:
            if apply_replay_batch(read_input(bridge, handle), metadata, state, False):
                raise AssertionError("recovery emitted intent")
        if metadata["cursor"] != barrier:
            raise ValueError("recovery crossed barrier")
        digest = state_digest(metadata, state)
        recovered = bytearray(96)
        recovered[0:16] = metadata["strategy"].to_bytes(16, "little")
        struct.pack_into("<Q", recovered, 16, metadata["config_version"])
        recovered[24:40] = metadata["state_schema"].to_bytes(16, "little")
        struct.pack_into(
            "<I4xQQ",
            recovered,
            40,
            metadata["state_schema_version"],
            metadata["cursor"],
            metadata["next_intent"],
        )
        recovered[64:96] = digest
        write_frame(sys.stdout.buffer, STRATEGY_RECOVERED, session, control_sequence[0], recovered)
        control_sequence[0] += 1

        message_type, received_session, sequence, activation = read_frame(sys.stdin.buffer)
        if message_type != ACTIVATE_STRATEGY or received_session != session or sequence != 3 or len(activation) != 72:
            raise ValueError("expected ActivateStrategy v1")
        strategy = int.from_bytes(activation[0:16], "little")
        activation_identity = int.from_bytes(activation[16:32], "little")
        activation_barrier = struct.unpack_from("<Q", activation, 32)[0]
        if (
            strategy != metadata["strategy"]
            or activation_identity != int(args.activation_identity, 0)
            or activation_barrier < metadata["cursor"]
            or activation[40:72] != digest
        ):
            raise ValueError("invalid activation")
        while metadata["cursor"] < activation_barrier:
            if apply_replay_batch(read_input(bridge, handle), metadata, state, False):
                raise AssertionError("catch-up emitted intent")
        while True:
            batch = read_input(bridge, handle)
            if fault_strategy:
                diagnostic = b"fixture callback exception"
                fault = bytearray(40 + len(diagnostic))
                fault[0:16] = fault_strategy.to_bytes(16, "little")
                struct.pack_into(
                    "<HHIQIHH",
                    fault,
                    16,
                    1,
                    1,
                    0,
                    metadata["cursor"],
                    0,
                    len(diagnostic),
                    0,
                )
                fault[40:] = diagnostic
                write_frame(
                    sys.stdout.buffer,
                    STRATEGY_FAULTED,
                    session,
                    control_sequence[0],
                    fault,
                )
                control_sequence[0] += 1
            sequences = apply_replay_batch(batch, metadata, state, True)
            if sequences:
                try:
                    publish_intent(bridge, handle, output_frame(batch, args, session, sequences[0]))
                except RecoveryNeeded as failure:
                    failure.last_batch = struct.unpack_from("<Q", batch, 72)[0]
                    failure.last_cursor = metadata["cursor"]
                    raise
                break
    finally:
        bridge.qsh_close_v1(handle)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--mode",
        choices=("normal", "crash", "hang", "trade", "recovery", "strategy-fault", "benchmark"),
        default="normal",
    )
    parser.add_argument("--input-mapping", required=True)
    parser.add_argument("--output-mapping", required=True)
    parser.add_argument("--bridge")
    parser.add_argument("--strategy-identity")
    parser.add_argument("--activation-identity")
    parser.add_argument("--fault-strategy-identity")
    parser.add_argument("--config-version", type=int, default=1)
    parser.add_argument("--intent-sequence", type=int, default=1)
    parser.add_argument("--trade-batches", type=int, default=1)
    parser.add_argument("--quantity", type=int, default=100)
    parser.add_argument("--limit-price", type=int, default=50_100_000_000)
    parser.add_argument("--benchmark-strategies", type=int, default=25)
    parser.add_argument("--benchmark-batches", type=int, default=10_500)
    parser.add_argument(
        "--benchmark-scenario",
        choices=("normal", "gc_exception", "slow", "recovery"),
        default="normal",
    )
    parser.add_argument("--benchmark-perturbed", action="store_true")
    args = parser.parse_args()
    if args.trade_batches <= 0:
        raise ValueError("trade batches must be positive")
    if args.benchmark_strategies <= 0 or args.benchmark_batches <= 0:
        raise ValueError("benchmark dimensions must be positive")
    # Handles are intentionally opaque here; the bridge opens them when the data plane is integrated.
    int(args.input_mapping)
    int(args.output_mapping)

    message_type, session, sequence, plan = read_frame(sys.stdin.buffer)
    if message_type != SESSION_PLAN or sequence != 1 or len(plan) != 176:
        raise ValueError("expected SessionPlan v1")
    session, hello = hello_payload(plan)
    write_frame(sys.stdout.buffer, HOST_HELLO, session, 1, hello)
    if args.mode == "crash":
        return 23

    trade_bridge = None
    if args.mode in ("trade", "recovery", "strategy-fault", "benchmark"):
        if args.mode != "benchmark" and (not args.strategy_identity or not args.activation_identity):
            raise ValueError("data mode requires strategy and activation identities")
        trade_bridge = open_trade_bridge(args, session)
    write_frame(sys.stdout.buffer, HOST_HEARTBEAT, session, 2, struct.pack("<QQ", 0, 0))
    if args.mode == "hang":
        while True:
            time.sleep(60)
    control_sequence = [3]
    try:
        if args.mode == "trade":
            trade_once(args, session, *trade_bridge)
        elif args.mode in ("recovery", "strategy-fault"):
            fault_strategy = (
                int(args.fault_strategy_identity, 0)
                if args.mode == "strategy-fault" and args.fault_strategy_identity
                else 0
            )
            if args.mode == "strategy-fault" and not fault_strategy:
                raise ValueError("strategy-fault mode requires fault strategy identity")
            recovery_once(args, session, *trade_bridge, control_sequence, fault_strategy)
        elif args.mode == "benchmark":
            benchmark_once(args, session, *trade_bridge)
    except RecoveryNeeded as failure:
        payload = struct.pack(
            "<HHIQQ",
            2,
            failure.reason,
            0,
            failure.last_batch,
            failure.last_cursor,
        )
        write_frame(
            sys.stdout.buffer,
            RECOVERY_REQUIRED,
            session,
            control_sequence[0],
            payload,
        )
        return 24

    message_type, received_session, sequence, _ = read_frame(sys.stdin.buffer)
    expected_shutdown_sequence = 4 if args.mode in ("recovery", "strategy-fault") else 2
    if message_type != SHUTDOWN or received_session != session or sequence != expected_shutdown_sequence:
        raise ValueError("expected Shutdown v1")
    write_frame(sys.stdout.buffer, SHUTDOWN_ACK, session, control_sequence[0])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
