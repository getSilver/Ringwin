const std = @import("std");
const canonical = @import("canonical_event.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const max_facts = 32;
pub const max_ledger_transactions = 64;

pub const Instrument = canonical.InstrumentIdentity;
const spot_instrument: Instrument = 1;
const swap_instrument: Instrument = 2;
const settlement_asset: canonical.AssetIdentity = 1;
pub const Side = enum(u8) { buy, sell };
pub const FactKind = enum(u8) { fill, funding, forced_execution, account_snapshot };
pub const LedgerLayer = enum(u8) { portfolio, exchange };
pub const LedgerUnit = enum(u8) { settlement_atoms, spot_quantity, swap_quantity };
pub const LedgerAccount = enum(u8) { cash, spot_asset, swap_position, trade, fee_expense, rebate_income, funding_pnl, penalty_expense };
pub const max_postings = 4;

pub const Position = struct {
    quantity: i64 = 0,
    open_cost_micros: i64 = 0,
};

pub const Layer = struct {
    usdt_balance_micros: i64 = 0,
    spot_asset_quantity: i64 = 0,
    spot: Position = .{},
    swap: Position = .{},
    margin_micros: i64 = 0,
    fee_micros: i64 = 0,
    rebate_micros: i64 = 0,
    funding_micros: i64 = 0,
    penalty_micros: i64 = 0,
    realized_pnl_micros: i64 = 0,
    unrealized_pnl_micros: i64 = 0,
};

pub const LedgerTransaction = struct {
    source_identity: u64,
    kind: FactKind,
    layer: LedgerLayer,
    postings: [max_postings]LedgerPosting = undefined,
    posting_count: u8,
};

pub const LedgerPosting = struct { account: LedgerAccount, unit: LedgerUnit, amount: i64 };

pub const Fill = struct {
    identity: u64,
    side: Side,
    quantity: canonical.InstrumentQuantity,
    price: canonical.InstrumentPrice,
    quantity_denominator: i64,
    fee: canonical.AssetAmount = .{ .asset = 0, .atoms = 0 },
    rebate: canonical.AssetAmount = .{ .asset = 0, .atoms = 0 },
    portfolio_margin_ppm: i64 = 0,
    exchange_margin_ppm: i64 = 0,
};

pub const FundingSettlement = struct {
    identity: u64,
    amount: canonical.AssetAmount,
};

pub const VenueForcedExecution = struct {
    identity: u64,
    side: Side,
    quantity: canonical.InstrumentQuantity,
    price: canonical.InstrumentPrice,
    quantity_denominator: i64,
    fee: canonical.AssetAmount = .{ .asset = 0, .atoms = 0 },
    penalty: canonical.AssetAmount = .{ .asset = 0, .atoms = 0 },
    portfolio_margin_ppm: i64 = 0,
    exchange_margin_ppm: i64 = 0,
};

pub const AccountSnapshot = struct {
    identity: u64,
    balance: canonical.AssetAmount,
    spot_asset_quantity: i64,
    swap_position_quantity: i64,
    margin: canonical.AssetAmount,
};

pub const Event = union(enum) {
    fill: Fill,
    funding_settlement: FundingSettlement,
    venue_forced_execution: VenueForcedExecution,
    account_snapshot: AccountSnapshot,
    mark_price: i64,
};

const SeenFact = struct {
    identity: u64,
    kind: FactKind,
    fingerprint: u64,
};

pub const Projection = struct {
    settlement_asset: canonical.AssetIdentity = settlement_asset,
    portfolio: Layer = .{},
    exchange: Layer = .{},
    treasury_usdt_micros: i64 = 0,
    suspense_usdt_micros: i64 = 0,
    reconciliation_break: bool = false,
    reconciliation_break_identity: u64 = 0,
    reconciliation_break_identities: [max_facts]u64 = undefined,
    reconciliation_break_count: u8 = 0,
    seen: [max_facts]SeenFact = undefined,
    seen_count: u8 = 0,
    ledger: [max_ledger_transactions]LedgerTransaction = undefined,
    ledger_count: u8 = 0,
    mark_price_micros: i64 = 0,
    quantity_denominator: i64 = 1,

    pub fn apply(self: *Projection, event: Event) !void {
        _ = try self.applyChanged(event);
    }

    pub fn applyChanged(self: *Projection, event: Event) !bool {
        const before = self.digest();
        var candidate = self.*;
        try candidate.applyEvent(event);
        try candidate.assertClosed();
        self.* = candidate;
        return !std.mem.eql(u8, &before, &self.digest());
    }

    pub fn digest(self: *const Projection) [Sha256.digest_length]u8 {
        var hasher = Sha256.init(.{});
        hashInt(&hasher, canonical.AssetIdentity, self.settlement_asset);
        hashLayer(&hasher, self.portfolio);
        hashLayer(&hasher, self.exchange);
        hashInt(&hasher, i64, self.treasury_usdt_micros);
        hashInt(&hasher, i64, self.suspense_usdt_micros);
        hashInt(&hasher, u8, @intFromBool(self.reconciliation_break));
        hashInt(&hasher, u64, self.reconciliation_break_identity);
        hashInt(&hasher, u8, self.reconciliation_break_count);
        for (self.reconciliation_break_identities[0..self.reconciliation_break_count]) |identity| hashInt(&hasher, u64, identity);
        hashInt(&hasher, u8, self.seen_count);
        for (self.seen[0..self.seen_count]) |seen| {
            hashInt(&hasher, u64, seen.identity);
            hashInt(&hasher, u8, @intFromEnum(seen.kind));
            hashInt(&hasher, u64, seen.fingerprint);
        }
        hashInt(&hasher, u8, self.ledger_count);
        for (self.ledger[0..self.ledger_count]) |transaction| {
            hashInt(&hasher, u64, transaction.source_identity);
            hashInt(&hasher, u8, @intFromEnum(transaction.kind));
            hashInt(&hasher, u8, @intFromEnum(transaction.layer));
            hashInt(&hasher, u8, transaction.posting_count);
            for (transaction.postings[0..transaction.posting_count]) |posting| {
                hashInt(&hasher, u8, @intFromEnum(posting.account));
                hashInt(&hasher, u8, @intFromEnum(posting.unit));
                hashInt(&hasher, i64, posting.amount);
            }
        }
        hashInt(&hasher, i64, self.mark_price_micros);
        hashInt(&hasher, i64, self.quantity_denominator);
        var result: [Sha256.digest_length]u8 = undefined;
        hasher.final(&result);
        return result;
    }

    fn applyEvent(self: *Projection, event: Event) !void {
        switch (event) {
            .fill => |fill| try self.applyMirroredFill(fill, .fill),
            .funding_settlement => |funding| try self.applyFunding(funding),
            .venue_forced_execution => |forced| try self.applyForced(forced),
            .account_snapshot => |snapshot| try self.reconcile(snapshot),
            .mark_price => |price| try self.valueAt(price),
        }
    }

    pub fn assertClosed(self: *const Projection) !void {
        for (self.ledger[0..self.ledger_count]) |transaction| {
            var balances: [3]i64 = .{ 0, 0, 0 };
            for (transaction.postings[0..transaction.posting_count]) |posting| {
                const index: usize = @intFromEnum(posting.unit);
                balances[index] = try std.math.add(i64, balances[index], posting.amount);
            }
            for (balances) |balance| if (balance != 0) return error.UnbalancedLedgerTransaction;
        }
        if (try std.math.add(i64, self.portfolio.usdt_balance_micros, try std.math.add(i64, self.treasury_usdt_micros, self.suspense_usdt_micros)) != self.exchange.usdt_balance_micros or
            self.portfolio.spot_asset_quantity != self.exchange.spot_asset_quantity or
            (!self.reconciliation_break and !sameAttributedEconomics(self.portfolio, self.exchange)))
            return error.EconomicLayerMismatch;
    }

    fn applyMirroredFill(self: *Projection, fill: Fill, kind: FactKind) !void {
        if (fill.quantity.lots <= 0 or fill.price.ticks <= 0 or fill.quantity.instrument != fill.price.instrument or
            fill.quantity.rules_version != fill.price.rules_version or fill.quantity_denominator <= 0 or
            (fill.fee.atoms != 0 and fill.fee.asset != self.settlement_asset) or
            (fill.rebate.atoms != 0 and fill.rebate.asset != self.settlement_asset) or
            fill.fee.atoms < 0 or fill.rebate.atoms < 0)
            return error.InvalidEconomicFact;
        if (self.seen_count != 0 and self.quantity_denominator != fill.quantity_denominator) return error.InconsistentQuantityDenominator;
        const fingerprint = fingerprintFill(fill);
        if (try self.remember(fill.identity, kind, fingerprint)) return;
        var portfolio = self.portfolio;
        var exchange = self.exchange;
        const portfolio_movement = try applyFillToLayer(&portfolio, fill);
        const exchange_movement = try applyFillToLayer(&exchange, fill);
        if (fill.quantity.instrument == swap_instrument) {
            portfolio.margin_micros = try rateMicros(portfolio.swap.open_cost_micros, fill.portfolio_margin_ppm);
            exchange.margin_micros = try rateMicros(exchange.swap.open_cost_micros, fill.exchange_margin_ppm);
        }
        if (portfolio_movement != exchange_movement) return error.EconomicLayerMismatch;
        const position_delta: i64 = if (fill.side == .buy) std.math.cast(i64, fill.quantity.lots) orelse return error.Overflow else -(std.math.cast(i64, fill.quantity.lots) orelse return error.Overflow);
        try self.appendPositionLedger(fill.identity, kind, .portfolio, fill.quantity.instrument, position_delta);
        try self.appendPositionLedger(fill.identity, kind, .exchange, fill.quantity.instrument, position_delta);
        try self.appendLedger(fill.identity, kind, .portfolio, .trade, portfolio_movement);
        try self.appendLedger(fill.identity, kind, .exchange, .trade, exchange_movement);
        if (fill.fee.atoms > 0) {
            const fee = std.math.cast(i64, fill.fee.atoms) orelse return error.Overflow;
            try self.appendLedger(fill.identity, kind, .portfolio, .fee_expense, -fee);
            try self.appendLedger(fill.identity, kind, .exchange, .fee_expense, -fee);
        }
        if (fill.rebate.atoms > 0) {
            const rebate = std.math.cast(i64, fill.rebate.atoms) orelse return error.Overflow;
            try self.appendLedger(fill.identity, kind, .portfolio, .rebate_income, rebate);
            try self.appendLedger(fill.identity, kind, .exchange, .rebate_income, rebate);
        }
        self.portfolio = portfolio;
        self.exchange = exchange;
        self.quantity_denominator = fill.quantity_denominator;
    }

    fn applyFunding(self: *Projection, funding: FundingSettlement) !void {
        if (funding.amount.asset != self.settlement_asset) return error.InvalidEconomicFact;
        const amount = std.math.cast(i64, funding.amount.atoms) orelse return error.Overflow;
        var fingerprint_hasher = std.hash.Wyhash.init(0);
        fingerprint_hasher.update(std.mem.asBytes(&funding.amount.asset));
        fingerprint_hasher.update(std.mem.asBytes(&funding.amount.atoms));
        const fingerprint = fingerprint_hasher.final();
        if (try self.remember(funding.identity, .funding, fingerprint)) return;
        if (self.portfolio.swap.quantity == 0) {
            self.exchange.usdt_balance_micros = try std.math.add(i64, self.exchange.usdt_balance_micros, amount);
            self.exchange.funding_micros = try std.math.add(i64, self.exchange.funding_micros, amount);
            self.suspense_usdt_micros = try std.math.add(i64, self.suspense_usdt_micros, amount);
            try self.openBreak(funding.identity);
            try self.appendLedger(funding.identity, .funding, .exchange, .funding_pnl, amount);
            return;
        }
        self.portfolio.usdt_balance_micros = try std.math.add(i64, self.portfolio.usdt_balance_micros, amount);
        self.exchange.usdt_balance_micros = try std.math.add(i64, self.exchange.usdt_balance_micros, amount);
        self.portfolio.funding_micros = try std.math.add(i64, self.portfolio.funding_micros, amount);
        self.exchange.funding_micros = try std.math.add(i64, self.exchange.funding_micros, amount);
        try self.appendLedger(funding.identity, .funding, .portfolio, .funding_pnl, amount);
        try self.appendLedger(funding.identity, .funding, .exchange, .funding_pnl, amount);
    }

    fn applyForced(self: *Projection, forced: VenueForcedExecution) !void {
        if (forced.quantity.lots <= 0 or forced.price.ticks <= 0 or
            forced.quantity.instrument != forced.price.instrument or
            forced.quantity.rules_version != forced.price.rules_version or
            (forced.fee.atoms != 0 and forced.fee.asset != self.settlement_asset) or
            (forced.penalty.atoms != 0 and forced.penalty.asset != self.settlement_asset) or
            forced.fee.atoms < 0 or forced.penalty.atoms < 0)
            return error.InvalidEconomicFact;
        const quantity = std.math.cast(i64, forced.quantity.lots) orelse return error.Overflow;
        const fee = std.math.cast(i64, forced.fee.atoms) orelse return error.Overflow;
        const penalty = std.math.cast(i64, forced.penalty.atoms) orelse return error.Overflow;
        const fill: Fill = .{
            .identity = forced.identity,
            .side = forced.side,
            .quantity = forced.quantity,
            .price = forced.price,
            .quantity_denominator = forced.quantity_denominator,
            .fee = forced.fee,
            .portfolio_margin_ppm = forced.portfolio_margin_ppm,
            .exchange_margin_ppm = forced.exchange_margin_ppm,
        };
        const fingerprint = fingerprintForced(forced);
        for (self.seen[0..self.seen_count]) |known| {
            if (known.identity == forced.identity and known.kind == .forced_execution) {
                if (known.fingerprint != fingerprint) return error.ConflictingEconomicIdentity;
                return;
            }
        }
        const closes_portfolio = self.portfolio.swap.quantity != 0 and
            ((self.portfolio.swap.quantity > 0 and forced.side == .sell) or (self.portfolio.swap.quantity < 0 and forced.side == .buy)) and
            quantity <= abs(self.portfolio.swap.quantity);
        if (closes_portfolio) {
            if (self.seen_count == max_facts) return error.EconomicFactCapacityExceeded;
            self.seen[self.seen_count] = .{ .identity = forced.identity, .kind = .forced_execution, .fingerprint = fingerprint };
            self.seen_count += 1;
            var portfolio = self.portfolio;
            var exchange = self.exchange;
            const portfolio_movement = try applyFillToLayer(&portfolio, fill);
            const exchange_movement = try applyFillToLayer(&exchange, fill);
            portfolio.margin_micros = try rateMicros(portfolio.swap.open_cost_micros, fill.portfolio_margin_ppm);
            exchange.margin_micros = try rateMicros(exchange.swap.open_cost_micros, fill.exchange_margin_ppm);
            const position_delta: i64 = if (forced.side == .buy) quantity else -quantity;
            try self.appendPositionLedger(forced.identity, .forced_execution, .portfolio, forced.quantity.instrument, position_delta);
            try self.appendPositionLedger(forced.identity, .forced_execution, .exchange, forced.quantity.instrument, position_delta);
            try self.appendLedger(forced.identity, .forced_execution, .portfolio, .trade, portfolio_movement);
            try self.appendLedger(forced.identity, .forced_execution, .exchange, .trade, exchange_movement);
            if (fee > 0) {
                try self.appendLedger(forced.identity, .forced_execution, .portfolio, .fee_expense, -fee);
                try self.appendLedger(forced.identity, .forced_execution, .exchange, .fee_expense, -fee);
            }
            self.portfolio = portfolio;
            self.exchange = exchange;
            self.quantity_denominator = forced.quantity_denominator;
            self.portfolio.penalty_micros = try std.math.add(i64, self.portfolio.penalty_micros, penalty);
            self.exchange.penalty_micros = try std.math.add(i64, self.exchange.penalty_micros, penalty);
            self.portfolio.usdt_balance_micros = try std.math.sub(i64, self.portfolio.usdt_balance_micros, penalty);
            self.exchange.usdt_balance_micros = try std.math.sub(i64, self.exchange.usdt_balance_micros, penalty);
            if (penalty > 0) {
                try self.appendLedger(forced.identity, .forced_execution, .portfolio, .penalty_expense, -penalty);
                try self.appendLedger(forced.identity, .forced_execution, .exchange, .penalty_expense, -penalty);
            }
            return;
        }
        if (self.seen_count == max_facts) return error.EconomicFactCapacityExceeded;
        self.seen[self.seen_count] = .{ .identity = forced.identity, .kind = .forced_execution, .fingerprint = fingerprint };
        self.seen_count += 1;
        var exchange = self.exchange;
        const movement = try applyFillToLayer(&exchange, fill);
        exchange.penalty_micros = try std.math.add(i64, exchange.penalty_micros, penalty);
        exchange.usdt_balance_micros = try std.math.sub(i64, exchange.usdt_balance_micros, penalty);
        const cash_change = try std.math.sub(i64, exchange.usdt_balance_micros, self.exchange.usdt_balance_micros);
        const position_delta: i64 = if (forced.side == .buy) quantity else -quantity;
        try self.appendPositionLedger(forced.identity, .forced_execution, .exchange, forced.quantity.instrument, position_delta);
        try self.appendLedger(forced.identity, .forced_execution, .exchange, .trade, movement);
        if (fee > 0) try self.appendLedger(forced.identity, .forced_execution, .exchange, .fee_expense, -fee);
        if (penalty > 0) try self.appendLedger(forced.identity, .forced_execution, .exchange, .penalty_expense, -penalty);
        self.suspense_usdt_micros = try std.math.add(i64, self.suspense_usdt_micros, cash_change);
        self.exchange = exchange;
        self.quantity_denominator = forced.quantity_denominator;
        try self.openBreak(forced.identity);
    }

    fn reconcile(self: *Projection, snapshot: AccountSnapshot) !void {
        if (snapshot.balance.asset != self.settlement_asset or snapshot.margin.asset != self.settlement_asset)
            return error.InvalidEconomicFact;
        const balance = std.math.cast(i64, snapshot.balance.atoms) orelse return error.Overflow;
        const margin = std.math.cast(i64, snapshot.margin.atoms) orelse return error.Overflow;
        var hash = std.hash.Wyhash.init(0);
        hash.update(std.mem.asBytes(&snapshot.identity));
        hash.update(std.mem.asBytes(&snapshot.balance.asset));
        hash.update(std.mem.asBytes(&snapshot.balance.atoms));
        hash.update(std.mem.asBytes(&snapshot.spot_asset_quantity));
        hash.update(std.mem.asBytes(&snapshot.swap_position_quantity));
        hash.update(std.mem.asBytes(&snapshot.margin.asset));
        hash.update(std.mem.asBytes(&snapshot.margin.atoms));
        if (try self.remember(snapshot.identity, .account_snapshot, hash.final())) return;
        const differs = balance != self.exchange.usdt_balance_micros or
            snapshot.spot_asset_quantity != self.exchange.spot_asset_quantity or
            snapshot.swap_position_quantity != self.exchange.swap.quantity or
            margin != self.exchange.margin_micros;
        if (differs) {
            try self.openBreak(snapshot.identity);
        }
    }

    fn valueAt(self: *Projection, price: i64) !void {
        if (price <= 0) return error.InvalidEconomicFact;
        self.mark_price_micros = price;
        self.portfolio.unrealized_pnl_micros = try std.math.add(i64, try unrealized(self.portfolio.spot, price, self.quantity_denominator), try unrealized(self.portfolio.swap, price, self.quantity_denominator));
        self.exchange.unrealized_pnl_micros = try std.math.add(i64, try unrealized(self.exchange.spot, price, self.quantity_denominator), try unrealized(self.exchange.swap, price, self.quantity_denominator));
    }

    fn remember(self: *Projection, identity: u64, kind: FactKind, fingerprint: u64) !bool {
        for (self.seen[0..self.seen_count]) |known| {
            if (known.identity == identity and known.kind == kind) {
                if (known.fingerprint != fingerprint) return error.ConflictingEconomicIdentity;
                return true;
            }
        }
        if (self.seen_count == max_facts) return error.EconomicFactCapacityExceeded;
        self.seen[self.seen_count] = .{ .identity = identity, .kind = kind, .fingerprint = fingerprint };
        self.seen_count += 1;
        return false;
    }

    fn appendLedger(self: *Projection, identity: u64, kind: FactKind, layer: LedgerLayer, account: LedgerAccount, cash_delta: i64) !void {
        if (cash_delta == 0) return;
        if (self.ledger_count == max_ledger_transactions) return error.LedgerCapacityExceeded;
        self.ledger[self.ledger_count] = .{
            .source_identity = identity,
            .kind = kind,
            .layer = layer,
            .posting_count = 2,
            .postings = .{ .{ .account = .cash, .unit = .settlement_atoms, .amount = cash_delta }, .{ .account = account, .unit = .settlement_atoms, .amount = try std.math.sub(i64, 0, cash_delta) }, undefined, undefined },
        };
        self.ledger_count += 1;
    }

    fn appendPositionLedger(self: *Projection, identity: u64, kind: FactKind, layer: LedgerLayer, instrument: Instrument, quantity_delta: i64) !void {
        if (quantity_delta == 0) return;
        if (self.ledger_count == max_ledger_transactions) return error.LedgerCapacityExceeded;
        const unit: LedgerUnit = if (instrument == spot_instrument) .spot_quantity else .swap_quantity;
        const account: LedgerAccount = if (instrument == spot_instrument) .spot_asset else .swap_position;
        self.ledger[self.ledger_count] = .{
            .source_identity = identity,
            .kind = kind,
            .layer = layer,
            .posting_count = 2,
            .postings = .{ .{ .account = account, .unit = unit, .amount = quantity_delta }, .{ .account = .trade, .unit = unit, .amount = try std.math.sub(i64, 0, quantity_delta) }, undefined, undefined },
        };
        self.ledger_count += 1;
    }

    fn openBreak(self: *Projection, identity: u64) !void {
        for (self.reconciliation_break_identities[0..self.reconciliation_break_count]) |known| if (known == identity) return;
        if (self.reconciliation_break_count == max_facts) return error.ReconciliationBreakCapacityExceeded;
        self.reconciliation_break_identities[self.reconciliation_break_count] = identity;
        self.reconciliation_break_count += 1;
        self.reconciliation_break = true;
        self.reconciliation_break_identity = identity;
    }
};

fn hashLayer(hasher: *Sha256, layer: Layer) void {
    hashInt(hasher, i64, layer.usdt_balance_micros);
    hashInt(hasher, i64, layer.spot_asset_quantity);
    hashInt(hasher, i64, layer.spot.quantity);
    hashInt(hasher, i64, layer.spot.open_cost_micros);
    hashInt(hasher, i64, layer.swap.quantity);
    hashInt(hasher, i64, layer.swap.open_cost_micros);
    hashInt(hasher, i64, layer.margin_micros);
    hashInt(hasher, i64, layer.fee_micros);
    hashInt(hasher, i64, layer.rebate_micros);
    hashInt(hasher, i64, layer.funding_micros);
    hashInt(hasher, i64, layer.penalty_micros);
    hashInt(hasher, i64, layer.realized_pnl_micros);
    hashInt(hasher, i64, layer.unrealized_pnl_micros);
}

fn hashInt(hasher: *Sha256, comptime T: type, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hasher.update(&bytes);
}

fn sameAttributedEconomics(portfolio: Layer, exchange: Layer) bool {
    return portfolio.spot_asset_quantity == exchange.spot_asset_quantity and
        std.meta.eql(portfolio.spot, exchange.spot) and
        std.meta.eql(portfolio.swap, exchange.swap) and
        portfolio.fee_micros == exchange.fee_micros and
        portfolio.rebate_micros == exchange.rebate_micros and
        portfolio.funding_micros == exchange.funding_micros and
        portfolio.penalty_micros == exchange.penalty_micros and
        portfolio.realized_pnl_micros == exchange.realized_pnl_micros and
        portfolio.unrealized_pnl_micros == exchange.unrealized_pnl_micros;
}

fn applyFillToLayer(layer: *Layer, fill: Fill) !i64 {
    const quantity = std.math.cast(i64, fill.quantity.lots) orelse return error.Overflow;
    const price = std.math.cast(i64, fill.price.ticks) orelse return error.Overflow;
    const fee = std.math.cast(i64, fill.fee.atoms) orelse return error.Overflow;
    const rebate = std.math.cast(i64, fill.rebate.atoms) orelse return error.Overflow;
    const notional = try ceilPositive(@as(i128, quantity) * price, fill.quantity_denominator);
    const net_fee = try std.math.sub(i64, fee, rebate);
    layer.fee_micros = try std.math.add(i64, layer.fee_micros, fee);
    layer.rebate_micros = try std.math.add(i64, layer.rebate_micros, rebate);
    if (fill.quantity.instrument == spot_instrument) {
        const direction: i64 = if (fill.side == .buy) 1 else -1;
        const next_asset = try std.math.add(i64, layer.spot_asset_quantity, try std.math.mul(i64, direction, quantity));
        if (next_asset < 0) return error.InsufficientSpotAsset;
        const realized = try updatePosition(&layer.spot, direction, quantity, notional);
        layer.spot_asset_quantity = next_asset;
        const trade_cash_delta = if (fill.side == .buy) -notional else notional;
        layer.usdt_balance_micros = try std.math.add(i64, layer.usdt_balance_micros, try std.math.sub(i64, trade_cash_delta, net_fee));
        layer.realized_pnl_micros = try std.math.add(i64, layer.realized_pnl_micros, realized);
        return trade_cash_delta;
    } else if (fill.quantity.instrument == swap_instrument) {
        const direction: i64 = if (fill.side == .buy) 1 else -1;
        const realized = try updatePosition(&layer.swap, direction, quantity, notional);
        layer.usdt_balance_micros = try std.math.add(i64, layer.usdt_balance_micros, try std.math.sub(i64, realized, net_fee));
        layer.realized_pnl_micros = try std.math.add(i64, layer.realized_pnl_micros, realized);
        return realized;
    } else return error.UnknownInstrument;
}

fn updatePosition(position: *Position, direction: i64, quantity: i64, notional: i64) !i64 {
    const signed_quantity = try std.math.mul(i64, direction, quantity);
    if (position.quantity == 0 or (position.quantity > 0) == (signed_quantity > 0)) {
        position.quantity = try std.math.add(i64, position.quantity, signed_quantity);
        position.open_cost_micros = try std.math.add(i64, position.open_cost_micros, notional);
        return 0;
    }
    const closing = @min(abs(position.quantity), quantity);
    const released_cost = std.math.cast(i64, @divFloor(@as(i128, position.open_cost_micros) * closing, abs(position.quantity))) orelse return error.Overflow;
    const closing_notional = std.math.cast(i64, @divFloor(@as(i128, notional) * closing, quantity)) orelse return error.Overflow;
    const realized = if (position.quantity > 0) closing_notional - released_cost else released_cost - closing_notional;
    const next = try std.math.add(i64, position.quantity, signed_quantity);
    if (next == 0) {
        position.* = .{};
    } else if ((next > 0) == (position.quantity > 0)) {
        position.quantity = next;
        position.open_cost_micros = try std.math.sub(i64, position.open_cost_micros, released_cost);
    } else {
        position.quantity = next;
        position.open_cost_micros = try std.math.sub(i64, notional, closing_notional);
    }
    return realized;
}

fn unrealized(position: Position, price: i64, denominator: i64) !i64 {
    if (position.quantity == 0) return 0;
    const value = try ceilPositive(@as(i128, abs(position.quantity)) * price, denominator);
    return if (position.quantity > 0) value - position.open_cost_micros else position.open_cost_micros - value;
}

fn fingerprintFill(fill: Fill) u64 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(std.mem.asBytes(&fill.identity));
    hash.update(std.mem.asBytes(&fill.quantity.instrument));
    hash.update(std.mem.asBytes(&fill.quantity.rules_version));
    hash.update(&.{@intFromEnum(fill.side)});
    hash.update(std.mem.asBytes(&fill.quantity.lots));
    hash.update(std.mem.asBytes(&fill.price.ticks));
    hash.update(std.mem.asBytes(&fill.quantity_denominator));
    hash.update(std.mem.asBytes(&fill.fee.asset));
    hash.update(std.mem.asBytes(&fill.fee.atoms));
    hash.update(std.mem.asBytes(&fill.rebate.asset));
    hash.update(std.mem.asBytes(&fill.rebate.atoms));
    hash.update(std.mem.asBytes(&fill.portfolio_margin_ppm));
    hash.update(std.mem.asBytes(&fill.exchange_margin_ppm));
    return hash.final();
}

