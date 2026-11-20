//! Read-only native cash postings for a cycle at a committed owner barrier.
const std = @import("std");
const trading = @import("../trading/trading_shard.zig");
const economics = @import("../portfolio/economics.zig");

pub const Flow = struct {
    account: u128,
    kind: economics.FactKind,
    identity: u64,
    at_ns: u64,
    asset: u64,
    scale: u8,
    atoms: i128,
};

pub const Projection = struct {
    strategy: u128,
    first_sequence: u64,
    barrier: u64,
    closed: bool = false,
    closed_at_ns: ?u64 = null,
    complete: bool = true,
    flows: std.ArrayList(Flow) = .empty,

    pub fn deinit(self: *Projection, allocator: std.mem.Allocator) void {
        self.flows.deinit(allocator);
    }

    pub fn json(self: Projection, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, .{
            .strategy = self.strategy,
            .first_sequence = self.first_sequence,
            .barrier = self.barrier,
            .closed = self.closed,
            .closed_at_ns = self.closed_at_ns,
            .complete = self.complete,
            .flows = self.flows.items,
        }, .{});
    }
};

/// Call on the owner's committed state or its recovered state. Missing cold
/// evidence keeps attribution pending instead of treating missing cash as zero.
pub fn project(allocator: std.mem.Allocator, shard: *const trading.TradingShard, journal: *const trading.journal.Journal, strategy: u128, first: u64) !Projection {
    const closed = shard.cycles.completed(strategy, first);
    const record = shard.cycles.find(strategy, first) orelse
        if (closed) |entry| entry.record else return error.UnknownCycle;
    var result: Projection = .{ .strategy = strategy, .first_sequence = first, .barrier = shard.authoritativeBarrier(), .closed = closed != null };
    errdefer result.deinit(allocator);
    const assets = shard.activatedAssets();
    if (closed) |entry| {
        var reader = try trading.journal.Reader.init(journal.bytes());
        while (true) switch (try reader.next()) {
            .record => |fact| if (fact.sequence == entry.fact_sequence) {
                if (fact.time_presence.source and fact.source_time != 0) result.closed_at_ns = fact.source_time;
                break;
            },
            .end => break,
        };
    }
    for (record.members[0..record.count]) |member| {
        const entry = shard.pairInstrument(member.account, member.instrument) orelse return error.UnknownInstrument;
        const stable = assets.resolveCode(entry.venue, "USDC") catch {
            if ((assets.resolveCode(entry.venue, "USDT") catch 0) != entry.rules.settlement_asset)
                result.complete = false;
            continue;
        };
        const scale = assets.get(stable).?.definition.atomic_scale;
        const account = shard.accountState(member.account) orelse return error.UnknownExchangeAccount;
        const p = &account.economic_projection;
        const history_complete = p.archived_fill_count == 0 and p.archived_funding_count == 0 and
            p.applied_forced_execution_count == 0 and p.archived_forced_count == 0;
        if (!history_complete) result.complete = false;
        const layer = p.portfolioLayer(record.portfolio) orelse return error.UnknownPortfolio;
        const known_lots = lotsAt(p, member.instrument, record.portfolio, std.math.maxInt(u64), null, 0);
        const funding_scope_proven = known_lots != null and known_lots.? == layer.positionForInstrument(member.instrument).quantity;
        for (p.applied_fills[0..p.applied_fill_count]) |fill| {
            if (fill.source.strategy != strategy or fill.source.cycle_first_sequence != first or
                fill.source.portfolio != record.portfolio or fill.source.exchange_account != member.account or
                fill.fill.quantity.instrument != member.instrument) continue;
            const at = if (fill.source.canonical_fill) |original| original.venue_fill_time_utc_ns else null;
            try appendFlow(allocator, &result, p, record.portfolio, member.account, .fill, fill.fill.identity, stable, scale, at);
        }
        for (p.fee_revisions[0..p.fee_revision_count]) |revision| {
            const fee = revision.adjustment;
            if (fee.strategy != strategy or fee.cycle_first_sequence != first or fee.portfolio != record.portfolio or
                fee.exchange_account != member.account) continue;
            const origin = p.feeOrigin(fee.fill_identity) orelse {
                result.complete = false;
                continue;
            };
            if (origin.original.instrument != member.instrument) continue;
            try appendFlow(allocator, &result, p, record.portfolio, member.account, .fee_adjustment, std.math.cast(u64, fee.identity) orelse return error.InvalidFxIdentity, stable, scale, fee.effective_time_utc_ns);
        }
        for (p.applied_fundings[0..p.applied_funding_count]) |funding| {
            if (funding.funding.amount.asset != stable or funding.funding.amount.atoms == 0 or
                funding.source.instrument != member.instrument) continue;
            const at = funding.source.exchange_time_utc_ns orelse {
                result.complete = false;
                continue;
            };
            const cycle_lots = lotsAt(p, member.instrument, record.portfolio, at, strategy, first) orelse {
                result.complete = false;
                continue;
            };
            if (cycle_lots == 0) continue;
            const portfolio_lots = lotsAt(p, member.instrument, record.portfolio, at, null, 0);
            if (!history_complete or !funding_scope_proven or !funding.portfolio_applied or funding.source.ownership == null or
                funding.source.portfolio != record.portfolio or portfolio_lots == null or portfolio_lots.? != cycle_lots)
            {
                result.complete = false;
                continue;
            }
            try appendFlow(allocator, &result, p, record.portfolio, member.account, .funding, funding.funding.identity, stable, scale, at);
        }
    }
    std.mem.sort(Flow, result.flows.items, {}, lessThan);
    return result;
}

