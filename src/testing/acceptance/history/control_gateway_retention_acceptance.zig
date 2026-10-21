//! Explicit task08 root kinds retain both persisted outcomes; no transport sends.
const std = @import("std");
const acceptance = @import("order_gateway_archive_acceptance.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");
const execution = @import("../../../execution/execution_gateway.zig");
const history = @import("../../../persistence/business_history.zig");
const codec = @import("../../../persistence/snapshot_codec.zig");
const contract = @import("../../../runtime/production_contract.zig");
const durable = @import("../../../persistence/durable_store.zig");
const trading = @import("../../../trading/trading_shard.zig");

// These are persisted wire fixtures, not attempts made by a transport.
fn appendProof(store: durable.Store, stream: durable.StreamIdentity, type_id: u16, proof: execution.DispatchProof) !void {
    const previous = try store.recover(undefined, stream);
    const sequence = previous.last_sequence + 1;
    var bytes: [trading.journal.max_payload_size]u8 = undefined;
    try store.append(undefined, .{ .stream = stream, .record = .{
        .type_id = type_id,
        .schema_version = contract.journal_schema_version,
        .flags = 0,
        .sequence = sequence,
        .source_time = 0,
        .receive_time = 0,
        .monotonic_time = 0,
        .wall_time = 0,
        .time_presence = .{},
        .payload = try codec.encodeBare(&bytes, proof),
    } });
    try store.commit(undefined, stream, sequence);
}

test "08 control and forced history retain accepted and Unknown through Gateway recovery without sending" {
    const harness = try acceptance.ArchiveHarness.createBase(std.testing.allocator, 130000);
    defer harness.destroy();
    try harness.bindAdapter(harness.simulator.adapter());
    var group: trading.oms.IntentGroup = .{ .first_intent_sequence = 101, .count = 1 };
    group.members[0] = .{ .intent_sequence = 101, .operation = .place, .instrument = 3, .quantity = 1, .limit_price = fixture.omsPrice(3, 50_000_000) };
    _ = try harness.owner.apply(fixture.atGroup(20, .{ .identity = 101, .payload = .{ .oms_intent_group = group } }));
    try harness.owner.checkpoint();
    const command = harness.owner.shard.oms.command_history[0];
    const authority = command.authority;
    const proof: execution.DispatchProof = .{
        .origin = .{ .decision_stream = harness.stream.id, .account = 2, .portfolio = harness.owner.shard.portfolio_identity },
        .context = .{ .account = 2, .capability_version = authority.capability.version, .rules_version = command.limit_price.rules_version, .config_version = authority.config.version, .adapter_session = authority.adapter_session, .dispatch_deadline_monotonic_ns = authority.dispatch_deadline_monotonic_ns },
        .command = command,
        .fencing_token = @intCast(authority.primary_lease.identity),
        .authority_barrier = harness.owner.shard.authoritativeBarrier(),
        .now_monotonic_ns = 2 * std.time.ns_per_s,
    };
    const store = harness.backend.interface();
    try appendProof(store, harness.dispatch_stream, 0x4701, proof);
    try appendProof(store, harness.dispatch_stream, 0x4703, proof);
    var unknown = proof;
    unknown.command.command_id += 100;
    unknown.command.order_id += 100;
    try appendProof(store, harness.dispatch_stream, 0x4701, unknown);
    harness.gateway.init();
    try harness.gateway.add(harness.route);
    try harness.gateway.attachRecoveredDurableDispatch(store, undefined, harness.dispatch_stream);
    const accepted = harness.gateway.accepted_dispatches[0];
    const uncertain = harness.gateway.uncertain_dispatches[0];
    const origin: history.Origin = .{ .stream = harness.stream, .account = 2 };
    const records = [_]history.Record{.{ .bytes = "offline complete history qualification", .payload_digest = history.hash("offline complete history qualification") }};
    for ([_]bool{ false, true }, 0..) |forced, index| {
        const barrier: u64 = @intCast(index + 1);
        const entries = [_]history.Entry{.{ .key = .{ .origin = origin, .identity = if (forced) .{ .forced_detail = 8001 } else .{ .control_archive = barrier } }, .record_index = 0 }};
        const receipt = try store.publishOrderHistory(undefined, .{ .origin = origin, .previous_root = harness.owner.shard.business_history_root, .barrier = barrier, .epoch = 1, .qualification_digest = history.hash(if (forced) "forced qualification" else "control qualification"), .records = &records, .entries = &entries });
        // Explicit committed-source fixtures select the actual Gateway kind branch.
        harness.owner.shard.business_history_root = receipt.root;
        if (forced) {
            harness.owner.shard.last_forced_archive = .{ .forced_id = 8001, .qualification_digest = receipt.qualification_digest, .receipt = receipt, .evidence = .{
                .proof = .{ .root = receipt.root, .request = .{ .pending_id = 1, .key = entries[0].key, .candidate_payload_digest = records[0].payload_digest, .original_input_digest = @splat(0), .root_digest = receipt.root.root_digest, .epoch = 1, .barrier = barrier } },
                .source = .{ .owners = @splat(.{}), .source = .{ .identity = 1, .exchange_account = 2, .version = 1, .barrier = 1, .payload = .{ .forced_execution = .{ .owner = null, .quantity = 0, .price_ticks = 1, .fee_atoms = 0, .penalty_atoms = 0 } } }, .positions = @splat(0), .allocations = @splat(.{ .allocation = .{ .identity = 0, .forced_execution_identity = 0, .count = 0 } }), .count = 0 },
            } };
            harness.owner.shard.last_business_archive_kind = .forced;
        } else {
            harness.owner.shard.last_control_archive = .{ .qualification_digest = receipt.qualification_digest, .receipt = receipt };
            harness.owner.shard.last_business_archive_kind = .control;
        }
        try harness.gateway.acknowledgeEconomicHistory(&harness.owner.shard);
        const once = (try store.recover(undefined, harness.dispatch_stream)).last_sequence;
        try harness.gateway.acknowledgeEconomicHistory(&harness.owner.shard);
        try std.testing.expectEqual(once, (try store.recover(undefined, harness.dispatch_stream)).last_sequence);
        harness.gateway.init();
        try harness.gateway.add(harness.route);
        try harness.gateway.attachRecoveredDurableDispatch(store, undefined, harness.dispatch_stream);
        try std.testing.expectEqualDeep(receipt.root, harness.gateway.archive_bindings[0].root);
        try std.testing.expectEqual(@as(u16, 1), harness.gateway.accepted_dispatch_count);
        try std.testing.expectEqual(@as(u16, 1), harness.gateway.uncertain_dispatch_count);
        try std.testing.expectEqualDeep(accepted, harness.gateway.accepted_dispatches[0]);
        try std.testing.expectEqualDeep(uncertain, harness.gateway.uncertain_dispatches[0]);
        try std.testing.expectEqual(@as(u64, 0), harness.gateway.send_attempt_count);
        try std.testing.expectEqual(@as(u64, 0), harness.simulator.sends);
    }
}