fn fingerprintForced(forced: VenueForcedExecution) u64 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(std.mem.asBytes(&forced.identity));
    hash.update(&.{@intFromEnum(forced.side)});
    hash.update(std.mem.asBytes(&forced.quantity.instrument));
    hash.update(std.mem.asBytes(&forced.quantity.rules_version));
    hash.update(std.mem.asBytes(&forced.quantity.lots));
    hash.update(std.mem.asBytes(&forced.price.ticks));
    hash.update(std.mem.asBytes(&forced.quantity_denominator));
    hash.update(std.mem.asBytes(&forced.fee.asset));
    hash.update(std.mem.asBytes(&forced.fee.atoms));
    hash.update(std.mem.asBytes(&forced.penalty.asset));
    hash.update(std.mem.asBytes(&forced.penalty.atoms));
    hash.update(std.mem.asBytes(&forced.portfolio_margin_ppm));
    hash.update(std.mem.asBytes(&forced.exchange_margin_ppm));
    return hash.final();
}

fn abs(value: i64) i64 {
    return std.math.cast(i64, if (@as(i128, value) < 0) -@as(i128, value) else @as(i128, value)) orelse std.math.maxInt(i64);
}

fn ceilPositive(numerator: i128, denominator: i128) !i64 {
    if (numerator < 0 or denominator <= 0) return error.InvalidEconomicFact;
    return std.math.cast(i64, @divFloor(numerator + denominator - 1, denominator)) orelse error.Overflow;
}

