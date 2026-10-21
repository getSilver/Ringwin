const std = @import("std");
const trading = @import("../../../trading/trading_shard.zig");
const allocation = @import("../../../trading/deployment_allocation.zig");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const durable = @import("../../../persistence/durable_store.zig");
const history = @import("../../../persistence/business_history.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");

pub fn configurationRows() ![14]allocation.Input {
    var rows: [14]allocation.Input = .{
        .{ .begin = .{ .identity = 7, .epoch = 1, .domain_count = 1, .account_count = 2, .asset_count = 1, .account_limit_count = 2, .ownership_count = 4, .slice_count = 2, .expected_digest = @splat(1) } },
        .{ .domain = .{ .identity = 1, .stream = 91, .portfolio = 10 } },
        .{ .account = .{ .identity = 20, .venue = 1 } },
        .{ .account = .{ .identity = 30, .venue = 21 } },
        .{ .asset_limit = .{ .asset = 1, .atoms = 100 } },
        .{ .account_limit = .{ .account = 20, .asset = 1, .atoms = 60 } },
        .{ .account_limit = .{ .account = 30, .asset = 1, .atoms = 40 } },
        .{ .ownership = .{ .account = 20, .instrument = 101, .domain = 1 } },
        .{ .ownership = .{ .account = 30, .instrument = 102, .domain = 1 } },
        .{ .slice = .{ .account = 20, .asset = 1, .domain = 1, .atoms = 60 } },
        .{ .slice = .{ .account = 30, .asset = 1, .domain = 1, .atoms = 40 } },
        .{ .ownership = .{ .account = 20, .instrument = 103, .domain = 1 } },
        .{ .ownership = .{ .account = 30, .instrument = 104, .domain = 1 } },
        .seal,
    };
    var configuration: allocation.Configuration = .{};
    for (rows[0 .. rows.len - 1]) |row| try configuration.apply(row);
    rows[0].begin.expected_digest = configuration.contentDigest();
    return rows;
}

test "05a account scoped public inputs keep two economic owners through snapshot restore" {
    try exerciseAccountRecovery(.single);
}

test "05b complete domain group commits both accounts through snapshot restore" {
    try exerciseAccountRecovery(.joint);
}

test "05b shared account budget rejects 60 plus 50 and 70 plus 40 but accepts 70 plus 30" {
    try exerciseAccountRecovery(.shared_budget);
}

const Scenario = enum { single, joint, shared_budget, fault_append, fault_commit, publish_fault, file_restore, safety_cancel, domain_history, shared_mark, reverse_competition, single_rejected, four_accounts, safety_reduce, capacity_load, unknown };
var fault_remaining: usize = 0;

test "05b Unknown commands retain both occupied members through Owner recovery without resend" {
    try exerciseAccountRecovery(.unknown);
}

test "05a canonical maximum snapshot encoding fits the unchanged Store byte ceiling" {
    const codec = @import("../../../persistence/snapshot_codec.zig");
    const maximum = codec.header_len + codec.maxBareSize(trading.TradingShard);
    std.debug.print("05a all-fields encoding upper_bound_bytes={d} store_ceiling_bytes={d}\n", .{ maximum, durable.max_snapshot_bytes });
    try std.testing.expect(maximum < durable.max_snapshot_bytes - 1024 * 1024);
}

test "05a reachable economic and rejection capacity retains safety fills and a measured snapshot" {
    try exerciseAccountRecovery(.capacity_load);
}

test "05b existing cycle reductions cannot exceed holdings through concurrent orders" {
    try exerciseAccountRecovery(.safety_reduce);
}

test "05a four account partitions route a competing third account and retain one writer" {
    try exerciseAccountRecovery(.four_accounts);
}

test "05b single member cannot open a domain cycle" {
    try exerciseAccountRecovery(.single_rejected);
}

test "05b AC arriving before AB keeps the shared member uniquely occupied" {
    try exerciseAccountRecovery(.reverse_competition);
}

test "05a one public mark updates both accounts owning the same venue instrument" {
    try exerciseAccountRecovery(.shared_mark);
}

test "05a domain funding and retired control history continue across both accounts" {
    try exerciseAccountRecovery(.domain_history);
}

test "05b safety cancellation reuses both occupied members without opening a cycle" {
    try exerciseAccountRecovery(.safety_cancel);
}

test "05a two account domain root and orders survive file store close and reopen" {
    try exerciseAccountRecovery(.file_restore);
}

test "05b checkpoint publication fault retains committed group and account economics" {
    try exerciseAccountRecovery(.publish_fault);
}

test "05b every joint append and commit fault recovers no half group" {
    for (1..11) |index| {
        fault_remaining = index;
        try exerciseAccountRecovery(.fault_append);
    }
    for (1..5) |index| {
        fault_remaining = index;
        try exerciseAccountRecovery(.fault_commit);
    }
}

fn exerciseAccountRecovery(scenario: Scenario) !void {
    const allocator = std.testing.allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    var store = memory.interface();
    const io: std.Io = if (scenario == .file_restore) std.testing.io else undefined;
    var temp: ?std.testing.TmpDir = null;
    defer if (temp) |*directory| directory.cleanup();
    var path_buffer: [1024]u8 = undefined;
    var path: []const u8 = &.{};
    var file: ?*durable.LinuxFileAdapter = null;
    defer if (file) |adapter| {
        adapter.close(io);
        allocator.destroy(adapter);
    };
    if (scenario == .file_restore) {
        temp = std.testing.tmpDir(.{});
        path = path_buffer[0..try temp.?.dir.realPath(io, &path_buffer)];
        const adapter = try allocator.create(durable.LinuxFileAdapter);
        @memset(std.mem.asBytes(adapter), 0);
        if (@import("builtin").os.tag == .linux) try adapter.initLinux(io, path) else try adapter.initWindowsVerification(io, path);
        file = adapter;
        store = adapter.interface();
    }
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, store, io, .{ .domain = .decision_log, .id = 91 });
    const shard = &owner.shard;
    const log = &owner.decision_journal;
    try initializeForScenario(owner, scenario);
    try exercisePartitionOrders(owner, scenario);
    if (scenario == .fault_append or scenario == .fault_commit) return;
    if (scenario == .publish_fault) {
        var failing = store.vtable.*;
        failing.publish = failPublish;
        owner.store = .{ .context = store.context, .vtable = &failing };
        try std.testing.expectError(error.DecisionLogUnavailable, owner.checkpoint());
        owner.store = store;
        try std.testing.expect(owner.closed);
    } else try owner.checkpoint();
    if (file) |adapter| {
        adapter.close(io);
        @memset(std.mem.asBytes(adapter), 0);
        if (@import("builtin").os.tag == .linux) try adapter.initLinux(io, path) else try adapter.initWindowsVerification(io, path);
        store = adapter.interface();
    }
    const recovered_owner = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered_owner);
    try demo.Owner.recoverInto(recovered_owner, store, io, owner.stream);
    try std.testing.expectEqualSlices(u8, &shard.canonicalStateDigest(), &recovered_owner.shard.canonicalStateDigest());
    if (scenario == .unknown) {
        try std.testing.expectEqual(@as(u8, 1), recovered_owner.shard.cycles.count);
        for ([_]u64{ 1, 2 }) |id| try std.testing.expectEqual(trading.oms.OrderState.unknown, recovered_owner.shard.oms.orderById(id).?.state);
        try exerciseDispatch(recovered_owner, 1);
    }
    try log.seal();
    const bytes = try allocator.alloc(u8, 32 * 1024 * 1024);
    defer allocator.free(bytes);
    const recovered = try allocator.create(trading.TradingShard);
    defer allocator.destroy(recovered);
    const encoded_snapshot = try shard.snapshot(log, log.last_sequence, bytes);
    try std.testing.expectEqual(encoded_snapshot.len, try shard.snapshotEncodedSize());
    _ = try trading.TradingShard.restoreSnapshotInto(recovered, encoded_snapshot);
    try std.testing.expectEqualSlices(u8, &shard.canonicalStateDigest(), &recovered.canonicalStateDigest());
    try std.testing.expectEqual(@as(i128, if (scenario == .domain_history) 605 else 600), recovered.accountState(30).?.economic_projection.portfolio.usdt_balance_atoms);
}

pub fn initializePythonOwner(owner: *demo.Owner) !void {
    try initializeForScenario(owner, .joint);
    try prepareTradingForScenario(owner, .joint);
}

