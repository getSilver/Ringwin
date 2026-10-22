const std = @import("std");
test {
    _ = @import("testing/acceptance/core/multi_account_authority_acceptance.zig");
    _ = @import("testing/acceptance/core/dual_ioc_dispatch_acceptance.zig");
}
const trading_shard = @import("trading/trading_shard.zig");
const trading_shard_tests = @import("testing/regression/trading_shard_tests.zig");
const recovery_cutover = @import("runtime/recovery_cutover.zig");
const account_coordinator = @import("portfolio/account_coordinator.zig");
const four_shard_acceptance = @import("testing/acceptance/core/four_shard_acceptance.zig");
const canonical_event = @import("model/canonical_event.zig");
const canonical_event_codec = @import("persistence/canonical_event_codec.zig");
const market_feed_adapter = @import("market/market_feed_adapter.zig");
const simulated_venue = @import("adapters/simulated/simulated_venue.zig");
const venue_adapter_contract = @import("testing/contracts/venue_adapter_contract.zig");
const simulated_lifecycle_projection = @import("testing/support/simulated_lifecycle_projection.zig");
const execution_gateway = @import("execution/execution_gateway.zig");
const simulated_market_feed = @import("adapters/simulated/simulated_market_feed.zig");
const market_projection = @import("market/market_projection.zig");
const account_projection = @import("portfolio/account_projection.zig");
const okx_market_feed = @import("adapters/okx/okx_market_feed.zig");
const binance_market_feed = @import("adapters/binance/binance_market_feed.zig");
const bybit_market_feed = @import("adapters/bybit/bybit_market_feed.zig");
const okx_venue_adapter = @import("adapters/okx/okx_venue_adapter.zig");
const binance_venue_adapter = @import("adapters/binance/binance_venue_adapter.zig");
const binance_private_reconciliation = @import("adapters/binance/binance_private_reconciliation.zig");
const binance_testnet_acceptance = @import("testing/acceptance/venues/binance_testnet_acceptance.zig");
const bybit_private_reconciliation = @import("adapters/bybit/bybit_private_reconciliation.zig");
const bybit_venue_adapter = @import("adapters/bybit/bybit_venue_adapter.zig");
const bybit_testnet_acceptance = @import("testing/acceptance/venues/bybit_testnet_acceptance.zig");
const multi_venue_testnet_acceptance = @import("testing/acceptance/venues/multi_venue_testnet_acceptance.zig");
const trading_shard_fixture = @import("testing/support/trading_shard_fixture.zig");
const trading_shard_benchmark = @import("benchmarks/trading_shard_benchmark.zig");
const production_contract = @import("runtime/production_contract.zig");
const production_runtime = @import("runtime/production_runtime.zig");
const telemetry_qualification = @import("runtime/telemetry_qualification.zig");
const failover = @import("runtime/failover.zig");
const durable_store = @import("persistence/durable_store.zig");
const demo_authority = @import("runtime/demo/demo_authority.zig");
const credential_store = @import("security/credential_store.zig");
const windows_verification_runtime = @import("runtime/windows_verification_runtime.zig");
const venue_fill_recovery_acceptance = @import("testing/acceptance/venues/venue_fill_recovery_acceptance.zig");
const raw_ingress = @import("persistence/raw_ingress.zig");
const windows_capacity_acceptance = @import("testing/acceptance/capacity/windows_capacity_acceptance.zig");
const windows_capacity_fault_acceptance = @import("testing/acceptance/capacity/windows_capacity_fault_acceptance.zig");
const windows_capacity_shared = @import("testing/support/windows_capacity_shared.zig");
const windows_observation_file_acceptance = @import("testing/acceptance/platform/windows_observation_file_acceptance.zig");

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
            if (std.mem.eql(u8, engine_dir, "--historical")) {
                const input_path = args.next() orelse return error.MissingHistoricalInput;
                if (args.next() != null) return error.UnknownArgument;
                return windows_verification_runtime.exportHistoricalEvidence(init, input_path);
            }
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
        if (std.mem.eql(u8, argument, "--linux-capacity-file") or std.mem.eql(u8, argument, "--linux-observation-file")) {
            if (@import("builtin").os.tag != .linux) return error.LinuxStoreRequired;
            const mode = args.next() orelse return error.MissingCapacityMode;
            const path = args.next() orelse return error.MissingStoreDirectory;
            if (args.next() != null) return error.UnknownArgument;
            if (std.mem.eql(u8, argument, "--linux-capacity-file")) return windows_capacity_acceptance.run(init, mode, path);
            return windows_observation_file_acceptance.run(init, mode, path);
        }
        if (std.mem.eql(u8, argument, "--windows-observation-file")) {
            if (@import("builtin").os.tag != .windows) return error.WindowsRequired;
            const mode = args.next() orelse return error.MissingCapacityMode;
            const path = args.next() orelse return error.MissingStoreDirectory;
            if (args.next() != null) return error.UnknownArgument;
            return windows_observation_file_acceptance.run(init, mode, path);
        }
        if (std.mem.eql(u8, argument, "--windows-capacity-file")) {
            if (@import("builtin").os.tag != .windows) return error.WindowsRequired;
            const mode = args.next() orelse return error.MissingCapacityMode;
            const path = args.next() orelse return error.MissingStoreDirectory;
            if (args.next() != null) return error.UnknownArgument;
            return windows_capacity_acceptance.run(init, mode, path);
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
    _ = @import("strategy/strategy_checkpoint_store.zig");
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
    _ = @import("testing/audit/historical_fee_audit.zig");
    _ = venue_fill_recovery_acceptance;
    _ = @import("testing/acceptance/platform/asset_precision_file_recovery_acceptance.zig");
    _ = @import("testing/acceptance/accounting/native_account_continuity_acceptance.zig");
    _ = @import("testing/acceptance/accounting/native_economic_reconciliation_acceptance.zig");
    _ = @import("testing/acceptance/accounting/native_multi_venue_accounting_acceptance.zig");
    _ = @import("testing/acceptance/accounting/simulated_native_accounting_acceptance.zig");
    _ = @import("runtime/demo/okx_live_chain.zig");
    _ = @import("testing/acceptance/capacity/core_observation_capacity_acceptance.zig");
    _ = @import("testing/acceptance/history/order_dispatch_archive_acceptance.zig");
    _ = @import("execution/order_history_batch.zig");
    _ = @import("trading/cold_business_candidate.zig");
    _ = @import("testing/acceptance/history/order_gateway_archive_acceptance.zig");
    _ = @import("testing/acceptance/core/cold_core_protocol_acceptance.zig");
    _ = @import("testing/acceptance/capacity/order_capacity_acceptance.zig");
    _ = @import("testing/acceptance/capacity/order_public_capacity_acceptance.zig");
    _ = @import("testing/acceptance/history/order_history_safety_acceptance.zig");
    _ = @import("portfolio/fill_history_batch.zig");
    _ = @import("portfolio/funding_history_batch.zig");
    _ = @import("portfolio/reconciliation_history_batch.zig");
    _ = @import("testing/acceptance/history/funding_archive_acceptance.zig");
    _ = @import("testing/acceptance/history/reconciliation_archive_acceptance.zig");
    _ = @import("testing/acceptance/history/reconciliation_archive_safety_acceptance.zig");
    _ = @import("testing/acceptance/history/fill_archive_acceptance.zig");
    _ = @import("testing/acceptance/history/control_archive_acceptance.zig");
    _ = @import("testing/acceptance/core/control_resident_order_acceptance.zig");
    _ = @import("testing/acceptance/history/control_gateway_retention_acceptance.zig");
    _ = @import("runtime/cutover_history.zig");
    _ = @import("testing/acceptance/history/coordinator_history_acceptance.zig");
    _ = @import("testing/acceptance/core/coordinator_safety_acceptance.zig");
    _ = @import("testing/acceptance/core/coordination_gateway_acceptance.zig");
    _ = @import("testing/acceptance/history/forced_archive_acceptance.zig");
    _ = @import("trading/trading_shard_event.zig");
    _ = @import("testing/acceptance/capacity/continuous_capacity_acceptance.zig");
    _ = @import("testing/acceptance/capacity/continuous_backpressure_acceptance.zig");
    _ = @import("testing/acceptance/accounting/continuous_account_acceptance.zig");
    _ = windows_capacity_acceptance;
    _ = windows_capacity_fault_acceptance;
    _ = windows_capacity_shared;
    _ = windows_observation_file_acceptance;
    _ = raw_ingress;
}
