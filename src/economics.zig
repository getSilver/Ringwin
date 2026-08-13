const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const max_facts = 32;
pub const max_ledger_transactions = 64;

pub const Instrument = enum(u8) { btc_usdt_spot, btc_usdt_swap };
pub const Side = enum(u8) { buy, sell };
pub const FactKind = enum(u8) { fill, funding, forced_execution, account_snapshot };
pub const LedgerLayer = enum(u8) { portfolio, exchange };
pub const LedgerUnit = enum(u8) { usdt_micros, spot_quantity, swap_quantity };
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
    instrument: Instrument,
    side: Side,
    quantity: i64,
    price_micros: i64,
    quantity_denominator: i64,
    fee_micros: i64 = 0,
    rebate_micros: i64 = 0,
    portfolio_margin_ppm: i64 = 0,
    exchange_margin_ppm: i64 = 0,
};

pub const FundingSettlement = struct {
    identity: u64,
    amount_micros: i64,
};

pub const VenueForcedExecution = struct {
    identity: u64,
    side: Side,
    quantity: i64,
    price_micros: i64,
    quantity_denominator: i64,
    fee_micros: i64 = 0,
    penalty_micros: i64 = 0,
    portfolio_margin_ppm: i64 = 0,
    exchange_margin_ppm: i64 = 0,
};