fn initializeForScenario(owner: *demo.Owner, scenario: Scenario) !void {
    const shard = &owner.shard;
    var rows = try configurationRows();
    if (scenario == .shared_budget) {
        rows[4].asset_limit.atoms = 200;
        for ([_]usize{ 5, 6 }) |index| rows[index].account_limit.atoms = 100;
        for ([_]usize{ 9, 10 }) |index| rows[index].slice.atoms = 100;
        var configuration: allocation.Configuration = .{};
        for (rows[0 .. rows.len - 1]) |row| try configuration.apply(row);
        rows[0].begin.expected_digest = configuration.contentDigest();
    }
    if (scenario == .shared_mark) {
        rows[3].account.venue = 1;
        rows[8].ownership.instrument = 101;
        rows[12].ownership.instrument = 103;
        var configuration: allocation.Configuration = .{};
        for (rows[0 .. rows.len - 1]) |row| try configuration.apply(row);
        rows[0].begin.expected_digest = configuration.contentDigest();
    }
    if (scenario != .four_accounts) try owner.pinDeploymentDigest(rows[0].begin.expected_digest);
    var identity: u64 = 1;
    if (scenario == .four_accounts) {
        rows[0].begin.account_count = 4;
        rows[0].begin.account_limit_count = 4;
        rows[0].begin.slice_count = 4;
        rows[0].begin.ownership_count = 5;
        rows[4].asset_limit.atoms = 140;
        rows[11].ownership.account = 40;
        var configuration: allocation.Configuration = .{};
        for (rows[0 .. rows.len - 1]) |row| try configuration.apply(row);
        for ([_]u128{ 40, 50 }, [_]u64{ 1, 21 }) |account, venue| {
            try configuration.apply(.{ .account = .{ .identity = account, .venue = venue } });
            try configuration.apply(.{ .account_limit = .{ .account = account, .asset = 1, .atoms = 20 } });
            try configuration.apply(.{ .slice = .{ .account = account, .asset = 1, .domain = 1, .atoms = 20 } });
        }
        try configuration.apply(.{ .ownership = .{ .account = 50, .instrument = 105, .domain = 1 } });
        rows[0].begin.expected_digest = configuration.contentDigest();
        configuration.header.?.expected_digest = rows[0].begin.expected_digest;
        try configuration.apply(.seal);
        // Pin the externally selected complete configuration before installing any row.
        try owner.pinDeploymentDigest(configuration.header.?.expected_digest);
        try owner.installDeployment(&configuration);
        identity = owner.shard.authoritativeBarrier() + 1;
    } else {
        for (rows) |row| {
            _ = try owner.apply(.{ .core = .{ .identity = identity, .payload = .{ .deployment_configuration = row } } });
            identity += 1;
        }
    }
    _ = try owner.apply(.{ .core = .{ .identity = identity, .payload = .{ .decision_domain_bound = .{ .domain = 1, .stream = 91 } } } });
    identity += 1;
    for (@import("../../../trading/asset_registry.zig").testDefinitions(6, 8)) |definition| {
        _ = try owner.apply(.{ .core = .{ .identity = identity, .payload = .{ .asset_definition_activated = definition } } });
        identity += 1;
    }
    const account_count: usize = if (scenario == .four_accounts) 4 else 2;
    const accounts = [_]u128{ 20, 30, 40, 50 };
    const instruments = [_]u128{ 101, if (scenario == .shared_mark) 101 else 102, 103, 105 };
    const venues = [_]u64{ 1, if (scenario == .shared_mark) 1 else 21, 1, 21 };
    const balances = [_]i128{ 1000, 2000, 3000, 4000 };
    const transfers = [_]i128{ 400, 600, 800, 1000 };
    for (accounts[0..account_count], instruments[0..account_count], venues[0..account_count], balances[0..account_count], transfers[0..account_count]) |account, instrument, venue, balance, transfer| {
        const payloads = [_]trading.CorePayload{
            .{ .instrument_rules_activated = .{ .version = 1, .instrument_identity = instrument, .quantity_denominator = 10000, .reservation_model = .leveraged, .product = .isolated_linear_usdt, .venue = venue } },
            .{ .margin_rules_activated = .{ .version = 1, .instrument = instrument } },
            .{ .account_configuration = .{ .exchange_account_identity = account } },
            .{ .exchange_balance = .{ .cash_atoms = balance } },
            .exchange_positions,
            .{ .opening_balance = .{ .cash_atoms = balance } },
            .{ .virtual_portfolio_activated = .{ .portfolio_identity = 10 } },
            .{ .portfolio_transfer = .{ .amount_atoms = transfer } },
        };
        for (payloads) |payload| {
            _ = try owner.apply(fixture.atGroup(10, .{ .identity = identity, .account_scope = account, .payload = payload }));
            identity += 1;
        }
    }
    try std.testing.expectEqual(@as(i128, 400), shard.accountState(20).?.economic_projection.portfolio.usdt_balance_atoms);
    try std.testing.expectEqual(@as(i128, 600), shard.accountState(30).?.economic_projection.portfolio.usdt_balance_atoms);
    try std.testing.expectEqual(@as(i128, 1000), shard.accountState(20).?.economic_projection.exchange.usdt_balance_atoms);
    try std.testing.expectEqual(@as(i128, 2000), shard.accountState(30).?.economic_projection.exchange.usdt_balance_atoms);
    try std.testing.expectEqual(@as(u8, 0), shard.account_view);
    _ = try owner.apply(.{ .core = .{ .identity = identity, .payload = .{ .strategy_activated = .{ .strategy_identity = 9, .config_version = 1, .activation_identity = 1 } } } });
    identity += 1;
    _ = try owner.apply(.{ .core = .{ .identity = identity, .payload = .{ .primary_lease_granted = .{ .fencing_token = 1 } } } });
    identity += 1;
    const limits = if (scenario == .shared_budget) [_]i128{ 100, 100, 20, 20 } else [_]i128{ 60, 40, 20, 20 };
    for (accounts[0..account_count], limits[0..account_count]) |account, limit| {
        const before = shard.canonicalStateDigest();
        var grant: trading.CoreEvent = .{ .identity = identity, .account_scope = account, .payload = .{ .risk_lease_granted = .{ .amount_atoms = limit } } };
        try std.testing.expectError(error.UnverifiedRiskLeaseAllocation, shard.apply(.{ .core = grant }));
        try std.testing.expectEqualSlices(u8, &before, &shard.canonicalStateDigest());
        grant.payload.risk_lease_granted.allocation = .{ .configuration_digest = rows[0].begin.expected_digest, .account = account, .asset = 1, .domain = 1, .stream = 91 };
        grant.payload.risk_lease_granted.amount_atoms = limit + 1;
        try std.testing.expectError(error.RiskLeaseOversubscribed, shard.apply(.{ .core = grant }));
        grant.payload.risk_lease_granted.amount_atoms = limit;
        _ = try owner.apply(.{ .core = grant });
        identity += 1;
    }
    for (accounts[0..account_count], instruments[0..account_count], venues[0..account_count], balances[0..account_count]) |account, instrument, venue, balance| {
        var bootstrap: trading.canonical.AccountBootstrapSnapshot = .{
            .identity = account,
            .exchange_account = account,
            .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true },
            .source_stream = 1,
            .source_sequence = 1,
            .balance_count = 1,
            .position_count = 0,
            .margin_count = if (account <= 30) 2 else 1,
        };
        const zero: trading.canonical.AssetAmount = .{ .asset = 1, .atoms = 0 };
        const amount: trading.canonical.AssetAmount = .{ .asset = 1, .atoms = balance };
        bootstrap.balances[0] = .{ .asset = 1, .total = amount, .available = amount, .held = zero, .cash_balance = amount, .liability = zero, .isolated_liability = zero, .cross_liability = zero };
        bootstrap.margins[0] = .{ .instrument = instrument, .amount = zero, .initial_margin = zero, .maintenance_margin = zero, .isolated_equity = zero };
        bootstrap.margins[1] = bootstrap.margins[0];
        bootstrap.margins[1].instrument = if (account == 20) 103 else 104;
        var event = @import("../../support/trading_shard_fixture.zig").canonicalAt(40, 1, .{ .account_bootstrap_snapshot = bootstrap });
        event.venue.envelope.exchange_account = account;
        event.venue.envelope.venue = venue;
        event.venue.envelope.identity.stream = 1;
        event.venue.envelope.source_stream = 1;
        _ = try owner.apply(event);
    }
    try std.testing.expectEqual(@as(?u128, 20), shard.accountState(20).?.canonical_account.exchange_account);
    try std.testing.expectEqual(@as(?u128, 30), shard.accountState(30).?.canonical_account.exchange_account);
    if (scenario == .four_accounts) {
        try std.testing.expectEqual(@as(u8, 3), shard.secondary_account_count);
        try std.testing.expectEqual(@as(i128, 3000), shard.accountState(40).?.economic_projection.exchange.usdt_balance_atoms);
        try std.testing.expectEqual(@as(i128, 4000), shard.accountState(50).?.economic_projection.exchange.usdt_balance_atoms);
    }
    try owner.sealBootstrap();
}