fn rateMicros(notional: i64, ppm: i64) !i64 {
    if (ppm < 0) return error.InvalidEconomicFact;
    return ceilPositive(@as(i128, notional) * ppm, 1_000_000);
}

fn fixtureQuantity(lots: i128) canonical.InstrumentQuantity {
    return .{ .instrument = swap_instrument, .rules_version = 1, .lots = lots };
}

fn fixturePrice(ticks: i128) canonical.InstrumentPrice {
    return .{ .instrument = swap_instrument, .rules_version = 1, .ticks = ticks };
}

fn fixtureAmount(atoms: i128) canonical.AssetAmount {
    return .{ .asset = settlement_asset, .atoms = atoms };
}

test "partial fills close two layers with average cost fees rebates margin and valuation" {
    var projection: Projection = .{};
    projection.portfolio.usdt_balance_micros = 10_000_000;
    projection.exchange.usdt_balance_micros = 10_000_000;
    try projection.apply(.{ .fill = .{ .identity = 1, .side = .buy, .quantity = fixtureQuantity(4), .price = fixturePrice(100), .quantity_denominator = 1, .fee = fixtureAmount(3), .rebate = fixtureAmount(1), .portfolio_margin_ppm = 100_000, .exchange_margin_ppm = 80_000 } });
    try projection.apply(.{ .fill = .{ .identity = 2, .side = .buy, .quantity = fixtureQuantity(6), .price = fixturePrice(110), .quantity_denominator = 1, .fee = fixtureAmount(4), .portfolio_margin_ppm = 100_000, .exchange_margin_ppm = 80_000 } });
    try projection.apply(.{ .fill = .{ .identity = 3, .side = .sell, .quantity = fixtureQuantity(5), .price = fixturePrice(120), .quantity_denominator = 1, .fee = fixtureAmount(2), .portfolio_margin_ppm = 100_000, .exchange_margin_ppm = 80_000 } });
    try projection.apply(.{ .mark_price = 115 });
    try std.testing.expectEqual(@as(i64, 5), projection.portfolio.swap.quantity);
    try std.testing.expectEqual(@as(i64, 530), projection.portfolio.swap.open_cost_micros);
    try std.testing.expectEqual(@as(i64, 70), projection.portfolio.realized_pnl_micros);
    try std.testing.expectEqual(@as(i64, 45), projection.portfolio.unrealized_pnl_micros);
    try std.testing.expectEqual(@as(i64, 53), projection.portfolio.margin_micros);
    try std.testing.expectEqual(@as(i64, 43), projection.exchange.margin_micros);
    try std.testing.expectEqual(@as(i64, 9), projection.portfolio.fee_micros);
    try std.testing.expectEqual(@as(i64, 1), projection.portfolio.rebate_micros);
    try std.testing.expectEqual(@as(u8, 16), projection.ledger_count);
    try projection.assertClosed();
}