pub const AccountSnapshot = struct {
    identity: u64,
    usdt_balance_micros: i64,
    spot_asset_quantity: i64,
    swap_position_quantity: i64,
    margin_micros: i64,
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
        if (fill.quantity <= 0 or fill.price_micros <= 0 or fill.quantity_denominator <= 0 or fill.fee_micros < 0 or fill.rebate_micros < 0)
            return error.InvalidEconomicFact;
        if (self.seen_count != 0 and self.quantity_denominator != fill.quantity_denominator) return error.InconsistentQuantityDenominator;
        const fingerprint = fingerprintFill(fill);
        if (try self.remember(fill.identity, kind, fingerprint)) return;
        var portfolio = self.portfolio;
        var exchange = self.exchange;
        const portfolio_movement = try applyFillToLayer(&portfolio, fill);
        const exchange_movement = try applyFillToLayer(&exchange, fill);
        if (fill.instrument == .btc_usdt_swap) {
            portfolio.margin_micros = try rateMicros(portfolio.swap.open_cost_micros, fill.portfolio_margin_ppm);
            exchange.margin_micros = try rateMicros(exchange.swap.open_cost_micros, fill.exchange_margin_ppm);
        }
        if (portfolio_movement != exchange_movement) return error.EconomicLayerMismatch;
        const position_delta: i64 = if (fill.side == .buy) fill.quantity else -fill.quantity;
        try self.appendPositionLedger(fill.identity, kind, .portfolio, fill.instrument, position_delta);
        try self.appendPositionLedger(fill.identity, kind, .exchange, fill.instrument, position_delta);
        try self.appendLedger(fill.identity, kind, .portfolio, .trade, portfolio_movement);
        try self.appendLedger(fill.identity, kind, .exchange, .trade, exchange_movement);
        if (fill.fee_micros > 0) {
            try self.appendLedger(fill.identity, kind, .portfolio, .fee_expense, -fill.fee_micros);
            try self.appendLedger(fill.identity, kind, .exchange, .fee_expense, -fill.fee_micros);
        }
        if (fill.rebate_micros > 0) {
            try self.appendLedger(fill.identity, kind, .portfolio, .rebate_income, fill.rebate_micros);
            try self.appendLedger(fill.identity, kind, .exchange, .rebate_income, fill.rebate_micros);
        }
        self.portfolio = portfolio;
        self.exchange = exchange;
        self.quantity_denominator = fill.quantity_denominator;
    }

    fn applyFunding(self: *Projection, funding: FundingSettlement) !void {
        const fingerprint: u64 = @bitCast(funding.amount_micros);
        if (try self.remember(funding.identity, .funding, fingerprint)) return;
        if (self.portfolio.swap.quantity == 0) {
            self.exchange.usdt_balance_micros = try std.math.add(i64, self.exchange.usdt_balance_micros, funding.amount_micros);
            self.exchange.funding_micros = try std.math.add(i64, self.exchange.funding_micros, funding.amount_micros);
            self.suspense_usdt_micros = try std.math.add(i64, self.suspense_usdt_micros, funding.amount_micros);
            try self.openBreak(funding.identity);
            try self.appendLedger(funding.identity, .funding, .exchange, .funding_pnl, funding.amount_micros);
            return;
        }
        self.portfolio.usdt_balance_micros = try std.math.add(i64, self.portfolio.usdt_balance_micros, funding.amount_micros);
        self.exchange.usdt_balance_micros = try std.math.add(i64, self.exchange.usdt_balance_micros, funding.amount_micros);
        self.portfolio.funding_micros = try std.math.add(i64, self.portfolio.funding_micros, funding.amount_micros);
        self.exchange.funding_micros = try std.math.add(i64, self.exchange.funding_micros, funding.amount_micros);
        try self.appendLedger(funding.identity, .funding, .portfolio, .funding_pnl, funding.amount_micros);
        try self.appendLedger(funding.identity, .funding, .exchange, .funding_pnl, funding.amount_micros);
    }

    fn applyForced(self: *Projection, forced: VenueForcedExecution) !void {
        if (forced.penalty_micros < 0) return error.InvalidEconomicFact;
        const fill: Fill = .{
            .identity = forced.identity,
            .instrument = .btc_usdt_swap,
            .side = forced.side,
            .quantity = forced.quantity,
            .price_micros = forced.price_micros,
            .quantity_denominator = forced.quantity_denominator,
            .fee_micros = forced.fee_micros,
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
            forced.quantity <= abs(self.portfolio.swap.quantity);
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
            const position_delta: i64 = if (forced.side == .buy) forced.quantity else -forced.quantity;
            try self.appendPositionLedger(forced.identity, .forced_execution, .portfolio, .btc_usdt_swap, position_delta);
            try self.appendPositionLedger(forced.identity, .forced_execution, .exchange, .btc_usdt_swap, position_delta);
            try self.appendLedger(forced.identity, .forced_execution, .portfolio, .trade, portfolio_movement);
            try self.appendLedger(forced.identity, .forced_execution, .exchange, .trade, exchange_movement);
            if (forced.fee_micros > 0) {
                try self.appendLedger(forced.identity, .forced_execution, .portfolio, .fee_expense, -forced.fee_micros);
                try self.appendLedger(forced.identity, .forced_execution, .exchange, .fee_expense, -forced.fee_micros);
            }
            self.portfolio = portfolio;
            self.exchange = exchange;
            self.quantity_denominator = forced.quantity_denominator;
            self.portfolio.penalty_micros = try std.math.add(i64, self.portfolio.penalty_micros, forced.penalty_micros);
            self.exchange.penalty_micros = try std.math.add(i64, self.exchange.penalty_micros, forced.penalty_micros);
            self.portfolio.usdt_balance_micros = try std.math.sub(i64, self.portfolio.usdt_balance_micros, forced.penalty_micros);
            self.exchange.usdt_balance_micros = try std.math.sub(i64, self.exchange.usdt_balance_micros, forced.penalty_micros);
            if (forced.penalty_micros > 0) {
                try self.appendLedger(forced.identity, .forced_execution, .portfolio, .penalty_expense, -forced.penalty_micros);
                try self.appendLedger(forced.identity, .forced_execution, .exchange, .penalty_expense, -forced.penalty_micros);
            }
            return;
        }
        if (self.seen_count == max_facts) return error.EconomicFactCapacityExceeded;
        self.seen[self.seen_count] = .{ .identity = forced.identity, .kind = .forced_execution, .fingerprint = fingerprint };
        self.seen_count += 1;
        var exchange = self.exchange;
        const movement = try applyFillToLayer(&exchange, fill);
        exchange.penalty_micros = try std.math.add(i64, exchange.penalty_micros, forced.penalty_micros);
        exchange.usdt_balance_micros = try std.math.sub(i64, exchange.usdt_balance_micros, forced.penalty_micros);
        const cash_change = try std.math.sub(i64, exchange.usdt_balance_micros, self.exchange.usdt_balance_micros);
        const position_delta: i64 = if (forced.side == .buy) forced.quantity else -forced.quantity;
        try self.appendPositionLedger(forced.identity, .forced_execution, .exchange, .btc_usdt_swap, position_delta);
        try self.appendLedger(forced.identity, .forced_execution, .exchange, .trade, movement);
        if (forced.fee_micros > 0) try self.appendLedger(forced.identity, .forced_execution, .exchange, .fee_expense, -forced.fee_micros);
        if (forced.penalty_micros > 0) try self.appendLedger(forced.identity, .forced_execution, .exchange, .penalty_expense, -forced.penalty_micros);
        self.suspense_usdt_micros = try std.math.add(i64, self.suspense_usdt_micros, cash_change);
        self.exchange = exchange;
        self.quantity_denominator = forced.quantity_denominator;
        try self.openBreak(forced.identity);
    }

    fn reconcile(self: *Projection, snapshot: AccountSnapshot) !void {
        var hash = std.hash.Wyhash.init(0);
        hash.update(std.mem.asBytes(&snapshot.identity));
        hash.update(std.mem.asBytes(&snapshot.usdt_balance_micros));
        hash.update(std.mem.asBytes(&snapshot.spot_asset_quantity));
        hash.update(std.mem.asBytes(&snapshot.swap_position_quantity));
        hash.update(std.mem.asBytes(&snapshot.margin_micros));
        if (try self.remember(snapshot.identity, .account_snapshot, hash.final())) return;
        const differs = snapshot.usdt_balance_micros != self.exchange.usdt_balance_micros or
            snapshot.spot_asset_quantity != self.exchange.spot_asset_quantity or
            snapshot.swap_position_quantity != self.exchange.swap.quantity or
            snapshot.margin_micros != self.exchange.margin_micros;
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
            .postings = .{ .{ .account = .cash, .unit = .usdt_micros, .amount = cash_delta }, .{ .account = account, .unit = .usdt_micros, .amount = try std.math.sub(i64, 0, cash_delta) }, undefined, undefined },
        };
        self.ledger_count += 1;
    }

    fn appendPositionLedger(self: *Projection, identity: u64, kind: FactKind, layer: LedgerLayer, instrument: Instrument, quantity_delta: i64) !void {
        if (quantity_delta == 0) return;
        if (self.ledger_count == max_ledger_transactions) return error.LedgerCapacityExceeded;
        const unit: LedgerUnit = if (instrument == .btc_usdt_spot) .spot_quantity else .swap_quantity;
        const account: LedgerAccount = if (instrument == .btc_usdt_spot) .spot_asset else .swap_position;
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
    const notional = try ceilPositive(@as(i128, fill.quantity) * fill.price_micros, fill.quantity_denominator);
    const net_fee = try std.math.sub(i64, fill.fee_micros, fill.rebate_micros);
    layer.fee_micros = try std.math.add(i64, layer.fee_micros, fill.fee_micros);
    layer.rebate_micros = try std.math.add(i64, layer.rebate_micros, fill.rebate_micros);
    switch (fill.instrument) {
        .btc_usdt_spot => {
            const direction: i64 = if (fill.side == .buy) 1 else -1;
            const next_asset = try std.math.add(i64, layer.spot_asset_quantity, try std.math.mul(i64, direction, fill.quantity));
            if (next_asset < 0) return error.InsufficientSpotAsset;
            const realized = try updatePosition(&layer.spot, direction, fill.quantity, notional);
            layer.spot_asset_quantity = next_asset;
            const trade_cash_delta = if (fill.side == .buy) -notional else notional;
            layer.usdt_balance_micros = try std.math.add(i64, layer.usdt_balance_micros, try std.math.sub(i64, trade_cash_delta, net_fee));
            layer.realized_pnl_micros = try std.math.add(i64, layer.realized_pnl_micros, realized);
            return trade_cash_delta;
        },
        .btc_usdt_swap => {
            const direction: i64 = if (fill.side == .buy) 1 else -1;
            const realized = try updatePosition(&layer.swap, direction, fill.quantity, notional);
            layer.usdt_balance_micros = try std.math.add(i64, layer.usdt_balance_micros, try std.math.sub(i64, realized, net_fee));
            layer.realized_pnl_micros = try std.math.add(i64, layer.realized_pnl_micros, realized);
            return realized;
        },
    }
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
    hash.update(&.{ @intFromEnum(fill.instrument), @intFromEnum(fill.side) });
    hash.update(std.mem.asBytes(&fill.quantity));
    hash.update(std.mem.asBytes(&fill.price_micros));
    hash.update(std.mem.asBytes(&fill.quantity_denominator));
    hash.update(std.mem.asBytes(&fill.fee_micros));
    hash.update(std.mem.asBytes(&fill.rebate_micros));
    hash.update(std.mem.asBytes(&fill.portfolio_margin_ppm));
    hash.update(std.mem.asBytes(&fill.exchange_margin_ppm));
    return hash.final();
}

