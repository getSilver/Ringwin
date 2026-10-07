const std = @import("std");
const trading_shard = @import("trading_shard.zig");
const trading_shard_tests = @import("trading_shard_tests.zig");
const recovery_cutover = @import("recovery_cutover.zig");
const account_coordinator = @import("account_coordinator.zig");
const four_shard_acceptance = @import("four_shard_acceptance.zig");
const canonical_event = @import("canonical_event.zig");
const canonical_event_codec = @import("canonical_event_codec.zig");
const market_feed_adapter = @import("market_feed_adapter.zig");
const simulated_venue = @import("simulated_venue.zig");
const venue_adapter_contract = @import("venue_adapter_contract.zig");
const simulated_lifecycle_projection = @import("simulated_lifecycle_projection.zig");
const execution_gateway = @import("execution_gateway.zig");
const simulated_market_feed = @import("simulated_market_feed.zig");
const market_projection = @import("market_projection.zig");
const account_projection = @import("account_projection.zig");
const okx_market_feed = @import("okx_market_feed.zig");
const binance_market_feed = @import("binance_market_feed.zig");
const bybit_market_feed = @import("bybit_market_feed.zig");
const okx_venue_adapter = @import("okx_venue_adapter.zig");
const binance_venue_adapter = @import("binance_venue_adapter.zig");
const binance_private_reconciliation = @import("binance_private_reconciliation.zig");
const binance_testnet_acceptance = @import("binance_testnet_acceptance.zig");
const bybit_private_reconciliation = @import("bybit_private_reconciliation.zig");
const bybit_venue_adapter = @import("bybit_venue_adapter.zig");
const bybit_testnet_acceptance = @import("bybit_testnet_acceptance.zig");
const multi_venue_testnet_acceptance = @import("multi_venue_testnet_acceptance.zig");
const trading_shard_fixture = @import("trading_shard_fixture.zig");
const trading_shard_benchmark = @import("trading_shard_benchmark.zig");
const production_contract = @import("production_contract.zig");
const production_runtime = @import("production_runtime.zig");
const telemetry_qualification = @import("telemetry_qualification.zig");
const failover = @import("failover.zig");
const durable_store = @import("durable_store.zig");
const demo_authority = @import("demo_authority.zig");
const credential_store = @import("credential_store.zig");
const windows_verification_runtime = @import("windows_verification_runtime.zig");
const venue_fill_recovery_acceptance = @import("venue_fill_recovery_acceptance.zig");
const raw_ingress = @import("raw_ingress.zig");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    const executable = args.next() orelse return error.MissingExecutable;
    if (args.next()) |argument| {
        if (std.mem.eql(u8, argument, "--production-role")) {
            const role = try production_runtime.parseRole(args.next() orelse return error.MissingRole);
            if (!std.mem.eql(u8, args.next() orelse return error.MissingSocketFlag, "--socket")) return error.MissingSocketFlag;
            const socket = args.next() orelse return error.MissingSocket;
            if (!std.mem.eql(u8, args.next() orelse return error.MissingGenerationFlag, "--generation")) return error.MissingGenerationFlag;
            const generation = try std.fmt.parseInt(u64, args.next() orelse return error.MissingGeneration, 10);
            if (args.next() != null) return error.UnknownArgument;
            return production_runtime.runRole(init, role, socket, generation);
        }
        if (std.mem.eql(u8, argument, "--verify-role")) {
            const role = try windows_verification_runtime.parseRole(args.next() orelse return error.MissingRole);
            if (!std.mem.eql(u8, args.next() orelse return error.MissingPipeFlag, "--pipe")) return error.MissingPipeFlag;
            const pipe = args.next() orelse return error.MissingPipe;
            if (!std.mem.eql(u8, args.next() orelse return error.MissingGenerationFlag, "--generation")) return error.MissingGenerationFlag;
            const generation = try std.fmt.parseInt(u64, args.next() orelse return error.MissingGeneration, 10);
            if (!std.mem.eql(u8, args.next() orelse return error.MissingGenerationFileFlag, "--generation-file")) return error.MissingGenerationFileFlag;
            const generation_file = args.next() orelse return error.MissingGenerationFile;
            if (!std.mem.eql(u8, args.next() orelse return error.MissingControllerPidFlag, "--controller-pid")) return error.MissingControllerPidFlag;
            const controller_pid = try std.fmt.parseInt(u32, args.next() orelse return error.MissingControllerPid, 10);
            var store_dir: []const u8 = "";
            var credential_dir: []const u8 = "";
            var demo_transport = false;
            while (args.next()) |flag| {
                if (std.mem.eql(u8, flag, "--store-dir")) {
                    store_dir = args.next() orelse return error.MissingStoreDir;
                } else if (std.mem.eql(u8, flag, "--credential-dir")) {
                    credential_dir = args.next() orelse return error.MissingCredentialDir;
                } else if (std.mem.eql(u8, flag, "--demo-transport")) {
                    demo_transport = true;
                } else return error.UnknownArgument;
            }
            return windows_verification_runtime.runRole(init, role, pipe, generation, generation_file, controller_pid, store_dir, credential_dir, demo_transport);
        }
        if (std.mem.eql(u8, argument, "--production-chain-test")) {
            if (args.next() != null) return error.UnknownArgument;
            return production_runtime.runIntegration(init, executable);
        }
        if (std.mem.eql(u8, argument, "--windows-chain-test")) {
            if (args.next() != null) return error.UnknownArgument;
            return windows_verification_runtime.runIntegration(init, executable);
        }
        if (std.mem.eql(u8, argument, "--windows-demo-readonly")) {
            if (args.next() != null) return error.UnknownArgument;
            return windows_verification_runtime.runDemoReadOnly(init, executable);
        }
        if (std.mem.eql(u8, argument, "--windows-demo-live")) {
            if (args.next() != null) return error.UnknownArgument;
            return windows_verification_runtime.runDemoLive(init, executable);
        }
        if (std.mem.eql(u8, argument, "--windows-demo-evidence")) {
            const engine_dir = args.next() orelse return error.MissingStoreDir;
            const execution_dir = args.next() orelse return error.MissingStoreDir;
            if (args.next() != null) return error.UnknownArgument;
            return windows_verification_runtime.exportDemoEvidence(init, engine_dir, execution_dir);
        }
        if (std.mem.eql(u8, argument, "--qualification-smoke")) {
            const report_path = args.next() orelse "qualification-report.json";
            if (args.next() != null) return error.UnknownArgument;
            return telemetry_qualification.runSmoke(init, report_path);
        }
        if (std.mem.eql(u8, argument, "--failover-smoke")) {
            const report_path = args.next() orelse "failover-report.json";
            if (args.next() != null) return error.UnknownArgument;
            return failover.runSmoke(init, report_path);
        }
        if (std.mem.eql(u8, argument, "--durable-store-test")) {
            if (args.next() != null) return error.UnknownArgument;
            return durable_store.runLinuxAcceptance(init);
        }
        if (std.mem.eql(u8, argument, "--credential-store-test")) {
            if (args.next() != null) return error.UnknownArgument;
            return credential_store.runLinuxAcceptance(init);
        }
        if (std.mem.eql(u8, argument, "--windows-durable-store-test")) {
            if (args.next() != null) return error.UnknownArgument;
            return durable_store.runWindowsAcceptance(init);
        }
        if (std.mem.eql(u8, argument, "--windows-credential-store-test")) {
            if (args.next() != null) return error.UnknownArgument;
            return credential_store.runWindowsAcceptance(init);
        }
        if (std.mem.eql(u8, argument, "--four-shard-acceptance"))
            return runFourShardAcceptanceEntry(init);
        if (std.mem.eql(u8, argument, "--offline-fixture"))
            return trading_shard_fixture.main(init);
        if (std.mem.eql(u8, argument, "--benchmark"))
            return trading_shard_benchmark.runBenchmark(init, false, false);
        if (std.mem.eql(u8, argument, "--benchmark-raw"))
            return trading_shard_benchmark.runBenchmark(init, false, true);
        if (std.mem.eql(u8, argument, "--benchmark-four-shard"))
            return trading_shard_benchmark.runBenchmark(init, true, false);
        if (std.mem.eql(u8, argument, "--benchmark-four-shard-raw"))
            return trading_shard_benchmark.runBenchmark(init, true, true);
        return error.UnknownArgument;
    }
    return error.RoleRequired;
}