test "funding and forced execution are idempotent and unowned facts enter suspense" {
    var projection: Projection = .{};
    projection.treasury_usdt_micros = 1_000;
    projection.exchange.usdt_balance_micros = 1_000;
    try projection.apply(.{ .funding_settlement = .{ .identity = 10, .amount = fixtureAmount(-25) } });
    try projection.apply(.{ .funding_settlement = .{ .identity = 10, .amount = fixtureAmount(-25) } });
    try std.testing.expectEqual(@as(i64, -25), projection.suspense_usdt_micros);
    try std.testing.expect(projection.reconciliation_break);
    try std.testing.expectEqual(@as(u8, 1), projection.ledger_count);
    try std.testing.expectError(error.ConflictingEconomicIdentity, projection.apply(.{ .funding_settlement = .{ .identity = 10, .amount = fixtureAmount(-26) } }));

    try projection.apply(.{ .venue_forced_execution = .{ .identity = 11, .side = .sell, .quantity = fixtureQuantity(2), .price = fixturePrice(100), .quantity_denominator = 1, .fee = fixtureAmount(3), .penalty = fixtureAmount(2) } });
    try projection.apply(.{ .venue_forced_execution = .{ .identity = 11, .side = .sell, .quantity = fixtureQuantity(2), .price = fixturePrice(100), .quantity_denominator = 1, .fee = fixtureAmount(3), .penalty = fixtureAmount(2) } });
    try std.testing.expectEqual(@as(i64, -2), projection.exchange.swap.quantity);
    try std.testing.expectEqual(@as(i64, -30), projection.suspense_usdt_micros);
    try std.testing.expectEqual(@as(u8, 4), projection.ledger_count);
    try projection.assertClosed();
}