fn fingerprintForced(forced: VenueForcedExecution) u64 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(std.mem.asBytes(&forced.identity));
    hash.update(&.{@intFromEnum(forced.side)});
    hash.update(std.mem.asBytes(&forced.quantity));
    hash.update(std.mem.asBytes(&forced.price_micros));
    hash.update(std.mem.asBytes(&forced.quantity_denominator));
    hash.update(std.mem.asBytes(&forced.fee_micros));
    hash.update(std.mem.asBytes(&forced.penalty_micros));
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

test "partial fills close two layers with average cost fees rebates margin and valuation" {
    var projection: Projection = .{};
    projection.portfolio.usdt_balance_micros = 10_000_000;
    projection.exchange.usdt_balance_micros = 10_000_000;
    try projection.apply(.{ .fill = .{ .identity = 1, .instrument = .btc_usdt_swap, .side = .buy, .quantity = 4, .price_micros = 100, .quantity_denominator = 1, .fee_micros = 3, .rebate_micros = 1, .portfolio_margin_ppm = 100_000, .exchange_margin_ppm = 80_000 } });
    try projection.apply(.{ .fill = .{ .identity = 2, .instrument = .btc_usdt_swap, .side = .buy, .quantity = 6, .price_micros = 110, .quantity_denominator = 1, .fee_micros = 4, .portfolio_margin_ppm = 100_000, .exchange_margin_ppm = 80_000 } });
    try projection.apply(.{ .fill = .{ .identity = 3, .instrument = .btc_usdt_swap, .side = .sell, .quantity = 5, .price_micros = 120, .quantity_denominator = 1, .fee_micros = 2, .portfolio_margin_ppm = 100_000, .exchange_margin_ppm = 80_000 } });
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
    try projection.apply(.{ .funding_settlement = .{ .identity = 10, .amount_micros = -25 } });
    try projection.apply(.{ .funding_settlement = .{ .identity = 10, .amount_micros = -25 } });
    try std.testing.expectEqual(@as(i64, -25), projection.suspense_usdt_micros);
    try std.testing.expect(projection.reconciliation_break);
    try std.testing.expectEqual(@as(u8, 1), projection.ledger_count);
    try std.testing.expectError(error.ConflictingEconomicIdentity, projection.apply(.{ .funding_settlement = .{ .identity = 10, .amount_micros = -26 } }));

    try projection.apply(.{ .venue_forced_execution = .{ .identity = 11, .side = .sell, .quantity = 2, .price_micros = 100, .quantity_denominator = 1, .fee_micros = 3, .penalty_micros = 2 } });
    try projection.apply(.{ .venue_forced_execution = .{ .identity = 11, .side = .sell, .quantity = 2, .price_micros = 100, .quantity_denominator = 1, .fee_micros = 3, .penalty_micros = 2 } });
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
    try projection.apply(.{ .account_snapshot = .{ .identity = 20, .usdt_balance_micros = 999, .spot_asset_quantity = 0, .swap_position_quantity = 7, .margin_micros = 55 } });
    try std.testing.expect(projection.reconciliation_break);
    try std.testing.expectEqual(@as(u64, 20), projection.reconciliation_break_identity);
    try std.testing.expectEqual(@as(u8, 1), projection.reconciliation_break_count);
    try std.testing.expectEqualDeep(before, projection.exchange);
    try std.testing.expectEqual(@as(u8, 0), projection.ledger_count);
    try projection.apply(.{ .account_snapshot = .{ .identity = 21, .usdt_balance_micros = 998, .spot_asset_quantity = 0, .swap_position_quantity = 8, .margin_micros = 56 } });
    try std.testing.expectEqual(@as(u8, 2), projection.reconciliation_break_count);
    try std.testing.expectEqual(@as(u64, 20), projection.reconciliation_break_identities[0]);
    try std.testing.expectEqual(@as(u64, 21), projection.reconciliation_break_identities[1]);
}

