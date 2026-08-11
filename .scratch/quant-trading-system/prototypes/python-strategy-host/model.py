"""PROTOTYPE: pure Python Strategy Host state model."""

from dataclasses import dataclass

ACTIVE = "Active"
NEEDS_SNAPSHOT = "NeedsSnapshot"
RECOVERING = "Recovering"


@dataclass(frozen=True)
class Intent:
    intent_id: int
    strategy_id: int
    batch_seq: int
    instrument: int
    sent_ns: int


class HostModel:
    """Owns strategy cursors and hides subscription fan-out behind accept()."""

    def __init__(self, strategy_ids, instrument_count=32, intent_every=400):
        self.strategy_ids = tuple(strategy_ids)
        self.routes = [[] for _ in range(instrument_count)]
        self.counts = {strategy_id: 0 for strategy_id in self.strategy_ids}
        for strategy_id in self.strategy_ids:
            for offset in range(4):
                instrument = (strategy_id * 7 + offset * 3) % instrument_count
                self.routes[instrument].append(strategy_id)
        self.status = ACTIVE
        self.last_seq = 0
        self.intent_every = intent_every
        self.deliveries = 0

    def snapshot(self):
        return self.last_seq, tuple(self.counts.items())

    def restore(self, seq, counts):
        restored = dict(counts)
        if restored.keys() != self.counts.keys():
            raise ValueError("snapshot strategy set mismatch")
        self.counts = restored
        self.last_seq = seq
        self.status = RECOVERING

    def resume(self, seq):
        if self.status != RECOVERING or seq != self.last_seq:
            raise ValueError("invalid recovery barrier")
        self.status = ACTIVE

    def lagged(self):
        self.status = NEEDS_SNAPSHOT

    def accept(self, seq, events, sent_ns):
        if self.status == NEEDS_SNAPSHOT:
            return ()
        if seq != self.last_seq + 1:
            self.status = NEEDS_SNAPSHOT
            return ()

        intents = []
        allow_intents = self.status == ACTIVE
        for instrument in events:
            for strategy_id in self.routes[instrument]:
                count = self.counts[strategy_id] + 1
                self.counts[strategy_id] = count
                self.deliveries += 1
                if allow_intents and count % self.intent_every == 0:
                    ordinal = count // self.intent_every
                    intents.append(
                        Intent(
                            intent_id=(strategy_id << 32) | ordinal,
                            strategy_id=strategy_id,
                            batch_seq=seq,
                            instrument=instrument,
                            sent_ns=sent_ns,
                        )
                    )
        self.last_seq = seq
        return tuple(intents)


def self_check():
    host = HostModel([1], instrument_count=4, intent_every=4)
    events = (3,)
    assert host.accept(1, events, 1) == ()
    checkpoint = host.snapshot()
    host.accept(3, events, 3)
    assert host.status == NEEDS_SNAPSHOT
    host.restore(*checkpoint)
    assert host.accept(2, events, 2) == ()
    assert host.accept(3, events, 3) == ()
    host.resume(3)
    intents = host.accept(4, events, 4)
    assert host.status == ACTIVE and len(intents) == 1