test "account snapshot opens a break without overwriting local economics" {
    var projection: Projection = .{};
    projection.treasury_usdt_micros = 1_000;
    projection.exchange.usdt_balance_micros = 1_000;
    const before = projection.exchange;
    try projection.apply(.{ .account_snapshot = .{ .identity = 20, .balance = fixtureAmount(999), .spot_asset_quantity = 0, .swap_position_quantity = 7, .margin = fixtureAmount(55) } });
    try std.testing.expect(projection.reconciliation_break);
    try std.testing.expectEqual(@as(u64, 20), projection.reconciliation_break_identity);
    try std.testing.expectEqual(@as(u8, 1), projection.reconciliation_break_count);
    try std.testing.expectEqualDeep(before, projection.exchange);
    try std.testing.expectEqual(@as(u8, 0), projection.ledger_count);
    try projection.apply(.{ .account_snapshot = .{ .identity = 21, .balance = fixtureAmount(998), .spot_asset_quantity = 0, .swap_position_quantity = 8, .margin = fixtureAmount(56) } });
    try std.testing.expectEqual(@as(u8, 2), projection.reconciliation_break_count);
    try std.testing.expectEqual(@as(u64, 20), projection.reconciliation_break_identities[0]);
    try std.testing.expectEqual(@as(u64, 21), projection.reconciliation_break_identities[1]);
}