test "duplicate attributed forced execution cannot charge penalty twice" {
    var projection: Projection = .{};
    projection.portfolio.usdt_balance_micros = 1_000;
    projection.exchange.usdt_balance_micros = 1_000;
    try projection.apply(.{ .fill = .{ .identity = 1, .instrument = .btc_usdt_swap, .side = .buy, .quantity = 10, .price_micros = 100, .quantity_denominator = 1 } });
    const forced: Event = .{ .venue_forced_execution = .{ .identity = 2, .side = .sell, .quantity = 2, .price_micros = 90, .quantity_denominator = 1, .fee_micros = 3, .penalty_micros = 5 } };
    try projection.apply(forced);
    const after = projection;
    try projection.apply(forced);
    try std.testing.expectEqualDeep(after, projection);
    try std.testing.expectError(error.ConflictingEconomicIdentity, projection.apply(.{ .venue_forced_execution = .{ .identity = 2, .side = .sell, .quantity = 2, .price_micros = 90, .quantity_denominator = 1, .fee_micros = 3, .penalty_micros = 6 } }));
}

test "negative forced penalty is rejected without changing projection" {
    var projection: Projection = .{};
    projection.treasury_usdt_micros = 1_000;
    projection.exchange.usdt_balance_micros = 1_000;
    const before = projection;
    try std.testing.expectError(error.InvalidEconomicFact, projection.apply(.{ .venue_forced_execution = .{ .identity = 1, .side = .sell, .quantity = 1, .price_micros = 100, .quantity_denominator = 1, .penalty_micros = -1 } }));
    try std.testing.expectEqualDeep(before, projection);
}

