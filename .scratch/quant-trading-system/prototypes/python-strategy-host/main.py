"""PROTOTYPE: shared-memory Python Strategy Host harness, not production IPC."""

import argparse
import ctypes
import multiprocessing as mp
from multiprocessing import shared_memory
from pathlib import Path
import struct
import sys
import time
from collections import deque

sys.path.insert(0, str(Path(__file__).parent))
from model import ACTIVE, NEEDS_SNAPSHOT, RECOVERING, HostModel, self_check

SLOT_SIZE = 1024
RING_CAPACITY = 64
SNAPSHOT = 1
RESUME = 2
MSG_INTENT = 1
MSG_RESYNC = 2
MSG_CHECKPOINT = 3
STATUS = {
    0: ACTIVE,
    1: NEEDS_SNAPSHOT,
    2: RECOVERING,
    3: "Stopped",
    4: "OutputOverflow",
    5: "Starting",
}
BATCH_HEADER = struct.Struct("<QIIQ")
EVENT = struct.Struct("<Hqq")
PAIR = struct.Struct("<QQ")
INTENT = struct.Struct("<BQQQQH")
MAX_BATCH_AGE_NS = 50_000_000


class Ring:
    def __init__(self, ctx, create=True, name=None, read=None, write=None):
        self.shm = shared_memory.SharedMemory(create=create, name=name, size=RING_CAPACITY * SLOT_SIZE)
        self.read = read if read is not None else ctx.RawValue(ctypes.c_ulonglong, 0)
        self.write = write if write is not None else ctx.RawValue(ctypes.c_ulonglong, 0)

    def descriptor(self):
        return self.shm.name, self.read, self.write

    @classmethod
    def attach(cls, ctx, descriptor):
        name, read, write = descriptor
        return cls(ctx, create=False, name=name, read=read, write=write)

    def put(self, payload):
        if len(payload) > SLOT_SIZE - 4:
            raise ValueError("slot too small")
        write = self.write.value
        if write - self.read.value >= RING_CAPACITY:
            return False
        offset = (write % RING_CAPACITY) * SLOT_SIZE
        struct.pack_into("<I", self.shm.buf, offset, len(payload))
        self.shm.buf[offset + 4 : offset + 4 + len(payload)] = payload
        self.write.value = write + 1
        return True

    def get(self):
        read = self.read.value
        if read == self.write.value:
            return None
        offset = (read % RING_CAPACITY) * SLOT_SIZE
        size = struct.unpack_from("<I", self.shm.buf, offset)[0]
        payload = bytes(self.shm.buf[offset + 4 : offset + 4 + size])
        self.read.value = read + 1
        return payload

    def clear(self):
        self.read.value = self.write.value

    def close(self, unlink=False):
        self.shm.close()
        if unlink:
            self.shm.unlink()


def encode_batch(seq, sent_ns, flags=0, events=(), counts=()):
    rows = counts if flags & SNAPSHOT else events
    payload = bytearray(BATCH_HEADER.pack(seq, flags, len(rows), sent_ns))
    if flags & SNAPSHOT:
        for strategy_id, count in rows:
            payload.extend(PAIR.pack(strategy_id, count))
    else:
        for instrument in rows:
            payload.extend(EVENT.pack(instrument, 100_000 + seq, 1_000))
    return bytes(payload)


def decode_batch(payload):
    seq, flags, count, sent_ns = BATCH_HEADER.unpack_from(payload)
    offset = BATCH_HEADER.size
    if flags & SNAPSHOT:
        rows = [PAIR.unpack_from(payload, offset + i * PAIR.size) for i in range(count)]
    else:
        rows = [EVENT.unpack_from(payload, offset + i * EVENT.size)[0] for i in range(count)]
    return seq, flags, sent_ns, rows


def encode_checkpoint(seq, counts):
    payload = bytearray(struct.pack("<BQ", MSG_CHECKPOINT, seq))
    for pair in counts:
        payload.extend(PAIR.pack(*pair))
    return bytes(payload)