test "duplicate attributed forced execution cannot charge penalty twice" {
    var projection: Projection = .{};
    projection.portfolio.usdt_balance_micros = 1_000;
    projection.exchange.usdt_balance_micros = 1_000;
    try projection.apply(.{ .fill = .{ .identity = 1, .side = .buy, .quantity = fixtureQuantity(10), .price = fixturePrice(100), .quantity_denominator = 1 } });
    const forced: Event = .{ .venue_forced_execution = .{ .identity = 2, .side = .sell, .quantity = fixtureQuantity(2), .price = fixturePrice(90), .quantity_denominator = 1, .fee = fixtureAmount(3), .penalty = fixtureAmount(5) } };
    try projection.apply(forced);
    const after = projection;
    try projection.apply(forced);
    try std.testing.expectEqualDeep(after, projection);
    try std.testing.expectError(error.ConflictingEconomicIdentity, projection.apply(.{ .venue_forced_execution = .{ .identity = 2, .side = .sell, .quantity = fixtureQuantity(2), .price = fixturePrice(90), .quantity_denominator = 1, .fee = fixtureAmount(3), .penalty = fixtureAmount(6) } }));
}

test "negative forced penalty is rejected without changing projection" {
    var projection: Projection = .{};
    projection.treasury_usdt_micros = 1_000;
    projection.exchange.usdt_balance_micros = 1_000;
    const before = projection;
    try std.testing.expectError(error.InvalidEconomicFact, projection.apply(.{ .venue_forced_execution = .{ .identity = 1, .side = .sell, .quantity = fixtureQuantity(1), .price = fixturePrice(100), .quantity_denominator = 1, .penalty = fixtureAmount(-1) } }));
    try std.testing.expectEqualDeep(before, projection);
}

