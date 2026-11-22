"""Fixed StrategyPackage API v1: immutable values, no authority handles."""

from __future__ import annotations

from typing import NamedTuple

from strategy_package import require, uint


class Context(NamedTuple):
    strategy_identity: str
    definition_identity: str
    config_version: int
    config_sha256: str
    package_manifest_sha256: str
    state_schema_identity: str
    state_schema_version: int


class Event(NamedTuple):
    sequence: int
    event_type: int
    schema_version: int
    payload_bytes: bytes


class ExactLimitPrice(NamedTuple):
    ticks: int
    rules_version: int
    tick_coefficient: int


class OrderIntent(NamedTuple):
    intent_sequence: int
    portfolio_identity: int
    exchange_account_identity: int
    instrument_identity: int
    side: str
    time_in_force: str
    portfolio_reduce_only: bool
    quantity: int
    limit_price: int | ExactLimitPrice


class IntentGroup(NamedTuple):
    members: tuple


class FeeCheckedIntentGroup(NamedTuple):
    members: tuple
    fee_version: str


class OrderQuery(NamedTuple):
    cycle_first_sequence: int
    intent_sequence: int


class OrderCancel(NamedTuple):
    cycle_first_sequence: int
    intent_sequence: int


class MakerIntent(NamedTuple):
    member: OrderIntent
    cycle_first_sequence: int
    peer_account: int
    peer_instrument: int
    fee_version: str


def validate_outputs(outputs, before, after, manifest, binding):
    """Check the existing 128-byte envelope / 80-byte intent codec capacities."""
    uint(before)
    uint(after)
    limits = manifest["limits"]
    require(type(outputs) is tuple and len(outputs) <= limits["max_output_frames_per_event"],
            "output type or frame capacity")
    count = 0
    scopes = {(int(s["exchange_account"], 16), int(s["instrument"], 16)) for s in binding["scopes"]}
    for output in outputs:
        if type(output) in (OrderQuery, OrderCancel):
            kind = "order_query" if type(output) is OrderQuery else "order_cancel"
            require(kind in manifest["output_kinds"] and limits["max_output_frame_bytes"] >= 144,
                    "undeclared cycle order reference or frame capacity")
            uint(output.cycle_first_sequence)
            uint(output.intent_sequence)
            require(output.intent_sequence >= output.cycle_first_sequence, "query precedes cycle")
            continue
        if type(output) is MakerIntent:
            kind, members = "maker_intent", (output.member,)
            uint(output.cycle_first_sequence)
            require(type(output.member) is OrderIntent and type(output.member.limit_price) is ExactLimitPrice
                    and output.member.intent_sequence >= output.cycle_first_sequence
                    and not output.member.portfolio_reduce_only and output.member.time_in_force in ("post-only", "ioc")
                    and (output.peer_account, output.peer_instrument) in scopes
                    and output.peer_account != output.member.exchange_account_identity
                    and output.peer_instrument != output.member.instrument_identity
                    and limits["max_output_frame_bytes"] >= 272, "invalid Maker route")
            uint(output.peer_account, 128)
            uint(output.peer_instrument, 128)
        elif type(output) is OrderIntent:
            kind, members = "order_intent", (output,)
        else:
            require(type(output) in (IntentGroup, FeeCheckedIntentGroup) and type(output.members) is tuple
                    and 2 <= len(output.members) <= 4, "expected complete group")
            kind, members = "intent_group", output.members
        if type(output) in (MakerIntent, FeeCheckedIntentGroup):
            version = output.fee_version
            require(type(version) is str and 0 < len(version) <= 20 and version.isascii()
                    and version.isdecimal() and not version.startswith("0"), "invalid fee version")
        require(kind in manifest["output_kinds"], "undeclared output kind")
        member_sizes = set()
        for member in members:
            require(type(member) is OrderIntent, "expected OrderIntent")
            uint(member.intent_sequence)
            require(member.intent_sequence == before + count, "non-contiguous IntentSequence")
            for value in member[1:4]:
                uint(value, 128)
            require(member.portfolio_identity == int(binding["portfolio_identity"], 16)
                    and (member.exchange_account_identity, member.instrument_identity) in scopes,
                    "output ownership mismatch")
            require(member.side in ("buy", "sell") and member.time_in_force in ("gtc", "ioc", "post-only")
                    and type(member.portfolio_reduce_only) is bool, "invalid order flags")
            uint(member.quantity, 63)
            price = member.limit_price
            if type(price) is ExactLimitPrice:
                uint(price.ticks, 63)
                uint(price.rules_version, 64)
                uint(price.tick_coefficient, 127)
                member_sizes.add(104)
            else:
                uint(price, 63)
                member_sizes.add(80)
            count += 1
        require(len(member_sizes) == 1 and 128 + len(members) * next(iter(member_sizes)) <=
                min(448, limits["max_output_frame_bytes"]), "output frame capacity or mixed price units")
    require(after == before + count, "next IntentSequence mismatch")
    return count