def host_process(
    input_descriptor,
    output_descriptor,
    strategy_ids,
    status,
    cursor,
    pause_until_ns,
    stop,
):
    ctx = mp.get_context()
    input_ring = Ring.attach(ctx, input_descriptor)
    output_ring = Ring.attach(ctx, output_descriptor)
    model = HostModel(strategy_ids)
    last_checkpoint = 0
    try:
        status.value = 0
        while not stop.is_set():
            if time.perf_counter_ns() < pause_until_ns.value:
                time.sleep(0.001)
                continue
            payload = input_ring.get()
            if payload is None:
                time.sleep(0)
                continue
            seq, flags, sent_ns, rows = decode_batch(payload)

            if flags & SNAPSHOT:
                model.restore(seq, rows)
            elif flags & RESUME:
                model.resume(seq)
            else:
                previous_status = model.status
                if model.status == ACTIVE and time.perf_counter_ns() - sent_ns > MAX_BATCH_AGE_NS:
                    model.lagged()
                    intents = ()
                else:
                    intents = model.accept(seq, rows, sent_ns)
                if previous_status != NEEDS_SNAPSHOT and model.status == NEEDS_SNAPSHOT:
                    if not output_ring.put(struct.pack("<BQ", MSG_RESYNC, model.last_seq)):
                        status.value = 4
                        return
                for intent in intents:
                    message = INTENT.pack(
                        MSG_INTENT,
                        intent.intent_id,
                        intent.strategy_id,
                        intent.batch_seq,
                        intent.sent_ns,
                        intent.instrument,
                    )
                    if not output_ring.put(message):
                        status.value = 4
                        return

            status.value = {ACTIVE: 0, NEEDS_SNAPSHOT: 1, RECOVERING: 2}[model.status]
            cursor.value = model.last_seq
            if model.status == ACTIVE and model.last_seq - last_checkpoint >= 250:
                checkpoint_seq, counts = model.snapshot()
                if not output_ring.put(encode_checkpoint(checkpoint_seq, counts)):
                    status.value = 4
                    return
                last_checkpoint = checkpoint_seq
    finally:
        status.value = 3 if status.value != 4 else 4
        input_ring.close()
        output_ring.close()


class Host:
    def __init__(self, ctx, host_id, strategy_ids):
        self.host_id = host_id
        self.strategy_ids = tuple(strategy_ids)
        self.input = Ring(ctx)
        self.output = Ring(ctx)
        self.status = ctx.RawValue(ctypes.c_int, 5)
        self.cursor = ctx.RawValue(ctypes.c_ulonglong, 0)
        self.pause_until_ns = ctx.RawValue(ctypes.c_longlong, 0)
        self.stop = ctx.Event()
        self.process = ctx.Process(
            target=host_process,
            args=(
                self.input.descriptor(),
                self.output.descriptor(),
                self.strategy_ids,
                self.status,
                self.cursor,
                self.pause_until_ns,
                self.stop,
            ),
        )
        self.checkpoint = (0, tuple((strategy_id, 0) for strategy_id in self.strategy_ids))
        self.pending = deque()
        self.recovering = False
        self.recovery_barrier = 0
        self.dropped = 0
        self.resyncs = 0

    def close(self):
        self.stop.set()
        self.process.join(2)
        if self.process.is_alive():
            self.process.terminate()
            self.process.join()
        self.input.close(unlink=True)
        self.output.close(unlink=True)


def percentile(values, fraction):
    if not values:
        return 0
    values.sort()
    return values[min(len(values) - 1, int(len(values) * fraction))]


def drain(host, history, current_seq, latencies, intent_ids):
    while True:
        message = host.output.get()
        if message is None:
            return
        kind = message[0]
        if kind == MSG_INTENT:
            _, intent_id, _, _, sent_ns, _ = INTENT.unpack(message)
            if intent_id in intent_ids:
                raise RuntimeError("duplicate OrderIntent identity")
            intent_ids.add(intent_id)
            latencies.append(time.perf_counter_ns() - sent_ns)
        elif kind == MSG_CHECKPOINT:
            seq = struct.unpack_from("<Q", message, 1)[0]
            counts = tuple(
                PAIR.unpack_from(message, 9 + i * PAIR.size)
                for i in range(len(host.strategy_ids))
            )
            host.checkpoint = (seq, counts)
        elif kind == MSG_RESYNC and not host.recovering:
            checkpoint_seq, counts = host.checkpoint
            host.input.clear()
            host.pending.append(encode_batch(checkpoint_seq, 0, SNAPSHOT, counts=counts))
            host.pending.extend(history[checkpoint_seq:current_seq])
            host.pending.append(encode_batch(current_seq, 0, RESUME))
            host.recovering = True
            host.recovery_barrier = current_seq
            host.resyncs += 1