fn lotsAt(p: *const economics.Projection, instrument: u128, portfolio: u128, at: u64, strategy: ?u128, first: u64) ?i128 {
    var lots: i128 = 0;
    for (p.applied_fills[0..p.applied_fill_count]) |fill| {
        if (fill.source.portfolio != portfolio or fill.fill.quantity.instrument != instrument or
            fill.fill.product != .isolated_linear) continue;
        if (strategy) |id| if (fill.source.strategy != id or fill.source.cycle_first_sequence != first) continue;
        const original = fill.source.canonical_fill orelse return null;
        const when = original.venue_fill_time_utc_ns orelse return null;
        if (when == at) return null;
        if (when < at) lots += if (fill.fill.side == .buy) fill.fill.quantity.lots else -@as(i128, fill.fill.quantity.lots);
    }
    return lots;
}

fn appendFlow(allocator: std.mem.Allocator, result: *Projection, p: *const economics.Projection, portfolio: u128, account: u128, kind: economics.FactKind, identity: u64, asset: u64, scale: u8, at: ?u64) !void {
    var atoms: i128 = 0;
    for (p.ledger[0..p.ledger_count]) |txn| {
        if (txn.layer != .portfolio or txn.kind != kind or txn.source_identity != identity or
            (txn.portfolio != 0 and txn.portfolio != portfolio)) continue;
        for (txn.postings[0..txn.posting_count]) |posting| {
            if (posting.asset == asset and (posting.account == .cash or posting.account == .spot_asset))
                atoms = try std.math.add(i128, atoms, posting.amount);
        }
    }
    if (atoms == 0) return;
    if (at == null or at.? == 0) {
        result.complete = false;
        return;
    }
    try result.flows.append(allocator, .{ .account = account, .kind = kind, .identity = identity, .at_ns = at.?, .asset = asset, .scale = scale, .atoms = atoms });
}

fn lessThan(_: void, a: Flow, b: Flow) bool {
    if (a.at_ns != b.at_ns) return a.at_ns < b.at_ns;
    if (a.account != b.account) return a.account < b.account;
    if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    return a.identity < b.identity;
}