fn prepareTradingForScenario(owner: *demo.Owner, scenario: Scenario) !void {
    const controls = [_]trading.CorePayload{
        .{ .control_command = .{ .command_identity = 900, .content_hash = 900, .target_identity = 1, .expected_version = 0, .expires_at = std.math.maxInt(u64), .kind = .start_recovery } },
        .recovery_completed,
        .{ .control_command = .{ .command_identity = 901, .content_hash = 901, .target_identity = 1, .expected_version = 2, .expires_at = std.math.maxInt(u64), .kind = .enable_trading } },
    };
    for (controls, 0..) |payload, index| _ = try owner.apply(fixture.atGroup(41, .{ .identity = index + 900, .payload = payload }));
    const configured_accounts = [_]u128{ 20, 30, if (scenario == .four_accounts) 40 else 20, 30, 50 };
    const configured_instruments = [_]u128{ 101, if (scenario == .shared_mark) 101 else 102, 103, 104, 105 };
    const configured_venues = [_]u64{ 1, if (scenario == .shared_mark) 1 else 21, 1, 21, 21 };
    const configured_count: usize = if (scenario == .four_accounts) 5 else 4;
    for (configured_accounts[0..configured_count], configured_instruments[0..configured_count], configured_venues[0..configured_count]) |account, instrument, venue| {
        if (instrument >= 103 and (scenario == .domain_history or scenario == .shared_mark)) continue;
        if (instrument >= 103 and !(scenario == .four_accounts and instrument != 104)) {
            _ = try owner.apply(fixture.atGroup(42, .{ .identity = @intCast(950 + instrument), .account_scope = account, .payload = .{ .instrument_rules_activated = .{
                .version = 1,
                .instrument_identity = instrument,
                .quantity_denominator = 10000,
                .reservation_model = .leveraged,
                .product = .isolated_linear_usdt,
                .venue = venue,
            } } }));
            _ = try owner.apply(fixture.atGroup(42, .{ .identity = @intCast(960 + instrument), .account_scope = account, .payload = .{ .margin_rules_activated = .{ .version = 1, .instrument = instrument } } }));
        }
        _ = try owner.apply(fixture.atGroup(42, .{ .identity = @intCast(1000 + instrument), .account_scope = account, .payload = .{ .capability_profile_activation = .{
            .exchange_account = account,
            .instrument = instrument,
            .venue = venue,
            .environment = .simulation,
            .product = .isolated_linear_usdt,
            .version = 1,
            .rules_version = 1,
            .config_version = 1,
            .adapter_session = 1,
            .max_dispatch_age_ns = std.time.ns_per_s,
            .supports_place = true,
            .supports_cancel = true,
            .supports_native_amend = false,
            .supports_venue_reduce_only = false,
            .supports_post_only = false,
            .supports_market_protection = false,
        } } }));
        var book = fixture.canonicalAt(43, 1, .{ .l2_book_snapshot = .{
            .instrument = instrument,
            .sequence = 1,
            .best_bid = .{ .instrument = instrument, .rules_version = 1, .ticks = 99 },
            .best_ask = .{ .instrument = instrument, .rules_version = 1, .ticks = 100 },
            .best_bid_quantity = .{ .instrument = instrument, .rules_version = 1, .lots = 100000 },
            .best_ask_quantity = .{ .instrument = instrument, .rules_version = 1, .lots = 100000 },
        } });
        book.venue.envelope.scope = .instrument;
        book.venue.envelope.exchange_account = null;
        book.venue.envelope.instrument = instrument;
        book.venue.envelope.venue = venue;
        book.venue.envelope.identity.stream = 1000 + instrument;
        book.venue.envelope.source_stream = @intCast(1000 + instrument);
        _ = try owner.apply(book);
        _ = try owner.apply(fixture.atGroup(44, .{ .identity = @intCast(1100 + instrument), .account_scope = account, .payload = .{ .mark_price = .{ .instrument = instrument, .price_atoms = 100 } } }));
    }
}