def run_benchmark(rate, seconds):
    self_check()
    ctx = mp.get_context("spawn")
    hosts = [
        Host(ctx, host_id, range(host_id * 25, (host_id + 1) * 25))
        for host_id in range(4)
    ]
    for host in hosts:
        host.process.start()
    ready_deadline = time.time() + 10
    while any(host.status.value == 5 for host in hosts):
        if time.time() >= ready_deadline:
            raise RuntimeError("Strategy Host startup timeout")
        time.sleep(0.001)

    total_batches = rate * seconds
    events = tuple(range(32))
    history = []
    latencies = []
    intent_ids = set()
    fault_seq = rate * 2
    start = time.perf_counter_ns()
    try:
        for seq in range(1, total_batches + 1):
            deadline = start + int(seq * 1_000_000_000 / rate)
            remaining = deadline - time.perf_counter_ns()
            if remaining > 200_000:
                time.sleep((remaining - 100_000) / 1_000_000_000)
            while time.perf_counter_ns() < deadline:
                pass

            sent_ns = time.perf_counter_ns()
            batch = encode_batch(seq, sent_ns, events=events)
            history.append(batch)
            if seq == fault_seq:
                hosts[0].pause_until_ns.value = sent_ns + 250_000_000

            for host in hosts:
                drain(host, history, seq, latencies, intent_ids)
                if host.recovering:
                    if seq > host.recovery_barrier:
                        host.pending.append(batch)
                    while host.pending and host.input.put(host.pending[0]):
                        host.pending.popleft()
                    if not host.pending and host.status.value == 0:
                        host.recovering = False
                        host.recovery_barrier = 0
                elif not host.input.put(batch):
                    host.dropped += 1

        deadline = time.time() + 5
        while time.time() < deadline:
            done = True
            for host in hosts:
                drain(host, history, total_batches, latencies, intent_ids)
                while host.pending and host.input.put(host.pending[0]):
                    host.pending.popleft()
                done &= not host.pending and host.cursor.value == total_batches and host.status.value == 0
            if done:
                break
            time.sleep(0.001)

        elapsed = (time.perf_counter_ns() - start) / 1_000_000_000
        print("self_check: ok")
        print(f"python={sys.version.split()[0]}, hosts=4, strategies=100")
        print(f"load: {rate} batches/s/host, 32 updates/batch, {seconds}s")
        print(f"elapsed: {elapsed:.3f}s")
        print(f"merged_market_copies: 128/batch vs 400/batch unmerged")
        print(f"strategy_deliveries: {total_batches * 400:,} ({total_batches * 400 / elapsed:,.0f}/s)")
        print(f"order_intents_returned: {len(intent_ids):,}")
        print(
            "intent_round_trip: "
            f"p50={percentile(latencies, .50) / 1_000_000:.3f}ms, "
            f"p99={percentile(latencies, .99) / 1_000_000:.3f}ms"
        )
        for host in hosts:
            print(
                f"host_{host.host_id}: status={STATUS[host.status.value]}, "
                f"cursor={host.cursor.value}, dropped={host.dropped}, resyncs={host.resyncs}"
            )
        if any(host.cursor.value != total_batches or host.status.value != 0 for host in hosts):
            raise RuntimeError("a Strategy Host did not converge")
        if hosts[0].resyncs != 1 or any(host.resyncs for host in hosts[1:]):
            raise RuntimeError("lag isolation/resync mismatch")
    finally:
        for host in hosts:
            host.close()


def run_demo():
    self_check()
    model = HostModel(range(4), instrument_count=8, intent_every=8)
    seq = 0
    checkpoint = model.snapshot()
    while True:
        print("\033[2J\033[H", end="")
        print("\033[1mPython Strategy Host state\033[0m")
        print(f"status: {model.status}")
        print(f"last_seq: {model.last_seq}")
        print(f"strategy_counts: {model.counts}")
        print(f"\033[2mcheckpoint_seq: {checkpoint[0]}\033[0m")
        print("\n[n] next batch  [g] inject gap  [s] snapshot+replay  [q] quit")
        command = input("> ").strip().lower()
        if command == "q":
            return
        if command == "n":
            seq += 1
            model.accept(seq, range(8), time.perf_counter_ns())
            if model.status == ACTIVE:
                checkpoint = model.snapshot()
        elif command == "g":
            seq += 2
            model.accept(seq, range(8), time.perf_counter_ns())
        elif command == "s" and model.status == NEEDS_SNAPSHOT:
            target = seq
            model.restore(*checkpoint)
            for replay_seq in range(checkpoint[0] + 1, target + 1):
                model.accept(replay_seq, range(8), 0)
            model.resume(target)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--demo", action="store_true")
    parser.add_argument("--rate", type=int, default=1000)
    parser.add_argument("--seconds", type=int, default=8)
    args = parser.parse_args()
    if args.demo:
        run_demo()
    else:
        run_benchmark(args.rate, args.seconds)
