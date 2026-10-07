const std = @import("std");
const canonical = @import("canonical_event.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

test "third native fees and rebates preserve explicit opening ownership and incomplete valuation" {
    var projection: Projection = .{};
    try projection.openNativeBalances(&.{.{ .asset = 99, .atoms = 10_000 }});
    try projection.apply(.{ .fill = .{
        .identity = 1,
        .side = .buy,
        .product = .spot,
        .quantity = fixtureQuantity(1),
        .price = fixturePrice(100),
        .price_tick_value = fixtureAmount(1),
        .quantity_denominator = 1,
        .base_atom_value = .{ .asset = 2, .atoms = 1 },
        .native_fee = .{ .asset = 99, .atoms = 100 },
        .native_rebate = .{ .asset = 99, .atoms = 50 },
    } });
    try std.testing.expectEqual(@as(i128, -50), projection.portfolio.nativeAsset(99).?.balance_atoms);
    try std.testing.expectEqual(@as(i128, 9_950), projection.exchange.nativeAsset(99).?.balance_atoms);
    try std.testing.expectEqual(@as(i128, 100), projection.portfolio.nativeAsset(99).?.fee_atoms);
    try std.testing.expectEqual(@as(i128, 50), projection.portfolio.nativeAsset(99).?.rebate_atoms);
    try std.testing.expectEqual(@as(i128, 10_000), projection.treasury_native_assets[0].atoms);
    try std.testing.expect(!projection.reportingValuationComplete());
    try projection.assertClosed();
}

pub const max_facts = 32;
pub const max_ledger_transactions = 64;

pub const Instrument = canonical.InstrumentIdentity;
const settlement_asset: canonical.AssetIdentity = 1;
pub const Side = enum(u8) { buy, sell };
pub const FactKind = enum(u8) { fill, funding, forced_execution, account_snapshot };
pub const LedgerLayer = enum(u8) { portfolio, exchange };
pub const LedgerUnit = enum(u8) { settlement_atoms, base_atoms, swap_quantity, native_asset_atoms };
pub const LedgerAccount = enum(u8) { cash, spot_asset, swap_position, trade, fee_expense, rebate_income, funding_pnl, penalty_expense };
pub const max_postings = 4;

pub const Position = struct {
    quantity: i64 = 0,
    open_cost_atoms: i128 = 0,
};

pub const max_native_assets = canonical.max_asset_definitions;
pub const NativeAssetState = struct {
    asset: canonical.AssetIdentity = 0,
    balance_atoms: i128 = 0,
    fee_atoms: i128 = 0,
    rebate_atoms: i128 = 0,
};

pub const Layer = struct {
    native_assets: [max_native_assets]NativeAssetState = @splat(.{}),
    native_asset_count: u8 = 0,
    usdt_balance_atoms: i128 = 0,
    spot_asset_atoms: i128 = 0,
    spot: Position = .{},
    swap: Position = .{},
    margin_atoms: i128 = 0,
    base_fee_atoms: i128 = 0,
    base_rebate_atoms: i128 = 0,
    fee_atoms: i128 = 0,
    rebate_atoms: i128 = 0,
    funding_atoms: i128 = 0,
    penalty_atoms: i128 = 0,
    realized_pnl_atoms: i128 = 0,
    unrealized_pnl_atoms: i128 = 0,

    pub fn nativeAsset(self: *const Layer, asset: canonical.AssetIdentity) ?NativeAssetState {
        for (self.native_assets[0..self.native_asset_count]) |entry| if (entry.asset == asset) return entry;
        return null;
    }

    fn nativeAssetMutable(self: *Layer, asset: canonical.AssetIdentity) !*NativeAssetState {
        if (asset == 0) return error.InvalidEconomicFact;
        for (self.native_assets[0..self.native_asset_count]) |*entry| if (entry.asset == asset) return entry;
        if (self.native_asset_count == max_native_assets) return error.NativeAssetCapacityExceeded;
        self.native_assets[self.native_asset_count] = .{ .asset = asset };
        self.native_asset_count += 1;
        return &self.native_assets[self.native_asset_count - 1];
    }
};

pub const LedgerTransaction = struct {
    source_identity: u64,
    kind: FactKind,
    layer: LedgerLayer,
    postings: [max_postings]LedgerPosting = undefined,
    posting_count: u8,
};

pub const LedgerPosting = struct { account: LedgerAccount, unit: LedgerUnit, asset: canonical.AssetIdentity = 0, amount: i128 };

/// Lifecycle ledger facts that are not represented by a market transaction
/// posting. Kept inside the economic projection so TradingShard has no second
/// ledger state to synchronize.
pub const LedgerSummary = struct {
    transaction_count: u64 = 0,
    portfolio_transfer_count: u64 = 0,
    portfolio_debits_atoms: i128 = 0,
    portfolio_credits_atoms: i128 = 0,
    exchange_debits_atoms: i128 = 0,
    exchange_credits_atoms: i128 = 0,
    projections_complete: bool = false,
};

pub const Fill = struct {
    identity: u64,
    order_id: u64 = 0,
    side: Side,
    quantity: canonical.InstrumentQuantity,
    price: canonical.InstrumentPrice,
    price_tick_value: canonical.AssetAmount,
    quantity_denominator: i64,
    quantity_numerator: i64 = 1,
    fee: canonical.AssetAmount = .{ .asset = 1, .atoms = 0 },
    rebate: canonical.AssetAmount = .{ .asset = 1, .atoms = 0 },
    base_atom_value: canonical.AssetAmount = .{ .asset = 1, .atoms = 0 },
    base_fee: canonical.AssetAmount = .{ .asset = 1, .atoms = 0 },
    base_rebate: canonical.AssetAmount = .{ .asset = 1, .atoms = 0 },
    native_fee: ?canonical.AssetAmount = null,
    native_rebate: ?canonical.AssetAmount = null,
    portfolio_margin_ppm: i64 = 0,
    exchange_margin_ppm: i64 = 0,
    product: canonical.Product,
};

pub const FundingSettlement = struct {
    identity: u64,
    amount: canonical.AssetAmount,
};

pub const VenueForcedExecution = struct {
    identity: u64,
    source_identity: u128 = 0,
    side: Side,
    quantity: canonical.InstrumentQuantity,
    price: canonical.InstrumentPrice,
    price_tick_value: canonical.AssetAmount,
    quantity_denominator: i64,
    quantity_numerator: i64 = 1,
    fee: canonical.AssetAmount = .{ .asset = 1, .atoms = 0 },
    penalty: canonical.AssetAmount = .{ .asset = 1, .atoms = 0 },
    expected_realized_pnl_atoms: ?i128 = null,
    portfolio_margin_ppm: i64 = 0,
    exchange_margin_ppm: i64 = 0,
    product: canonical.Product,
};

pub const MarkPrice = struct {
    product: canonical.Product,
    quantity_numerator: i64 = 1,
    price_atoms: i128,
    quantity_denominator: i64,
};

pub const AccountSnapshot = struct {
    identity: u64,
    balance: canonical.AssetAmount,
    spot_asset_atoms: i128,
    swap_position_quantity: i64,
    margin: canonical.AssetAmount,
};

pub const Event = union(enum) {
    fill: Fill,
    funding_settlement: FundingSettlement,
    venue_forced_execution: VenueForcedExecution,
    account_snapshot: AccountSnapshot,
    mark_price: MarkPrice,
};

const SeenFact = struct {
    identity: u64,
    kind: FactKind,
    fingerprint: u64,
};

pub const CanonicalFactEvidence = struct {
    identity: u64,
    order_id: u64,
    quantity: i64,
    digest: [Sha256.digest_length]u8,
};

pub const Projection = struct {
    treasury_native_assets: [max_native_assets]canonical.AssetAmount = @splat(.{ .asset = 0, .atoms = 0 }),
    treasury_native_asset_count: u8 = 0,
    suspense_native_assets: [max_native_assets]canonical.AssetAmount = @splat(.{ .asset = 0, .atoms = 0 }),
    suspense_native_asset_count: u8 = 0,
    settlement_asset: canonical.AssetIdentity = settlement_asset,
    base_asset: canonical.AssetIdentity = 0,
    portfolio: Layer = .{},
    exchange: Layer = .{},
    treasury_usdt_atoms: i128 = 0,
    suspense_usdt_atoms: i128 = 0,
    reconciliation_break: bool = false,
    reconciliation_break_identity: u64 = 0,
    reconciliation_break_identities: [max_facts]u64 = undefined,
    reconciliation_break_count: u8 = 0,
    seen: [max_facts]SeenFact = undefined,
    seen_count: u8 = 0,
    canonical_fill_evidence: [max_facts]CanonicalFactEvidence = undefined,
    canonical_fill_evidence_count: u8 = 0,
    ledger: [max_ledger_transactions]LedgerTransaction = undefined,
    ledger_count: u8 = 0,
    ledger_summary: LedgerSummary = .{},
    spot_mark_price_atoms: i128 = 0,
    swap_mark_price_atoms: i128 = 0,
    spot_quantity_denominator: i64 = 0,
    spot_quantity_numerator: i64 = 1,
    swap_quantity_denominator: i64 = 0,
    swap_quantity_numerator: i64 = 1,

    pub fn apply(self: *Projection, event: Event) !void {
        _ = try self.applyChanged(event);
    }

    pub fn openNativeBalances(self: *Projection, balances: []const canonical.AssetAmount) !void {
        if (balances.len > max_native_assets or self.treasury_native_asset_count != 0 or self.exchange.native_asset_count != 0)
            return error.InvalidOpeningBalance;
        var candidate = self.*;
        for (balances, 0..) |balance, index| {
            if (balance.asset == 0 or balance.asset == self.settlement_asset or balance.asset == self.base_asset or balance.atoms < 0)
                return error.InvalidOpeningBalance;
            for (balances[0..index]) |prior| if (prior.asset == balance.asset) return error.InvalidOpeningBalance;
            (try candidate.exchange.nativeAssetMutable(balance.asset)).balance_atoms = balance.atoms;
            _ = try candidate.portfolio.nativeAssetMutable(balance.asset);
            candidate.treasury_native_assets[index] = balance;
        }
        candidate.treasury_native_asset_count = @intCast(balances.len);
        try candidate.assertClosed();
        self.* = candidate;
    }

    pub fn reportingValuationComplete(self: *const Projection) bool {
        for (self.exchange.native_assets[0..self.exchange.native_asset_count]) |entry|
            if (entry.balance_atoms != 0 or entry.fee_atoms != 0 or entry.rebate_atoms != 0) return false;
        return true;
    }

    pub fn applyChanged(self: *Projection, event: Event) !bool {
        const before = self.digest();
        var candidate = self.*;
        try candidate.applyEvent(event);
        try candidate.assertClosed();
        self.* = candidate;
        return !std.mem.eql(u8, &before, &self.digest());
    }

    pub const CanonicalFillIdentity = enum { unknown, duplicate };

    /// Canonical fill identity lives in this projection. TradingShard must not
    /// keep a second last-fill scalar, and duplicate identity is independent of
    /// later OMS remaining quantity.
    pub fn lookupCanonicalFill(
        self: *const Projection,
        identity: u64,
        payload_digest: [Sha256.digest_length]u8,
    ) !CanonicalFillIdentity {
        for (self.canonical_fill_evidence[0..self.canonical_fill_evidence_count]) |known| {
            if (known.identity != identity) continue;
            if (!std.mem.eql(u8, &known.digest, &payload_digest)) return error.ConflictingEconomicIdentity;
            return .duplicate;
        }
        return .unknown;
    }

    pub fn appliedCanonicalFillQuantity(self: *const Projection, order_id: u64) !i64 {
        var total: i64 = 0;
        for (self.canonical_fill_evidence[0..self.canonical_fill_evidence_count]) |known| {
            if (known.order_id == order_id)
                total = try std.math.add(i64, total, known.quantity);
        }
        return total;
    }

    pub fn applyCanonicalFill(self: *Projection, fill: Fill, payload_digest: [Sha256.digest_length]u8) !bool {
        switch (try self.lookupCanonicalFill(fill.identity, payload_digest)) {
            .duplicate => return false,
            .unknown => {},
        }
        var candidate = self.*;
        if (candidate.canonical_fill_evidence_count == candidate.canonical_fill_evidence.len)
            return error.EconomicFactCapacityExceeded;
        const changed = try candidate.applyChanged(.{ .fill = fill });
        const quantity = std.math.cast(i64, fill.quantity.lots) orelse return error.Overflow;
        if (fill.order_id == 0 or quantity <= 0) return error.InvalidEconomicFact;
        candidate.canonical_fill_evidence[candidate.canonical_fill_evidence_count] = .{
            .identity = fill.identity,
            .order_id = fill.order_id,
            .quantity = quantity,
            .digest = payload_digest,
        };
        candidate.canonical_fill_evidence_count += 1;
        self.* = candidate;
        return changed;
    }

    pub fn digest(self: *const Projection) [Sha256.digest_length]u8 {
        var hasher = Sha256.init(.{});
        hashInt(&hasher, canonical.AssetIdentity, self.settlement_asset);
        hashInt(&hasher, canonical.AssetIdentity, self.base_asset);
        hashLayer(&hasher, self.portfolio);
        hashLayer(&hasher, self.exchange);
        hashInt(&hasher, i128, self.treasury_usdt_atoms);
        hashInt(&hasher, i128, self.suspense_usdt_atoms);
        hashNativeBalances(&hasher, self.treasury_native_assets[0..self.treasury_native_asset_count]);
        hashNativeBalances(&hasher, self.suspense_native_assets[0..self.suspense_native_asset_count]);
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
        hashInt(&hasher, u8, self.canonical_fill_evidence_count);
        for (self.canonical_fill_evidence[0..self.canonical_fill_evidence_count]) |known| {
            hashInt(&hasher, u64, known.identity);
            hashInt(&hasher, u64, known.order_id);
            hashInt(&hasher, i64, known.quantity);
            hasher.update(&known.digest);
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
                hashInt(&hasher, canonical.AssetIdentity, posting.asset);
                hashInt(&hasher, i128, posting.amount);
            }
        }
        hashInt(&hasher, i128, self.spot_mark_price_atoms);
        hashInt(&hasher, i128, self.swap_mark_price_atoms);
        hashInt(&hasher, i64, self.spot_quantity_denominator);
        hashInt(&hasher, i64, self.spot_quantity_numerator);
        hashInt(&hasher, i64, self.swap_quantity_denominator);
        hashInt(&hasher, i64, self.swap_quantity_numerator);
        var result: [Sha256.digest_length]u8 = undefined;
        hasher.final(&result);
        return result;
    }

    /// Compares the business result of independently identified facts. It is
    /// deliberately not a snapshot or audit digest: arrival order stays in
    /// `digest` and in TradingShard's CanonicalStateDigest.
    pub fn semanticDigest(self: *const Projection) [Sha256.digest_length]u8 {
        return self.normalizedForSemanticDigest().digest();
    }

    pub fn normalizedForSemanticDigest(self: *const Projection) Projection {
        var normalized = self.*;
        sortCanonicalEvidence(normalized.canonical_fill_evidence[0..normalized.canonical_fill_evidence_count]);
        sortLedger(normalized.ledger[0..normalized.ledger_count]);
        return normalized;
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
        if (self.portfolio.native_asset_count > max_native_assets or self.exchange.native_asset_count > max_native_assets or
            self.treasury_native_asset_count > max_native_assets or self.suspense_native_asset_count > max_native_assets)
            return error.InvalidEconomicFact;
        for ([_][]const canonical.AssetAmount{
            self.treasury_native_assets[0..self.treasury_native_asset_count],
            self.suspense_native_assets[0..self.suspense_native_asset_count],
        }, 0..) |balances, owner| {
            for (balances, 0..) |balance, index| {
                if (balance.asset == 0 or self.exchange.nativeAsset(balance.asset) == null) return error.InvalidEconomicFact;
                if ((owner == 0 and balance.atoms < 0) or (owner == 1 and balance.atoms != 0 and !self.reconciliation_break)) return error.InvalidEconomicFact;
                for (balances[0..index]) |prior| if (prior.asset == balance.asset) return error.InvalidEconomicFact;
            }
        }
        for (self.exchange.native_assets[0..self.exchange.native_asset_count], 0..) |entry, index| {
            if (entry.asset == 0 or entry.asset == self.settlement_asset or entry.asset == self.base_asset or
                entry.balance_atoms < 0 or entry.fee_atoms < 0 or entry.rebate_atoms < 0) return error.InvalidEconomicFact;
            for (self.exchange.native_assets[0..index]) |prior| if (prior.asset == entry.asset) return error.InvalidEconomicFact;
            const portfolio = self.portfolio.nativeAsset(entry.asset) orelse return error.EconomicLayerMismatch;
            if (portfolio.fee_atoms != entry.fee_atoms or portfolio.rebate_atoms != entry.rebate_atoms or
                try std.math.add(i128, portfolio.balance_atoms, try std.math.add(i128, nativeBalance(self.treasury_native_assets[0..self.treasury_native_asset_count], entry.asset), nativeBalance(self.suspense_native_assets[0..self.suspense_native_asset_count], entry.asset))) != entry.balance_atoms)
                return error.EconomicLayerMismatch;
        }
        if (self.portfolio.native_asset_count != self.exchange.native_asset_count) return error.EconomicLayerMismatch;
        for ([_]Layer{ self.portfolio, self.exchange }) |layer| {
            if (layer.spot_asset_atoms < 0 or layer.base_fee_atoms < 0 or layer.base_rebate_atoms < 0 or
                (self.base_asset == 0 and (layer.spot_asset_atoms != 0 or layer.base_fee_atoms != 0 or layer.base_rebate_atoms != 0)))
                return error.InvalidEconomicFact;
        }
        for (self.ledger[0..self.ledger_count]) |transaction| {
            var balances: [4]i128 = .{ 0, 0, 0, 0 };
            var native_asset: ?canonical.AssetIdentity = null;
            for (transaction.postings[0..transaction.posting_count]) |posting| {
                const expected_asset: canonical.AssetIdentity = switch (posting.unit) {
                    .settlement_atoms => self.settlement_asset,
                    .base_atoms => self.base_asset,
                    .swap_quantity => 0,
                    .native_asset_atoms => blk: {
                        if (posting.asset == 0 or self.exchange.nativeAsset(posting.asset) == null) return error.UnbalancedLedgerTransaction;
                        if (native_asset) |asset| {
                            if (asset != posting.asset) return error.UnbalancedLedgerTransaction;
                        } else native_asset = posting.asset;
                        break :blk posting.asset;
                    },
                };
                if (posting.asset != expected_asset) return error.UnbalancedLedgerTransaction;
                const index: usize = @intFromEnum(posting.unit);
                balances[index] = try std.math.add(i128, balances[index], posting.amount);
            }
            for (balances) |balance| if (balance != 0) return error.UnbalancedLedgerTransaction;
        }
        if (try std.math.add(i128, self.portfolio.usdt_balance_atoms, try std.math.add(i128, self.treasury_usdt_atoms, self.suspense_usdt_atoms)) != self.exchange.usdt_balance_atoms or
            self.portfolio.spot_asset_atoms != self.exchange.spot_asset_atoms or
            (!self.reconciliation_break and !sameAttributedEconomics(self.portfolio, self.exchange)))
            return error.EconomicLayerMismatch;
    }

    fn applyMirroredFill(self: *Projection, fill: Fill, kind: FactKind) !void {
        if (fill.quantity.lots <= 0 or fill.price.ticks <= 0 or fill.quantity.instrument != fill.price.instrument or
            fill.price_tick_value.asset != self.settlement_asset or fill.price_tick_value.atoms <= 0 or
            fill.quantity.rules_version != fill.price.rules_version or fill.quantity_denominator <= 0 or
            fill.quantity_numerator <= 0 or
            (fill.fee.atoms != 0 and fill.fee.asset != self.settlement_asset) or
            (fill.rebate.atoms != 0 and fill.rebate.asset != self.settlement_asset) or
            fill.fee.atoms < 0 or fill.rebate.atoms < 0 or fill.base_fee.atoms < 0 or
            fill.base_rebate.atoms < 0 or (if (fill.native_fee) |fee| fee.atoms < 0 else false) or
            (if (fill.native_rebate) |rebate| rebate.atoms < 0 else false) or
            (fill.product != .spot and (fill.base_fee.atoms != 0 or fill.base_rebate.atoms != 0)))
            return error.InvalidEconomicFact;
        if (fill.product == .spot) {
            if (fill.base_atom_value.asset == 0 or fill.base_atom_value.atoms <= 0 or
                (self.base_asset != 0 and self.base_asset != fill.base_atom_value.asset) or
                (fill.base_fee.atoms != 0 and fill.base_fee.asset != fill.base_atom_value.asset) or
                (fill.base_rebate.atoms != 0 and fill.base_rebate.asset != fill.base_atom_value.asset))
                return error.InvalidEconomicFact;
            self.base_asset = fill.base_atom_value.asset;
        }
        if (self.denominator(fill.product) != 0 and (self.denominator(fill.product) != fill.quantity_denominator or
            (if (fill.product == .spot) self.spot_quantity_numerator else self.swap_quantity_numerator) != fill.quantity_numerator))
            return error.InconsistentQuantityDenominator;
        const fingerprint = fingerprintFill(fill);
        if (try self.remember(fill.identity, kind, fingerprint)) return;
        var portfolio = self.portfolio;
        var exchange = self.exchange;
        const portfolio_movement = try applyFillToLayer(&portfolio, fill);
        const exchange_movement = try applyFillToLayer(&exchange, fill);
        if (fill.product == .isolated_linear_usdt) {
            portfolio.margin_atoms = try rateAtoms(portfolio.swap.open_cost_atoms, fill.portfolio_margin_ppm);
            exchange.margin_atoms = try rateAtoms(exchange.swap.open_cost_atoms, fill.exchange_margin_ppm);
        }
        if (portfolio_movement != exchange_movement) return error.EconomicLayerMismatch;
        for ([_]struct { amount: ?canonical.AssetAmount, account: LedgerAccount }{
            .{ .amount = fill.native_fee, .account = .fee_expense },
            .{ .amount = fill.native_rebate, .account = .rebate_income },
        }) |charge| {
            const amount = charge.amount orelse continue;
            if (amount.atoms == 0) continue;
            if (amount.asset == 0 or amount.asset == self.settlement_asset or amount.asset == self.base_asset)
                return error.InvalidEconomicFact;
            const delta = if (charge.account == .fee_expense) try std.math.sub(i128, 0, amount.atoms) else amount.atoms;
            for ([_]*Layer{ &portfolio, &exchange }) |layer| {
                const entry = try layer.nativeAssetMutable(amount.asset);
                entry.balance_atoms = try std.math.add(i128, entry.balance_atoms, delta);
                if (charge.account == .fee_expense) entry.fee_atoms = try std.math.add(i128, entry.fee_atoms, amount.atoms) else entry.rebate_atoms = try std.math.add(i128, entry.rebate_atoms, amount.atoms);
            }
            try self.appendNativeChargeLedger(fill.identity, kind, .portfolio, charge.account, amount.asset, delta);
            try self.appendNativeChargeLedger(fill.identity, kind, .exchange, charge.account, amount.asset, delta);
        }
        const position_delta: i64 = if (fill.side == .buy) std.math.cast(i64, fill.quantity.lots) orelse return error.Overflow else -(std.math.cast(i64, fill.quantity.lots) orelse return error.Overflow);
        const traded_amount = if (fill.product == .spot) try std.math.mul(i128, position_delta, fill.base_atom_value.atoms) else position_delta;
        try self.appendPositionLedger(fill.identity, kind, .portfolio, fill.product, traded_amount);
        try self.appendPositionLedger(fill.identity, kind, .exchange, fill.product, traded_amount);
        if (fill.base_fee.atoms != 0) {
            try self.appendSpotChargeLedger(fill.identity, kind, .portfolio, .fee_expense, -fill.base_fee.atoms);
            try self.appendSpotChargeLedger(fill.identity, kind, .exchange, .fee_expense, -fill.base_fee.atoms);
        }
        if (fill.base_rebate.atoms != 0) {
            try self.appendSpotChargeLedger(fill.identity, kind, .portfolio, .rebate_income, fill.base_rebate.atoms);
            try self.appendSpotChargeLedger(fill.identity, kind, .exchange, .rebate_income, fill.base_rebate.atoms);
        }
        try self.appendLedger(fill.identity, kind, .portfolio, .trade, portfolio_movement);
        try self.appendLedger(fill.identity, kind, .exchange, .trade, exchange_movement);
        if (fill.fee.atoms > 0) {
            const fee = fill.fee.atoms;
            try self.appendLedger(fill.identity, kind, .portfolio, .fee_expense, -fee);
            try self.appendLedger(fill.identity, kind, .exchange, .fee_expense, -fee);
        }
        if (fill.rebate.atoms > 0) {
            const rebate = fill.rebate.atoms;
            try self.appendLedger(fill.identity, kind, .portfolio, .rebate_income, rebate);
            try self.appendLedger(fill.identity, kind, .exchange, .rebate_income, rebate);
        }
        self.portfolio = portfolio;
        self.exchange = exchange;
        self.setDenominator(fill.product, fill.quantity_denominator, fill.quantity_numerator);
    }

    fn applyFunding(self: *Projection, funding: FundingSettlement) !void {
        if (funding.amount.asset != self.settlement_asset) return error.InvalidEconomicFact;
        const amount = funding.amount.atoms;
        var fingerprint_hasher = std.hash.Wyhash.init(0);
        fingerprint_hasher.update(std.mem.asBytes(&funding.amount.asset));
        fingerprint_hasher.update(std.mem.asBytes(&funding.amount.atoms));
        const fingerprint = fingerprint_hasher.final();
        if (try self.remember(funding.identity, .funding, fingerprint)) return;
        if (self.portfolio.swap.quantity == 0) {
            self.exchange.usdt_balance_atoms = try std.math.add(i128, self.exchange.usdt_balance_atoms, amount);
            self.exchange.funding_atoms = try std.math.add(i128, self.exchange.funding_atoms, amount);
            self.suspense_usdt_atoms = try std.math.add(i128, self.suspense_usdt_atoms, amount);
            try self.openBreak(funding.identity);
            try self.appendLedger(funding.identity, .funding, .exchange, .funding_pnl, amount);
            return;
        }
        self.portfolio.usdt_balance_atoms = try std.math.add(i128, self.portfolio.usdt_balance_atoms, amount);
        self.exchange.usdt_balance_atoms = try std.math.add(i128, self.exchange.usdt_balance_atoms, amount);
        self.portfolio.funding_atoms = try std.math.add(i128, self.portfolio.funding_atoms, amount);
        self.exchange.funding_atoms = try std.math.add(i128, self.exchange.funding_atoms, amount);
        try self.appendLedger(funding.identity, .funding, .portfolio, .funding_pnl, amount);
        try self.appendLedger(funding.identity, .funding, .exchange, .funding_pnl, amount);
    }

    fn applyForced(self: *Projection, forced: VenueForcedExecution) !void {
        if (forced.quantity.lots <= 0 or forced.price.ticks <= 0 or
            forced.price_tick_value.asset != self.settlement_asset or forced.price_tick_value.atoms <= 0 or
            forced.quantity.instrument != forced.price.instrument or
            forced.quantity.rules_version != forced.price.rules_version or
            forced.product != .isolated_linear_usdt or
            (forced.fee.atoms != 0 and forced.fee.asset != self.settlement_asset) or
            (forced.penalty.atoms != 0 and forced.penalty.asset != self.settlement_asset) or
            forced.fee.atoms < 0 or forced.penalty.atoms < 0)
            return error.InvalidEconomicFact;
        const quantity = std.math.cast(i64, forced.quantity.lots) orelse return error.Overflow;
        const fee = forced.fee.atoms;
        const penalty = forced.penalty.atoms;
        const fill: Fill = .{
            .identity = forced.identity,
            .side = forced.side,
            .quantity = forced.quantity,
            .price = forced.price,
            .price_tick_value = forced.price_tick_value,
            .quantity_denominator = forced.quantity_denominator,
            .quantity_numerator = forced.quantity_numerator,
            .fee = forced.fee,
            .portfolio_margin_ppm = forced.portfolio_margin_ppm,
            .exchange_margin_ppm = forced.exchange_margin_ppm,
            .product = forced.product,
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
            if (forced.expected_realized_pnl_atoms) |expected| {
                if (try std.math.sub(i128, portfolio.realized_pnl_atoms, self.portfolio.realized_pnl_atoms) != expected)
                    return error.ForcedExecutionPnlMismatch;
            }
            portfolio.margin_atoms = try rateAtoms(portfolio.swap.open_cost_atoms, fill.portfolio_margin_ppm);
            exchange.margin_atoms = try rateAtoms(exchange.swap.open_cost_atoms, fill.exchange_margin_ppm);
            const position_delta: i64 = if (forced.side == .buy) quantity else -quantity;
            try self.appendPositionLedger(forced.identity, .forced_execution, .portfolio, .isolated_linear_usdt, position_delta);
            try self.appendPositionLedger(forced.identity, .forced_execution, .exchange, .isolated_linear_usdt, position_delta);
            try self.appendLedger(forced.identity, .forced_execution, .portfolio, .trade, portfolio_movement);
            try self.appendLedger(forced.identity, .forced_execution, .exchange, .trade, exchange_movement);
            if (fee > 0) {
                try self.appendLedger(forced.identity, .forced_execution, .portfolio, .fee_expense, -fee);
                try self.appendLedger(forced.identity, .forced_execution, .exchange, .fee_expense, -fee);
            }
            self.portfolio = portfolio;
            self.exchange = exchange;
            self.setDenominator(forced.product, forced.quantity_denominator, forced.quantity_numerator);
            self.portfolio.penalty_atoms = try std.math.add(i128, self.portfolio.penalty_atoms, penalty);
            self.exchange.penalty_atoms = try std.math.add(i128, self.exchange.penalty_atoms, penalty);
            self.portfolio.usdt_balance_atoms = try std.math.sub(i128, self.portfolio.usdt_balance_atoms, penalty);
            self.exchange.usdt_balance_atoms = try std.math.sub(i128, self.exchange.usdt_balance_atoms, penalty);
            if (penalty > 0) {
                try self.appendLedger(forced.identity, .forced_execution, .portfolio, .penalty_expense, -penalty);
                try self.appendLedger(forced.identity, .forced_execution, .exchange, .penalty_expense, -penalty);
            }
            return;
        }
        if (self.seen_count == max_facts) return error.EconomicFactCapacityExceeded;
        if (forced.expected_realized_pnl_atoms != null) return error.ForcedExecutionOwnerMismatch;
        self.seen[self.seen_count] = .{ .identity = forced.identity, .kind = .forced_execution, .fingerprint = fingerprint };
        self.seen_count += 1;
        var exchange = self.exchange;
        const movement = try applyFillToLayer(&exchange, fill);
        exchange.penalty_atoms = try std.math.add(i128, exchange.penalty_atoms, penalty);
        exchange.usdt_balance_atoms = try std.math.sub(i128, exchange.usdt_balance_atoms, penalty);
        const cash_change = try std.math.sub(i128, exchange.usdt_balance_atoms, self.exchange.usdt_balance_atoms);
        const position_delta: i64 = if (forced.side == .buy) quantity else -quantity;
        try self.appendPositionLedger(forced.identity, .forced_execution, .exchange, .isolated_linear_usdt, position_delta);
        try self.appendLedger(forced.identity, .forced_execution, .exchange, .trade, movement);
        if (fee > 0) try self.appendLedger(forced.identity, .forced_execution, .exchange, .fee_expense, -fee);
        if (penalty > 0) try self.appendLedger(forced.identity, .forced_execution, .exchange, .penalty_expense, -penalty);
        self.suspense_usdt_atoms = try std.math.add(i128, self.suspense_usdt_atoms, cash_change);
        self.exchange = exchange;
        self.setDenominator(forced.product, forced.quantity_denominator, forced.quantity_numerator);
        try self.openBreak(forced.identity);
    }

    fn reconcile(self: *Projection, snapshot: AccountSnapshot) !void {
        if (snapshot.balance.asset != self.settlement_asset or snapshot.margin.asset != self.settlement_asset)
            return error.InvalidEconomicFact;
        const balance = snapshot.balance.atoms;
        const margin = snapshot.margin.atoms;
        var hash = std.hash.Wyhash.init(0);
        hash.update(std.mem.asBytes(&snapshot.identity));
        hash.update(std.mem.asBytes(&snapshot.balance.asset));
        hash.update(std.mem.asBytes(&snapshot.balance.atoms));
        hash.update(std.mem.asBytes(&snapshot.spot_asset_atoms));
        hash.update(std.mem.asBytes(&snapshot.swap_position_quantity));
        hash.update(std.mem.asBytes(&snapshot.margin.asset));
        hash.update(std.mem.asBytes(&snapshot.margin.atoms));
        if (try self.remember(snapshot.identity, .account_snapshot, hash.final())) return;
        const differs = balance != self.exchange.usdt_balance_atoms or
            snapshot.spot_asset_atoms != self.exchange.spot_asset_atoms or
            snapshot.swap_position_quantity != self.exchange.swap.quantity or
            margin != self.exchange.margin_atoms;
        if (differs) {
            try self.openBreak(snapshot.identity);
        }
    }

    fn valueAt(self: *Projection, mark: MarkPrice) !void {
        if (mark.price_atoms <= 0 or mark.quantity_denominator <= 0 or mark.quantity_numerator <= 0) return error.InvalidEconomicFact;
        if (self.denominator(mark.product) != 0 and (self.denominator(mark.product) != mark.quantity_denominator or
            (if (mark.product == .spot) self.spot_quantity_numerator else self.swap_quantity_numerator) != mark.quantity_numerator))
            return error.InconsistentQuantityDenominator;
        switch (mark.product) {
            .spot => {
                self.spot_mark_price_atoms = mark.price_atoms;
                self.spot_quantity_denominator = mark.quantity_denominator;
                self.spot_quantity_numerator = mark.quantity_numerator;
            },
            .isolated_linear_usdt => {
                self.swap_mark_price_atoms = mark.price_atoms;
                self.swap_quantity_denominator = mark.quantity_denominator;
                self.swap_quantity_numerator = mark.quantity_numerator;
            },
        }
        self.portfolio.unrealized_pnl_atoms = try std.math.add(i128, try self.unrealizedAt(.spot, self.portfolio.spot), try self.unrealizedAt(.isolated_linear_usdt, self.portfolio.swap));
        self.exchange.unrealized_pnl_atoms = try std.math.add(i128, try self.unrealizedAt(.spot, self.exchange.spot), try self.unrealizedAt(.isolated_linear_usdt, self.exchange.swap));
    }

    fn denominator(self: *const Projection, product: canonical.Product) i64 {
        return if (product == .spot) self.spot_quantity_denominator else self.swap_quantity_denominator;
    }

    fn setDenominator(self: *Projection, product: canonical.Product, value: i64, numerator: i64) void {
        if (product == .spot) {
            self.spot_quantity_denominator = value;
            self.spot_quantity_numerator = numerator;
        } else {
            self.swap_quantity_denominator = value;
            self.swap_quantity_numerator = numerator;
        }
    }

    fn unrealizedAt(self: *const Projection, product: canonical.Product, position: Position) !i128 {
        const price = if (product == .spot) self.spot_mark_price_atoms else self.swap_mark_price_atoms;
        if (price == 0) return 0;
        return unrealized(position, try std.math.mul(i128, price, if (product == .spot) self.spot_quantity_numerator else self.swap_quantity_numerator), self.denominator(product));
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

    fn appendLedger(self: *Projection, identity: u64, kind: FactKind, layer: LedgerLayer, account: LedgerAccount, cash_delta: i128) !void {
        if (cash_delta == 0) return;
        if (self.ledger_count == max_ledger_transactions) return error.LedgerCapacityExceeded;
        self.ledger[self.ledger_count] = .{
            .source_identity = identity,
            .kind = kind,
            .layer = layer,
            .posting_count = 2,
            .postings = .{ .{ .account = .cash, .unit = .settlement_atoms, .asset = self.settlement_asset, .amount = cash_delta }, .{ .account = account, .unit = .settlement_atoms, .asset = self.settlement_asset, .amount = try std.math.sub(i128, 0, cash_delta) }, undefined, undefined },
        };
        self.ledger_count += 1;
    }

    fn appendPositionLedger(self: *Projection, identity: u64, kind: FactKind, layer: LedgerLayer, product: canonical.Product, quantity_delta: i128) !void {
        if (quantity_delta == 0) return;
        if (self.ledger_count == max_ledger_transactions) return error.LedgerCapacityExceeded;
        const unit: LedgerUnit = if (product == .spot) .base_atoms else .swap_quantity;
        const account: LedgerAccount = if (product == .spot) .spot_asset else .swap_position;
        const asset: canonical.AssetIdentity = if (product == .spot) self.base_asset else 0;
        self.ledger[self.ledger_count] = .{
            .source_identity = identity,
            .kind = kind,
            .layer = layer,
            .posting_count = 2,
            .postings = .{ .{ .account = account, .unit = unit, .asset = asset, .amount = quantity_delta }, .{ .account = .trade, .unit = unit, .asset = asset, .amount = try std.math.sub(i128, 0, quantity_delta) }, undefined, undefined },
        };
        self.ledger_count += 1;
    }

    fn appendSpotChargeLedger(self: *Projection, identity: u64, kind: FactKind, layer: LedgerLayer, account: LedgerAccount, quantity_delta: i128) !void {
        if (self.ledger_count == max_ledger_transactions) return error.LedgerCapacityExceeded;
        self.ledger[self.ledger_count] = .{
            .source_identity = identity,
            .kind = kind,
            .layer = layer,
            .posting_count = 2,
            .postings = .{ .{ .account = .spot_asset, .unit = .base_atoms, .asset = self.base_asset, .amount = quantity_delta }, .{ .account = account, .unit = .base_atoms, .asset = self.base_asset, .amount = try std.math.sub(i128, 0, quantity_delta) }, undefined, undefined },
        };
        self.ledger_count += 1;
    }

    fn appendNativeChargeLedger(self: *Projection, identity: u64, kind: FactKind, layer: LedgerLayer, account: LedgerAccount, asset: canonical.AssetIdentity, delta: i128) !void {
        if (self.ledger_count == max_ledger_transactions) return error.LedgerCapacityExceeded;
        self.ledger[self.ledger_count] = .{
            .source_identity = identity,
            .kind = kind,
            .layer = layer,
            .posting_count = 2,
            .postings = .{ .{ .account = .cash, .unit = .native_asset_atoms, .asset = asset, .amount = delta }, .{ .account = account, .unit = .native_asset_atoms, .asset = asset, .amount = try std.math.sub(i128, 0, delta) }, undefined, undefined },
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

fn sortCanonicalEvidence(values: []CanonicalFactEvidence) void {
    var index: usize = 1;
    while (index < values.len) : (index += 1) {
        var cursor = index;
        while (cursor > 0 and values[cursor].identity < values[cursor - 1].identity) : (cursor -= 1)
            std.mem.swap(CanonicalFactEvidence, &values[cursor], &values[cursor - 1]);
    }
}

fn ledgerLessThan(left: LedgerTransaction, right: LedgerTransaction) bool {
    if (left.source_identity != right.source_identity) return left.source_identity < right.source_identity;
    if (left.kind != right.kind) return @intFromEnum(left.kind) < @intFromEnum(right.kind);
    if (left.layer != right.layer) return @intFromEnum(left.layer) < @intFromEnum(right.layer);
    var index: usize = 0;
    while (index < left.posting_count) : (index += 1) {
        const a = left.postings[index];
        const b = right.postings[index];
        if (a.account != b.account) return @intFromEnum(a.account) < @intFromEnum(b.account);
        if (a.unit != b.unit) return @intFromEnum(a.unit) < @intFromEnum(b.unit);
        if (a.asset != b.asset) return a.asset < b.asset;
        if (a.amount != b.amount) return a.amount < b.amount;
    }
    return left.posting_count < right.posting_count;
}

fn sortLedger(values: []LedgerTransaction) void {
    var index: usize = 1;
    while (index < values.len) : (index += 1) {
        var cursor = index;
        while (cursor > 0 and ledgerLessThan(values[cursor], values[cursor - 1])) : (cursor -= 1)
            std.mem.swap(LedgerTransaction, &values[cursor], &values[cursor - 1]);
    }
}

fn hashLayer(hasher: *Sha256, layer: Layer) void {
    hashInt(hasher, u8, layer.native_asset_count);
    var previous: canonical.AssetIdentity = 0;
    for (0..layer.native_asset_count) |_| {
        var next: ?NativeAssetState = null;
        for (layer.native_assets[0..layer.native_asset_count]) |entry| {
            if (entry.asset > previous and (next == null or entry.asset < next.?.asset)) next = entry;
        }
        const entry = next orelse unreachable;
        hashInt(hasher, canonical.AssetIdentity, entry.asset);
        hashInt(hasher, i128, entry.balance_atoms);
        hashInt(hasher, i128, entry.fee_atoms);
        hashInt(hasher, i128, entry.rebate_atoms);
        previous = entry.asset;
    }
    hashInt(hasher, i128, layer.usdt_balance_atoms);
    hashInt(hasher, i128, layer.spot_asset_atoms);
    hashInt(hasher, i128, layer.base_fee_atoms);
    hashInt(hasher, i128, layer.base_rebate_atoms);
    hashInt(hasher, i64, layer.spot.quantity);
    hashInt(hasher, i128, layer.spot.open_cost_atoms);
    hashInt(hasher, i64, layer.swap.quantity);
    hashInt(hasher, i128, layer.swap.open_cost_atoms);
    hashInt(hasher, i128, layer.margin_atoms);
    hashInt(hasher, i128, layer.fee_atoms);
    hashInt(hasher, i128, layer.rebate_atoms);
    hashInt(hasher, i128, layer.funding_atoms);
    hashInt(hasher, i128, layer.penalty_atoms);
    hashInt(hasher, i128, layer.realized_pnl_atoms);
    hashInt(hasher, i128, layer.unrealized_pnl_atoms);
}

fn nativeBalance(balances: []const canonical.AssetAmount, asset: canonical.AssetIdentity) i128 {
    for (balances) |balance| if (balance.asset == asset) return balance.atoms;
    return 0;
}

fn hashNativeBalances(hasher: *Sha256, balances: []const canonical.AssetAmount) void {
    hashInt(hasher, u8, @intCast(balances.len));
    var previous: canonical.AssetIdentity = 0;
    for (balances) |_| {
        var next: ?canonical.AssetAmount = null;
        for (balances) |balance| {
            if (balance.asset > previous and (next == null or balance.asset < next.?.asset)) next = balance;
        }
        const balance = next orelse unreachable;
        hashInt(hasher, canonical.AssetIdentity, balance.asset);
        hashInt(hasher, i128, balance.atoms);
        previous = balance.asset;
    }
}

fn hashInt(hasher: *Sha256, comptime T: type, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hasher.update(&bytes);
}

fn sameAttributedEconomics(portfolio: Layer, exchange: Layer) bool {
    return portfolio.spot_asset_atoms == exchange.spot_asset_atoms and
        portfolio.base_fee_atoms == exchange.base_fee_atoms and portfolio.base_rebate_atoms == exchange.base_rebate_atoms and
        std.meta.eql(portfolio.spot, exchange.spot) and
        std.meta.eql(portfolio.swap, exchange.swap) and
        portfolio.fee_atoms == exchange.fee_atoms and
        portfolio.rebate_atoms == exchange.rebate_atoms and
        portfolio.funding_atoms == exchange.funding_atoms and
        portfolio.penalty_atoms == exchange.penalty_atoms and
        portfolio.realized_pnl_atoms == exchange.realized_pnl_atoms and
        portfolio.unrealized_pnl_atoms == exchange.unrealized_pnl_atoms;
}

fn applyFillToLayer(layer: *Layer, fill: Fill) !i128 {
    const quantity = std.math.cast(i64, fill.quantity.lots) orelse return error.Overflow;
    if (fill.price_tick_value.atoms <= 0 or fill.quantity_denominator <= 0)
        return error.InvalidEconomicFact;
    const fee = fill.fee.atoms;
    const rebate = fill.rebate.atoms;
    const price = try std.math.mul(i128, fill.price.ticks, fill.price_tick_value.atoms);
    const numerator = try std.math.mul(i128, try std.math.mul(i128, quantity, price), fill.quantity_numerator);
    if (@rem(numerator, fill.quantity_denominator) != 0) return error.InexactEconomicAmount;
    const notional = @divExact(numerator, fill.quantity_denominator);
    const net_fee = try std.math.sub(i128, fee, rebate);
    layer.fee_atoms = try std.math.add(i128, layer.fee_atoms, fee);
    layer.rebate_atoms = try std.math.add(i128, layer.rebate_atoms, rebate);
    if (fill.product == .spot) {
        const direction: i64 = if (fill.side == .buy) 1 else -1;
        const traded_delta = try std.math.mul(i64, direction, quantity);
        const native_delta = try std.math.mul(i128, traded_delta, fill.base_atom_value.atoms);
        const next_asset = try std.math.add(i128, layer.spot_asset_atoms, try std.math.add(i128, native_delta, try std.math.sub(i128, fill.base_rebate.atoms, fill.base_fee.atoms)));
        if (next_asset < 0) return error.InsufficientSpotAsset;
        const realized = try updatePosition(&layer.spot, direction, quantity, notional);
        layer.spot_asset_atoms = next_asset;
        layer.base_fee_atoms = try std.math.add(i128, layer.base_fee_atoms, fill.base_fee.atoms);
        layer.base_rebate_atoms = try std.math.add(i128, layer.base_rebate_atoms, fill.base_rebate.atoms);
        const trade_cash_delta = if (fill.side == .buy) -notional else notional;
        layer.usdt_balance_atoms = try std.math.add(i128, layer.usdt_balance_atoms, try std.math.sub(i128, trade_cash_delta, net_fee));
        layer.realized_pnl_atoms = try std.math.add(i128, layer.realized_pnl_atoms, realized);
        return trade_cash_delta;
    } else if (fill.product == .isolated_linear_usdt) {
        const direction: i64 = if (fill.side == .buy) 1 else -1;
        const realized = try updatePosition(&layer.swap, direction, quantity, notional);
        layer.usdt_balance_atoms = try std.math.add(i128, layer.usdt_balance_atoms, try std.math.sub(i128, realized, net_fee));
        layer.realized_pnl_atoms = try std.math.add(i128, layer.realized_pnl_atoms, realized);
        return realized;
    } else return error.UnknownInstrument;
}

fn updatePosition(position: *Position, direction: i64, quantity: i64, notional: i128) !i128 {
    const signed_quantity = try std.math.mul(i64, direction, quantity);
    if (position.quantity == 0 or (position.quantity > 0) == (signed_quantity > 0)) {
        position.quantity = try std.math.add(i64, position.quantity, signed_quantity);
        position.open_cost_atoms = try std.math.add(i128, position.open_cost_atoms, notional);
        return 0;
    }
    const closing = @min(abs(position.quantity), quantity);
    const released_cost = @divFloor(try std.math.mul(i128, position.open_cost_atoms, closing), abs(position.quantity));
    const closing_notional = @divFloor(try std.math.mul(i128, notional, closing), quantity);
    const realized = if (position.quantity > 0) try std.math.sub(i128, closing_notional, released_cost) else try std.math.sub(i128, released_cost, closing_notional);
    const next = try std.math.add(i64, position.quantity, signed_quantity);
    if (next == 0) {
        position.* = .{};
    } else if ((next > 0) == (position.quantity > 0)) {
        position.quantity = next;
        position.open_cost_atoms = try std.math.sub(i128, position.open_cost_atoms, released_cost);
    } else {
        position.quantity = next;
        position.open_cost_atoms = try std.math.sub(i128, notional, closing_notional);
    }
    return realized;
}

fn unrealized(position: Position, price: i128, denominator: i64) !i128 {
    if (position.quantity == 0) return 0;
    const value = try ceilPositive(try std.math.mul(i128, abs(position.quantity), price), denominator);
    return if (position.quantity > 0) try std.math.sub(i128, value, position.open_cost_atoms) else try std.math.sub(i128, position.open_cost_atoms, value);
}

pub fn coreFillDigest(fill: Fill) [Sha256.digest_length]u8 {
    var hash = Sha256.init(.{});
    hashFill(&hash, fill);
    return hash.finalResult();
}

fn fingerprintFill(fill: Fill) u64 {
    var hash = std.hash.Wyhash.init(0);
    hashFill(&hash, fill);
    return hash.final();
}

fn hashFill(hash: anytype, fill: Fill) void {
    hash.update(std.mem.asBytes(&fill.identity));
    hash.update(std.mem.asBytes(&fill.order_id));
    hash.update(std.mem.asBytes(&fill.quantity.instrument));
    hash.update(std.mem.asBytes(&fill.quantity.rules_version));
    hash.update(&.{@intFromEnum(fill.side)});
    hash.update(std.mem.asBytes(&fill.quantity.lots));
    hash.update(std.mem.asBytes(&fill.price.ticks));
    hash.update(std.mem.asBytes(&fill.price_tick_value.asset));
    hash.update(std.mem.asBytes(&fill.price_tick_value.atoms));
    hash.update(std.mem.asBytes(&fill.quantity_denominator));
    hash.update(std.mem.asBytes(&fill.fee.asset));
    hash.update(std.mem.asBytes(&fill.fee.atoms));
    hash.update(std.mem.asBytes(&fill.rebate.asset));
    hash.update(std.mem.asBytes(&fill.rebate.atoms));
    hash.update(std.mem.asBytes(&fill.base_atom_value.asset));
    hash.update(std.mem.asBytes(&fill.base_atom_value.atoms));
    hash.update(std.mem.asBytes(&fill.quantity_numerator));
    hash.update(std.mem.asBytes(&fill.base_fee.asset));
    hash.update(std.mem.asBytes(&fill.base_fee.atoms));
    hash.update(std.mem.asBytes(&fill.base_rebate.asset));
    hash.update(std.mem.asBytes(&fill.base_rebate.atoms));
    for ([_]?canonical.AssetAmount{ fill.native_fee, fill.native_rebate }) |amount| {
        hash.update(&.{@intFromBool(amount != null)});
        if (amount) |value| {
            hash.update(std.mem.asBytes(&value.asset));
            hash.update(std.mem.asBytes(&value.atoms));
        }
    }
    hash.update(std.mem.asBytes(&fill.portfolio_margin_ppm));
    hash.update(std.mem.asBytes(&fill.exchange_margin_ppm));
    hash.update(&.{@intFromEnum(fill.product)});
}

fn fingerprintForced(forced: VenueForcedExecution) u64 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(std.mem.asBytes(&forced.identity));
    hash.update(std.mem.asBytes(&forced.source_identity));
    hash.update(&.{@intFromEnum(forced.side)});
    hash.update(std.mem.asBytes(&forced.quantity.instrument));
    hash.update(std.mem.asBytes(&forced.quantity.rules_version));
    hash.update(std.mem.asBytes(&forced.quantity.lots));
    hash.update(std.mem.asBytes(&forced.price.ticks));
    hash.update(std.mem.asBytes(&forced.price_tick_value.asset));
    hash.update(std.mem.asBytes(&forced.price_tick_value.atoms));
    hash.update(std.mem.asBytes(&forced.quantity_denominator));
    hash.update(std.mem.asBytes(&forced.quantity_numerator));
    hash.update(std.mem.asBytes(&forced.fee.asset));
    hash.update(std.mem.asBytes(&forced.fee.atoms));
    hash.update(std.mem.asBytes(&forced.penalty.asset));
    hash.update(std.mem.asBytes(&forced.penalty.atoms));
    hash.update(&.{@intFromBool(forced.expected_realized_pnl_atoms != null)});
    if (forced.expected_realized_pnl_atoms) |pnl| hash.update(std.mem.asBytes(&pnl));
    hash.update(std.mem.asBytes(&forced.portfolio_margin_ppm));
    hash.update(std.mem.asBytes(&forced.exchange_margin_ppm));
    hash.update(&.{@intFromEnum(forced.product)});
    return hash.final();
}

fn abs(value: i64) i64 {
    return std.math.cast(i64, if (@as(i128, value) < 0) -@as(i128, value) else @as(i128, value)) orelse std.math.maxInt(i64);
}

fn ceilPositive(numerator: i128, denominator: i128) !i128 {
    if (numerator < 0 or denominator <= 0) return error.InvalidEconomicFact;
    return std.math.add(i128, @divFloor(numerator, denominator), @as(i128, if (@rem(numerator, denominator) == 0) 0 else 1));
}

fn rateAtoms(notional: i128, ppm: i64) !i128 {
    if (ppm < 0) return error.InvalidEconomicFact;
    return ceilPositive(try std.math.mul(i128, notional, ppm), 1_000_000);
}

fn fixtureQuantity(lots: i128) canonical.InstrumentQuantity {
    return .{ .instrument = 2, .rules_version = 1, .lots = lots };
}

fn fixturePrice(ticks: i128) canonical.InstrumentPrice {
    return .{ .instrument = 2, .rules_version = 1, .ticks = ticks };
}

fn fixtureAmount(atoms: i128) canonical.AssetAmount {
    return .{ .asset = settlement_asset, .atoms = atoms };
}

test "partial fills close two layers with average cost fees rebates margin and valuation" {
    var projection: Projection = .{};
    projection.portfolio.usdt_balance_atoms = 10_000_000;
    projection.exchange.usdt_balance_atoms = 10_000_000;
    try projection.apply(.{ .fill = .{ .identity = 1, .side = .buy, .quantity = fixtureQuantity(4), .price = fixturePrice(100), .price_tick_value = fixtureAmount(1), .quantity_denominator = 1, .fee = fixtureAmount(3), .rebate = fixtureAmount(1), .portfolio_margin_ppm = 100_000, .exchange_margin_ppm = 80_000, .product = .isolated_linear_usdt } });
    try projection.apply(.{ .fill = .{ .identity = 2, .side = .buy, .quantity = fixtureQuantity(6), .price = fixturePrice(110), .price_tick_value = fixtureAmount(1), .quantity_denominator = 1, .fee = fixtureAmount(4), .portfolio_margin_ppm = 100_000, .exchange_margin_ppm = 80_000, .product = .isolated_linear_usdt } });
    try projection.apply(.{ .fill = .{ .identity = 3, .side = .sell, .quantity = fixtureQuantity(5), .price = fixturePrice(120), .price_tick_value = fixtureAmount(1), .quantity_denominator = 1, .fee = fixtureAmount(2), .portfolio_margin_ppm = 100_000, .exchange_margin_ppm = 80_000, .product = .isolated_linear_usdt } });
    try projection.apply(.{ .mark_price = .{ .product = .isolated_linear_usdt, .price_atoms = 115, .quantity_denominator = 1 } });
    try std.testing.expectEqual(@as(i64, 5), projection.portfolio.swap.quantity);
    try std.testing.expectEqual(@as(i64, 530), projection.portfolio.swap.open_cost_atoms);
    try std.testing.expectEqual(@as(i64, 70), projection.portfolio.realized_pnl_atoms);
    try std.testing.expectEqual(@as(i64, 45), projection.portfolio.unrealized_pnl_atoms);
    try std.testing.expectEqual(@as(i64, 53), projection.portfolio.margin_atoms);
    try std.testing.expectEqual(@as(i64, 43), projection.exchange.margin_atoms);
    try std.testing.expectEqual(@as(i64, 9), projection.portfolio.fee_atoms);
    try std.testing.expectEqual(@as(i64, 1), projection.portfolio.rebate_atoms);
    try std.testing.expectEqual(@as(u8, 16), projection.ledger_count);
    try projection.assertClosed();
}

test "spot base-asset fee preserves gross traded lots and open cost" {
    var projection: Projection = .{};
    projection.portfolio.usdt_balance_atoms = 10_000;
    projection.exchange.usdt_balance_atoms = 10_000;
    try projection.apply(.{ .fill = .{
        .identity = 1,
        .side = .buy,
        .quantity = fixtureQuantity(10),
        .price = fixturePrice(100),
        .price_tick_value = fixtureAmount(1),
        .quantity_denominator = 1,
        .base_fee = .{ .asset = 0x425443, .atoms = 1 },
        .base_atom_value = .{ .asset = 0x425443, .atoms = 1 },
        .product = .spot,
    } });
    try std.testing.expectEqual(@as(i64, 9), projection.portfolio.spot_asset_atoms);
    try std.testing.expectEqual(@as(i64, 10), projection.portfolio.spot.quantity);
    try std.testing.expectEqual(@as(i128, 1_000), projection.portfolio.spot.open_cost_atoms);
    try std.testing.expectEqual(@as(i64, 9_000), projection.portfolio.usdt_balance_atoms);
    try std.testing.expectEqual(@as(i64, 0), projection.portfolio.fee_atoms);
    try projection.assertClosed();
}

test "funding and forced execution are idempotent and unowned facts enter suspense" {
    var projection: Projection = .{};
    projection.treasury_usdt_atoms = 1_000;
    projection.exchange.usdt_balance_atoms = 1_000;
    try projection.apply(.{ .funding_settlement = .{ .identity = 10, .amount = fixtureAmount(-25) } });
    try projection.apply(.{ .funding_settlement = .{ .identity = 10, .amount = fixtureAmount(-25) } });
    try std.testing.expectEqual(@as(i64, -25), projection.suspense_usdt_atoms);
    try std.testing.expect(projection.reconciliation_break);
    try std.testing.expectEqual(@as(u8, 1), projection.ledger_count);
    try std.testing.expectError(error.ConflictingEconomicIdentity, projection.apply(.{ .funding_settlement = .{ .identity = 10, .amount = fixtureAmount(-26) } }));

    try projection.apply(.{ .venue_forced_execution = .{ .identity = 11, .side = .sell, .quantity = fixtureQuantity(2), .price = fixturePrice(100), .price_tick_value = fixtureAmount(1), .quantity_denominator = 1, .fee = fixtureAmount(3), .penalty = fixtureAmount(2), .product = .isolated_linear_usdt } });
    try projection.apply(.{ .venue_forced_execution = .{ .identity = 11, .side = .sell, .quantity = fixtureQuantity(2), .price = fixturePrice(100), .price_tick_value = fixtureAmount(1), .quantity_denominator = 1, .fee = fixtureAmount(3), .penalty = fixtureAmount(2), .product = .isolated_linear_usdt } });
    try std.testing.expectEqual(@as(i64, -2), projection.exchange.swap.quantity);
    try std.testing.expectEqual(@as(i64, -30), projection.suspense_usdt_atoms);
    try std.testing.expectEqual(@as(u8, 4), projection.ledger_count);
    try projection.assertClosed();
}

test "account snapshot opens a break without overwriting local economics" {
    var projection: Projection = .{};
    projection.treasury_usdt_atoms = 1_000;
    projection.exchange.usdt_balance_atoms = 1_000;
    const before = projection.exchange;
    try projection.apply(.{ .account_snapshot = .{ .identity = 20, .balance = fixtureAmount(999), .spot_asset_atoms = 0, .swap_position_quantity = 7, .margin = fixtureAmount(55) } });
    try std.testing.expect(projection.reconciliation_break);
    try std.testing.expectEqual(@as(u64, 20), projection.reconciliation_break_identity);
    try std.testing.expectEqual(@as(u8, 1), projection.reconciliation_break_count);
    try std.testing.expectEqualDeep(before, projection.exchange);
    try std.testing.expectEqual(@as(u8, 0), projection.ledger_count);
    try projection.apply(.{ .account_snapshot = .{ .identity = 21, .balance = fixtureAmount(998), .spot_asset_atoms = 0, .swap_position_quantity = 8, .margin = fixtureAmount(56) } });
    try std.testing.expectEqual(@as(u8, 2), projection.reconciliation_break_count);
    try std.testing.expectEqual(@as(u64, 20), projection.reconciliation_break_identities[0]);
    try std.testing.expectEqual(@as(u64, 21), projection.reconciliation_break_identities[1]);
}

test "duplicate attributed forced execution cannot charge penalty twice" {
    var projection: Projection = .{};
    projection.portfolio.usdt_balance_atoms = 1_000;
    projection.exchange.usdt_balance_atoms = 1_000;
    try projection.apply(.{ .fill = .{ .identity = 1, .side = .buy, .quantity = fixtureQuantity(10), .price = fixturePrice(100), .price_tick_value = fixtureAmount(1), .quantity_denominator = 1, .product = .isolated_linear_usdt } });
    const forced: Event = .{ .venue_forced_execution = .{ .identity = 2, .source_identity = 7, .side = .sell, .quantity = fixtureQuantity(2), .price = fixturePrice(90), .price_tick_value = fixtureAmount(1), .quantity_denominator = 1, .fee = fixtureAmount(3), .penalty = fixtureAmount(5), .product = .isolated_linear_usdt } };
    try projection.apply(forced);
    const after = projection;
    try projection.apply(forced);
    try std.testing.expectEqualDeep(after, projection);
    try std.testing.expectError(error.ConflictingEconomicIdentity, projection.apply(.{ .venue_forced_execution = .{ .identity = 2, .side = .sell, .quantity = fixtureQuantity(2), .price = fixturePrice(90), .price_tick_value = fixtureAmount(1), .quantity_denominator = 1, .fee = fixtureAmount(3), .penalty = fixtureAmount(6), .product = .isolated_linear_usdt } }));
    try std.testing.expectError(error.ConflictingEconomicIdentity, projection.apply(.{ .venue_forced_execution = .{ .identity = 2, .source_identity = 8, .side = .sell, .quantity = fixtureQuantity(2), .price = fixturePrice(90), .price_tick_value = fixtureAmount(1), .quantity_denominator = 1, .fee = fixtureAmount(3), .penalty = fixtureAmount(5), .product = .isolated_linear_usdt } }));
}

test "negative forced penalty is rejected without changing projection" {
    var projection: Projection = .{};
    projection.treasury_usdt_atoms = 1_000;
    projection.exchange.usdt_balance_atoms = 1_000;
    const before = projection;
    try std.testing.expectError(error.InvalidEconomicFact, projection.apply(.{ .venue_forced_execution = .{ .identity = 1, .side = .sell, .quantity = fixtureQuantity(1), .price = fixturePrice(100), .price_tick_value = fixtureAmount(1), .quantity_denominator = 1, .penalty = fixtureAmount(-1), .product = .isolated_linear_usdt } }));
    try std.testing.expectEqualDeep(before, projection);
}

test "allocated forced PnL must match the closed portfolio position" {
    var projection: Projection = .{};
    try projection.apply(.{ .fill = .{ .identity = 1, .side = .buy, .quantity = fixtureQuantity(1), .price = fixturePrice(100), .price_tick_value = fixtureAmount(1), .quantity_denominator = 1, .product = .isolated_linear_usdt } });
    const before = projection.digest();
    try std.testing.expectError(error.ForcedExecutionPnlMismatch, projection.apply(.{ .venue_forced_execution = .{
        .identity = 2,
        .side = .sell,
        .quantity = fixtureQuantity(1),
        .price = fixturePrice(100),
        .price_tick_value = fixtureAmount(1),
        .quantity_denominator = 1,
        .expected_realized_pnl_atoms = 1,
        .product = .isolated_linear_usdt,
    } }));
    try std.testing.expectEqualSlices(u8, &before, &projection.digest());
}

test "valuation respects the contract quantity denominator" {
    var projection: Projection = .{};
    projection.portfolio.usdt_balance_atoms = 1_000;
    projection.exchange.usdt_balance_atoms = 1_000;
    try projection.apply(.{ .fill = .{ .identity = 1, .side = .buy, .quantity = fixtureQuantity(10), .price = fixturePrice(100), .price_tick_value = fixtureAmount(1), .quantity_denominator = 10, .product = .isolated_linear_usdt } });
    try projection.apply(.{ .mark_price = .{ .product = .isolated_linear_usdt, .price_atoms = 120, .quantity_denominator = 10 } });
    try std.testing.expectEqual(@as(i64, 20), projection.portfolio.unrealized_pnl_atoms);
}

test "ledger postings reproduce signed fee rebate and funding cash movements" {
    var projection: Projection = .{};
    projection.portfolio.usdt_balance_atoms = 1_000;
    projection.exchange.usdt_balance_atoms = 1_000;
    try projection.apply(.{ .fill = .{ .identity = 1, .side = .buy, .quantity = fixtureQuantity(1), .price = fixturePrice(100), .price_tick_value = fixtureAmount(1), .quantity_denominator = 1, .fee = fixtureAmount(3), .rebate = fixtureAmount(1), .product = .isolated_linear_usdt } });
    try projection.apply(.{ .funding_settlement = .{ .identity = 2, .amount = fixtureAmount(7) } });

    try std.testing.expectEqual(@as(i64, 1_005), projection.portfolio.usdt_balance_atoms);
    try std.testing.expectEqual(@as(u8, 8), projection.ledger_count);
    try std.testing.expectEqualDeep(LedgerPosting{ .account = .swap_position, .unit = .swap_quantity, .amount = 1 }, projection.ledger[0].postings[0]);
    try std.testing.expectEqualDeep(LedgerPosting{ .account = .trade, .unit = .swap_quantity, .amount = -1 }, projection.ledger[0].postings[1]);
    try std.testing.expectEqualDeep(LedgerPosting{ .account = .cash, .unit = .settlement_atoms, .asset = 1, .amount = -3 }, projection.ledger[2].postings[0]);
    try std.testing.expectEqualDeep(LedgerPosting{ .account = .fee_expense, .unit = .settlement_atoms, .asset = 1, .amount = 3 }, projection.ledger[2].postings[1]);
    try std.testing.expectEqualDeep(LedgerPosting{ .account = .cash, .unit = .settlement_atoms, .asset = 1, .amount = 1 }, projection.ledger[4].postings[0]);
    try std.testing.expectEqualDeep(LedgerPosting{ .account = .rebate_income, .unit = .settlement_atoms, .asset = 1, .amount = -1 }, projection.ledger[4].postings[1]);
    try std.testing.expectEqualDeep(LedgerPosting{ .account = .cash, .unit = .settlement_atoms, .asset = 1, .amount = 7 }, projection.ledger[6].postings[0]);
    try std.testing.expectEqualDeep(LedgerPosting{ .account = .funding_pnl, .unit = .settlement_atoms, .asset = 1, .amount = -7 }, projection.ledger[6].postings[1]);
    try projection.assertClosed();
}

test "canonical fill evidence is idempotent and rejects a conflicting payload" {
    var projection: Projection = .{};
    projection.portfolio.usdt_balance_atoms = 1_000;
    projection.exchange.usdt_balance_atoms = 1_000;
    const fill: Fill = .{
        .identity = 7,
        .order_id = 1,
        .side = .buy,
        .quantity = fixtureQuantity(1),
        .price = fixturePrice(100),
        .price_tick_value = fixtureAmount(1),
        .quantity_denominator = 1,
        .product = .isolated_linear_usdt,
    };
    const digest_a: [Sha256.digest_length]u8 = @splat(1);
    const digest_b: [Sha256.digest_length]u8 = @splat(2);
    try std.testing.expect(try projection.applyCanonicalFill(fill, digest_a));
    try std.testing.expectEqual(Projection.CanonicalFillIdentity.duplicate, try projection.lookupCanonicalFill(7, digest_a));
    try std.testing.expect(!(try projection.applyCanonicalFill(fill, digest_a)));
    try std.testing.expectEqual(@as(i64, 1), projection.portfolio.swap.quantity);
    try std.testing.expectError(error.ConflictingEconomicIdentity, projection.lookupCanonicalFill(7, digest_b));
    try std.testing.expectError(error.ConflictingEconomicIdentity, projection.applyCanonicalFill(fill, digest_b));
    try std.testing.expectEqual(@as(i64, 1), projection.portfolio.swap.quantity);
}
