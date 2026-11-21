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
        if type(output) is OrderIntent:
            kind, members = "order_intent", (output,)
        else:
            require(type(output) in (IntentGroup, FeeCheckedIntentGroup) and type(output.members) is tuple
                    and 2 <= len(output.members) <= 4, "expected complete group")
            kind, members = "intent_group", output.members
            if type(output) is FeeCheckedIntentGroup:
                version = output.fee_version
                require(type(version) is str and len(version) <= 20 and version.isascii()
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