fn exercisePartitionOrders(owner: *demo.Owner, scenario: Scenario) !void {
    const joint = scenario != .single and scenario != .shared_budget;
    try prepareTradingForScenario(owner, scenario);
    if (scenario == .shared_mark) {
        var mark = fixture.canonicalAt(47, 1, .{ .reference_price = .{ .instrument = 101, .kind = .mark, .price = .{ .instrument = 101, .rules_version = 1, .ticks = 111 } } });
        mark.venue.envelope.scope = .instrument;
        mark.venue.envelope.exchange_account = null;
        mark.venue.envelope.instrument = 101;
        mark.venue.envelope.venue = 1;
        mark.venue.envelope.identity.stream = 9000;
        mark.venue.envelope.source_stream = 9000;
        _ = try owner.apply(mark);
        for ([_]u128{ 20, 30 }) |account| {
            const state = owner.shard.accountState(account).?;
            try std.testing.expectEqual(@as(i128, 111), state.economic_projection.portfolio.instrumentPosition(101).?.mark_price_atoms);
            try std.testing.expectEqual(@as(i128, 111), state.economic_projection.exchange.instrumentPosition(101).?.mark_price_atoms);
        }
        return;
    }
    if (scenario == .single_rejected) {
        var group: trading.oms.IntentGroup = .{ .first_intent_sequence = 1, .count = 1 };
        group.members[0] = .{ .intent_sequence = 1, .strategy_instance = 9, .exchange_account = 20, .operation = .place, .instrument = 101, .quantity = 10000, .limit_price = .{ .instrument = 101, .rules_version = 1, .ticks = 100 } };
        _ = try owner.apply(fixture.atGroup(45, .{ .identity = 1199, .account_scope = 20, .payload = .{ .oms_intent_group = group } }));
        try std.testing.expectEqual(@import("../../../trading/trading_shard_event.zig").RejectReason.invalid_scope, owner.shard.last_reject_reason);
        try std.testing.expectEqual(@as(u16, 0), owner.shard.oms.order_count);
        try std.testing.expectEqual(@as(u8, 0), owner.shard.cycles.count);
        return;
    }
    if (scenario == .shared_budget) return exerciseSharedBudget(owner);
    if (joint) {
        const host = @import("../../../strategy/strategy_host_gateway.zig");
        if (scenario != .domain_history and scenario != .four_accounts) {
            // Both members fit the slice separately; their shared reservation does not.
            var excessive: trading.oms.IntentGroup = .{ .first_intent_sequence = 1, .count = 2 };
            for ([_]u128{ 101, 103 }, 0..) |instrument, index| excessive.members[index] = .{
                .intent_sequence = index + 1,
                .strategy_instance = 9,
                .exchange_account = 20,
                .operation = .place,
                .instrument = instrument,
                .quantity = 200000,
                .limit_price = .{ .instrument = instrument, .rules_version = 1, .ticks = 100 },
            };
            _ = try owner.apply(fixture.atGroup(45, .{ .identity = 1190, .account_scope = 20, .payload = .{ .oms_intent_group = excessive } }));
            try std.testing.expectEqual(@import("../../../trading/trading_shard_event.zig").RejectReason.strategy_limit_exceeded, owner.shard.last_reject_reason);
            try std.testing.expectEqual(@as(u16, 0), owner.shard.oms.order_count);
            try std.testing.expectEqual(@as(u8, 0), owner.shard.cycles.count);
            try std.testing.expectEqual(@as(i128, 0), (try owner.shard.oms.reservationsForAccount(1, 20)).atoms);
        }
        const barrier = owner.shard.authoritativeBarrier();
        const config: host.Config = .{ .schema_registry = trading.schema_registry_identity, .decision_domain = 1, .session = .{ .fencing = 1, .shard = 1, .generation = 1 }, .authorization = .{ .strategy_identity = 9, .config_version = 1, .activation_identity = 1, .activation_barrier = barrier } };
        _ = try owner.apply(fixture.atGroup(45, .{ .identity = 1199, .payload = .{ .host_activated = .{
            .strategy_identity = 9,
            .config_version = 1,
            .activation_identity = 1,
            .activation_barrier = barrier,
            .session = config.session,
            .state_digest = owner.shard.canonicalStateDigest(),
        } } }));
        const orders = [_]host.OutputOrder{
            .{ .portfolio_identity = 10, .exchange_account_identity = 20, .instrument_identity = 101, .quantity = 10000, .limit_price_micros = 100 },
            .{ .portfolio_identity = 10, .exchange_account_identity = 30, .instrument_identity = if (scenario == .reverse_competition) 104 else 102, .quantity = 10000, .limit_price_micros = 100 },
        };
        var storage: [host.max_group_frame_len]u8 = undefined;
        const frame = try host.encodeOutputGroupFrame(&storage, config, 1, owner.shard.authoritativeBarrier() + 1, 3, &orders);
        var candidate: host.GroupCandidate = .{ .len = @intCast(frame.len) };
        @memcpy(candidate.bytes[0..frame.len], frame);
        const input = fixture.atGroup(45, .{ .identity = 1200, .payload = .{ .external_intent_group = candidate } });
        if (scenario == .fault_append or scenario == .fault_commit) return exerciseFailedGroup(owner, input, scenario == .fault_commit);
        _ = try owner.apply(input);
        try std.testing.expectEqual(@import("../../../trading/trading_shard_event.zig").RejectReason.none, owner.shard.last_reject_reason);
        try std.testing.expectEqual(@as(u16, 2), owner.shard.oms.order_count);
        const before = owner.shard.canonicalStateDigest();
        _ = try owner.apply(input);
        try std.testing.expectEqualSlices(u8, &before, &owner.shard.canonicalStateDigest());
        try exerciseDispatch(owner, 1);
        for (if (scenario == .reverse_competition) [_][2]u128{ .{ 101, 102 }, .{ 103, 104 } } else [_][2]u128{ .{ 101, 104 }, .{ 103, 102 } }, 0..) |instruments, attempt| {
            var competing: trading.oms.IntentGroup = .{ .first_intent_sequence = 5 + 2 * attempt, .count = 2 };
            for ([_]u128{ if (scenario == .four_accounts and attempt == 1) 40 else 20, 30 }, instruments, 0..) |account, instrument, index| competing.members[index] = .{
                .intent_sequence = competing.first_intent_sequence + index,
                .strategy_instance = 9,
                .exchange_account = account,
                .operation = .place,
                .instrument = instrument,
                .quantity = 10000,
                .limit_price = .{ .instrument = instrument, .rules_version = 1, .ticks = 100 },
            };
            _ = try owner.apply(fixture.atGroup(45, .{ .identity = 1201 + attempt, .payload = .{ .oms_intent_group = competing } }));
            try std.testing.expectEqual(@import("../../../trading/trading_shard_event.zig").RejectReason.instrument_occupied, owner.shard.last_reject_reason);
            try std.testing.expectEqual(@as(u16, 2), owner.shard.oms.order_count);
            try std.testing.expectEqual(@as(u8, 1), owner.shard.cycles.count);
        }
    }
    if (scenario == .four_accounts) {
        try verifyScopeRejections(&owner.shard);
        try std.testing.expectEqual(@as(i128, 0), (try owner.shard.oms.reservationsForAccount(1, 40)).atoms);
        var cd: trading.oms.IntentGroup = .{ .first_intent_sequence = 1001, .count = 2 };
        for ([_]u128{ 40, 50 }, [_]u128{ 103, 105 }, 0..) |account, instrument, index| cd.members[index] = .{
            .intent_sequence = 1001 + index,
            .strategy_instance = 9,
            .exchange_account = account,
            .operation = .place,
            .instrument = instrument,
            .quantity = 10000,
            .limit_price = .{ .instrument = instrument, .rules_version = 1, .ticks = 100 },
        };
        _ = try owner.apply(fixture.atGroup(46, .{ .identity = 1300, .payload = .{ .oms_intent_group = cd } }));
        try std.testing.expectEqual(@as(u16, 4), owner.shard.oms.order_count);
        try std.testing.expectEqual(@as(u8, 2), owner.shard.cycles.count);
        try exerciseDispatch(owner, 3);
        return;
    }
    if (scenario == .reverse_competition) return;
    if (scenario == .unknown) {
        for ([_]u128{ 20, 30 }, 0..) |account, index| {
            var batch: trading.oms.DispatchBatch = .{ .count = 1 };
            batch.items[0] = .{ .command_id = index + 1, .state = .unknown };
            _ = try owner.apply(fixture.atGroup(46, .{ .identity = 1400 + index, .account_scope = account, .payload = .{ .oms_dispatch_batch = batch } }));
            try std.testing.expectEqual(trading.oms.OrderState.unknown, owner.shard.oms.orderById(index + 1).?.state);
            try std.testing.expect((try owner.shard.oms.reservationsForAccount(1, account)).atoms > 0);
        }
        try std.testing.expectEqual(@as(u8, 1), owner.shard.cycles.count);
        try exerciseDispatch(owner, 1);
        return;
    }
    if (scenario == .safety_cancel) {
        var cancellation: trading.oms.IntentGroup = .{ .first_intent_sequence = 10001, .count = 2 };
        for ([_]u128{ 20, 30 }, [_]u128{ 101, 102 }, [_]u64{ 1, 21 }, 0..) |account, instrument, venue, index| {
            const order = owner.shard.oms.orderById(index + 1).?;
            var report = fixture.canonicalAt(46, 2, .{ .execution_report = .{
                .identity = 1,
                .order = order.id,
                .client_order_id = order.client_order_id,
                .instrument = instrument,
                .exchange_account = account,
                .revision = 1,
                .status = .accepted,
                .cumulative_quantity = .{ .instrument = instrument, .rules_version = 1, .lots = 0 },
                .remaining_quantity = .{ .instrument = instrument, .rules_version = 1, .lots = 10000 },
            } });
            report.venue.envelope.exchange_account = account;
            report.venue.envelope.venue = venue;
            _ = try owner.apply(report);
            cancellation.members[index] = .{ .intent_sequence = 10001 + index, .strategy_instance = 9, .exchange_account = account, .operation = .cancel, .instrument = instrument, .target_order_id = order.id, .expected_revision = 1 };
        }
        try owner.checkpoint();
        var rejected: usize = 0;
        while (rejected < 128) : (rejected += 1) {
            var risk_group: trading.oms.IntentGroup = .{ .first_intent_sequence = 101 + 2 * rejected, .count = 2 };
            for ([_]u128{ 20, 30 }, [_]u128{ 103, 104 }, 0..) |account, instrument, index| risk_group.members[index] = .{
                .intent_sequence = risk_group.first_intent_sequence + index,
                .strategy_instance = 9,
                .exchange_account = account,
                .operation = .place,
                .instrument = instrument,
                .quantity = 200000,
                .limit_price = .{ .instrument = instrument, .rules_version = 1, .ticks = 100 },
            };
            const before = owner.shard.canonicalStateDigest();
            _ = owner.apply(fixture.atGroup(47, .{ .identity = 3000 + rejected, .payload = .{ .oms_intent_group = risk_group } })) catch |err| {
                try std.testing.expectEqual(error.AdmissionCapacity, err);
                try std.testing.expectEqualSlices(u8, &before, &owner.shard.canonicalStateDigest());
                break;
            };
            try std.testing.expectEqual(@as(u16, 2), owner.shard.oms.order_count);
        }
        try std.testing.expect(rejected > 0 and rejected < 128);
        try std.testing.expect(!owner.closed);
        _ = try owner.apply(fixture.atGroup(47, .{ .identity = 1299, .payload = .{ .oms_intent_group = cancellation } }));
        try std.testing.expectEqual(@as(u16, 4), owner.shard.oms.command_history_count);
        try std.testing.expectEqual(@as(u8, 1), owner.shard.cycles.count);
        try std.testing.expectEqual(trading.oms.OrderState.pending_cancel, owner.shard.oms.orderById(1).?.state);
        try std.testing.expectEqual(trading.oms.OrderState.pending_cancel, owner.shard.oms.orderById(2).?.state);
        try exerciseDispatch(owner, 3);
        return;
    }
    if (!joint) {
        var group: trading.oms.IntentGroup = .{ .first_intent_sequence = 1, .count = 2 };
        for ([_]u128{ 20, 30 }, [_]u128{ 101, 102 }, 0..) |account, instrument, index| group.members[index] = .{
            .intent_sequence = index + 1,
            .strategy_instance = 9,
            .exchange_account = account,
            .operation = .place,
            .instrument = instrument,
            .quantity = 10000,
            .limit_price = .{ .instrument = instrument, .rules_version = 1, .ticks = 100 },
        };
        _ = try owner.apply(fixture.atGroup(45, .{ .identity = 1200, .payload = .{ .oms_intent_group = group } }));
        try std.testing.expectEqual(@as(u16, 2), owner.shard.oms.order_count);
    }
    if (scenario == .capacity_load) {
        for ([_]u128{ 20, 30 }) |account| {
            const account_index: usize = if (account == 20) 0 else 1;
            const instrument: u128 = if (account == 20) 101 else 102;
            const venue: u64 = if (account == 20) 1 else 21;
            const order = owner.shard.oms.orderById(account_index + 1).?;
            var partial = fixture.canonicalAt(46, 2, .{ .fill = .{
                .identity = 10,
                .order = order.id,
                .client_order_id = order.client_order_id,
                .venue_order = try trading.canonical.VenueOrderRef.init(venue, "domain-order"),
                .venue_trade = try trading.canonical.VenueTradeRef.init(venue, "domain-partial"),
                .instrument = instrument,
                .exchange_account = account,
                .side = .buy,
                .quantity = .{ .instrument = instrument, .rules_version = 1, .lots = 5000 },
                .price = .{ .instrument = instrument, .rules_version = 1, .ticks = 100 },
                .fee = .{ .asset = 1, .atoms = 0 },
                .venue_fill_time_utc_ns = fixture.atGroup(46, .{ .identity = 0, .payload = .recovery_completed }).core.source_time,
                .liquidity = .taker,
            } });
            partial.venue.envelope.exchange_account = account;
            partial.venue.envelope.venue = venue;
            _ = try owner.apply(partial);
            // Retain the account's economic frontier while half of its order is outstanding.
            for (0..14) |index| {
                _ = try owner.apply(fixture.atGroup(46, .{ .identity = 5000 + index, .account_scope = account, .payload = .{ .funding_settlement = .{ .settlement_id = index + 1, .amount_atoms = 0, .instrument = instrument } } }));
                if (index % 5 == 4) try owner.checkpoint();
            }
        }
        var candidate: trading.oms.IntentGroup = .{ .first_intent_sequence = 5001, .count = 2 };
        for ([_]u128{ 20, 30 }, [_]u128{ 103, 104 }, 0..) |account, instrument, index| candidate.members[index] = .{
            .intent_sequence = 5001 + index,
            .strategy_instance = 9,
            .exchange_account = account,
            .instrument = instrument,
            .operation = .place,
            .quantity = 10000,
            .limit_price = .{ .instrument = instrument, .rules_version = 1, .ticks = 100 },
        };
        _ = try owner.apply(fixture.atGroup(46, .{ .identity = 6000, .payload = .{ .oms_intent_group = candidate } }));
        try std.testing.expectEqual(@import("../../../trading/trading_shard_event.zig").RejectReason.admission_capacity_exhausted, owner.shard.last_reject_reason);
        try std.testing.expectEqual(@as(u16, 2), owner.shard.oms.order_count);
        try std.testing.expectEqual(@as(i128, 0), (try owner.shard.oms.reservationsForAccount(1, 20)).atoms - owner.shard.oms.orderById(1).?.reservation.atoms);
        try owner.checkpoint();
    }
    for ([_]u128{ 20, 30 }, [_]u128{ 101, 102 }, [_]u64{ 1, 21 }, 0..) |account, instrument, venue, account_index| {
        const order = owner.shard.oms.orderById(account_index + 1).?;
        try std.testing.expectEqual(account, order.exchange_account);
        const fill: trading.canonical.Payload = .{ .fill = .{
            .identity = 1,
            .order = order.id,
            .client_order_id = order.client_order_id,
            .venue_order = try trading.canonical.VenueOrderRef.init(venue, "domain-order"),
            .venue_trade = try trading.canonical.VenueTradeRef.init(venue, "domain-fill"),
            .instrument = instrument,
            .exchange_account = account,
            .side = .buy,
            .quantity = .{ .instrument = instrument, .rules_version = 1, .lots = if (scenario == .capacity_load) 5000 else 10000 },
            .price = .{ .instrument = instrument, .rules_version = 1, .ticks = 100 },
            .fee = .{ .asset = 1, .atoms = 0 },
            .venue_fill_time_utc_ns = fixture.atGroup(46, .{ .identity = 0, .payload = .recovery_completed }).core.source_time,
            .liquidity = .taker,
        } };
        const report: trading.canonical.Payload = .{ .execution_report = .{ .identity = 2, .order = order.id, .client_order_id = order.client_order_id, .instrument = instrument, .exchange_account = account, .revision = 1, .status = .filled, .cumulative_quantity = .{ .instrument = instrument, .rules_version = 1, .lots = 10000 }, .remaining_quantity = .{ .instrument = instrument, .rules_version = 1, .lots = 0 } } };
        const events: [2]trading.canonical.Payload = if (account_index == 0) .{ fill, report } else .{ report, fill };
        for (events, 0..) |payload, index| {
            var event = fixture.canonicalAt(46, index + (if (scenario == .capacity_load) @as(usize, 3) else 2), payload);
            event.venue.envelope.exchange_account = account;
            event.venue.envelope.venue = venue;
            _ = try owner.apply(event);
        }
        const state = owner.shard.accountState(account).?;
        try std.testing.expectEqual(@as(i64, 10000), try state.economic_projection.appliedCanonicalFillQuantity(order.id));
        try std.testing.expectEqual(@as(i64, 10000), state.economic_projection.portfolio.positionForInstrument(instrument).quantity);
    }
    try std.testing.expectEqual(@as(u8, 1), owner.shard.cycles.count);
    try owner.checkpoint();
    var reopened: trading.oms.IntentGroup = .{ .first_intent_sequence = 99, .count = 2 };
    reopened.members[0] = .{ .intent_sequence = 99, .strategy_instance = 9, .exchange_account = 20, .operation = .place, .instrument = 101, .quantity = 10000, .limit_price = .{ .instrument = 101, .rules_version = 1, .ticks = 100 } };
    reopened.members[1] = reopened.members[0];
    reopened.members[1].intent_sequence = 100;
    reopened.members[1].exchange_account = 30;
    reopened.members[1].instrument = 102;
    reopened.members[1].limit_price.instrument = 102;
    _ = try owner.apply(fixture.atGroup(47, .{ .identity = 1299, .payload = .{ .oms_intent_group = reopened } }));
    try std.testing.expectEqual(@import("../../../trading/trading_shard_event.zig").RejectReason.instrument_occupied, owner.shard.last_reject_reason);
    try std.testing.expectEqual(@as(u16, 2), owner.shard.oms.order_count);
    if (scenario == .domain_history) try exerciseDomainHistory(owner);
    if (scenario == .capacity_load) {
        for ([_]u128{ 20, 30 }) |account| {
            const state = owner.shard.accountState(account).?;
            try std.testing.expectEqual(@as(u64, 16), state.open_economic_fact_count);
            try std.testing.expectEqual(@as(u8, 16), state.economic_projection.seen_count);
        }
        var reduction: trading.oms.IntentGroup = .{ .first_intent_sequence = 5901, .count = 2 };
        for ([_]u128{ 20, 30 }, [_]u128{ 101, 102 }, 0..) |account, instrument, index| reduction.members[index] = .{
            .intent_sequence = 5901 + index,
            .strategy_instance = 9,
            .exchange_account = account,
            .instrument = instrument,
            .operation = .place,
            .side = .sell,
            .portfolio_reduce_only = true,
            .quantity = 1,
            .limit_price = .{ .instrument = instrument, .rules_version = 1, .ticks = 100 },
        };
        _ = try owner.apply(fixture.atGroup(47, .{ .identity = 6900, .payload = .{ .oms_intent_group = reduction } }));
        try std.testing.expectEqual(@import("../../../trading/trading_shard_event.zig").RejectReason.admission_capacity_exhausted, owner.shard.last_reject_reason);
        try std.testing.expectEqual(@as(u16, 2), owner.shard.oms.order_count);
        try std.testing.expectEqual(@as(u16, 2), owner.shard.oms.command_history_count);
        try owner.checkpoint();
        var rejected: usize = 0;
        while (rejected < 128) : (rejected += 1) {
            var group: trading.oms.IntentGroup = .{ .first_intent_sequence = 6001 + 2 * rejected, .count = 2 };
            for ([_]u128{ 20, 30 }, [_]u128{ 103, 104 }, 0..) |account, instrument, index| group.members[index] = .{
                .intent_sequence = group.first_intent_sequence + index,
                .strategy_instance = 9,
                .exchange_account = account,
                .instrument = instrument,
                .operation = .place,
                .quantity = 10000,
                .limit_price = .{ .instrument = instrument, .rules_version = 1, .ticks = 100 },
            };
            const before = owner.shard.canonicalStateDigest();
            _ = owner.apply(fixture.atGroup(47, .{ .identity = 7000 + rejected, .payload = .{ .oms_intent_group = group } })) catch |err| {
                try std.testing.expectEqual(error.AdmissionCapacity, err);
                try std.testing.expectEqualSlices(u8, &before, &owner.shard.canonicalStateDigest());
                break;
            };
        }
        try std.testing.expect(rejected > 0 and rejected < 128);
        try owner.checkpoint();
        const persisted = try owner.store.recover(owner.io, owner.stream);
        std.debug.print("05a operational-frontier snapshot_bytes={d} rejected_groups={d} orders={d} commands={d} pinned={d}\n", .{
            persisted.snapshot.len, rejected, owner.shard.oms.order_count, owner.shard.oms.command_history_count, owner.shard.trace.pinned_len,
        });
    }
    if (scenario == .safety_reduce) try exerciseReductions(owner);
}

