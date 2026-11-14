"""Offline Maker shadow, with explicitly counterfactual execution suggestions.

Reuses the read-only capture/replay driver. No Action or Intent escapes this
module. Capture JSON requires the original Frame archive and dependencies.
"""
import copy
from dataclasses import dataclass, replace, asdict

from strategies.cross_venue import arbitrage_baseline as b
from strategies.cross_venue import arbitrage_cycle as cycle
from strategies.cross_venue import arbitrage_maker as maker
from strategies.cross_venue import arbitrage_checkpoint as checkpoint
from strategies.cross_venue import arbitrage_shadow as shadow


@dataclass(frozen=True)
class Frame(shadow.Frame):
    MODE = "maker_taker"
    quotes: tuple = ()
    cycle_facts: object = None

    def __post_init__(self):
        super().__post_init__()
        if (type(self.quotes) is not tuple or len(self.quotes) > 16
                or any(not isinstance(q, maker.Quote) for q in self.quotes)
                or not isinstance(self.cycle_facts, cycle.Facts)):
            raise b.Rejected("maker_shadow_frame")
        if (self.cycle_facts.cursor, self.cycle_facts.at_ns) != (self.facts.cursor, self.facts.at_ns):
            raise b.Rejected("maker_shadow_cursor")


class Session(shadow.Session):
    MODE = "maker_taker"
    SCHEMA = "arbitrage_maker_read_only_capture_v1"

    def __init__(self, protocol, config, signal_states, monitor, metadata, maker_cycle):
        super().__init__(protocol, config, signal_states, monitor, metadata)
        if not isinstance(maker_cycle, maker.Cycle):
            raise b.Rejected("maker_shadow_cycle")
        self._components["maker"] = copy.deepcopy(maker_cycle)
        checkpoint.checkpoint(metadata, self._components)
        self._initial = self._initial_identity()

    def _initial_identity(self):
        return checkpoint.content((self.SCHEMA, self.MODE, super()._initial_identity()))

    def _restart_metadata(self, components):
        return dict(super()._restart_metadata(components), next_intent=components["maker"].next_sequence)

    def _extend_decision(self, frame, components, decision, request, healthy):
        private = components["maker"]
        f = frame.cycle_facts
        for i, leg in enumerate(private.plan.legs):
            observations = [o for o in frame.observations
                            if (o.account, o.rules.instrument) == (leg.account, leg.rules.instrument)]
            if (len(observations) != 1 or observations[0].rules != leg.rules
                    or observations[0].book != f.market.books[i]):
                raise b.Rejected("maker_shadow_market")
        # The caller certifies projected economic facts; every result is simulated.
        monitor = components["monitor"]
        approved = any(a.enabled and a.key[1] == private.plan.policy.direction and a.key[2:] == ("maker_taker", private.plan.maker_leg)
            and a.config_hash == self.config.content_hash
            and a.valid_from_ns <= f.at_ns < a.valid_until_ns
            and a.model_hash == private.plan.policy.model_hash
            and a.policy_version == private.plan.policy.version
            and a.execution_hash == private.plan.execution_hash
            and any(o.plan.key == a.key and o.plan.calibration.version == a.calibration_version
                    and o.execution_hash == a.execution_hash for o in frame.options)
            and tuple((x[1], x[2]) for x in a.key[0]) ==
                tuple((leg.account, leg.rules.instrument) for leg in private.plan.legs)
            and a.rules_versions == tuple(leg.rules.version for leg in private.plan.legs)
            for a in frame.approvals)
        healthy = healthy and not decision["error"]
        f = replace(f, market=replace(f.market, model_invalid=f.market.model_invalid or monitor.state == "InvalidLatched"),
                    opening_allowed=f.opening_allowed and frame.facts.opening_allowed and approved and healthy
                    and frame.facts.config_hash == self.config.content_hash
                    and self.config.valid_from_ns <= f.at_ns < self.config.valid_until_ns,
                    model_warning=f.model_warning or monitor.state != "Normal" or bool(decision["error"]))
        if private.phase == "idle":
            if request is None or decision["suggestion"] is None:
                decision["maker"] = dict(evidence="counterfactual_simulation", reason="not_admitted", orders=[], cancels=[], queries=[])
                return
            option = next(x for x in frame.options if x.plan.key == request.key and x.lots == request.lots)
            bound = replace(private.plan, request_ref=request.identity)
            private = maker.Cycle.from_admission(bound, request, option)
            components["maker"] = private
            action = private.start(cursor=f.cursor, at_ns=f.at_ns, market=f.market, quotes=frame.quotes)
        else:
            action = private.apply(f, quotes=frame.quotes)
        decision["maker"] = dict(evidence="counterfactual_simulation", reason=action.reason,
            orders=[asdict(i) for i in action.intents], cancels=list(action.cancels), queries=list(action.queries),
            reconcile=action.reconcile, escalate=action.escalate, phase=private.phase,
            exposure=[str(x) for x in private.exposure_bounds(f)])

    def report(self):
        return dict(super().report(), execution_evidence="counterfactual_simulation",
                    queue_evidence="not_observed", actual_fills="not_observed", actual_pnl="not_observed")