test "valuation respects the contract quantity denominator" {
    var projection: Projection = .{};
    projection.portfolio.usdt_balance_micros = 1_000;
    projection.exchange.usdt_balance_micros = 1_000;
    try projection.apply(.{ .fill = .{ .identity = 1, .instrument = .btc_usdt_swap, .side = .buy, .quantity = 10, .price_micros = 100, .quantity_denominator = 10 } });
    try projection.apply(.{ .mark_price = 120 });
    try std.testing.expectEqual(@as(i64, 20), projection.portfolio.unrealized_pnl_micros);
}

test "ledger postings reproduce signed fee rebate and funding cash movements" {
    var projection: Projection = .{};
    projection.portfolio.usdt_balance_micros = 1_000;
    projection.exchange.usdt_balance_micros = 1_000;
    try projection.apply(.{ .fill = .{ .identity = 1, .instrument = .btc_usdt_swap, .side = .buy, .quantity = 1, .price_micros = 100, .quantity_denominator = 1, .fee_micros = 3, .rebate_micros = 1 } });
    try projection.apply(.{ .funding_settlement = .{ .identity = 2, .amount_micros = 7 } });

    try std.testing.expectEqual(@as(i64, 1_005), projection.portfolio.usdt_balance_micros);
    try std.testing.expectEqual(@as(u8, 8), projection.ledger_count);
    try std.testing.expectEqualDeep(LedgerPosting{ .account = .swap_position, .unit = .swap_quantity, .amount = 1 }, projection.ledger[0].postings[0]);
    try std.testing.expectEqualDeep(LedgerPosting{ .account = .trade, .unit = .swap_quantity, .amount = -1 }, projection.ledger[0].postings[1]);
    try std.testing.expectEqualDeep(LedgerPosting{ .account = .cash, .unit = .usdt_micros, .amount = -3 }, projection.ledger[2].postings[0]);
    try std.testing.expectEqualDeep(LedgerPosting{ .account = .fee_expense, .unit = .usdt_micros, .amount = 3 }, projection.ledger[2].postings[1]);
    try std.testing.expectEqualDeep(LedgerPosting{ .account = .cash, .unit = .usdt_micros, .amount = 1 }, projection.ledger[4].postings[0]);
    try std.testing.expectEqualDeep(LedgerPosting{ .account = .rebate_income, .unit = .usdt_micros, .amount = -1 }, projection.ledger[4].postings[1]);
    try std.testing.expectEqualDeep(LedgerPosting{ .account = .cash, .unit = .usdt_micros, .amount = 7 }, projection.ledger[6].postings[0]);
    try std.testing.expectEqualDeep(LedgerPosting{ .account = .funding_pnl, .unit = .usdt_micros, .amount = -7 }, projection.ledger[6].postings[1]);
    try projection.assertClosed();
}