fn exerciseReductions(owner: *demo.Owner) !void {
    var group: trading.oms.IntentGroup = .{ .first_intent_sequence = 1001, .count = 2 };
    for ([_]u128{ 20, 30 }, [_]u128{ 101, 102 }, 0..) |account, instrument, index| group.members[index] = .{
        .intent_sequence = 1001 + index,
        .strategy_instance = 9,
        .exchange_account = account,
        .operation = .place,
        .instrument = instrument,
        .side = .sell,
        .portfolio_reduce_only = true,
        .quantity = 6000,
        .limit_price = .{ .instrument = instrument, .rules_version = 1, .ticks = 100 },
    };
    _ = try owner.apply(fixture.atGroup(48, .{ .identity = 5000, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(u16, 4), owner.shard.oms.order_count);
    try std.testing.expectEqual(@as(u8, 1), owner.shard.cycles.count);
    group.first_intent_sequence = 1003;
    group.members[0].intent_sequence = 1003;
    group.members[1].intent_sequence = 1004;
    group.members[0].quantity = 5000;
    group.members[1].quantity = 4000;
    _ = try owner.apply(fixture.atGroup(48, .{ .identity = 5001, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@import("../../../trading/trading_shard_event.zig").RejectReason.portfolio_reduce_only_violation, owner.shard.last_reject_reason);
    try std.testing.expectEqual(@as(u16, 4), owner.shard.oms.order_count);
    group.first_intent_sequence = 1005;
    group.members[0].intent_sequence = 1005;
    group.members[1].intent_sequence = 1006;
    group.members[0].quantity = 4000;
    _ = try owner.apply(fixture.atGroup(48, .{ .identity = 5002, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(u16, 6), owner.shard.oms.order_count);
    try std.testing.expectEqual(@as(u8, 1), owner.shard.cycles.count);
}

fn verifyScopeRejections(shard: *trading.TradingShard) !void {
    const before = shard.canonicalStateDigest();
    const wrong_venue: trading.CorePayload = .{ .instrument_rules_activated = .{ .version = 1, .instrument_identity = 101, .quantity_denominator = 10000, .reservation_model = .leveraged, .product = .isolated_linear_usdt, .venue = 21 } };
    try std.testing.expectError(error.CanonicalScopeMismatch, shard.apply(fixture.atGroup(45, .{ .identity = 2000, .account_scope = 20, .payload = wrong_venue })));
    try std.testing.expectError(error.CanonicalScopeMismatch, shard.apply(fixture.atGroup(45, .{ .identity = 2001, .account_scope = 30, .payload = wrong_venue })));
    try std.testing.expectError(error.CanonicalScopeMismatch, shard.apply(fixture.atGroup(45, .{ .identity = 2002, .payload = .{ .mark_price = .{ .instrument = 101, .price_atoms = 100 } } })));
    try std.testing.expectError(error.InvalidVirtualPortfolio, shard.apply(fixture.atGroup(45, .{ .identity = 2003, .account_scope = 20, .payload = .{ .virtual_portfolio_activated = .{ .portfolio_identity = 11 } } })));
    var capability = shard.registryInstrument(101).?.capability.?;
    capability.environment = .demo;
    try std.testing.expectError(error.CanonicalScopeMismatch, shard.apply(fixture.atGroup(45, .{ .identity = 2004, .account_scope = 20, .payload = .{ .capability_profile_activation = capability } })));
    try std.testing.expectEqualSlices(u8, &before, &shard.canonicalStateDigest());
}

fn exerciseDomainHistory(owner: *demo.Owner) !void {
    const gateway_module = @import("../../../execution/execution_gateway.zig");
    const allocator = std.testing.allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const gateway = try allocator.create(gateway_module.Gateway);
    defer allocator.destroy(gateway);
    gateway.init();
    try gateway.bootstrapDurableDispatch(memory.interface(), undefined, .{ .domain = .control, .id = 92 });
    const pinned = owner.shard.canonicalStateDigest();
    for ([_]u64{ 1, 2 }) |order_id| try std.testing.expectError(error.OrderArchivePinned, owner.archiveTerminalOrder(order_id, gateway));
    try std.testing.expectError(error.FillArchivePinned, owner.archiveFillHistory(1, gateway));
    try std.testing.expectEqualSlices(u8, &pinned, &owner.shard.canonicalStateDigest());
    for ([_]u128{ 20, 30 }) |account| {
        const funding = fixture.atGroup(45, .{ .identity = 2001, .account_scope = account, .payload = .{ .funding_settlement = .{ .settlement_id = 1, .amount_atoms = 5 } } });
        _ = try owner.apply(funding);
        _ = try owner.archiveFundingHistoryForAccount(account, 1, gateway);
        const before = owner.shard.accountState(account).?.economic_projection.digest();
        _ = try owner.apply(funding);
        try std.testing.expectEqualSlices(u8, &before, &owner.shard.accountState(account).?.economic_projection.digest());
        try std.testing.expectEqual(@as(u8, 0), owner.shard.accountState(account).?.economic_projection.applied_funding_count);
        try reconcileDomainAccount(owner, account, gateway);
        try owner.checkpoint();
    }
    try std.testing.expectEqual(@as(i128, 405), owner.shard.accountState(20).?.economic_projection.portfolio.usdt_balance_atoms);
    try std.testing.expectEqual(@as(i128, 605), owner.shard.accountState(30).?.economic_projection.portfolio.usdt_balance_atoms);
    const root = owner.shard.business_history_root.?;
    try std.testing.expectEqual(@as(std.meta.Tag(history.OriginScope), .decision_domain), std.meta.activeTag(root.origin.scope));
    _ = try owner.archiveControlHistory(gateway);
    try std.testing.expect(owner.shard.business_history_root.?.generation > root.generation);
}

fn reconcileDomainAccount(owner: *demo.Owner, account: u128, gateway: *@import("../../../execution/execution_gateway.zig").Gateway) !void {
    const state = owner.shard.accountState(account).?;
    var evidence: trading.canonical.AccountEconomicEvidence = .{
        .exchange_account = account,
        .scope = .spot_and_isolated_linear_usdt,
        .from_utc_ns = state.economic_baseline_utc_ns,
        .through_utc_ns = 1,
        .source = .{ .stream = 7, .sequence = 10, .digest = history.hash("complete account after") },
        .before_source = .{ .stream = 7, .sequence = 8, .digest = history.hash("complete account before") },
        .balance_count = state.economic_baseline_balance_count,
        .before_balance_count = state.economic_baseline_balance_count,
        .before_balances = state.economic_baseline_balances,
        .covered_economic_fact_count = @intCast(state.open_economic_fact_count),
        .query_count = 1,
        .bills_complete = true,
        .bill_chain_digest = history.hash("all bills in exact interval"),
    };
    for (state.economic_baseline_balances[0..state.economic_baseline_balance_count], 0..) |balance, index| {
        evidence.balances[index] = .{ .asset = balance.asset, .atoms = if (balance.asset == 1) state.economic_projection.exchange.usdt_balance_atoms else 0 };
        evidence.asset_versions[index] = 1;
    }
    for (state.open_economic_facts[0..@intCast(state.open_economic_fact_count)], 0..) |fact, index|
        evidence.facts[index] = .{ .identity = fact.identity, .kind = fact.kind, .digest = fact.digest, .fee_confirmed = true };
    evidence.query_sources[0] = .{ .stream = 7, .sequence = 9, .digest = history.hash("complete account bills") };
    var window = fixture.canonicalAt(60, 10, .{ .account_reconciliation_result = .{ .identity = 10000, .complete = true, .account_economics = evidence } });
    window.venue.envelope.identity.stream = 7;
    window.venue.envelope.source_stream = 7;
    window.venue.envelope.exchange_account = account;
    window.venue.envelope.venue = if (account == 20) 1 else 21;
    window.venue.envelope.raw_evidence = evidence.source;
    window.venue.event.account_reconciliation_result.account_economics.?.through_utc_ns = window.venue.envelope.times.source_utc_ns.?;
    _ = try owner.apply(window);
    const after = owner.shard.accountState(account).?;
    try std.testing.expectEqual(@as(u64, 0), after.economic_fault_count);
    try std.testing.expect(after.pending_reconciliation_window != null);
    try std.testing.expect(!owner.shard.history_conflict_latched);
    try std.testing.expectEqual(@as(u64, 0), after.open_economic_unknown_time_count);
    _ = try owner.archiveReconciliationWindowHistoryForAccount(account, 10000, gateway);
    try std.testing.expectEqual(@as(u64, 0), owner.shard.accountState(account).?.open_economic_fact_count);
}

fn failNthAppend(context: *anyopaque, io: std.Io, request: durable.Append) anyerror!void {
    if (fault_remaining == 1) return error.InjectedEio;
    fault_remaining -= 1;
    const memory: *durable.MemoryAdapter = @ptrCast(@alignCast(context));
    try memory.interface().append(io, request);
}
fn failNthCommit(context: *anyopaque, io: std.Io, stream: durable.StreamIdentity, barrier: u64) anyerror!void {
    if (fault_remaining == 1) return error.InjectedEio;
    fault_remaining -= 1;
    const memory: *durable.MemoryAdapter = @ptrCast(@alignCast(context));
    try memory.interface().commit(io, stream, barrier);
}
fn exerciseFailedGroup(owner: *demo.Owner, input: trading.CanonicalEvent, at_commit: bool) !void {
    const store = owner.store;
    var failing = store.vtable.*;
    if (at_commit) failing.commit = failNthCommit else failing.append = failNthAppend;
    owner.store = .{ .context = store.context, .vtable = &failing };
    defer owner.store = store;
    try std.testing.expectError(error.DecisionLogUnavailable, owner.apply(input));
    try std.testing.expect(owner.closed);
    try std.testing.expectEqual(@as(u16, 0), owner.shard.oms.order_count);
    try std.testing.expectEqual(@as(u8, 0), owner.shard.cycles.count);
    const recovered = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, store, undefined, owner.stream);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    try std.testing.expectEqual(@as(u16, 0), recovered.shard.oms.command_history_count);
    try std.testing.expectEqual(@as(i128, 0), (try recovered.shard.oms.reservationsForAccount(1, 20)).atoms);
    try std.testing.expectEqual(@as(i128, 0), (try recovered.shard.oms.reservationsForAccount(1, 30)).atoms);
    const physical = try store.recover(undefined, owner.stream);
    if (physical.last_sequence > physical.committed_barrier) try std.testing.expect(recovered.closed);
}

const CountingAdapter = struct {
    sends: usize = 0,
    account: u128,
    fn adapter(self: *@This()) @import("../../../execution/venue_adapter.zig").VenueAdapter {
        return .{ .ptr = self, .vtable = &.{ .start = start, .try_send = send, .try_drain = drain, .stop = stop } };
    }
    fn start(_: *anyopaque, _: @import("../../../execution/venue_adapter.zig").VenueConfig) @import("../../../execution/venue_adapter.zig").StartError!void {}
    fn send(ptr: *anyopaque, request: trading.canonical.AdapterRequest) @import("../../../execution/venue_adapter.zig").SendError!@import("../../../execution/venue_adapter.zig").SendResult {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        std.debug.assert(request.order_command.exchange_account == self.account);
        self.sends += 1;
        return .accepted;
    }
    fn drain(_: *anyopaque) @import("../../../execution/venue_adapter.zig").DrainError!?trading.canonical.AdapterOutputBatch {
        return null;
    }
    fn stop(_: *anyopaque, _: @import("../../../execution/venue_adapter.zig").DrainDeadline) @import("../../../execution/venue_adapter.zig").StopError!void {}
};

fn exerciseDispatch(owner: *demo.Owner, first_command: u64) !void {
    const gateway_module = @import("../../../execution/execution_gateway.zig");
    const allocator = std.testing.allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const gateway = try allocator.create(gateway_module.Gateway);
    defer allocator.destroy(gateway);
    gateway.init();
    try gateway.bootstrapDurableDispatch(memory.interface(), undefined, .{ .domain = .control, .id = 92 });
    var adapters = [_]CountingAdapter{ .{ .account = 20 }, .{ .account = 30 }, .{ .account = 40 }, .{ .account = 50 } };
    const selected_accounts = owner.shard.deployment.accounts[0..owner.shard.deployment.account_count];
    for (adapters[0..selected_accounts.len], selected_accounts) |*adapter, configured| try gateway.add(.{
        .account = adapter.account,
        .adapter = adapter.adapter(),
        .venue_identity = configured.venue,
        .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 },
        .supported_products = gateway_module.productMask(.isolated_linear_usdt),
    });
    for (owner.shard.oms.command_history[0..owner.shard.oms.command_history_count]) |command| {
        var view: trading.TradingShard = undefined;
        try owner.shard.copyAccountViewInto(&view, command.authority.exchange_account);
        try gateway.observeAuthorityFromShard(&owner.shard, .{
            .account = command.authority.exchange_account,
            .effective_trading_authority = view.operational_state.effectiveTradingAuthority(),
            .reservation_identity = command.reservation_identity,
            .reservation = command.reservation,
            .primary_lease_expires_at_monotonic_ns = 100 * std.time.ns_per_s,
            .fencing_token = 1,
            .exchange_position = view.currentNetExchangePosition(command.instrument).?,
            .authority_barrier = owner.shard.authoritativeBarrier(),
        });
    }
    const now = owner.shard.oms.findCommand(first_command).?.authority.dispatch_deadline_monotonic_ns - std.time.ns_per_s;
    try std.testing.expectError(error.NotSent, gateway.sendFromShard(&owner.shard, first_command, now));
    try gateway.pinDeploymentDigest(owner.shard.deployment.header.?.expected_digest);
    try std.testing.expectError(error.ImmutableDeploymentConfiguration, gateway.pinDeploymentDigest(@splat(99)));
    for ([_]u64{ first_command, first_command + 1 }) |command_id| {
        if (owner.shard.oms.orderById(owner.shard.oms.findCommand(command_id).?.order_id).?.state == .unknown) {
            try std.testing.expectError(error.NotSent, gateway.sendFromShard(&owner.shard, command_id, now));
        } else {
            try std.testing.expectEqual(@import("../../../execution/venue_adapter.zig").SendResult.accepted, try gateway.sendFromShard(&owner.shard, command_id, now));
            try std.testing.expect(gateway.acceptedClientOrderIdFromShard(&owner.shard, command_id) != null);
        }
    }
    for (adapters[0..selected_accounts.len]) |adapter| {
        var expected: usize = 0;
        for ([_]u64{ first_command, first_command + 1 }) |command_id|
            if (owner.shard.oms.findCommand(command_id).?.authority.exchange_account == adapter.account and owner.shard.oms.orderById(owner.shard.oms.findCommand(command_id).?.order_id).?.state != .unknown) {
                expected += 1;
            };
        try std.testing.expectEqual(expected, adapter.sends);
    }
}

fn exerciseSharedBudget(owner: *demo.Owner) !void {
    const reasons = @import("../../../trading/trading_shard_event.zig").RejectReason;
    for ([_]u128{ 101, 103 }) |instrument| {
        _ = try owner.apply(fixture.atGroup(45, .{ .identity = @intCast(1300 + instrument), .account_scope = 20, .payload = .{ .margin_rules_activated = .{
            .version = 2,
            .instrument = instrument,
            .venue_initial_margin_ppm = 1_000_000,
            .internal_initial_margin_ppm = 1_000_000,
            .internal_maintenance_margin_ppm = 1,
            .fee_ppm = 0,
        } } }));
    }
    var group: trading.oms.IntentGroup = .{ .first_intent_sequence = 1, .count = 2 };
    for ([_]u128{ 101, 103 }, [_]i64{ 6000, 5000 }, 0..) |instrument, quantity, index| group.members[index] = .{
        .intent_sequence = index + 1,
        .strategy_instance = 9,
        .exchange_account = 20,
        .operation = .place,
        .instrument = instrument,
        .quantity = quantity,
        .limit_price = .{ .instrument = instrument, .rules_version = 1, .ticks = 100 },
    };
    _ = try owner.apply(fixture.atGroup(46, .{ .identity = 1500, .account_scope = 20, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(reasons.strategy_limit_exceeded, owner.shard.last_reject_reason);
    try std.testing.expectEqual(@as(u16, 0), owner.shard.oms.order_count);
    try std.testing.expectEqual(@as(u8, 0), owner.shard.cycles.count);
    group.members[1] = group.members[0];
    group.members[1].intent_sequence = 4;
    group.members[1].exchange_account = 30;
    group.members[1].instrument = 102;
    group.members[1].limit_price.instrument = 102;
    group.members[1].quantity = 1;
    group.first_intent_sequence = 3;
    group.members[0].intent_sequence = 3;
    group.members[0].quantity = 7000;
    _ = try owner.apply(fixture.atGroup(46, .{ .identity = 1501, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(i128, 70), (try owner.shard.oms.reservationsForAccount(1, 20)).atoms);
    group.first_intent_sequence = 5;
    group.members[0].intent_sequence = 5;
    group.members[1].intent_sequence = 6;
    group.members[1].instrument = 104;
    group.members[1].limit_price.instrument = 104;
    group.members[0].instrument = 103;
    group.members[0].limit_price.instrument = 103;
    group.members[0].quantity = 4000;
    _ = try owner.apply(fixture.atGroup(46, .{ .identity = 1502, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(reasons.strategy_limit_exceeded, owner.shard.last_reject_reason);
    try std.testing.expectEqual(@as(u16, 2), owner.shard.oms.order_count);
    try std.testing.expectEqual(@as(i128, 70), (try owner.shard.oms.reservationsForAccount(1, 20)).atoms);
    group.first_intent_sequence = 7;
    group.members[0].intent_sequence = 7;
    group.members[1].intent_sequence = 8;
    group.members[0].quantity = 3000;
    _ = try owner.apply(fixture.atGroup(46, .{ .identity = 1503, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(u16, 4), owner.shard.oms.order_count);
    try std.testing.expectEqual(@as(i128, 100), (try owner.shard.oms.reservationsForAccount(1, 20)).atoms);
    try std.testing.expectEqual(@as(i128, 4), (try owner.shard.oms.reservationsForAccount(1, 30)).atoms);
}

test "05a domain history distinguishes equal command identities by account and configuration" {
    const allocator = std.testing.allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const origin: history.Origin = .{ .stream = .{ .domain = .decision_log, .id = 91 }, .account = 0, .scope = .{ .decision_domain = .{ .identity = 1, .deployment = 7, .epoch = 1, .configuration_digest = @splat(1) } } };
    const records = [_]history.Record{ .{ .bytes = "account A", .payload_digest = history.hash("account A") }, .{ .bytes = "account B", .payload_digest = history.hash("account B") } };
    const entries = [_]history.Entry{ .{ .key = .{ .origin = origin, .account = 20, .identity = .{ .command = 1 } }, .record_index = 0 }, .{ .key = .{ .origin = origin, .account = 30, .identity = .{ .command = 1 } }, .record_index = 1 } };
    const receipt = try memory.interface().publishOrderHistory(undefined, .{ .origin = origin, .barrier = 1, .epoch = 1, .qualification_digest = @splat(2), .records = &records, .entries = &entries });
    for (entries, records) |entry, record| {
        const request: history.LookupRequest = .{ .pending_id = 1, .key = entry.key, .candidate_payload_digest = record.payload_digest, .original_input_digest = @splat(3), .root_digest = receipt.root.root_digest, .epoch = 1, .barrier = 1 };
        const result = try memory.interface().queryOrderHistory(undefined, request);
        try std.testing.expectEqual(history.Verdict.same, try history.verifyResult(request, &result.proof, receipt.root));
        var wrong = request;
        wrong.key.account = if (entry.key.account == 20) 30 else 20;
        try std.testing.expectError(error.InvalidHistoryProof, history.verifyResult(wrong, &result.proof, receipt.root));
        wrong = request;
        wrong.key.origin.scope.decision_domain.configuration_digest = @splat(4);
        try std.testing.expectError(error.InvalidHistoryProof, history.verifyResult(wrong, &result.proof, receipt.root));
    }
    try std.testing.expectError(error.InvalidHistoryKey, history.encodeKey(.{ .origin = origin, .identity = .{ .command = 1 } }));
    _ = try history.encodeKey(.{ .origin = origin, .identity = .{ .group = .{ .strategy = 9, .first_sequence = 1 } } });
}

test "05a complete global budgets survive public stable snapshot and replay" {
    const allocator = std.testing.allocator;
    const shard = try allocator.create(trading.TradingShard);
    defer allocator.destroy(shard);
    shard.* = .{};
    const log = try allocator.create(trading.journal.Journal);
    defer allocator.destroy(log);
    log.* = trading.journal.Journal.init();
    const rows = try configurationRows();
    for (rows, 0..) |row, index| _ = try trading.applyStable(shard, log, .{ .core = .{ .identity = index + 1, .payload = .{ .deployment_configuration = row } } });
    try std.testing.expect(shard.deployment.sealed);
    try std.testing.expectEqual(@as(?i128, 60), shard.deployment.sliceLimit(20, 1, 1));
    try std.testing.expectEqual(@as(?i128, 40), shard.deployment.sliceLimit(30, 1, 1));
    const recovered = try allocator.create(trading.TradingShard);
    defer allocator.destroy(recovered);
    const bytes = try allocator.alloc(u8, 32 * 1024 * 1024);
    defer allocator.free(bytes);
    try log.seal();
    _ = try trading.TradingShard.restoreSnapshotInto(recovered, try shard.snapshot(log, log.last_sequence, bytes));
    try std.testing.expectEqualSlices(u8, &shard.canonicalStateDigest(), &recovered.canonicalStateDigest());
}

test "05a global over-allocation and duplicate account instrument owners fail atomically" {
    const allocator = std.testing.allocator;
    const shard = try allocator.create(trading.TradingShard);
    defer allocator.destroy(shard);
    const cases = [_]anyerror{ error.GlobalBudgetOversubscribed, error.ConflictingDeploymentOwnership, error.AccountBudgetOversubscribed, error.DeploymentDigestMismatch, error.Overflow, error.ConflictingDeploymentOwnership };
    for (cases, 0..) |expected, variant| {
        shard.* = .{};
        var rows = try configurationRows();
        switch (variant) {
            0 => rows[6].account_limit.atoms = 41,
            1 => rows[8].ownership = rows[7].ownership,
            2 => rows[10].slice.atoms = 41,
            3 => rows[0].begin.expected_digest = @splat(2),
            4 => {
                rows[4].asset_limit.atoms = std.math.maxInt(i128);
                rows[5].account_limit.atoms = std.math.maxInt(i128);
                rows[6].account_limit.atoms = 1;
            },
            5 => {
                rows[0].begin.domain_count = 2;
                rows[8].ownership = .{ .account = 20, .instrument = 101, .domain = 2 };
            },
            else => unreachable,
        }
        for (rows[0 .. rows.len - 1], 0..) |row, index| _ = try shard.apply(.{ .core = .{ .identity = index + 1, .payload = .{ .deployment_configuration = row } } });
        if (variant == 5) _ = try shard.apply(.{ .core = .{ .identity = 100, .payload = .{ .deployment_configuration = .{ .domain = .{ .identity = 2, .stream = 92, .portfolio = 11 } } } } });
        const before = shard.canonicalStateDigest();
        try std.testing.expectError(expected, shard.apply(.{ .core = .{ .identity = 12, .payload = .{ .deployment_configuration = .seal } } }));
        try std.testing.expect(!shard.deployment.sealed);
        try std.testing.expectEqualSlices(u8, &before, &shard.canonicalStateDigest());
    }
}

test "05a incomplete deployment cannot publish a budget or admit legacy account configuration" {
    const shard = try std.testing.allocator.create(trading.TradingShard);
    defer std.testing.allocator.destroy(shard);
    shard.* = .{};
    _ = try shard.apply(.{ .core = .{ .identity = 1, .payload = .{ .deployment_configuration = .{ .begin = .{
        .identity = 7,
        .epoch = 1,
        .domain_count = 1,
        .account_count = 2,
        .asset_count = 1,
        .account_limit_count = 2,
        .ownership_count = 2,
        .slice_count = 2,
        .expected_digest = @splat(1),
    } } } } });
    try std.testing.expect(!shard.deployment.sealed);
    const before = shard.canonicalStateDigest();
    try std.testing.expectError(error.IncompleteDeploymentConfiguration, shard.apply(.{ .core = .{ .identity = 2, .payload = .{ .deployment_configuration = .seal } } }));
    try std.testing.expectEqualSlices(u8, &before, &shard.canonicalStateDigest());
    try std.testing.expectError(error.DeploymentConfigurationRequired, shard.apply(.{ .core = .{ .identity = 3, .payload = .{ .account_configuration = .{ .exchange_account_identity = 2 } } } }));
}

test "05a Owner requires an independently pinned complete deployment digest before commit" {
    const allocator = std.testing.allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    const rows = try configurationRows();
    const begin: trading.CanonicalEvent = .{ .core = .{ .identity = 1, .payload = .{ .deployment_configuration = rows[0] } } };
    try std.testing.expectError(error.DeploymentAnchorRequired, owner.apply(begin));
    try std.testing.expectEqual(@as(u64, 0), owner.shard.authoritativeBarrier());
    try owner.pinDeploymentDigest(rows[0].begin.expected_digest);
    for (rows, 0..) |row, index| _ = try owner.apply(.{ .core = .{ .identity = index + 1, .payload = .{ .deployment_configuration = row } } });
    try std.testing.expect(owner.shard.deployment.sealed);
    try std.testing.expectError(error.ImmutableDeploymentConfiguration, owner.pinDeploymentDigest(@splat(2)));
    try std.testing.expectError(error.InvalidDecisionDomain, owner.apply(.{ .core = .{ .identity = 13, .payload = .{ .decision_domain_bound = .{ .domain = 1, .stream = 92 } } } }));
    try owner.sealBootstrap();
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, memory.interface(), undefined, owner.stream);
    try std.testing.expect(recovered.shard.deployment.sealed);
    try std.testing.expect(recovered.deployment_anchor == null);
    try recovered.pinDeploymentDigest(rows[0].begin.expected_digest);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
}

fn failPublish(_: *anyopaque, _: std.Io, _: durable.StreamIdentity, _: u64, _: []const u8) anyerror!void {
    return error.InjectedEio;
}
fn failAppend(_: *anyopaque, _: std.Io, _: durable.Append) anyerror!void {
    return error.InjectedEio;
}
fn failCommit(_: *anyopaque, _: std.Io, _: durable.StreamIdentity, _: u64) anyerror!void {
    return error.InjectedEio;
}

test "05a uncommitted deployment seal never publishes and orphan tail remains closed" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |at_commit| {
        const memory = try allocator.create(durable.MemoryAdapter);
        defer allocator.destroy(memory);
        memory.* = .init();
        defer memory.deinit();
        const owner = try allocator.create(demo.Owner);
        defer allocator.destroy(owner);
        const store = memory.interface();
        try demo.Owner.bootstrapInto(owner, store, undefined, .{ .domain = .decision_log, .id = 91 });
        const rows = try configurationRows();
        try owner.pinDeploymentDigest(rows[0].begin.expected_digest);
        for (rows[0 .. rows.len - 1], 0..) |row, index| _ = try owner.apply(.{ .core = .{ .identity = index + 1, .payload = .{ .deployment_configuration = row } } });
        try owner.sealBootstrap();
        const before = owner.shard.canonicalStateDigest();
        var failing = store.vtable.*;
        if (at_commit) failing.commit = failCommit else failing.append = failAppend;
        owner.store = .{ .context = store.context, .vtable = &failing };
        try std.testing.expectError(error.DecisionLogUnavailable, owner.apply(.{ .core = .{ .identity = 99, .payload = .{ .deployment_configuration = .seal } } }));
        try std.testing.expect(owner.closed);
        try std.testing.expect(!owner.shard.deployment.sealed);
        try std.testing.expectEqualSlices(u8, &before, &owner.shard.canonicalStateDigest());
        const recovered = try allocator.create(demo.Owner);
        defer allocator.destroy(recovered);
        try demo.Owner.recoverInto(recovered, store, undefined, owner.stream);
        try std.testing.expectEqualSlices(u8, &before, &recovered.shard.canonicalStateDigest());
        try std.testing.expect(!recovered.shard.deployment.sealed);
        try std.testing.expectEqual(at_commit, recovered.closed);
        const physical = try store.recover(undefined, owner.stream);
        try std.testing.expectEqual(at_commit, physical.last_sequence > physical.committed_barrier);
        if (at_commit) try std.testing.expectError(error.DecisionLogUnavailable, recovered.apply(.{ .core = .{ .identity = 100, .payload = .{ .deployment_configuration = .seal } } }));
    }
}

test "05a maximum complete deployment installs across checkpoints and is immutable after recovery" {
    const allocator = std.testing.allocator;
    const configuration = try allocator.create(allocation.Configuration);
    defer allocator.destroy(configuration);
    configuration.* = .{};
    try configuration.apply(.{ .begin = .{ .identity = 77, .epoch = 1, .domain_count = 4, .account_count = 4, .asset_count = 128, .account_limit_count = 512, .ownership_count = 500, .slice_count = 2048, .expected_digest = @splat(1) } });
    for (0..4) |index| {
        try configuration.apply(.{ .domain = .{ .identity = index + 1, .stream = 91 + index, .portfolio = 10 + index } });
        try configuration.apply(.{ .account = .{ .identity = 20 + index, .venue = 1 } });
    }
    for (0..128) |index| try configuration.apply(.{ .asset_limit = .{ .asset = index + 1, .atoms = 16 } });
    for (0..4) |account| for (0..128) |asset| {
        try configuration.apply(.{ .account_limit = .{ .account = 20 + account, .asset = asset + 1, .atoms = 4 } });
        for (0..4) |domain| try configuration.apply(.{ .slice = .{ .account = 20 + account, .asset = asset + 1, .domain = domain + 1, .atoms = 1 } });
    };
    for (0..500) |index| try configuration.apply(.{ .ownership = .{ .account = 20 + index / 125, .instrument = 1000 + index, .domain = index % 4 + 1 } });
    configuration.header.?.expected_digest = configuration.contentDigest();
    try configuration.apply(.seal);
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    try owner.pinDeploymentDigest(configuration.header.?.expected_digest);
    try owner.installDeployment(configuration);
    try std.testing.expect(owner.shard.deployment.sealed);
    try std.testing.expectEqual(@as(?i128, 1), owner.shard.deployment.sliceLimit(23, 128, 4));
    const barrier = owner.shard.authoritativeBarrier();
    try owner.installDeployment(configuration);
    try std.testing.expectEqual(barrier, owner.shard.authoritativeBarrier());
    try owner.sealBootstrap();
    const persisted = try memory.interface().recover(undefined, owner.stream);
    std.debug.print("05a maximum-manifest snapshot_bytes={d} checkpoint_generation={d}\n", .{ persisted.snapshot.len, owner.shard.checkpointGeneration() });
    try std.testing.expect(persisted.snapshot.len < durable.max_snapshot_bytes);
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, memory.interface(), undefined, owner.stream);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    try recovered.pinDeploymentDigest(configuration.header.?.expected_digest);
    try recovered.installDeployment(configuration);
    try std.testing.expectEqual(owner.shard.authoritativeBarrier(), recovered.shard.authoritativeBarrier());
}