fn runFourShardAcceptanceEntry(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout.interface;
    const evidence = try four_shard_acceptance.runFourShardAcceptance();
    try out.print(
        "four_shard_acceptance: schema={d}, journal_schema={d}, state_schema={d}, shards={d}, replay=equivalent, recovery_paths=3\n",
        .{ evidence.schema_version, evidence.journal_schema_version, evidence.state_schema_version, evidence.shard_digests.len },
    );
    for (evidence.shard_digests, 0..) |digest, index| {
        const hex = std.fmt.bytesToHex(digest, .lower);
        try out.print("shard_{d}: barrier={d}, digest={s}\n", .{ index, evidence.shard_barriers[index], &hex });
    }
    const coordinator_hex = std.fmt.bytesToHex(evidence.coordinator_digest, .lower);
    const shared_hex = std.fmt.bytesToHex(evidence.shared_summary, .lower);
    try out.print("coordinator_barrier={d}, coordinator_digest={s}\n", .{ evidence.coordinator_barrier, &coordinator_hex });
    try out.print("shared_summary={s}\n", .{&shared_hex});
    try out.print(
        "side_effects: owned_command_count={d}, replay_send_capability={}\n",
        .{ evidence.owned_command_count, evidence.replay_send_capability },
    );
    try out.flush();
}

test {
    _ = trading_shard;
    _ = trading_shard_tests;
    _ = recovery_cutover;
    _ = account_coordinator;
    _ = four_shard_acceptance;
    _ = canonical_event;
    _ = canonical_event_codec;
    _ = market_feed_adapter;
    _ = simulated_venue;
    _ = venue_adapter_contract;
    _ = simulated_lifecycle_projection;
    _ = execution_gateway;
    _ = simulated_market_feed;
    _ = market_projection;
    _ = account_projection;
    _ = okx_market_feed;
    _ = binance_market_feed;
    _ = bybit_market_feed;
    _ = okx_venue_adapter;
    _ = binance_venue_adapter;
    _ = binance_private_reconciliation;
    _ = binance_testnet_acceptance;
    _ = bybit_private_reconciliation;
    _ = bybit_venue_adapter;
    _ = bybit_testnet_acceptance;
    _ = multi_venue_testnet_acceptance;
    _ = trading_shard_fixture;
    _ = production_contract;
    _ = production_runtime;
    _ = telemetry_qualification;
    _ = failover;
    _ = durable_store;
    _ = demo_authority;
    _ = credential_store;
    _ = windows_verification_runtime;
    _ = venue_fill_recovery_acceptance;
    _ = @import("asset_precision_file_recovery_acceptance.zig");
    _ = @import("native_account_continuity_acceptance.zig");
    _ = @import("native_economic_reconciliation_acceptance.zig");
    _ = @import("okx_live_chain.zig");
    _ = raw_ingress;
}
