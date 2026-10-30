"""Fixed StrategyPackage API v1: immutable values, no authority handles."""

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


class OrderIntent(NamedTuple):
    intent_sequence: int
    portfolio_identity: int
    exchange_account_identity: int
    instrument_identity: int
    side: str
    time_in_force: str
    portfolio_reduce_only: bool
    quantity: int
    limit_price: int


class IntentGroup(NamedTuple):
    members: tuple


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
            require(type(output) is IntentGroup and type(output.members) is tuple
                    and 2 <= len(output.members) <= 4, "expected complete group")
            kind, members = "intent_group", output.members
        require(kind in manifest["output_kinds"], "undeclared output kind")
        require(128 + 80 * len(members) <= limits["max_output_frame_bytes"], "output frame capacity")
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
            for value in (member.quantity, member.limit_price):
                uint(value, 63)
            count += 1
    require(after == before + count, "next IntentSequence mismatch")
    return count
