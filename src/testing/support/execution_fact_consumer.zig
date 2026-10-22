const trading = @import("../../trading/trading_shard.zig");

/// Test strategy: propose once per new applied quantity; checkpoint this cursor with its output.
pub const FillConsumer = struct {
    applied_quantity: i64 = 0,
    possible_quantity: i64 = 0,
    proposals: usize = 0,

    /// Keep the original target fixed and reserve the entire possible outstanding execution.
    pub fn additionalHedgeQuantity(self: @This(), target: i64) !i64 {
        if (target < 0) return error.InvalidTarget;
        return @max(0, @max(0, target - self.applied_quantity) - self.possible_quantity);
    }

    pub fn observe(self: *@This(), shard: *const trading.TradingShard, account: u128, order_id: u64) !void {
        const state = shard.accountState(account) orelse return error.MissingAccount;
        const applied = try state.economic_projection.appliedCanonicalFillQuantity(order_id);
        if (applied < self.applied_quantity) return error.EconomicQuantityRegressed;
        if (applied > self.applied_quantity) self.proposals += 1;
        self.applied_quantity = applied;
        const order = shard.oms.orderById(order_id) orelse return error.MissingOrder;
        const maximum = switch (order.state) {
            .filled, .canceled, .rejected => order.cumulative_quantity,
            else => @max(order.confirmed_quantity, order.pending_basis_quantity),
        };
        self.possible_quantity = @max(0, maximum - applied);
    }
};
