"""Private handoff of an evaluated candidate and its committed Writer receipt."""
import json
from pathlib import Path

from opportunity_scanner.scanner_config import _object, uint_text

MAX_BYTES = 64 * 1024


def read_approved_evaluation(path, *, strategy_identity):
    with Path(path).open("rb") as source:
        raw = source.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise ValueError("approved evaluation capacity")
    document = json.loads(raw, object_pairs_hook=_object)
    if document["schema"] != "approved_evaluation_v1":
        raise ValueError("approved evaluation schema")
    selection, evaluation, receipt = (document[name] for name in ("selection", "evaluation", "receipt"))
    binding = receipt["pair"]
    approval = uint_text(selection["identity"], minimum=1, maximum=(1 << 128) - 1)
    if (receipt["status"] != "accepted" or uint_text(receipt["identity"]) != approval
            or int(binding["identity"], 16) != approval
            or uint_text(selection["strategy_identity"]) != strategy_identity
            or evaluation["id"] != selection["candidate_id"] or evaluation["status"] != "evaluated"
            or any(evaluation[key] != selection["evaluation"][key]
                   for key in ("scenario_digest", "data_cutoff_ns", "valid_until_ns"))
            or binding["direction"] != evaluation["direction"]
            or binding["mode"] != "taker_taker" or evaluation["mode"] != "taker_taker"
            or len(binding["legs"]) != 2):
        raise ValueError("approved evaluation binding")
    return uint_text(selection["portfolio_identity"], minimum=1), evaluation, binding