test "valuation respects the contract quantity denominator" {
    var projection: Projection = .{};
    projection.portfolio.usdt_balance_micros = 1_000;
    projection.exchange.usdt_balance_micros = 1_000;
    try projection.apply(.{ .fill = .{ .identity = 1, .side = .buy, .quantity = fixtureQuantity(10), .price = fixturePrice(100), .quantity_denominator = 10 } });
    try projection.apply(.{ .mark_price = 120 });
    try std.testing.expectEqual(@as(i64, 20), projection.portfolio.unrealized_pnl_micros);
}

test "ledger postings reproduce signed fee rebate and funding cash movements" {
    var projection: Projection = .{};
    projection.portfolio.usdt_balance_micros = 1_000;
    projection.exchange.usdt_balance_micros = 1_000;
    try projection.apply(.{ .fill = .{ .identity = 1, .side = .buy, .quantity = fixtureQuantity(1), .price = fixturePrice(100), .quantity_denominator = 1, .fee = fixtureAmount(3), .rebate = fixtureAmount(1) } });
    try projection.apply(.{ .funding_settlement = .{ .identity = 2, .amount = fixtureAmount(7) } });

    try std.testing.expectEqual(@as(i64, 1_005), projection.portfolio.usdt_balance_micros);
    try std.testing.expectEqual(@as(u8, 8), projection.ledger_count);
    try std.testing.expectEqualDeep(LedgerPosting{ .account = .swap_position, .unit = .swap_quantity, .amount = 1 }, projection.ledger[0].postings[0]);
    try std.testing.expectEqualDeep(LedgerPosting{ .account = .trade, .unit = .swap_quantity, .amount = -1 }, projection.ledger[0].postings[1]);
    try std.testing.expectEqualDeep(LedgerPosting{ .account = .cash, .unit = .settlement_atoms, .amount = -3 }, projection.ledger[2].postings[0]);
    try std.testing.expectEqualDeep(LedgerPosting{ .account = .fee_expense, .unit = .settlement_atoms, .amount = 3 }, projection.ledger[2].postings[1]);
    try std.testing.expectEqualDeep(LedgerPosting{ .account = .cash, .unit = .settlement_atoms, .amount = 1 }, projection.ledger[4].postings[0]);
    try std.testing.expectEqualDeep(LedgerPosting{ .account = .rebate_income, .unit = .settlement_atoms, .amount = -1 }, projection.ledger[4].postings[1]);
    try std.testing.expectEqualDeep(LedgerPosting{ .account = .cash, .unit = .settlement_atoms, .amount = 7 }, projection.ledger[6].postings[0]);
    try std.testing.expectEqualDeep(LedgerPosting{ .account = .funding_pnl, .unit = .settlement_atoms, .amount = -7 }, projection.ledger[6].postings[1]);
    try projection.assertClosed();
}
