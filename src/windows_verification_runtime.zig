//! Windows verification process chain. This is not a ProductionRole dispatcher
//! and cannot make permitsProduction() true.

const builtin = @import("builtin");
const std = @import("std");
const live_transport_enabled = if (@hasDecl(@import("root"), "windows_demo_transport_enabled"))
    @import("root").windows_demo_transport_enabled
else
    false;
const curl = if (live_transport_enabled) @import("okx_curl_transport.zig") else struct {};
const okx_auth = if (live_transport_enabled) @import("okx_rest_auth.zig") else struct {};
const canonical = @import("canonical_event.zig");
const credential_store = @import("credential_store.zig");
const demo_authority = @import("demo_authority.zig");
const durable_store = @import("durable_store.zig");
const execution_gateway = @import("execution_gateway.zig");
const failover = @import("failover.zig");
const fixture = @import("trading_shard_fixture.zig");
const host_gateway = @import("strategy_host_gateway.zig");
const ipc = @import("strategy_host_ipc.zig");
const okx_demo = @import("okx_demo_live_acceptance.zig");
const okx_live = @import("okx_live_chain.zig");
const market_feed = @import("okx_market_feed.zig");
const okx_private = @import("okx_private_reconciliation.zig");
const okx_venue = @import("okx_venue_adapter.zig");
const production_contract = @import("production_contract.zig");
const raw_ingress = @import("raw_ingress.zig");
const simulated_venue = @import("simulated_venue.zig");
const snapshot_codec = @import("snapshot_codec.zig");
const strategy_host_lifecycle = @import("strategy_host_lifecycle.zig");
const trading_shard = @import("trading_shard.zig");

pub const max_control_queue = 8;
pub const max_frame_bytes = 1;
pub const Role = production_contract.VerificationRole;
pub const Command = enum(u8) { enable_risk = 'A', export_snapshot = 'E', load_snapshot = 'L', ingest_market = 'I', produce_market = 'M', poll_market = 'm', bootstrap_private = 'B', private_ws = 'P', poll_private = 'p', ingest_private = 'V', verify_private = 'Q', refresh_private = 'r', seal_private = 's', export_fence = 'F', install_fence = 'f', quote_okx = 'q', prepare_okx = 'K', activate_okx = 'C', produce_okx_intent = 'J', cleanup_okx = 'c', inspect_okx = 'i', export_okx_snapshot = 'N', send_okx = 'O', verify_okx = 'Z', probe = 'h', drain = 'D', stop = 'S' };
pub const Status = enum(u8) { hello = 'H', owner_ready = 'o', ready = 'R', risk_enabled = 'A', snapshot_ready = 'E', snapshot_accepted = 'L', market_output = 'M', market_applied = 'I', market_ready = 'n', private_output = 'P', private_ready = 'B', private_applied = 'V', fence_ready = 'f', okx_quote = 'q', okx_prepared = 'K', okx_activated = 'C', okx_command = 'J', okx_state = 'i', okx_send_ready = 'y', okx_sent = 'O', okx_verified = 'Z', healthy = 'h', draining = 'G', stopped = 'T', forced_stop = 'F', failed = 'X' };

pub const BoundedQueue = struct {
    values: [max_control_queue]Command = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    pub fn push(self: *BoundedQueue, value: Command) !void {
        if (self.count == self.values.len) return error.Backpressure;
        self.values[self.tail] = value;
        self.tail = (self.tail + 1) % self.values.len;
        self.count += 1;
    }

    pub fn pop(self: *BoundedQueue) ?Command {
        if (self.count == 0) return null;
        const value = self.values[self.head];
        self.head = (self.head + 1) % self.values.len;
        self.count -= 1;
        return value;
    }
};

pub fn parseRole(value: []const u8) !Role {
    inline for (std.meta.fields(Role)) |field| {
        if (std.mem.eql(u8, value, field.name)) return @field(Role, field.name);
    }
    return error.UnknownRole;
}

pub fn roleName(role: Role) []const u8 {
    return @tagName(role);
}

pub fn runRole(
    init: std.process.Init,
    role: Role,
    pipe_name: []const u8,
    generation: u64,
    generation_file: []const u8,
    controller_pid: u32,
    store_dir: []const u8,
    credential_dir: []const u8,
    demo_transport: bool,
) !void {
    if (comptime builtin.os.tag != .windows) return error.WindowsVerificationRoleRequired;
    if (pipe_name.len == 0 or generation == 0 or generation_file.len == 0 or controller_pid == 0) return error.InvalidRoleConfiguration;
    const live_write = std.mem.eql(u8, init.environ_map.get("RINGWIN_DEMO_LIVE_AUTHORIZED") orelse "", "1");
    const disk_generation = try readGenerationFile(init.io, generation_file);
    if (disk_generation != generation) return error.GenerationMismatch;
    try installConsoleHandler();

    const controller = try currentUserSid(init.gpa);
    defer init.gpa.free(controller);
    var server = try listenPipe(pipe_name, controller);

    var stdout_buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout.interface.print(
        "verification_role: role={s}, generation={d}, ipc=named_pipe, venue={s}, production_qualification=false\n",
        .{ roleName(role), generation, if ((role == .engine and demo_transport) or role == .market_feed or (role == .execution_gateway and store_dir.len != 0)) "OKX" else "SimulatedVenue" },
    );
    try stdout.interface.flush();

    var client = try server.accept(controller, controller_pid);
    defer client.close();
    try writeStatus(client, .hello);

    var engine_state: ?*EngineOwners = null;
    defer if (engine_state) |owners| {
        owners.deinit(init);
        init.gpa.destroy(owners);
    };
    if (role == .engine and store_dir.len != 0 and credential_dir.len != 0) {
        engine_state = EngineOwners.start(init, store_dir, credential_dir, generation) catch |err| {
            writeStatus(client, .failed) catch {};
            try stdout.interface.print("engine_start_failed: {s}\n", .{@errorName(err)});
            try stdout.interface.flush();
            return err;
        };
    }
    var okx_owner: ?*demo_authority.Owner = null;
    defer if (okx_owner) |owner| init.gpa.destroy(owner);
    var okx_fence: ?*OkxFenceView = null;
    defer if (okx_fence) |owner| {
        owner.deinit(init);
        init.gpa.destroy(owner);
    };
    var okx_host: ?*strategy_host_lifecycle.ManagedHost = null;
    defer if (okx_host) |host| {
        host.deinit(init.io);
        init.gpa.destroy(host);
    };
    var okx_command_id: u64 = 0;
    var okx_cleanup_command_id: u64 = 0;
    if (engine_state) |state| {
        const owner = try init.gpa.create(demo_authority.Owner);
        owner.* = try demo_authority.Owner.bootstrap(state.store.interface(), init.io, .{ .domain = .decision_log, .id = 91 });
        okx_owner = owner;
    }
    var market_state: ?*MarketOwners = null;
    defer if (market_state) |owners| {
        owners.deinit(init);
        init.gpa.destroy(owners);
    };
    if (role == .market_feed and store_dir.len != 0) {
        market_state = MarketOwners.start(init, store_dir, demo_transport) catch |err| {
            std.debug.print("windows_demo_market_start_failed={s}\n", .{@errorName(err)});
            writeStatus(client, .failed) catch {};
            return err;
        };
    }
    var execution_state: ?*ExecutionOwners = null;
    defer if (execution_state) |owners| {
        owners.deinit(init);
        init.gpa.destroy(owners);
    };
    if (role == .execution_gateway and store_dir.len != 0) {
        execution_state = ExecutionOwners.start(init, store_dir, demo_transport) catch |err| {
            writeStatus(client, .failed) catch {};
            return err;
        };
    }
    var control_fence: ?*OkxFenceOwner = null;
    defer if (control_fence) |owner| {
        owner.deinit();
        init.gpa.destroy(owner);
    };
    if (role == .control_fence and store_dir.len != 0) {
        control_fence = try OkxFenceOwner.start(init, store_dir, demo_transport);
    }
    try writeStatus(client, if (role == .engine) .owner_ready else .ready);

    var draining = false;
    var risk_gate_open = false;
    while (true) {
        const command = waitForCommand(client, draining, init.io, control_fence) catch |err| {
            if (err == error.DrainDeadline) {
                try writeStatus(client, .forced_stop);
                try writeStatus(client, .stopped);
                return;
            }
            writeStatus(client, .failed) catch {};
            return err;
        } orelse {
            if (!termination_requested.load(.seq_cst)) {
                try writeStatus(client, .failed);
                return error.RoleIpcDisconnected;
            }
            risk_gate_open = false;
            draining = true;
            try writeStatus(client, .draining);
            try writeStatus(client, .forced_stop);
            try writeStatus(client, .stopped);
            return;
        };
        if (try readGenerationFile(init.io, generation_file) != generation) {
            writeStatus(client, .failed) catch {};
            return error.GenerationMismatch;
        }
        switch (command) {
            .probe => {
                if (role != .telemetry or draining) return error.InvalidRoleTransition;
                try writeStatus(client, .healthy);
            },
            .enable_risk => {
                if ((role != .engine and role != .execution_gateway) or draining or risk_gate_open)
                    return error.InvalidRoleTransition;
                risk_gate_open = true;
                if (role == .engine and !demo_transport) {
                    const owners = engine_state orelse return error.EngineOwnersMissing;
                    owners.exercise(init) catch |err| {
                        try stdout.interface.print("engine_exercise_failed: {s}\n", .{@errorName(err)});
                        try stdout.interface.flush();
                        return err;
                    };
                }
                try writeStatus(client, .risk_enabled);
                if (role == .engine and !demo_transport) try writeStatus(client, .ready);
            },
            .export_snapshot => {
                if (role != .engine or !risk_gate_open or draining) return error.InvalidRoleTransition;
                const owner = engine_state orelse return error.EngineOwnersMissing;
                var snapshot_storage: [durable_store.max_snapshot_bytes]u8 = undefined;
                const snapshot = try owner.shard_run.committedSnapshot(&snapshot_storage);
                try writeStatus(client, .snapshot_ready);
                try writeSnapshotFrame(client, generation, .{
                    .bytes = snapshot,
                    .barrier = owner.shard_run.shard.trace.len,
                    .digest = owner.shard_run.shard.canonicalStateDigest(),
                });
            },
            .load_snapshot => {
                if (role != .execution_gateway or !risk_gate_open or draining) return error.InvalidRoleTransition;
                var snapshot_storage: [durable_store.max_snapshot_bytes]u8 = undefined;
                const snapshot = readSnapshotFrame(client, generation, &snapshot_storage) catch |err| {
                    writeStatus(client, .failed) catch {};
                    return err;
                };
                const restored = trading_shard.TradingShard.restoreSnapshot(snapshot.bytes) catch |err| {
                    writeStatus(client, .failed) catch {};
                    return err;
                };
                if (restored.barrier != snapshot.barrier or
                    !std.mem.eql(u8, &restored.shard.canonicalStateDigest(), &snapshot.digest))
                {
                    writeStatus(client, .failed) catch {};
                    return error.DecisionSnapshotMismatch;
                }
                try writeStatus(client, .snapshot_accepted);
            },
            .produce_market => {
                if (role != .market_feed or draining) return error.InvalidRoleTransition;
                const owners = market_state orelse return error.MarketOwnerMissing;
                var raw: [raw_ingress.max_frame_bytes]u8 = undefined;
                const frame = readPayloadFrame(client, generation, &raw) catch |err| {
                    writeStatus(client, .failed) catch {};
                    return err;
                };
                try owners.feed.ingest(init.gpa, .{
                    .receive_time_utc_ns = 1_800_000_000_000_000_001,
                    .monotonic_time_ns = 10_000_001,
                    .wall_time_utc_ns = 1_800_000_000_000_000_002,
                }, frame);
                const batch = (try owners.feed.adapter().tryDrain()) orelse return error.MarketOutputMissing;
                try writeStatus(client, .market_output);
                try writeAll(client, &[_]u8{batch.len});
                for (batch.slice()) |event| {
                    var encoded: [4096]u8 = undefined;
                    try writePayloadFrame(client, generation, try snapshot_codec.encodeBare(&encoded, event));
                }
            },
            .poll_market => {
                if (role != .market_feed or draining) return error.InvalidRoleTransition;
                const owners = market_state orelse return error.MarketOwnerMissing;
                try owners.pollLive(init, client, generation);
                try writeStatus(client, .market_ready);
            },
            .ingest_market => {
                if (role != .engine or draining) return error.InvalidRoleTransition;
                var count: [1]u8 = undefined;
                try readExact(client, &count);
                if (count[0] == 0 or count[0] > canonical.max_events_per_adapter_batch) return error.InvalidMarketBatch;
                var batch: canonical.AdapterOutputBatch = .{};
                for (0..count[0]) |_| {
                    var encoded: [4096]u8 = undefined;
                    const frame = try readPayloadFrame(client, generation, &encoded);
                    try batch.append(try snapshot_codec.decodeBare(frame, canonical.EventRecord));
                }
                const demo_owner = okx_owner orelse return error.EngineOwnersMissing;
                demo_owner.applyAdapterBatch(batch) catch |err| {
                    try stdout.interface.print("okx_market_apply_failed: {s}\n", .{@errorName(err)});
                    try stdout.interface.flush();
                    writeStatus(client, .failed) catch {};
                    return err;
                };
                try writeStatus(client, .market_applied);
            },
            .bootstrap_private => {
                if (role != .execution_gateway or draining) return error.InvalidRoleTransition;
                const owners = execution_state orelse return error.ExecutionOwnerMissing;
                owners.bootstrapPrivate(init, client, generation) catch |err| {
                    std.debug.print("windows_demo_private_bootstrap_failed={s}\n", .{@errorName(err)});
                    writeStatus(client, .failed) catch {};
                    return err;
                };
                try writeStatus(client, .private_ready);
            },
            .private_ws => {
                if (role != .execution_gateway or draining) return error.InvalidRoleTransition;
                const owners = execution_state orelse return error.ExecutionOwnerMissing;
                if (owners.live_mode) return error.FixtureIngressDisabled;
                var raw: [raw_ingress.max_frame_bytes]u8 = undefined;
                const frame = try readPayloadFrame(client, generation, &raw);
                try owners.ingestPrivate(client, generation, frame);
                try writeStatus(client, .private_ready);
            },
            .poll_private => {
                if (role != .execution_gateway or draining) return error.InvalidRoleTransition;
                const owners = execution_state orelse return error.ExecutionOwnerMissing;
                if (!owners.live_mode) return error.DemoTransportRequired;
                if (comptime live_transport_enabled) {
                    const owner = owners.curl_transport orelse return error.DemoTransportUnavailable;
                    var buffer: [raw_ingress.max_frame_bytes]u8 = undefined;
                    if (std.mem.eql(u8, init.environ_map.get("RINGWIN_DEMO_FORCE_WS_RECONNECT") orelse "", "1")) owner.wsDisconnect();
                    const message = okx_demo.receiveWithKeepalive(owner, &buffer) catch |err| switch (err) {
                        error.WebSocketTransport, error.WebSocketClosed, error.NotConnected => blk: {
                            std.debug.print("windows_demo_private: ws=reconnecting\n", .{});
                            try owners.reconnectLivePrivate(init, client, generation);
                            break :blk null;
                        },
                        else => return err,
                    };
                    if (message) |value|
                        try owners.ingestLivePrivate(init.io, client, generation, value);
                    try writeStatus(client, .private_ready);
                } else return error.DemoTransportBuildRequired;
            },
            .refresh_private => {
                if (role != .execution_gateway or draining) return error.InvalidRoleTransition;
                const owners = execution_state orelse return error.ExecutionOwnerMissing;
                if (!owners.live_mode) return error.DemoTransportRequired;
                try owners.refreshLivePrivate(init, client, generation);
                try writeStatus(client, .private_ready);
            },
            .ingest_private => {
                if (role != .engine or draining) return error.InvalidRoleTransition;
                const owner = okx_owner orelse return error.EngineOwnersMissing;
                var count: [1]u8 = undefined;
                try readExact(client, &count);
                if (count[0] == 0 or count[0] > canonical.max_events_per_adapter_batch) return error.InvalidPrivateBatch;
                var batch: canonical.AdapterOutputBatch = .{};
                for (0..count[0]) |_| {
                    var encoded: [4096]u8 = undefined;
                    const frame = try readPayloadFrame(client, generation, &encoded);
                    try batch.append(try snapshot_codec.decodeBare(frame, canonical.EventRecord));
                }
                owner.applyAdapterBatch(batch) catch |err| {
                    std.debug.print("windows_demo_private_apply_failed={s}\n", .{@errorName(err)});
                    writeStatus(client, .failed) catch {};
                    return err;
                };
                try writeStatus(client, .private_applied);
            },
            .verify_private => {
                if (role != .engine or draining) return error.InvalidRoleTransition;
                const owner = okx_owner orelse return error.EngineOwnersMissing;
                if (!owner.shard.canonical_account.valid) return error.PrivateAccountNotReady;
                if (demo_transport) std.debug.print("windows_demo_account: observations={d}\n", .{owner.shard.canonical_account.seen_count});
                try writeStatus(client, .private_ready);
            },
            .seal_private => {
                if (role != .engine or draining) return error.InvalidRoleTransition;
                if (live_write) return error.InvalidRoleTransition;
                const owner = okx_owner orelse return error.EngineOwnersMissing;
                if (!owner.shard.canonical_account.valid) return error.PrivateAccountNotReady;
                try owner.sealBootstrap();
                try writeStatus(client, .private_ready);
            },
            .export_fence => {
                if (role != .control_fence or draining) return error.InvalidRoleTransition;
                const fence = control_fence orelse return error.FencingAuthorityUnavailable;
                if (fence.live_mode) try fence.authority.renew(&fence.lease, try awakeNs(init.io));
                try writeStatus(client, .fence_ready);
                try writeLease(client, fence.lease);
            },
            .install_fence => {
                if ((role != .engine and role != .execution_gateway) or draining) return error.InvalidRoleTransition;
                var path_storage: [256]u8 = undefined;
                const path = try readPayloadFrame(client, generation, &path_storage);
                const lease = try readLease(client);
                if (role == .engine) {
                    if (okx_fence) |view|
                        try view.refresh(init.io, path, lease)
                    else
                        okx_fence = try OkxFenceView.start(init, path, lease, demo_transport);
                } else {
                    const owners = execution_state orelse return error.ExecutionOwnerMissing;
                    try owners.installFence(init, path, lease);
                }
                try writeStatus(client, .fence_ready);
            },
            .quote_okx => {
                if (role != .execution_gateway or !demo_transport or draining) return error.InvalidRoleTransition;
                const owners = execution_state orelse return error.ExecutionOwnerMissing;
                var quote_input: [9]u8 = undefined;
                try readExact(client, &quote_input);
                const side: host_gateway.Side = switch (quote_input[0]) {
                    1 => .buy,
                    2 => .sell,
                    else => return error.InvalidDemoSide,
                };
                const quantity = std.mem.readInt(i64, quote_input[1..9], .little);
                if (quantity < 1_000 or quantity > 20_000) return error.InvalidDemoQuantity;
                if (comptime live_transport_enabled) {
                    const transport = owners.curl_transport orelse return error.DemoTransportUnavailable;
                    const price = try okx_demo.windowsProtectedPrice(init, transport, side, quantity);
                    var encoded: [8]u8 = undefined;
                    std.mem.writeInt(i64, &encoded, price, .little);
                    try writeStatus(client, .okx_quote);
                    try writeAll(client, &encoded);
                } else return error.DemoTransportBuildRequired;
            },
            .prepare_okx => {
                if (role != .engine or draining or okx_fence == null) return error.InvalidRoleTransition;
                const owner = okx_owner orelse return error.EngineOwnersMissing;
                if (!owner.shard.canonical_account.valid) return error.PrivateAccountNotReady;
                var policy = try demo_authority.Policy.parse(init.gpa, offline_okx_policy);
                defer policy.deinit();
                const lease_now = if (demo_transport) try awakeNs(init.io) else 1;
                var price_bytes: [8]u8 = undefined;
                if (live_write) try readExact(client, &price_bytes);
                const mark_price = if (live_write) std.mem.readInt(i64, &price_bytes, .little) else 50_000_000;
                policy.value.initializePendingHost(owner, mark_price, &okx_fence.?.guard, lease_now, 1) catch |err| {
                    std.debug.print("windows_demo_prepare_failed={s}\n", .{@errorName(err)});
                    writeStatus(client, .failed) catch {};
                    return err;
                };
                try writeStatus(client, .okx_prepared);
            },
            .activate_okx => {
                if (role != .engine or !risk_gate_open or draining or okx_host != null or okx_fence == null)
                    return error.InvalidRoleTransition;
                std.debug.print("windows_demo_host: stage=begin\n", .{});
                const owner = okx_owner orelse return error.EngineOwnersMissing;
                const python_abi = try strategy_host_lifecycle.discoverPythonAbi(init, "python");
                std.debug.print("windows_demo_host: stage=abi\n", .{});
                var plan = strategy_host_lifecycle.developmentPlan(0, generation, python_abi);
                plan.session.fencing = okx_fence.?.lease.token;
                const host = try init.gpa.create(strategy_host_lifecycle.ManagedHost);
                errdefer if (okx_host == null) init.gpa.destroy(host);
                var price_bytes: [8]u8 = undefined;
                if (live_write) try readExact(client, &price_bytes);
                const price = if (live_write) std.mem.readInt(i64, &price_bytes, .little) else 50_100_100_000;
                if (price <= 0) return error.InvalidDemoPrice;
                std.debug.print("windows_demo_host: stage=price\n", .{});
                var price_text: [24]u8 = undefined;
                const price_arg = try std.fmt.bufPrint(&price_text, "{d}", .{price});
                host.* = try strategy_host_lifecycle.ManagedHost.start(init, "python", "python/strategy_host.py", plan, "trade", &.{
                    "--strategy-identity",   "40",                                                     "--activation-identity", "50",                                "--config-version",   "1",
                    "--intent-sequence",     "1",                                                      "--quantity",            if (live_write) "5000" else "20000", "--limit-price",      price_arg,
                    "--instrument-identity", std.fmt.comptimePrint("{d}", .{okx_venue.btc_usdt_spot}), "--time-in-force",       "ioc",                               "--price-from-input",
                });
                okx_host = host;
                std.debug.print("windows_demo_host: stage=started\n", .{});
                try host.sendPlan(init.io);
                std.debug.print("windows_demo_host: stage=plan_sent\n", .{});
                if (try host.receive(init.io, 1) != .accepted or try host.receive(init.io, 2) != .accepted or
                    host.supervisor.state != .ready_for_recovery) return error.HostHandshakeFailed;
                std.debug.print("windows_demo_host: stage=handshake\n", .{});
                var policy = try demo_authority.Policy.parse(init.gpa, offline_okx_policy);
                defer policy.deinit();
                const barrier = owner.shard.trace.len;
                const digest = owner.shard.canonicalStateDigest();
                try policy.value.activateHost(owner, plan.session, barrier, digest);
                std.debug.print("windows_demo_host: stage=owner_activated\n", .{});
                try host.activate(init.io, .{ .strategy_identity = 40, .activation_identity = 50, .barrier = barrier, .state_digest = digest });
                std.debug.print("windows_demo_host: stage=host_activated\n", .{});
                try writeStatus(client, .okx_activated);
                try writeStatus(client, .ready);
            },
            .produce_okx_intent => {
                if (role != .engine or !risk_gate_open or draining or okx_command_id != 0) return error.InvalidRoleTransition;
                const owner = okx_owner orelse return error.EngineOwnersMissing;
                const host = okx_host orelse return error.HostNotActivated;
                const plan = host.supervisor.plan;
                const host_config: host_gateway.Config = .{
                    .schema_registry = plan.compatibility.schema_registry,
                    .decision_domain = plan.decision_domain,
                    .session = plan.session,
                    .authorization = .{ .strategy_identity = 40, .config_version = 1, .activation_identity = 50, .activation_barrier = owner.shard.host_activation_barrier },
                };
                const subscriptions = [_]host_gateway.Subscription{host_gateway.Subscription.of(40, &.{.mark_price})};
                var strategy_gateway = try host_gateway.Gateway.init(host_config, &subscriptions);
                const cursor = owner.shard.trace.len;
                const published_ns: i64 = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
                var price_bytes: [8]u8 = undefined;
                if (live_write) try readExact(client, &price_bytes) else std.mem.writeInt(i64, &price_bytes, 50_100_100_000, .little);
                const events = [_]host_gateway.EventEnvelope{.{
                    .event_type = .mark_price,
                    .shard_sequence = cursor,
                    .source_time_ns = published_ns,
                    .receive_time_ns = published_ns,
                    .monotonic_time_ns = published_ns,
                    .wall_time_utc_ns = published_ns,
                    .payload = &price_bytes,
                }};
                var input_storage: [512]u8 = undefined;
                const input = try strategy_gateway.encodeBatch(&input_storage, 1, cursor, cursor, published_ns, &events);
                try host.sendInput(init.io, input, published_ns);
                try strategy_gateway.recordPublished(1, cursor, published_ns);
                try strategy_gateway.activate(&owner.shard, &owner.decision_journal);
                var output_storage: [512]u8 = undefined;
                const host_output = try host.receiveOutput(init.io, @intCast(std.Io.Clock.awake.now(init.io).nanoseconds), &output_storage);
                const decision = strategy_gateway.ingest(host_output, @intCast(std.Io.Clock.awake.now(init.io).nanoseconds));
                const intent = switch (decision) {
                    .accepted => |value| value,
                    .rejected => |rejection| {
                        std.debug.print("okx_host_intent_reject={s}\n", .{@tagName(rejection.reason)});
                        return error.HostIntentRejected;
                    },
                };
                const proved = (try owner.apply(.{ .core = .{
                    .identity = cursor + 1,
                    .monotonic_time = if (live_write) try awakeNs(init.io) else 2,
                    .time_presence = .{ .monotonic = true },
                    .payload = .{ .external_order_intent = intent },
                } })) orelse return error.MissingDemoCommand;
                okx_command_id = proved.command_id;
                try writeStatus(client, .okx_command);
                var encoded: [8]u8 = undefined;
                std.mem.writeInt(u64, &encoded, okx_command_id, .little);
                try writeAll(client, &encoded);
            },
            .cleanup_okx => {
                if (role != .engine or !demo_transport or !risk_gate_open or draining or okx_host == null or okx_cleanup_command_id != 0)
                    return error.InvalidRoleTransition;
                const owner = okx_owner orelse return error.EngineOwnersMissing;
                const position = owner.shard.currentNetExchangePosition(okx_venue.btc_usdt_spot) orelse return error.MissingDemoPosition;
                const quantity = std.math.cast(i64, position.lots) orelse return error.InvalidDemoPosition;
                if (quantity < 1_000 or quantity > 20_000 or !owner.shard.oms.openOrdersClosed()) return error.CleanupNotReady;
                var price_bytes: [8]u8 = undefined;
                try readExact(client, &price_bytes);
                const price = std.mem.readInt(i64, &price_bytes, .little);
                if (price <= 0) return error.InvalidDemoPrice;
                const host = okx_host.?;
                const cursor = owner.shard.trace.len;
                const now = try awakeNs(init.io);
                const config: host_gateway.Config = .{
                    .schema_registry = host.supervisor.plan.compatibility.schema_registry,
                    .decision_domain = host.supervisor.plan.decision_domain,
                    .session = host.supervisor.plan.session,
                    .authorization = .{ .strategy_identity = 40, .config_version = 1, .activation_identity = 50, .activation_barrier = owner.shard.host_activation_barrier },
                };
                const subscriptions = [_]host_gateway.Subscription{host_gateway.Subscription.of(40, &.{.mark_price})};
                var gateway = try host_gateway.Gateway.init(config, &subscriptions);
                const now_i64 = std.math.cast(i64, now) orelse return error.InvalidMonotonicClock;
                try gateway.recordPublished(1, cursor, now_i64);
                try gateway.activate(&owner.shard, &owner.decision_journal);
                var output: [256]u8 = undefined;
                const frame = try host_gateway.encodeOutputOrderFrame(&output, config, 1, cursor, cursor + 1, .{
                    .instrument_identity = okx_venue.btc_usdt_spot,
                    .side = .sell,
                    .time_in_force = .immediate_or_cancel,
                    .portfolio_reduce_only = true,
                    .quantity = quantity,
                    .limit_price_micros = price,
                });
                const intent = switch (gateway.ingest(frame, now_i64)) {
                    .accepted => |value| value,
                    .rejected => return error.DemoCleanupIntentRejected,
                };
                const proved = (try owner.apply(.{ .core = .{
                    .identity = cursor + 1,
                    .monotonic_time = now,
                    .time_presence = .{ .monotonic = true },
                    .payload = .{ .external_order_intent = intent },
                } })) orelse return error.DemoCleanupRiskRejected;
                okx_cleanup_command_id = proved.command_id;
                okx_command_id = proved.command_id;
                var encoded: [8]u8 = undefined;
                std.mem.writeInt(u64, &encoded, proved.command_id, .little);
                try writeStatus(client, .okx_command);
                try writeAll(client, &encoded);
            },
            .export_okx_snapshot => {
                if (role != .engine or okx_command_id == 0 or draining) return error.InvalidRoleTransition;
                const owner = okx_owner orelse return error.EngineOwnersMissing;
                var storage: [durable_store.max_snapshot_bytes]u8 = undefined;
                const bytes = try owner.committedSnapshot(&storage);
                try writeStatus(client, .snapshot_ready);
                try writeSnapshotFrame(client, generation, .{ .bytes = bytes, .barrier = owner.shard.trace.len, .digest = owner.shard.canonicalStateDigest() });
            },
            .send_okx => {
                if (role != .execution_gateway or !risk_gate_open or draining) return error.InvalidRoleTransition;
                const owners = execution_state orelse return error.ExecutionOwnerMissing;
                var command_bytes: [8]u8 = undefined;
                try readExact(client, &command_bytes);
                const command_id = std.mem.readInt(u64, &command_bytes, .little);
                var storage: [durable_store.max_snapshot_bytes]u8 = undefined;
                const snapshot = try readSnapshotFrame(client, generation, &storage);
                if (owners.live_mode) {
                    if (!live_write) return error.DemoLiveAuthorizationMissing;
                    const deadline_text = init.environ_map.get("RINGWIN_DEMO_LIVE_DEADLINE_UNIX") orelse return error.DemoLiveDeadlineMissing;
                    const deadline = try std.fmt.parseInt(u64, deadline_text, 10);
                    const now_seconds = (try okx_demo.clock(init.io)).times.wall_time_utc_ns / std.time.ns_per_s;
                    if (now_seconds >= deadline) return error.DemoWriteDeadlineExpired;
                    const restored = try trading_shard.TradingShard.restoreSnapshot(snapshot.bytes);
                    var order_command: ?trading_shard.OrderCommand = null;
                    for (restored.shard.oms.command_history[0..restored.shard.oms.command_history_count]) |candidate| {
                        if (candidate.command_id == command_id) order_command = candidate;
                    }
                    const selected = order_command orelse return error.MissingDemoCommand;
                    if (comptime live_transport_enabled) {
                        const transport = owners.curl_transport orelse return error.DemoTransportUnavailable;
                        try okx_demo.windowsPriceStillExecutable(init, transport, if (selected.side == .buy) .buy else .sell, selected.quantity, @intCast(selected.limit_price.ticks * 100_000));
                    } else return error.DemoTransportBuildRequired;
                    try writeStatus(client, .okx_send_ready);
                    var path_storage: [256]u8 = undefined;
                    const path = try readPayloadFrame(client, generation, &path_storage);
                    const lease = try readLease(client);
                    try owners.installFence(init, path, lease);
                    if ((try okx_demo.clock(init.io)).times.wall_time_utc_ns / std.time.ns_per_s >= deadline)
                        return error.DemoWriteDeadlineExpired;
                }
                const result = demo_authority.sendFromCommittedSnapshot(snapshot.bytes, snapshot.barrier, snapshot.digest, &owners.gateway, &owners.guard, command_id, if (owners.live_mode) try awakeNs(init.io) else 2) catch |err| {
                    std.debug.print("windows_demo_send_failed={s}\n", .{@errorName(err)});
                    try writeStatus(client, .failed);
                    return err;
                };
                if (result != .accepted) return error.GatewaySendFailed;
                var batches: [execution_gateway.max_routes]canonical.AdapterOutputBatch = undefined;
                const count = try owners.gateway.drainFair(&batches);
                if (count != 1) return error.MissingDispatchResult;
                var submitted = false;
                for (batches[0].slice()) |event| switch (event.event) {
                    .order_dispatch_result => |dispatch| if (dispatch.command == command_id) {
                        submitted = dispatch.state == .submitted;
                        if (!submitted) std.debug.print("windows_demo_dispatch: state={s} reason={s}\n", .{
                            @tagName(dispatch.state), if (dispatch.reason) |reason| @tagName(reason) else "none",
                        });
                    },
                    else => {},
                };
                try owners.writeBatch(client, generation, batches[0]);
                if (!submitted) {
                    try writeStatus(client, .failed);
                    return error.DemoDispatchNotSubmitted;
                }
                const wire_id = owners.gateway.acceptedClientOrderId(2, command_id) orelse return error.MissingDispatchIdentity;
                try writeStatus(client, .okx_sent);
                try writePayloadFrame(client, generation, wire_id.slice());
            },
            .inspect_okx => {
                if (role != .engine or !demo_transport or draining or okx_command_id == 0) return error.InvalidRoleTransition;
                const owner = okx_owner orelse return error.EngineOwnersMissing;
                var order_id: u64 = 0;
                for (owner.shard.oms.command_history[0..owner.shard.oms.command_history_count]) |known|
                    if (known.command_id == okx_command_id) {
                        order_id = known.order_id;
                        break;
                    };
                const order = owner.shard.oms.orderById(order_id) orelse return error.MissingDemoOrder;
                if (order.state == .unknown) return error.UnknownDemoOrder;
                const terminal = order.state == .filled or order.state == .canceled or order.state == .rejected;
                const quantity = (owner.shard.currentNetExchangePosition(okx_venue.btc_usdt_spot) orelse return error.MissingDemoPosition).lots;
                var encoded: [9]u8 = undefined;
                encoded[0] = @intFromBool(terminal);
                std.mem.writeInt(i64, encoded[1..9], @intCast(quantity), .little);
                try writeStatus(client, .okx_state);
                try writeAll(client, &encoded);
            },
            .verify_okx => {
                if (role != .engine or okx_command_id == 0 or draining) return error.InvalidRoleTransition;
                const owner = okx_owner orelse return error.EngineOwnersMissing;
                if (live_write) {
                    if (!owner.shard.oms.openOrdersClosed() or owner.shard.canonical_account.failure != null or
                        !owner.shard.canonical_account.valid or
                        (owner.shard.currentNetExchangePosition(okx_venue.btc_usdt_spot) orelse return error.MissingDemoPosition).lots != 0 or
                        okx_cleanup_command_id == 0 or owner.shard.economicSummary().portfolio.spot.quantity != 0)
                        return error.OkxLedgerNotClosed;
                    try demo_authority.requireZeroDemoExposure(&owner.shard.canonical_account);
                } else if (owner.shard.oms.orders[0].state != .filled or
                    owner.shard.economicSummary().portfolio.spot.quantity != 20_000 or
                    owner.shard.economicSummary().portfolio.fee_micros != 1) return error.OkxLedgerNotClosed;
                try writeStatus(client, .okx_verified);
                try writeAll(client, &owner.shard.canonicalStateDigest());
            },
            .drain => {
                risk_gate_open = false;
                draining = true;
                try writeStatus(client, .draining);
            },
            .stop => {
                if (!draining) {
                    try writeStatus(client, .failed);
                    return error.InvalidRoleTransition;
                }
                try writeStatus(client, .stopped);
                return;
            },
        }
    }
}

const EngineOwners = struct {
    host: strategy_host_lifecycle.ManagedHost,
    store: durable_store.WindowsFileAdapter,
    credentials: credential_store.CredentialStore,
    shard_run: demo_authority.Owner,
    venue: simulated_venue.SimulatedVenue,
    gateway: execution_gateway.Gateway,
    premature_host_intent: host_gateway.OrderIntent,
    fill_count: u64 = 0,
    replay_send_capability: bool = true,

    fn start(init: std.process.Init, store_dir: []const u8, credential_dir: []const u8, generation: u64) !*EngineOwners {
        if (store_dir.len == 0 or credential_dir.len == 0) return error.EnginePathsRequired;
        const self = try init.gpa.create(EngineOwners);
        errdefer init.gpa.destroy(self);
        const python_abi = try strategy_host_lifecycle.discoverPythonAbi(init, "python");
        self.host = try strategy_host_lifecycle.ManagedHost.start(
            init,
            "python",
            "python/strategy_host.py",
            strategy_host_lifecycle.developmentPlan(1, generation, python_abi),
            "trade",
            &.{ "--strategy-identity", "1", "--activation-identity", "1", "--config-version", "1", "--intent-sequence", "220", "--quantity", "10", "--limit-price", "50100000000" },
        );
        errdefer self.host.deinit(init.io);
        try self.host.sendPlan(init.io);
        if (try self.host.receive(init.io, 1) != .accepted or
            try self.host.receive(init.io, 2) != .accepted or
            self.host.supervisor.state != .ready_for_recovery)
            return error.HostHandshakeFailed;
        @memset(std.mem.asBytes(&self.store), 0);
        try self.store.initWindowsVerification(init.io, store_dir);
        errdefer self.store.close(init.io);
        self.credentials = try credential_store.CredentialStore.open(init.io, init.gpa, credential_dir);
        errdefer self.credentials.close(init.io);
        try admitObservation(init, &self.credentials);

        self.shard_run = try demo_authority.Owner.bootstrap(self.store.interface(), init.io, .{ .domain = .decision_log, .id = 78 });
        const genesis = fixture.genesisEvents(.{
            .strategy_identity = 1,
            .config_version = 1,
            .activation_identity = 1,
            .activation_barrier = 0,
        }, .leveraged);
        for (genesis) |event| if (try self.shard_run.apply(event) != null) return error.UnexpectedCommand;
        const host_intent: host_gateway.OrderIntent = .{
            .strategy_identity = 1,
            .intent_sequence = 1,
            .strategy_cursor = 1,
            .config_version = 1,
            .activation_identity = 1,
            .portfolio_identity = 1,
            .exchange_account_identity = 2,
            .instrument_identity = 3,
            .side = .buy,
            .order_type = .limit,
            .time_in_force = .good_til_canceled,
            .portfolio_reduce_only = false,
            .quantity = 10,
            .limit_price_micros = 50_000_000,
        };
        self.premature_host_intent = host_intent;
        const trace_before = self.shard_run.shard.trace.len;
        const rejected = try self.shard_run.apply(fixture.atGroup(12, .{ .identity = 4, .payload = .{ .external_order_intent = host_intent } }));
        if (rejected != null or
            self.shard_run.shard.last_reject_reason != .host_not_activated or
            self.shard_run.shard.trace.len != trace_before + 1 or
            self.shard_run.shard.trace.events[trace_before].kind != .strategy_intent_rejected)
            return error.HostIntentBeforeActivation;
        const host_digest = self.shard_run.shard.canonicalStateDigest();
        const activation_barrier = self.shard_run.shard.trace.len;
        if (try self.shard_run.apply(fixture.atGroup(11, .{ .identity = 3, .payload = .{ .host_activated = .{
            .strategy_identity = 1,
            .config_version = 1,
            .activation_identity = 1,
            .session = self.host.supervisor.plan.session,
            .activation_barrier = activation_barrier,
            .state_digest = host_digest,
        } } })) != null) return error.UnexpectedCommand;
        try self.shard_run.sealBootstrap();
        try self.host.activate(init.io, .{
            .strategy_identity = 1,
            .activation_identity = 1,
            .barrier = activation_barrier,
            .state_digest = host_digest,
        });

        self.venue = .{};
        self.gateway = .{};
        self.fill_count = 0;
        self.replay_send_capability = false;
        return self;
    }

    fn deinit(self: *EngineOwners, init: std.process.Init) void {
        self.store.close(init.io);
        self.credentials.close(init.io);
        self.host.deinit(init.io);
    }

    fn exercise(self: *EngineOwners, init: std.process.Init) !void {
        const capability = fixture.atGroup(12, .{ .identity = 219, .payload = .{ .capability_profile_activation = .{
            .exchange_account = 2,
            .instrument = fixture.swap_instrument,
            .venue = 1,
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
        } } });
        _ = try self.shard_run.apply(capability);
        var account_bootstrap = fixture.canonicalAt(12, 1, .{ .account_bootstrap_snapshot = .{
            .identity = 1,
            .exchange_account = 2,
            .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true },
            .source_stream = 2,
            .source_sequence = 1,
            .balance_count = 0,
            .position_count = 0,
            .margin_count = 0,
        } });
        account_bootstrap.venue.envelope.identity.stream = 2;
        account_bootstrap.venue.envelope.source_stream = 2;
        account_bootstrap.venue.envelope.raw_evidence.stream = 2;
        _ = try self.shard_run.apply(account_bootstrap);
        var market_prelude = [_]trading_shard.CanonicalEvent{
            fixture.atGroup(12, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = fixture.swap_instrument, .price_micros = 50_000_000_000 } } }),
            fixture.canonicalAt(12, 99, .{ .instrument_definition_observed = .{ .instrument = fixture.swap_instrument, .rules_version = 1 } }),
            fixture.snapshotAt(13, 100),
            fixture.deltaAt(14, 100, 101, 49_850_000_000),
        };
        for (market_prelude[1..]) |*event| {
            event.venue.envelope.identity.stream = 3;
            event.venue.envelope.source_stream = 3;
            event.venue.envelope.raw_evidence.stream = 3;
        }
        for (market_prelude, 0..) |event, index| _ = self.shard_run.apply(event) catch |err| {
            std.debug.print("market_prelude_failed={d} {s}\n", .{ index, @errorName(err) });
            return err;
        };
        const host_config: host_gateway.Config = .{
            .schema_registry = self.host.supervisor.plan.compatibility.schema_registry,
            .decision_domain = self.host.supervisor.plan.decision_domain,
            .session = self.host.supervisor.plan.session,
            .authorization = .{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = self.shard_run.shard.host_activation_barrier },
        };
        const subscriptions = [_]host_gateway.Subscription{host_gateway.Subscription.of(1, &.{.mark_price})};
        var strategy_gateway = try host_gateway.Gateway.init(host_config, &subscriptions);
        const cursor = self.shard_run.shard.trace.len;
        const published_ns: i64 = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
        const payload = [_]u8{1};
        const events = [_]host_gateway.EventEnvelope{.{
            .event_type = .mark_price,
            .shard_sequence = cursor,
            .source_time_ns = published_ns,
            .receive_time_ns = published_ns,
            .monotonic_time_ns = published_ns,
            .wall_time_utc_ns = published_ns,
            .payload = &payload,
        }};
        var input_storage: [512]u8 = undefined;
        const input = try strategy_gateway.encodeBatch(&input_storage, 1, cursor, cursor, published_ns, &events);
        try self.host.sendInput(init.io, input, published_ns);
        try strategy_gateway.recordPublished(1, cursor, published_ns);
        try strategy_gateway.activate(&self.shard_run.shard, &self.shard_run.decision_journal);
        var output_storage: [512]u8 = undefined;
        const host_output = try self.host.receiveOutput(init.io, @intCast(std.Io.Clock.awake.now(init.io).nanoseconds), &output_storage);
        const host_decision = strategy_gateway.ingest(host_output, @intCast(std.Io.Clock.awake.now(init.io).nanoseconds));
        const host_intent = switch (host_decision) {
            .accepted => |intent| intent,
            .rejected => return error.HostIntentRejected,
        };
        const proved = (try self.shard_run.apply(fixture.atGroup(12, .{ .identity = 220, .payload = .{ .external_order_intent = host_intent } }))) orelse {
            std.debug.print("host_intent_reject={s} cursor={d} activation_barrier={d} source_cursor={d}\n", .{
                @tagName(self.shard_run.shard.last_reject_reason), host_intent.strategy_cursor,
                self.shard_run.shard.host_activation_barrier,      self.shard_run.shard.strategy_cursor,
            });
            return error.MissingOmsCommand;
        };

        const adapter = self.venue.adapter();
        try adapter.start(.{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 1, .request_capacity = 1, .output_capacity = 1 });
        try self.gateway.add(.{ .account = 2, .adapter = adapter, .venue_identity = 1, .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } });
        try self.gateway.observeAuthority(.{
            .account = 2,
            .effective_trading_authority = true,
            .reservation_identity = proved.reservation_identity,
            .reservation = proved.reservation,
            .primary_lease_expires_at_monotonic_ns = 3 * std.time.ns_per_s,
            .fencing_token = 1,
            .exchange_position = .{ .instrument = fixture.swap_instrument, .rules_version = 1, .lots = 0 },
            .authority_barrier = 1,
        });
        const store = self.store.interface();
        const stream: durable_store.StreamIdentity = .{ .domain = .control, .id = 77 };
        try self.gateway.bootstrapDurableDispatch(store, init.io, stream);
        if (store.safetyGate() != .open) return error.DurableSafetyGateClosed;
        const recovered = try store.recover(init.io, stream);
        if (recovered.status != .ready or recovered.committed_barrier == 0) return error.DurableBootstrapIncomplete;
        if (self.shard_run.shard.risk_lease_micros <= 0) return error.RiskLeaseClosed;
        if (self.shard_run.shard.fencing_token == 0) return error.MissingFencingToken;
        if (!proved.authority.complete()) return error.IncompleteDispatchAuthority;
        const send_now = proved.authority.dispatch_deadline_monotonic_ns -| 1;
        const send_result = try self.gateway.sendFromShard(&self.shard_run.shard, proved.command_id, send_now);
        if (send_result != .accepted) return error.GatewaySendFailed;
        if ((try store.recover(init.io, stream)).committed_barrier < 2) return error.DurableCommitMissing;
        var output: [execution_gateway.max_routes]canonical.AdapterOutputBatch = undefined;
        if (try self.gateway.drainFair(&output) != 1) return error.MissingSimulatedFill;
        try self.shard_run.applyAdapterBatch(output[0]);
        if (self.shard_run.shard.oms.orders[0].state != .filled) return error.LedgerNotClosed;
        if (self.shard_run.shard.economicSummary().portfolio.swap.quantity != 10) return error.LedgerNotClosed;
        self.fill_count = 1;

        const replayed = try init.gpa.create(trading_shard.ReplayTradingShard);
        defer init.gpa.destroy(replayed);
        replayed.* = .{};
        const genesis = fixture.genesisEvents(.{
            .strategy_identity = 1,
            .config_version = 1,
            .activation_identity = 1,
            .activation_barrier = 0,
        }, .leveraged);
        for (genesis) |event| _ = try replayed.apply(event);
        _ = try replayed.apply(fixture.atGroup(12, .{ .identity = 4, .payload = .{ .external_order_intent = self.premature_host_intent } }));
        const digest = replayed.canonicalStateDigest();
        _ = try replayed.apply(fixture.atGroup(11, .{ .identity = 3, .payload = .{ .host_activated = .{
            .strategy_identity = 1,
            .config_version = 1,
            .activation_identity = 1,
            .session = self.host.supervisor.plan.session,
            .activation_barrier = self.shard_run.shard.host_activation_barrier,
            .state_digest = digest,
        } } }));
        _ = try replayed.apply(capability);
        _ = try replayed.apply(account_bootstrap);
        for (market_prelude) |event| _ = try replayed.apply(event);
        _ = try replayed.apply(fixture.atGroup(12, .{ .identity = 220, .payload = .{ .external_order_intent = host_intent } }));
        for (output[0].slice()) |event| _ = try replayed.apply(.{ .venue = event });
        if (!std.mem.eql(u8, &self.shard_run.shard.canonicalStateDigest(), &replayed.canonicalStateDigest()))
            return error.ReplayDigestMismatch;
        comptime std.debug.assert(!@hasField(trading_shard.ReplayTradingShard, "gateway"));
        self.replay_send_capability = false;

        var stdout_buffer: [512]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
        try stdout.interface.print(
            "windows_engine: host_supervisor=handshake host_activated=python host_intent=python durable_commit=pass venue=simulated fill={d} replay_send_capability=false send_capability=false production_qualification=false\n",
            .{self.fill_count},
        );
        try stdout.interface.flush();
    }
};

const MarketOwners = struct {
    store: durable_store.WindowsFileAdapter,
    raw: raw_ingress.DurableSink,
    feed: market_feed.OkxMarketFeed,
    live_mode: bool,
    curl_runtime: if (live_transport_enabled) ?curl.Runtime else void,
    public_ws: if (live_transport_enabled) ?curl.PublicWs else void,
    proxy_z: if (live_transport_enabled) ?[:0]u8 else void,
    book_subscribed: bool = false,

    fn start(init: std.process.Init, store_dir: []const u8, live_mode: bool) !*MarketOwners {
        if (live_mode and !live_transport_enabled) return error.DemoTransportBuildRequired;
        const self = try init.gpa.create(MarketOwners);
        errdefer init.gpa.destroy(self);
        self.live_mode = live_mode;
        if (comptime live_transport_enabled) {
            self.curl_runtime = null;
            self.public_ws = null;
            self.proxy_z = null;
        }
        @memset(std.mem.asBytes(&self.store), 0);
        try self.store.initWindowsVerification(init.io, store_dir);
        errdefer self.store.close(init.io);
        const stream: durable_store.StreamIdentity = .{ .domain = .raw_ingress, .id = 90 };
        const has_history = blk: {
            var manifest = self.store.dir.openFile(init.io, "manifest.bin", .{}) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => return err,
            };
            manifest.close(init.io);
            break :blk true;
        };
        self.raw = if (has_history)
            try raw_ingress.DurableSink.recover(self.store.interface(), init.io, stream)
        else
            try raw_ingress.DurableSink.init(self.store.interface(), init.io, stream);
        self.feed = market_feed.OkxMarketFeed.init(self.raw.interface());
        try self.feed.adapter().start(.{
            .venue = 1,
            .environment = .demo,
            .subscription_set = 2,
            .config_version = 1,
            .session = 90,
            .output_capacity = canonical.max_events_per_adapter_batch,
        });
        if (has_history) {
            const Replay = struct {
                init: std.process.Init,
                feed: *market_feed.OkxMarketFeed,
                fn consume(ptr: *anyopaque, sequence: u64, record: @import("okx_public_market.zig").RawIngressRecord, bytes: []const u8) !void {
                    const self_replay: *@This() = @ptrCast(@alignCast(ptr));
                    try self_replay.feed.replay(self_replay.init.gpa, record.source_session, .{
                        .receive_time_utc_ns = record.receive_time_utc_ns,
                        .monotonic_time_ns = record.monotonic_time_ns,
                        .wall_time_utc_ns = record.wall_time_utc_ns,
                    }, .{ .stream_sequence = sequence, .sha256 = record.sha256 }, bytes);
                    _ = try self_replay.feed.adapter().tryDrain();
                }
            };
            var replay: Replay = .{ .init = init, .feed = &self.feed };
            try raw_ingress.replayCommitted(self.store.interface(), init.io, stream, .{ .ptr = &replay, .consume_fn = Replay.consume });
        }
        if (comptime live_transport_enabled) {
            if (live_mode) {
                if (init.environ_map.get("HTTPS_PROXY") orelse init.environ_map.get("ALL_PROXY")) |proxy| {
                    self.proxy_z = try init.gpa.allocSentinel(u8, proxy.len, 0);
                    @memcpy(self.proxy_z.?, proxy);
                }
                errdefer if (self.proxy_z) |value| init.gpa.free(value);
                self.curl_runtime = try curl.Runtime.init();
                errdefer self.curl_runtime.?.deinit();
                var rest_bytes: [raw_ingress.max_frame_bytes]u8 = undefined;
                const response = try curl.perform(
                    "https://openapi.okx.com/api/v5/public/instruments?instType=SPOT&instId=BTC-USDT",
                    "GET",
                    &.{"x-simulated-trading: 1"},
                    "",
                    self.proxy_z,
                    &rest_bytes,
                );
                if (response.outcome != .response or response.http_status != 200) return error.PublicRulesUnavailable;
                try self.feed.ingest(init.gpa, (try okx_demo.clock(init.io)).times, rest_bytes[0..response.body_len]);
                try requireDemoSpotRules(init.gpa, rest_bytes[0..response.body_len]);
                self.public_ws = try curl.PublicWs.connect(self.proxy_z);
                errdefer self.public_ws.?.close();
                try self.public_ws.?.send("{\"op\":\"subscribe\",\"args\":[{\"channel\":\"books5\",\"instId\":\"BTC-USDT\"}]}");
            }
        }
        return self;
    }

    fn deinit(self: *MarketOwners, init: std.process.Init) void {
        if (comptime live_transport_enabled) {
            if (self.public_ws) |ws| ws.close();
            if (self.curl_runtime) |*runtime| runtime.deinit();
            if (self.proxy_z) |value| init.gpa.free(value);
        }
        self.store.close(init.io);
    }

    fn pollLive(self: *MarketOwners, init: std.process.Init, pipe: Pipe, generation: u64) !void {
        if (!self.live_mode) return error.DemoTransportRequired;
        if (comptime live_transport_enabled) {
            try self.writePending(pipe, generation);
            const ws = self.public_ws orelse return error.PublicWsUnavailable;
            var buffer: [raw_ingress.max_frame_bytes]u8 = undefined;
            for (0..16) |_| {
                const message = ws.receive(&buffer, 5_000) catch |err| switch (err) {
                    error.WebSocketTimeout => continue,
                    else => return err,
                };
                const parsed = try std.json.parseFromSlice(std.json.Value, init.gpa, message, .{});
                defer parsed.deinit();
                const root = switch (parsed.value) {
                    .object => |value| value,
                    else => return error.InvalidPublicFrame,
                };
                if (root.get("event")) |event| {
                    if (event != .string) return error.InvalidPublicFrame;
                    if (std.mem.eql(u8, event.string, "error")) return error.PublicSubscriptionRejected;
                    if (std.mem.eql(u8, event.string, "subscribe")) {
                        if (self.book_subscribed) return error.DuplicatePublicSubscription;
                        try self.feed.beginSubscription(.btc_usdt_spot, (try okx_demo.clock(init.io)).times, message);
                        self.book_subscribed = true;
                        try self.writePending(pipe, generation);
                    }
                    continue;
                }
                if (!self.book_subscribed) return error.PublicDataBeforeSubscription;
                try self.feed.ingest(init.gpa, (try okx_demo.clock(init.io)).times, message);
                try self.writePending(pipe, generation);
                if (self.feed.decoder.isPublicMarketReady(.btc_usdt_spot)) return;
            }
            return error.PublicMarketNotReady;
        } else return error.DemoTransportBuildRequired;
    }

    fn writePending(self: *MarketOwners, pipe: Pipe, generation: u64) !void {
        while (try self.feed.adapter().tryDrain()) |batch| {
            try writeStatus(pipe, .market_output);
            try writeAll(pipe, &[_]u8{batch.len});
            for (batch.slice()) |event| {
                var encoded: [4096]u8 = undefined;
                try writePayloadFrame(pipe, generation, try snapshot_codec.encodeBare(&encoded, event));
            }
        }
    }
};

fn requireDemoSpotRules(gpa: std.mem.Allocator, raw: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidPublicRules,
    };
    const data = switch (root.get("data") orelse return error.InvalidPublicRules) {
        .array => |value| value,
        else => return error.InvalidPublicRules,
    };
    if (data.items.len != 1) return error.InvalidPublicRules;
    const rule = switch (data.items[0]) {
        .object => |value| value,
        else => return error.InvalidPublicRules,
    };
    const spot = okx_demo.demoRules().spot;
    for ([_]struct { name: []const u8, expected: @TypeOf(spot.tick_size) }{
        .{ .name = "tickSz", .expected = spot.tick_size },
        .{ .name = "lotSz", .expected = spot.lot_size },
    }) |check| {
        const value = switch (rule.get(check.name) orelse return error.InvalidPublicRules) {
            .string => |text| text,
            else => return error.InvalidPublicRules,
        };
        const actual = try @import("okx_public_market.zig").Decimal.parse(value);
        if (actual.coefficient != check.expected.coefficient or actual.scale != check.expected.scale)
            return error.DemoRulesMismatch;
    }
    const state = switch (rule.get("state") orelse return error.InvalidPublicRules) {
        .string => |text| text,
        else => return error.InvalidPublicRules,
    };
    if (!std.mem.eql(u8, state, "live")) return error.DemoInstrumentUnavailable;
}

test "live Demo spot rules must match the execution adapter" {
    const valid = "{\"data\":[{\"tickSz\":\"0.1\",\"lotSz\":\"0.00000001\",\"state\":\"live\"}]}";
    try requireDemoSpotRules(std.testing.allocator, valid);
    try std.testing.expectError(error.DemoRulesMismatch, requireDemoSpotRules(std.testing.allocator, "{\"data\":[{\"tickSz\":\"0.01\",\"lotSz\":\"0.00000001\",\"state\":\"live\"}]}"));
}

const ExecutionOwners = struct {
    store: durable_store.WindowsFileAdapter,
    raw: raw_ingress.DurableSink,
    transport: OfflineTransport,
    live_mode: bool,
    curl_runtime: if (live_transport_enabled) ?curl.Runtime else void,
    curl_transport: if (live_transport_enabled) ?*curl.TransportOwner else void,
    proxy_z: if (live_transport_enabled) ?[:0]u8 else void,
    chain: okx_live.Chain,
    clock: AdapterClock,
    reconciler: okx_private.Reconciler,
    venue: okx_venue.OkxVenueAdapter,
    gateway: execution_gateway.Gateway,
    authority: failover.FencingAuthority,
    lease: failover.PrimaryLease,
    guard: failover.GatewayLeaseGuard,
    fence_path: ?[]u8 = null,
    reconciliation_id: u128 = 1,

    const OfflineTransport = struct {
        writes: u8 = 0,
        fn interface(self: *@This()) okx_live.Transport {
            return .{ .ptr = self, .submit_fn = submit };
        }
        fn submit(ptr: *anyopaque, _: []const u8, _: []const u8) okx_live.TransportResult {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.writes += 1;
            return .{
                .outcome = .response,
                .response = "{\"code\":\"0\",\"data\":[{\"sCode\":\"0\",\"ordId\":\"1001\"}]}",
                .source_session = 1,
                .times = .{ .receive_time_utc_ns = 1_800_000_000_000_000_001, .monotonic_time_ns = 2, .wall_time_utc_ns = 1_800_000_000_000_000_002 },
            };
        }
    };
    const AdapterClock = struct {
        fn interface(self: *@This()) okx_venue.Clock {
            return .{ .ptr = self, .now_fn = now };
        }
        fn now(_: *anyopaque) u64 {
            return 2;
        }
    };

    fn start(init: std.process.Init, store_dir: []const u8, live_mode: bool) !*ExecutionOwners {
        if (live_mode and !live_transport_enabled) return error.DemoTransportBuildRequired;
        const self = try init.gpa.create(ExecutionOwners);
        errdefer init.gpa.destroy(self);
        self.fence_path = null;
        self.live_mode = live_mode;
        if (comptime live_transport_enabled) {
            self.curl_runtime = null;
            self.curl_transport = null;
            self.proxy_z = null;
        }
        @memset(std.mem.asBytes(&self.store), 0);
        try self.store.initWindowsVerification(init.io, store_dir);
        errdefer self.store.close(init.io);
        const has_history = blk: {
            var manifest = self.store.dir.openFile(init.io, "manifest.bin", .{}) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => return err,
            };
            manifest.close(init.io);
            break :blk true;
        };
        const raw_stream: durable_store.StreamIdentity = .{ .domain = .raw_ingress, .id = 93 };
        self.raw = if (has_history)
            try raw_ingress.DurableSink.recover(self.store.interface(), init.io, raw_stream)
        else
            try raw_ingress.DurableSink.init(self.store.interface(), init.io, raw_stream);
        self.transport = .{};
        var adapter_transport = self.transport.interface();
        if (comptime live_transport_enabled) {
            if (live_mode) {
                const key = init.environ_map.get("RINGWIN_OKX_KEY") orelse return error.MissingCredential;
                const secret = init.environ_map.get("RINGWIN_OKX_SECRET") orelse return error.MissingCredential;
                const passphrase = init.environ_map.get("RINGWIN_OKX_PASSPHRASE") orelse return error.MissingCredential;
                const base_url = init.environ_map.get("RINGWIN_OKX_REST_BASE_URL") orelse return error.MissingEndpointProfile;
                const entity = init.environ_map.get("RINGWIN_OKX_ENTITY") orelse return error.MissingEndpointProfile;
                var endpoint = try curl.demoEndpointProfile(base_url, entity);
                if (init.environ_map.get("RINGWIN_OKX_PRIVATE_WS_URL")) |url|
                    endpoint = try curl.withDemoPrivateWs(endpoint, url);
                if (init.environ_map.get("HTTPS_PROXY") orelse init.environ_map.get("ALL_PROXY")) |proxy| {
                    self.proxy_z = try init.gpa.allocSentinel(u8, proxy.len, 0);
                    @memcpy(self.proxy_z.?, proxy);
                }
                errdefer if (self.proxy_z) |value| init.gpa.free(value);
                self.curl_runtime = try curl.Runtime.init();
                errdefer self.curl_runtime.?.deinit();
                const owner = try init.gpa.create(curl.TransportOwner);
                errdefer init.gpa.destroy(owner);
                owner.* = try curl.TransportOwner.initWithEndpoint(
                    try okx_auth.Credentials.init(key, secret, passphrase),
                    self.proxy_z,
                    1,
                    endpoint,
                );
                errdefer owner.deinit();
                self.curl_transport = owner;
                adapter_transport = owner.transport();
            }
        }
        var qualification = okx_demo.qualified();
        if (live_mode) qualification.explicit_demo_live = false;
        self.chain = .{ .mode = .demo_live, .qualification = qualification, .raw_sink = self.raw.interface(), .transport = adapter_transport };
        self.clock = .{};
        self.reconciler = .{};
        self.venue = okx_venue.OkxVenueAdapter.init(init.gpa, &self.chain, self.clock.interface(), okx_demo.demoProfile(), okx_demo.demoRules());
        self.venue.attachPrivateReconciler(&self.reconciler);
        try self.venue.adapter().start(.{ .venue = 1, .environment = .demo, .exchange_account = 2, .adapter_session = 1, .request_capacity = 4, .output_capacity = 4 });
        try self.venue.beginPrivateSession();
        if (has_history) {
            const Replay = struct {
                venue: *okx_venue.OkxVenueAdapter,
                reconciliation_started: bool = false,
                previous_source: ?okx_private.IngressSource = null,
                after: ?u64 = null,
                fn consume(ptr: *anyopaque, sequence: u64, record: @import("okx_public_market.zig").RawIngressRecord, bytes: []const u8) !void {
                    const self_replay: *@This() = @ptrCast(@alignCast(ptr));
                    if (record.source_session != 1) return error.PrivateReplaySessionMismatch;
                    if (record.origin == okx_live.transport_response_origin) return;
                    const evidence: okx_private.RawEvidenceRef = .{ .stream_sequence = sequence, .sha256 = record.sha256 };
                    const times: okx_private.Times = .{
                        .receive_time_utc_ns = record.receive_time_utc_ns,
                        .monotonic_time_ns = record.monotonic_time_ns,
                        .wall_time_utc_ns = record.wall_time_utc_ns,
                    };
                    const ingress = if (record.origin == 0)
                        try self_replay.venue.replayPrivateWs(times, evidence, bytes)
                    else blk: {
                        const source = std.enums.fromInt(okx_private.IngressSource, record.origin - 1) orelse return error.InvalidPrivateReplaySource;
                        if (source.isWebSocket()) return error.InvalidPrivateReplaySource;
                        if (!self_replay.reconciliation_started or
                            (source == .rest_account_config and self_replay.venue.reconciler.?.readiness().reconciliation_ready))
                        {
                            if (try self_replay.venue.adapter().trySend(.{ .account_reconciliation = .{ .identity = 1, .exchange_account = 2, .expected_session = 1 } }) != .accepted)
                                return error.PrivateReplayReconciliationRejected;
                            self_replay.reconciliation_started = true;
                            while (try self_replay.venue.adapter().tryDrain()) |_| {}
                        }
                        if (self_replay.previous_source != source) self_replay.after = null;
                        const endpoint = for (okx_demo.rest_endpoints) |candidate| {
                            if (candidate.source == source) break candidate;
                        } else return error.InvalidPrivateReplaySource;
                        const parsed = try std.json.parseFromSlice(std.json.Value, self_replay.venue.allocator, bytes, .{});
                        defer parsed.deinit();
                        const rows = parsed.value.object.get("data") orelse return error.InvalidRestPage;
                        if (rows != .array) return error.InvalidRestPage;
                        const final = endpoint.cursor == .none or rows.array.items.len < endpoint.page_size;
                        const batch = try self_replay.venue.replayPrivateRest(times, source, .{
                            .requested_after = self_replay.after,
                            .final = final,
                        }, evidence, bytes);
                        self_replay.previous_source = source;
                        self_replay.after = if (final) null else batch.oldest_cursor orelse return error.MissingRestPageCursor;
                        break :blk batch;
                    };
                    if (ingress.rejection) |reason| {
                        std.debug.print("private_replay_reject seq={d} origin={d} reason={s}\n", .{ sequence, record.origin, @tagName(reason) });
                        return error.PrivateReplayRejected;
                    }
                    while (try self_replay.venue.adapter().tryDrain()) |_| {}
                }
            };
            var replay: Replay = .{ .venue = &self.venue };
            try raw_ingress.replayCommitted(self.store.interface(), init.io, raw_stream, .{ .ptr = &replay, .consume_fn = Replay.consume });
        }
        self.authority = .{};
        self.lease = .{ .key = .{ .exchange_account = 2, .decision_domain = 1 }, .node = 0, .token = 0, .issued_at_ns = 0, .expires_at_ns = 0 };
        self.guard = .{ .authority = &self.authority, .lease = &self.lease };
        self.gateway = .{};
        try self.gateway.add(.{ .account = 2, .adapter = self.venue.adapter(), .venue_identity = 1, .environment = .demo, .lease_guard = &self.guard, .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1, .supports_post_only = true, .supports_market_protection = true } });
        if (has_history)
            try self.gateway.attachRecoveredDurableDispatch(self.store.interface(), init.io, .{ .domain = .control, .id = 92 })
        else
            try self.gateway.bootstrapDurableDispatch(self.store.interface(), init.io, .{ .domain = .control, .id = 92 });
        return self;
    }

    fn deinit(self: *ExecutionOwners, init: std.process.Init) void {
        if (self.fence_path) |path| init.gpa.free(path);
        if (comptime live_transport_enabled) {
            if (self.curl_transport) |owner| {
                owner.deinit();
                init.gpa.destroy(owner);
            }
            if (self.curl_runtime) |*runtime| runtime.deinit();
            if (self.proxy_z) |value| init.gpa.free(value);
        }
        self.store.close(init.io);
    }

    fn installFence(self: *ExecutionOwners, init: std.process.Init, path: []const u8, lease: failover.PrimaryLease) !void {
        if (lease.token == 0 or lease.key.exchange_account != 2 or lease.key.decision_domain != 1)
            return error.InvalidDemoLease;
        if (self.fence_path) |existing| {
            if (!std.mem.eql(u8, existing, path) or lease.token < self.lease.token or
                (lease.token == self.lease.token and lease.expires_at_ns <= self.lease.expires_at_ns))
                return error.InvalidDemoLease;
        }
        const authority = try failover.readWindowsFencingCheckpoint(init.io, path);
        var current = authority;
        if (!current.accepts(lease.key, lease.node, lease.token)) return error.InvalidDemoLease;
        if (self.fence_path == null) self.fence_path = try init.gpa.dupe(u8, path);
        self.authority = authority;
        self.lease = lease;
        self.guard.windows_checkpoint = .{ .io = init.io, .path = self.fence_path.? };
        try self.guard.check(if (self.live_mode) try awakeNs(init.io) else lease.issued_at_ns, lease.token, true);
    }

    fn ingestPrivate(self: *ExecutionOwners, pipe: Pipe, generation: u64, raw: []const u8) !void {
        const times: okx_private.Times = .{ .receive_time_utc_ns = 1_800_000_000_000_000_001, .monotonic_time_ns = 10_000_001, .wall_time_utc_ns = 1_800_000_000_000_000_002 };
        const ingress = try self.venue.ingestPrivateWs(times, raw);
        if (ingress.rejection != null or ingress.event_count != 0) return error.PrivateIngressRejected;
        try self.drainPrivate(pipe, generation);
    }

    fn drainPrivate(self: *ExecutionOwners, pipe: Pipe, generation: u64) !void {
        while (try self.venue.adapter().tryDrain()) |batch| {
            try self.writeBatch(pipe, generation, batch);
        }
    }

    fn writeBatch(_: *ExecutionOwners, pipe: Pipe, generation: u64, batch: canonical.AdapterOutputBatch) !void {
        try writeStatus(pipe, .private_output);
        try writeAll(pipe, &[_]u8{batch.len});
        for (batch.slice()) |event| {
            var encoded: [4096]u8 = undefined;
            try writePayloadFrame(pipe, generation, try snapshot_codec.encodeBare(&encoded, event));
        }
    }

    fn bootstrapPrivate(self: *ExecutionOwners, init: std.process.Init, pipe: Pipe, generation: u64) !void {
        if (self.live_mode) {
            if (comptime live_transport_enabled) return self.bootstrapLivePrivate(init, pipe, generation);
            return error.DemoTransportBuildRequired;
        }
        const ws_frames = [_][]const u8{
            \\{"event":"subscribe","arg":{"channel":"orders","instType":"ANY"}}
            ,
            \\{"event":"subscribe","arg":{"channel":"account"}}
            ,
            \\{"event":"subscribe","arg":{"channel":"positions","instType":"ANY"}}
            ,
            \\{"arg":{"channel":"account"},"eventType":"snapshot","curPage":1,"lastPage":true,"data":[{"uTime":"1800000000000","totalEq":"25","adjEq":"25","imr":"0","mmr":"0","mgnRatio":"","isoEq":"0","details":[{"ccy":"USDT","cashBal":"25","availBal":"25","eq":"25","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}]}]}
            ,
            \\{"arg":{"channel":"positions"},"eventType":"snapshot","curPage":1,"lastPage":true,"data":[]}
        };
        for (ws_frames) |frame| try self.ingestPrivate(pipe, generation, frame);
        if (!self.reconciler.readiness().private_stream_ready) return error.IncompletePrivateStream;
        if (try self.venue.adapter().trySend(.{ .account_reconciliation = .{ .identity = 1, .exchange_account = 2, .expected_session = 1 } }) != .accepted)
            return error.AdapterRejectedReconciliation;
        try self.drainPrivate(pipe, generation);
        const sources = [_]okx_private.IngressSource{ .rest_account_config, .rest_leverage, .rest_balance, .rest_positions, .rest_orders_pending, .rest_orders_history_spot, .rest_orders_history_swap, .rest_fills_history_spot, .rest_fills_history_swap };
        const rest_frames = [_][]const u8{
            \\{"code":"0","data":[{"acctLv":"2","posMode":"net_mode","ctIsoMode":"automatic","autoLoan":false,"enableSpotBorrow":false,"perm":"read_only,trade"}]}
            ,
            \\{"code":"0","data":[{"instId":"BTC-USDT-SWAP","mgnMode":"isolated","posSide":"net","lever":"3"}]}
            ,
            \\{"code":"0","data":[{"uTime":"1800000000000","totalEq":"25","adjEq":"25","imr":"0","mmr":"0","mgnRatio":"","isoEq":"0","details":[{"ccy":"USDT","cashBal":"25","availBal":"25","eq":"25","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}]}]}
            ,
            \\{"code":"0","data":[]}
            ,
            \\{"code":"0","data":[]}
            ,
            \\{"code":"0","data":[]}
            ,
            \\{"code":"0","data":[]}
            ,
            \\{"code":"0","data":[]}
            ,
            \\{"code":"0","data":[]}
        };
        const times: okx_private.Times = .{ .receive_time_utc_ns = 1_800_000_000_000_000_001, .monotonic_time_ns = 10_000_001, .wall_time_utc_ns = 1_800_000_000_000_000_002 };
        for (0..2) |_| {
            for (sources, rest_frames) |source, frame| {
                const ingress = try self.venue.ingestPrivateRest(times, source, .{ .final = true }, frame);
                if (ingress.rejection != null) return error.PrivateIngressRejected;
                try self.drainPrivate(pipe, generation);
            }
            _ = try self.reconciler.tryComplete();
        }
        if (!self.reconciler.readiness().reconciliation_ready) return error.ReconciliationNotReady;
    }

    fn bootstrapLivePrivate(self: *ExecutionOwners, init: std.process.Init, pipe: Pipe, generation: u64) !void {
        if (comptime live_transport_enabled) {
            const owner = self.curl_transport orelse return error.DemoTransportUnavailable;
            const expected_uid_hash = init.environ_map.get("RINGWIN_OKX_UID_SHA256") orelse return error.MissingDemoAccountIdentity;
            if (expected_uid_hash.len != 64) return error.InvalidDemoAccountIdentity;
            try okx_demo.refresh(owner, init.io);
            const config_response = owner.request(.get, "/api/v5/account/config", "");
            if (config_response.outcome != .response) return error.DemoAccountIdentityUnavailable;
            const parsed = try std.json.parseFromSlice(std.json.Value, init.gpa, config_response.response.?, .{});
            defer parsed.deinit();
            const data = parsed.value.object.get("data") orelse return error.InvalidDemoAccountIdentity;
            if (data != .array or data.array.items.len != 1) return error.InvalidDemoAccountIdentity;
            const uid = data.array.items[0].object.get("uid") orelse return error.InvalidDemoAccountIdentity;
            if (uid != .string or uid.string.len == 0) return error.InvalidDemoAccountIdentity;
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(uid.string, &digest, .{});
            const actual_hash = std.fmt.bytesToHex(digest, .lower);
            if (!std.ascii.eqlIgnoreCase(&actual_hash, expected_uid_hash)) return error.DemoAccountIdentityMismatch;
            std.debug.print("windows_demo_private: account_identity=matched\n", .{});
            try owner.wsConnect();
            std.debug.print("windows_demo_private: ws=connected\n", .{});
            const stamp = try okx_demo.clock(init.io);
            try owner.wsLogin(stamp.secondsSlice());
            std.debug.print("windows_demo_private: login=sent\n", .{});
            var buffer: [raw_ingress.max_frame_bytes]u8 = undefined;
            var login_ok = false;
            for (0..8) |_| {
                const message = (try okx_demo.receiveWithKeepalive(owner, &buffer)) orelse continue;
                try self.ingestLivePrivate(init.io, pipe, generation, message);
                if (std.mem.indexOf(u8, message, "\"event\":\"login\"") != null) {
                    login_ok = true;
                    break;
                }
            }
            if (!login_ok) return error.MissingLoginAck;
            std.debug.print("windows_demo_private: login=ack\n", .{});
            try owner.wsSend("{\"op\":\"subscribe\",\"args\":[{\"channel\":\"orders\",\"instType\":\"ANY\"},{\"channel\":\"account\"},{\"channel\":\"positions\",\"instType\":\"ANY\"}]}");
            std.debug.print("windows_demo_private: subscriptions=sent\n", .{});
            for (0..24) |_| {
                const message = (try okx_demo.receiveWithKeepalive(owner, &buffer)) orelse continue;
                std.debug.print("windows_demo_private: ws_frame_bytes={d}\n", .{message.len});
                try self.ingestLivePrivate(init.io, pipe, generation, message);
                std.debug.print("windows_demo_private: stream_ready={}\n", .{self.reconciler.readiness().private_stream_ready});
                if (self.reconciler.readiness().private_stream_ready) break;
            }
            if (!self.reconciler.readiness().private_stream_ready) return error.IncompletePrivateStream;
            if (try self.venue.adapter().trySend(.{ .account_reconciliation = .{ .identity = 1, .exchange_account = 2, .expected_session = 1 } }) != .accepted)
                return error.AdapterRejectedReconciliation;
            try self.drainPrivate(pipe, generation);
            for (0..2) |_| {
                for (okx_demo.rest_endpoints) |endpoint| {
                    std.debug.print("windows_demo_private: rest={s}\n", .{@tagName(endpoint.source)});
                    try okx_demo.ingestRestEndpoint(init, owner, &self.venue, endpoint);
                    try self.drainPrivate(pipe, generation);
                }
                _ = try self.reconciler.tryComplete();
                try self.drainPrivate(pipe, generation);
                if (self.reconciler.readiness().reconciliation_ready) break;
            }
            if (!self.reconciler.readiness().reconciliation_ready) return error.ReconciliationNotReady;
            // REST full snapshots remain the account authority for this bounded run.
            // An account WS burst can exceed the eight-entry observation window.
            try owner.wsSend("{\"op\":\"unsubscribe\",\"args\":[{\"channel\":\"account\"}]}");
            var unsubscribed = false;
            for (0..16) |_| {
                const message = (try okx_demo.receiveWithKeepalive(owner, &buffer)) orelse continue;
                try self.ingestLivePrivate(init.io, pipe, generation, message);
                if (std.mem.indexOf(u8, message, "\"event\":\"unsubscribe\"") != null and
                    std.mem.indexOf(u8, message, "\"channel\":\"account\"") != null)
                {
                    unsubscribed = true;
                    break;
                }
            }
            if (!unsubscribed) return error.AccountUnsubscribeUnconfirmed;
            try self.refreshLivePrivate(init, pipe, generation);
            if (std.mem.eql(u8, init.environ_map.get("RINGWIN_DEMO_LIVE_AUTHORIZED") orelse "", "1"))
                self.chain.qualification.explicit_demo_live = true;
        } else return error.DemoTransportBuildRequired;
    }

    fn refreshLivePrivate(self: *ExecutionOwners, init: std.process.Init, pipe: Pipe, generation: u64) !void {
        if (comptime live_transport_enabled) {
            const owner = self.curl_transport orelse return error.DemoTransportUnavailable;
            try self.drainPrivate(pipe, generation);
            if (self.venue.pending_account_reconciliation == null) {
                self.reconciliation_id += 1;
                const result = try self.venue.adapter().trySend(.{ .account_reconciliation = .{
                    .identity = self.reconciliation_id,
                    .exchange_account = 2,
                    .expected_session = 1,
                } });
                if (result != .accepted) {
                    std.debug.print("windows_demo_refresh: send_result={s}\n", .{@tagName(result)});
                    return error.AdapterRejectedReconciliation;
                }
                try self.drainPrivate(pipe, generation);
            } else if (self.reconciler.stage != .reconciling) return error.AdapterRejectedReconciliation;
            for (0..2) |_| {
                for (okx_demo.rest_endpoints) |endpoint| {
                    std.debug.print("windows_demo_refresh: rest={s}\n", .{@tagName(endpoint.source)});
                    try okx_demo.ingestRestEndpoint(init, owner, &self.venue, endpoint);
                    try self.drainPrivate(pipe, generation);
                }
                _ = try self.reconciler.tryComplete();
                try self.drainPrivate(pipe, generation);
                if (self.reconciler.readiness().reconciliation_ready) break;
            }
            if (!self.reconciler.readiness().reconciliation_ready) return error.ReconciliationNotReady;
        } else return error.DemoTransportBuildRequired;
    }

    fn reconnectLivePrivate(self: *ExecutionOwners, init: std.process.Init, pipe: Pipe, generation: u64) !void {
        if (comptime live_transport_enabled) {
            const owner = self.curl_transport orelse return error.DemoTransportUnavailable;
            owner.wsDisconnect();
            try owner.wsConnect();
            const stamp = try okx_demo.clock(init.io);
            try owner.wsLogin(stamp.secondsSlice());
            var buffer: [raw_ingress.max_frame_bytes]u8 = undefined;
            var login_ok = false;
            for (0..8) |_| {
                const message = (try okx_demo.receiveWithKeepalive(owner, &buffer)) orelse continue;
                try self.ingestLivePrivate(init.io, pipe, generation, message);
                if (std.mem.indexOf(u8, message, "\"event\":\"login\"") != null) {
                    login_ok = true;
                    break;
                }
            }
            if (!login_ok) return error.MissingLoginAck;
            try owner.wsSend("{\"op\":\"subscribe\",\"args\":[{\"channel\":\"orders\",\"instType\":\"ANY\"}]}");
            try self.refreshLivePrivate(init, pipe, generation);
        } else return error.DemoTransportBuildRequired;
    }

    fn ingestLivePrivate(self: *ExecutionOwners, io: std.Io, pipe: Pipe, generation: u64, raw: []const u8) !void {
        if (comptime live_transport_enabled) {
            const times = (try okx_demo.clock(io)).times;
            const ingress = try self.venue.ingestPrivateWs(times, raw);
            if (ingress.rejection != null or ingress.event_count != 0) return error.PrivateIngressRejected;
            try self.drainPrivate(pipe, generation);
        } else return error.DemoTransportBuildRequired;
    }
};

const offline_okx_policy =
    \\{"schema":1,"startup":"virgin","exchange_account":2,"portfolio_identity":1,"strategy_identity":40,"activation_identity":50,"config_version":1,"portfolio_allocation_micros":20000000,"risk_limit_micros":10000000,"decision_stream_id":91,"dispatch_stream_id":92,"decision_domain":1,"node_identity":1}
;

const OkxFenceOwner = struct {
    store: failover.WindowsFencingStore,
    authority: failover.FencingAuthority,
    lease: failover.PrimaryLease,
    guard: failover.GatewayLeaseGuard,
    live_mode: bool,

    fn start(init: std.process.Init, store_dir: []const u8, live_mode: bool) !*OkxFenceOwner {
        const self = try init.gpa.create(OkxFenceOwner);
        errdefer init.gpa.destroy(self);
        self.store = try failover.WindowsFencingStore.openWindowsVerification(init.io, store_dir);
        errdefer self.store.close();
        self.authority = try self.store.load();
        self.live_mode = live_mode;
        self.lease = try self.authority.acquire(.{ .exchange_account = 2, .decision_domain = 1 }, 1, if (live_mode) try awakeNs(init.io) else 1);
        self.guard = .{ .authority = &self.authority, .lease = &self.lease };
        return self;
    }

    fn heartbeat(self: *OkxFenceOwner, io: std.Io) !void {
        if (!self.live_mode) return;
        const now = try awakeNs(io);
        if (now >= self.lease.expires_at_ns) return error.PrimaryLeaseExpired;
        if (self.lease.expires_at_ns - now <= 250 * std.time.ns_per_ms)
            try self.authority.renew(&self.lease, now);
    }

    fn deinit(self: *OkxFenceOwner) void {
        self.authority.revoke(&self.lease) catch {};
        self.store.close();
    }
};

fn awakeNs(io: std.Io) !u64 {
    return std.math.cast(u64, std.Io.Clock.awake.now(io).nanoseconds) orelse error.InvalidMonotonicClock;
}

const OkxFenceView = struct {
    authority: failover.FencingAuthority,
    lease: failover.PrimaryLease,
    guard: failover.GatewayLeaseGuard,
    path: []u8,
    live_mode: bool,

    fn start(init: std.process.Init, path: []const u8, lease: failover.PrimaryLease, live_mode: bool) !*OkxFenceView {
        if (lease.token == 0 or lease.key.exchange_account != 2 or lease.key.decision_domain != 1)
            return error.InvalidDemoLease;
        const self = try init.gpa.create(OkxFenceView);
        errdefer init.gpa.destroy(self);
        self.path = try init.gpa.dupe(u8, path);
        errdefer init.gpa.free(self.path);
        self.authority = try failover.readWindowsFencingCheckpoint(init.io, self.path);
        self.lease = lease;
        self.live_mode = live_mode;
        self.guard = .{ .authority = &self.authority, .lease = &self.lease, .windows_checkpoint = .{ .io = init.io, .path = self.path } };
        try self.guard.check(if (live_mode) try awakeNs(init.io) else lease.issued_at_ns, lease.token, true);
        return self;
    }

    fn refresh(self: *OkxFenceView, io: std.Io, path: []const u8, lease: failover.PrimaryLease) !void {
        if (!std.mem.eql(u8, self.path, path) or lease.key.exchange_account != 2 or lease.key.decision_domain != 1 or
            lease.token < self.lease.token or (lease.token == self.lease.token and lease.expires_at_ns <= self.lease.expires_at_ns))
            return error.InvalidDemoLease;
        self.authority = try failover.readWindowsFencingCheckpoint(io, self.path);
        self.lease = lease;
        try self.guard.check(if (self.live_mode) try awakeNs(io) else lease.issued_at_ns, lease.token, true);
    }

    fn deinit(self: *OkxFenceView, init: std.process.Init) void {
        init.gpa.free(self.path);
    }
};

fn admitObservation(init: std.process.Init, store: *credential_store.CredentialStore) !void {
    const stdin = std.Io.File.stdin();
    var password_bytes: [credential_store.max_password]u8 = undefined;
    defer std.crypto.secureZero(u8, &password_bytes);
    var metadata = try credential_store.Metadata.init(.observation, 42, .production, 4_000_000_000, "obs-win-42", "windows-node-1", "198.51.100.42");
    metadata.state = .active;
    metadata.generation = 2;
    const runtime = credential_store.RuntimeContext{
        .account = 42,
        .environment = .production,
        .endpoint_environment = .production,
        .node_id = "windows-node-1",
        .egress_ip = "198.51.100.42",
    };
    const admission = try store.admitObservationReadOnly(init.io, stdin, .restricted_fd, &password_bytes, metadata, runtime, 1_700_000_000, .{ .dont_dump = false });
    if (!admission.isReady() or admission.send_capability or admission.trading_enabled) return error.SecurityGateClosed;
}

var termination_requested = std.atomic.Value(bool).init(false);

fn onConsole(ctrl: u32) callconv(.winapi) i32 {
    _ = ctrl;
    termination_requested.store(true, .seq_cst);
    return 1;
}

fn installConsoleHandler() !void {
    termination_requested.store(false, .seq_cst);
    if (windows_api.SetConsoleCtrlHandler(&onConsole, 1) == 0) return error.ConsoleHandlerFailed;
}

const Pipe = struct {
    handle: std.os.windows.HANDLE,

    fn close(self: Pipe) void {
        std.os.windows.CloseHandle(self.handle);
    }
};

const PipeServer = struct {
    handle: std.os.windows.HANDLE,

    fn close(self: PipeServer) void {
        std.os.windows.CloseHandle(self.handle);
    }

    fn accept(self: PipeServer, expected_sid: []u8, expected_pid: u32) !Pipe {
        if (windows_api.ConnectNamedPipe(self.handle, null) == 0) {
            const err = windows_api.GetLastError();
            if (err != 535) return error.PipeAcceptFailed; // ERROR_PIPE_CONNECTED
        }
        try verifyClientSid(self.handle, expected_sid, expected_pid);
        return .{ .handle = self.handle };
    }
};

fn listenPipe(name: []const u8, sid: []u8) !PipeServer {
    var name_utf16: [160]u16 = undefined;
    const pipe_name = try toUtf16(name, &name_utf16);
    var sd: [64]u8 align(8) = undefined;
    var acl: ?*anyopaque = null;
    try buildUserOnlyDescriptor(sid, &sd, &acl);
    defer {
        if (acl) |value| _ = windows_api.LocalFree(value);
    }
    var attributes: SecurityAttributes = .{
        .length = @sizeOf(SecurityAttributes),
        .descriptor = &sd,
        .inherit = 0,
    };
    const handle = windows_api.CreateNamedPipeW(
        pipe_name.ptr,
        0x00000003 | 0x00080000, // DUPLEX | FIRST_PIPE_INSTANCE
        0, // byte mode, wait
        1,
        16,
        16,
        5_000,
        &attributes,
    );
    if (handle == std.os.windows.INVALID_HANDLE_VALUE) return error.PipeCreateFailed;
    return .{ .handle = handle };
}

fn connectPipe(io: std.Io, name: []const u8) !Pipe {
    var name_utf16: [160]u16 = undefined;
    const pipe_name = try toUtf16(name, &name_utf16);
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        _ = windows_api.WaitNamedPipeW(pipe_name.ptr, 50);
        const handle = windows_api.CreateFileW(
            pipe_name.ptr,
            0x80000000 | 0x40000000, // GENERIC_READ | GENERIC_WRITE
            0,
            null,
            3, // OPEN_EXISTING
            0,
            null,
        );
        if (handle != std.os.windows.INVALID_HANDLE_VALUE) return .{ .handle = handle };
        io.sleep(.fromNanoseconds(5 * std.time.ns_per_ms), .awake) catch {};
    }
    return error.RolePipeTimeout;
}

fn writeStatus(pipe: Pipe, status: Status) !void {
    const byte = [1]u8{@intFromEnum(status)};
    try writeAll(pipe, &byte);
}

fn readStatus(pipe: Pipe) !Status {
    var byte: [1]u8 = undefined;
    try readExact(pipe, &byte);
    return std.enums.fromInt(Status, byte[0]) orelse error.InvalidStatus;
}

fn sendCommand(pipe: Pipe, command: Command) !void {
    const byte = [1]u8{@intFromEnum(command)};
    try writeAll(pipe, &byte);
}

fn waitForCommand(pipe: Pipe, draining: bool, io: std.Io, fence: ?*OkxFenceOwner) !?Command {
    const started = windows_api.GetTickCount64();
    while (true) {
        if (fence) |owner| try owner.heartbeat(io);
        if (termination_requested.load(.seq_cst)) return null;
        var available: u32 = 0;
        if (windows_api.PeekNamedPipe(pipe.handle, null, 0, null, &available, null) == 0)
            return error.RoleIpcDisconnected;
        if (available > 0) {
            var byte: [1]u8 = undefined;
            readExact(pipe, &byte) catch {
                if (termination_requested.load(.seq_cst)) return null;
                return error.RoleIpcDisconnected;
            };
            return std.enums.fromInt(Command, byte[0]) orelse error.InvalidControlFrame;
        }
        if (draining and windows_api.GetTickCount64() - started >= 5_000) return error.DrainDeadline;
        windows_api.Sleep(10);
    }
}

fn writeAll(pipe: Pipe, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        var written: u32 = 0;
        if (windows_api.WriteFile(pipe.handle, bytes[offset..].ptr, @intCast(bytes.len - offset), &written, null) == 0)
            return error.PipeWriteFailed;
        if (written == 0) return error.PipeWriteFailed;
        offset += written;
    }
}

fn readExact(pipe: Pipe, dest: []u8) !void {
    var offset: usize = 0;
    while (offset < dest.len) {
        var read_n: u32 = 0;
        if (windows_api.ReadFile(pipe.handle, dest[offset..].ptr, @intCast(dest.len - offset), &read_n, null) == 0)
            return error.PipeReadFailed;
        if (read_n == 0) return error.EndOfStream;
        offset += read_n;
    }
}

fn writePayloadFrame(pipe: Pipe, generation: u64, payload: []const u8) !void {
    if (generation == 0 or payload.len == 0 or payload.len > raw_ingress.max_frame_bytes)
        return error.InvalidBusinessFrame;
    var header: [12]u8 = undefined;
    std.mem.writeInt(u64, header[0..8], generation, .little);
    std.mem.writeInt(u32, header[8..12], @intCast(payload.len), .little);
    try writeAll(pipe, &header);
    try writeAll(pipe, payload);
}

fn writeLease(pipe: Pipe, lease: failover.PrimaryLease) !void {
    var frame: [32]u8 = undefined;
    std.mem.writeInt(u64, frame[0..8], lease.node, .little);
    std.mem.writeInt(u64, frame[8..16], lease.token, .little);
    std.mem.writeInt(u64, frame[16..24], lease.issued_at_ns, .little);
    std.mem.writeInt(u64, frame[24..32], lease.expires_at_ns, .little);
    try writeAll(pipe, &frame);
}

fn readLease(pipe: Pipe) !failover.PrimaryLease {
    var frame: [32]u8 = undefined;
    try readExact(pipe, &frame);
    const lease: failover.PrimaryLease = .{
        .key = .{ .exchange_account = 2, .decision_domain = 1 },
        .node = std.mem.readInt(u64, frame[0..8], .little),
        .token = std.mem.readInt(u64, frame[8..16], .little),
        .issued_at_ns = std.mem.readInt(u64, frame[16..24], .little),
        .expires_at_ns = std.mem.readInt(u64, frame[24..32], .little),
    };
    if (lease.node == 0 or lease.token == 0 or !lease.valid(lease.issued_at_ns)) return error.InvalidDemoLease;
    return lease;
}

fn readPayloadFrame(pipe: Pipe, generation: u64, storage: []u8) ![]const u8 {
    var header: [12]u8 = undefined;
    try readExact(pipe, &header);
    const length = std.mem.readInt(u32, header[8..12], .little);
    if (generation == 0 or std.mem.readInt(u64, header[0..8], .little) != generation or
        length == 0 or length > storage.len or length > raw_ingress.max_frame_bytes)
        return error.InvalidBusinessFrame;
    try readExact(pipe, storage[0..length]);
    return storage[0..length];
}

const SnapshotFrame = struct {
    bytes: []const u8,
    barrier: u64,
    digest: [32]u8,
};

fn writeSnapshotFrame(pipe: Pipe, generation: u64, snapshot: SnapshotFrame) !void {
    if (generation == 0 or snapshot.barrier == 0 or snapshot.bytes.len == 0 or snapshot.bytes.len > durable_store.max_snapshot_bytes)
        return error.InvalidDecisionSnapshot;
    var header: [52]u8 = undefined;
    std.mem.writeInt(u64, header[0..8], generation, .little);
    std.mem.writeInt(u64, header[8..16], snapshot.barrier, .little);
    @memcpy(header[16..48], &snapshot.digest);
    std.mem.writeInt(u32, header[48..52], @intCast(snapshot.bytes.len), .little);
    try writeAll(pipe, &header);
    try writeAll(pipe, snapshot.bytes);
}

fn readSnapshotFrame(pipe: Pipe, generation: u64, storage: []u8) !SnapshotFrame {
    var header: [52]u8 = undefined;
    try readExact(pipe, &header);
    const received_generation = std.mem.readInt(u64, header[0..8], .little);
    const barrier = std.mem.readInt(u64, header[8..16], .little);
    const length = std.mem.readInt(u32, header[48..52], .little);
    if (generation == 0 or received_generation != generation or barrier == 0 or length == 0 or length > storage.len or
        length > durable_store.max_snapshot_bytes)
        return error.InvalidDecisionSnapshotFrame;
    try readExact(pipe, storage[0..length]);
    return .{ .bytes = storage[0..length], .barrier = barrier, .digest = header[16..48].* };
}

const SecurityAttributes = extern struct {
    length: u32,
    descriptor: ?*anyopaque,
    inherit: i32,
};

fn toUtf16(name: []const u8, dest: []u16) ![:0]u16 {
    if (name.len + 1 > dest.len) return error.PipeNameTooLong;
    for (name, 0..) |byte, index| dest[index] = byte;
    dest[name.len] = 0;
    return dest[0..name.len :0];
}

fn currentUserSid(allocator: std.mem.Allocator) ![]u8 {
    var token: std.os.windows.HANDLE = undefined;
    if (windows_api.OpenProcessToken(windows_api.GetCurrentProcess(), 0x0008, &token) == 0) // TOKEN_QUERY
        return error.TokenQueryFailed;
    defer std.os.windows.CloseHandle(token);
    var needed: u32 = 0;
    _ = windows_api.GetTokenInformation(token, 1, null, 0, &needed); // TokenUser
    if (needed == 0) return error.TokenQueryFailed;
    const buffer = try allocator.alloc(u8, needed);
    errdefer allocator.free(buffer);
    if (windows_api.GetTokenInformation(token, 1, buffer.ptr, needed, &needed) == 0)
        return error.TokenQueryFailed;
    const sid_ptr = @as(*align(1) const SidAndAttributes, @ptrCast(buffer)).sid;
    const sid_len = windows_api.GetLengthSid(sid_ptr);
    const sid = try allocator.alloc(u8, sid_len);
    if (windows_api.CopySid(sid_len, sid.ptr, sid_ptr) == 0) {
        allocator.free(sid);
        return error.SidCopyFailed;
    }
    allocator.free(buffer);
    return sid;
}

const SidAndAttributes = extern struct {
    sid: *anyopaque,
    attributes: u32,
};

fn buildUserOnlyDescriptor(sid: []u8, sd: []align(8) u8, acl: *?*anyopaque) !void {
    @memset(sd, 0);
    if (windows_api.InitializeSecurityDescriptor(sd.ptr, 1) == 0) return error.SecurityDescriptorFailed;
    var access = ExplicitAccess{
        .permissions = 0x10000000, // GENERIC_ALL
        .access_mode = 2, // SET_ACCESS
        .inheritance = 0,
        .trustee = .{
            .multiple = null,
            .multiple_op = 0,
            .form = 0, // TRUSTEE_IS_SID
            .kind = 1, // TRUSTEE_IS_USER
            .name = sid.ptr,
        },
    };
    if (windows_api.SetEntriesInAclW(1, @ptrCast(&access), null, acl) != 0 or acl.* == null)
        return error.AclFailed;
    if (windows_api.SetSecurityDescriptorDacl(sd.ptr, 1, acl.*, 0) == 0) return error.SecurityDescriptorFailed;
}

fn verifyClientSid(pipe: std.os.windows.HANDLE, expected: []u8, expected_pid: u32) !void {
    var process_id: u32 = 0;
    if (windows_api.GetNamedPipeClientProcessId(pipe, &process_id) == 0) return error.ClientSidRejected;
    if (process_id != expected_pid) return error.ClientSidRejected;
    const process = windows_api.OpenProcess(0x1000, 0, process_id); // PROCESS_QUERY_LIMITED_INFORMATION
    if (process == null) return error.ClientSidRejected;
    defer std.os.windows.CloseHandle(process.?);
    var token: std.os.windows.HANDLE = undefined;
    if (windows_api.OpenProcessToken(process.?, 0x0008, &token) == 0) return error.ClientSidRejected;
    defer std.os.windows.CloseHandle(token);
    var needed: u32 = 0;
    _ = windows_api.GetTokenInformation(token, 1, null, 0, &needed);
    var storage: [512]u8 = undefined;
    if (needed == 0 or needed > storage.len) return error.ClientSidRejected;
    if (windows_api.GetTokenInformation(token, 1, &storage, needed, &needed) == 0)
        return error.ClientSidRejected;
    const sid_ptr = @as(*align(1) const SidAndAttributes, @ptrCast(&storage)).sid;
    if (windows_api.EqualSid(sid_ptr, expected.ptr) == 0) return error.ClientSidRejected;
}

const ExplicitAccess = extern struct {
    permissions: u32,
    access_mode: u32,
    inheritance: u32,
    trustee: Trustee,
};

const Trustee = extern struct {
    multiple: ?*anyopaque,
    multiple_op: u32,
    form: u32,
    kind: u32,
    name: ?*anyopaque,
};

fn readGenerationFile(io: std.Io, path: []const u8) !u64 {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.GenerationFileMissing,
        else => return err,
    };
    defer file.close(io);
    var bytes: [8]u8 = undefined;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const amount = file.readStreaming(io, &.{bytes[offset..]}) catch |err| switch (err) {
            error.EndOfStream => return error.GenerationFileCorrupt,
            else => return err,
        };
        if (amount == 0) return error.GenerationFileCorrupt;
        offset += amount;
    }
    var trailing: [1]u8 = undefined;
    const extra = file.readStreaming(io, &.{&trailing}) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => return err,
    };
    if (extra != 0) return error.GenerationFileCorrupt;
    return std.mem.readInt(u64, &bytes, .little);
}

fn writeGenerationFile(io: std.Io, path: []const u8, value: u64) !void {
    var tmp_buf: [280]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .little);
    {
        var file = try std.Io.Dir.cwd().createFile(io, tmp, .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, &encoded);
        try file.sync(io);
    }
    var tmp_utf16: [280]u16 = undefined;
    var path_utf16: [280]u16 = undefined;
    const source = try toUtf16(tmp, &tmp_utf16);
    const destination = try toUtf16(path, &path_utf16);
    if (windows_api.MoveFileExW(source.ptr, destination.ptr, 0x1 | 0x8) == 0) // REPLACE_EXISTING | WRITE_THROUGH
        return error.GenerationReplaceFailed;
}

pub fn incrementGeneration(io: std.Io, path: []const u8) !u64 {
    const current = readGenerationFile(io, path) catch |err| switch (err) {
        error.GenerationFileMissing => 0,
        else => return err,
    };
    const next = std.math.add(u64, current, 1) catch return error.GenerationOverflow;
    try writeGenerationFile(io, path, next);
    return next;
}

test "Windows generation refuses corruption and advances after restart" {
    if (builtin.os.tag != .windows) return;
    var io_threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();
    var path_buf: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "C:\\Windows\\Temp\\ringwin-generation-test-{d}.bin", .{windows_api.GetCurrentProcessId()});
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer {
        var tmp_buf: [180]u8 = undefined;
        const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch unreachable;
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    }
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try std.testing.expectEqual(@as(u64, 1), try incrementGeneration(io, path));
    try std.testing.expectEqual(@as(u64, 2), try incrementGeneration(io, path));
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    try file.writeStreamingAll(io, "bad");
    file.close(io);
    try std.testing.expectError(error.GenerationFileCorrupt, incrementGeneration(io, path));
    file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    try file.writeStreamingAll(io, "123456789");
    file.close(io);
    try std.testing.expectError(error.GenerationFileCorrupt, incrementGeneration(io, path));
}

test "Windows pipe rejects another process with the same user SID" {
    if (builtin.os.tag != .windows) return;
    var io_threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer io_threaded.deinit();
    const sid = try currentUserSid(std.testing.allocator);
    defer std.testing.allocator.free(sid);
    var name_buf: [96]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "\\\\.\\pipe\\ringwin-pid-test-{d}", .{windows_api.GetCurrentProcessId()});
    const server = try listenPipe(name, sid);
    defer server.close();
    const client = try connectPipe(io_threaded.io(), name);
    defer client.close();
    try std.testing.expectError(error.ClientSidRejected, server.accept(sid, windows_api.GetCurrentProcessId() + 1));
}

fn expectStatus(pipe: Pipe, expected: Status) !void {
    const actual = try readStatus(pipe);
    if (actual != expected) return error.UnexpectedRoleStatus;
}

fn spawnRole(
    init: std.process.Init,
    executable: []const u8,
    role: Role,
    pipe_name: []const u8,
    generation: u64,
    generation_file: []const u8,
    store_dir: []const u8,
    credential_dir: []const u8,
) !std.process.Child {
    var child_env = try init.environ_map.clone(init.gpa);
    defer child_env.deinit();
    _ = child_env.swapRemove("RINGWIN_OKX_KEY");
    _ = child_env.swapRemove("RINGWIN_OKX_SECRET");
    _ = child_env.swapRemove("RINGWIN_OKX_PASSPHRASE");
    var generation_text: [24]u8 = undefined;
    const generation_arg = try std.fmt.bufPrint(&generation_text, "{d}", .{generation});
    var controller_text: [24]u8 = undefined;
    const controller_arg = try std.fmt.bufPrint(&controller_text, "{d}", .{windows_api.GetCurrentProcessId()});
    if (role == .engine) {
        return std.process.spawn(init.io, .{
            .argv = &.{
                executable,
                "--verify-role",
                roleName(role),
                "--pipe",
                pipe_name,
                "--generation",
                generation_arg,
                "--generation-file",
                generation_file,
                "--controller-pid",
                controller_arg,
                "--store-dir",
                store_dir,
                "--credential-dir",
                credential_dir,
            },
            .stdin = .pipe,
            .environ_map = &child_env,
            .stdout = .inherit,
            .stderr = .inherit,
        });
    }
    if ((role == .control_fence or role == .market_feed or role == .execution_gateway) and store_dir.len != 0) {
        return std.process.spawn(init.io, .{
            .argv = &.{ executable, "--verify-role", roleName(role), "--pipe", pipe_name, "--generation", generation_arg, "--generation-file", generation_file, "--controller-pid", controller_arg, "--store-dir", store_dir },
            .stdin = .ignore,
            .environ_map = &child_env,
            .stdout = .inherit,
            .stderr = .inherit,
        });
    }
    return std.process.spawn(init.io, .{
        .argv = &.{
            executable,
            "--verify-role",
            roleName(role),
            "--pipe",
            pipe_name,
            "--generation",
            generation_arg,
            "--generation-file",
            generation_file,
            "--controller-pid",
            controller_arg,
        },
        .stdin = .ignore,
        .environ_map = &child_env,
        .stdout = .inherit,
        .stderr = .inherit,
    });
}

fn spawnDemoExecutionRole(
    init: std.process.Init,
    executable: []const u8,
    pipe_name: []const u8,
    generation: u64,
    generation_file: []const u8,
    store_dir: []const u8,
) !std.process.Child {
    var generation_text: [24]u8 = undefined;
    const generation_arg = try std.fmt.bufPrint(&generation_text, "{d}", .{generation});
    var controller_text: [24]u8 = undefined;
    const controller_arg = try std.fmt.bufPrint(&controller_text, "{d}", .{windows_api.GetCurrentProcessId()});
    return std.process.spawn(init.io, .{
        .argv = &.{ executable, "--verify-role", "execution_gateway", "--pipe", pipe_name, "--generation", generation_arg, "--generation-file", generation_file, "--controller-pid", controller_arg, "--store-dir", store_dir, "--demo-transport" },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
}

fn spawnDemoUncredentialedRole(
    init: std.process.Init,
    executable: []const u8,
    role: Role,
    pipe_name: []const u8,
    generation: u64,
    generation_file: []const u8,
    store_dir: []const u8,
) !std.process.Child {
    if (role != .market_feed and role != .control_fence) return error.InvalidRole;
    var child_env = try init.environ_map.clone(init.gpa);
    defer child_env.deinit();
    _ = child_env.swapRemove("RINGWIN_OKX_KEY");
    _ = child_env.swapRemove("RINGWIN_OKX_SECRET");
    _ = child_env.swapRemove("RINGWIN_OKX_PASSPHRASE");
    var generation_text: [24]u8 = undefined;
    const generation_arg = try std.fmt.bufPrint(&generation_text, "{d}", .{generation});
    var controller_text: [24]u8 = undefined;
    const controller_arg = try std.fmt.bufPrint(&controller_text, "{d}", .{windows_api.GetCurrentProcessId()});
    return std.process.spawn(init.io, .{
        .argv = &.{ executable, "--verify-role", roleName(role), "--pipe", pipe_name, "--generation", generation_arg, "--generation-file", generation_file, "--controller-pid", controller_arg, "--store-dir", store_dir, "--demo-transport" },
        .stdin = .ignore,
        .environ_map = &child_env,
        .stdout = .inherit,
        .stderr = .inherit,
    });
}

fn spawnDemoEngineRole(
    init: std.process.Init,
    executable: []const u8,
    pipe_name: []const u8,
    generation: u64,
    generation_file: []const u8,
    store_dir: []const u8,
    credential_dir: []const u8,
) !std.process.Child {
    var child_env = try init.environ_map.clone(init.gpa);
    defer child_env.deinit();
    _ = child_env.swapRemove("RINGWIN_OKX_KEY");
    _ = child_env.swapRemove("RINGWIN_OKX_SECRET");
    _ = child_env.swapRemove("RINGWIN_OKX_PASSPHRASE");
    var generation_text: [24]u8 = undefined;
    const generation_arg = try std.fmt.bufPrint(&generation_text, "{d}", .{generation});
    var controller_text: [24]u8 = undefined;
    const controller_arg = try std.fmt.bufPrint(&controller_text, "{d}", .{windows_api.GetCurrentProcessId()});
    return std.process.spawn(init.io, .{
        .argv = &.{ executable, "--verify-role", "engine", "--pipe", pipe_name, "--generation", generation_arg, "--generation-file", generation_file, "--controller-pid", controller_arg, "--store-dir", store_dir, "--credential-dir", credential_dir, "--demo-transport" },
        .stdin = .pipe,
        .environ_map = &child_env,
        .stdout = .inherit,
        .stderr = .inherit,
    });
}

fn stageCredentials(init: std.process.Init, credential_dir: []const u8, password: []const u8) !void {
    var store = try credential_store.CredentialStore.open(init.io, init.gpa, credential_dir);
    defer store.close(init.io);
    const metadata = try credential_store.Metadata.init(.observation, 42, .production, 4_000_000_000, "obs-win-42", "windows-node-1", "198.51.100.42");
    var material = try credential_store.SecretMaterial.init("observation-key", "observation-secret", "observation-pass");
    var read_handle: std.os.windows.HANDLE = undefined;
    var write_handle: std.os.windows.HANDLE = undefined;
    if (windows_api.CreatePipe(&read_handle, &write_handle, null, 0) == 0) return error.PasswordPipeFailed;
    var read_file: std.Io.File = .{ .handle = read_handle, .flags = .{ .nonblocking = false } };
    defer read_file.close(init.io);
    var written: u32 = 0;
    if (windows_api.WriteFile(write_handle, password.ptr, @intCast(password.len), &written, null) == 0)
        return error.PasswordPipeFailed;
    std.os.windows.CloseHandle(write_handle);
    var password_bytes: [credential_store.max_password]u8 = undefined;
    defer std.crypto.secureZero(u8, &password_bytes);
    try store.stage(init.io, metadata, &material, read_file, .restricted_fd, &password_bytes);
}

fn activateCredentials(init: std.process.Init, credential_dir: []const u8, password: []const u8) !void {
    var store = try credential_store.CredentialStore.open(init.io, init.gpa, credential_dir);
    defer store.close(init.io);
    const metadata = try credential_store.Metadata.init(.observation, 42, .production, 4_000_000_000, "obs-win-42", "windows-node-1", "198.51.100.42");
    var read_handle: std.os.windows.HANDLE = undefined;
    var write_handle: std.os.windows.HANDLE = undefined;
    if (windows_api.CreatePipe(&read_handle, &write_handle, null, 0) == 0) return error.PasswordPipeFailed;
    var read_file: std.Io.File = .{ .handle = read_handle, .flags = .{ .nonblocking = false } };
    defer read_file.close(init.io);
    var written: u32 = 0;
    if (windows_api.WriteFile(write_handle, password.ptr, @intCast(password.len), &written, null) == 0)
        return error.PasswordPipeFailed;
    std.os.windows.CloseHandle(write_handle);
    var password_bytes: [credential_store.max_password]u8 = undefined;
    defer std.crypto.secureZero(u8, &password_bytes);
    try store.activate(init.io, .observation, read_file, .restricted_fd, &password_bytes, metadata);
}

pub fn runDemoReadOnly(init: std.process.Init, executable: []const u8) !void {
    return runDemoChain(init, executable, false);
}

pub fn runDemoLive(init: std.process.Init, executable: []const u8) !void {
    if (!std.mem.eql(u8, init.environ_map.get("RINGWIN_DEMO_LIVE_AUTHORIZED") orelse "", "1"))
        return error.DemoLiveAuthorizationMissing;
    return runDemoChain(init, executable, true);
}

fn runDemoChain(init: std.process.Init, executable: []const u8, live: bool) !void {
    if (comptime !live_transport_enabled) return error.DemoTransportBuildRequired;
    if (comptime builtin.os.tag != .windows) return error.WindowsVerificationRoleRequired;
    const pid = windows_api.GetCurrentProcessId();
    var root_buf: [180]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "C:\\Windows\\Temp\\ringwin-demo-{s}-{d}", .{ if (live) "live" else "readonly", pid });
    if (!std.mem.startsWith(u8, root, "C:\\Windows\\Temp\\ringwin-demo-")) return error.InvalidVerificationPath;
    try std.Io.Dir.createDirAbsolute(init.io, root, .default_dir);
    defer if (!live) std.Io.Dir.cwd().deleteTree(init.io, root) catch {};
    var gen_buf: [220]u8 = undefined;
    const generation_file = try std.fmt.bufPrint(&gen_buf, "{s}\\generation.bin", .{root});
    var engine_buf: [220]u8 = undefined;
    const engine_dir = try std.fmt.bufPrint(&engine_buf, "{s}\\engine", .{root});
    var execution_buf: [220]u8 = undefined;
    const execution_dir = try std.fmt.bufPrint(&execution_buf, "{s}\\execution", .{root});
    var credential_buf: [220]u8 = undefined;
    const credential_dir = try std.fmt.bufPrint(&credential_buf, "{s}\\credentials", .{root});
    var fence_buf: [220]u8 = undefined;
    const fence_dir = try std.fmt.bufPrint(&fence_buf, "{s}\\fence", .{root});
    var market_buf: [220]u8 = undefined;
    const market_dir = try std.fmt.bufPrint(&market_buf, "{s}\\market", .{root});
    for ([_][]const u8{ engine_dir, execution_dir, credential_dir, fence_dir, market_dir }) |path|
        try std.Io.Dir.createDirAbsolute(init.io, path, .default_dir);
    const password = "fixture-password\n";
    try stageCredentials(init, credential_dir, password);
    try activateCredentials(init, credential_dir, password);
    const generation = try incrementGeneration(init.io, generation_file);
    var pipe_buffers: [5][96]u8 = undefined;
    var pipe_names: [5][]const u8 = undefined;
    for (&pipe_buffers, 0..) |*buffer, index|
        pipe_names[index] = try std.fmt.bufPrint(buffer, "\\\\.\\pipe\\ringwin-demo-{s}-{d}-{d}", .{ if (live) "live" else "readonly", pid, index });
    var children: [5]std.process.Child = undefined;
    var connections: [5]Pipe = undefined;
    var started: usize = 0;
    defer {
        for (connections[0..started]) |pipe| pipe.close();
        for (children[0..started]) |*child| child.kill(init.io);
    }
    for (0..5) |index| {
        children[index] = switch (index) {
            0 => try spawnDemoEngineRole(init, executable, pipe_names[index], generation, generation_file, engine_dir, credential_dir),
            1 => try spawnDemoExecutionRole(init, executable, pipe_names[index], generation, generation_file, execution_dir),
            2 => try spawnDemoUncredentialedRole(init, executable, .control_fence, pipe_names[index], generation, generation_file, fence_dir),
            3 => try spawnDemoUncredentialedRole(init, executable, .market_feed, pipe_names[index], generation, generation_file, market_dir),
            4 => try spawnRole(init, executable, .telemetry, pipe_names[index], generation, generation_file, "", ""),
            else => unreachable,
        };
        started += 1;
        if (index == 0) {
            const stdin_file = children[index].stdin orelse return error.PasswordPipeFailed;
            try stdin_file.writeStreamingAll(init.io, password);
            stdin_file.close(init.io);
            children[index].stdin = null;
        }
        connections[index] = try connectPipe(init.io, pipe_names[index]);
        try expectStatus(connections[index], .hello);
        try expectStatus(connections[index], if (index == 0) .owner_ready else .ready);
    }
    try checkTelemetry(connections[4]);
    try sendCommand(connections[2], .export_fence);
    try expectStatus(connections[2], .fence_ready);
    const lease = try readLease(connections[2]);
    for ([_]usize{ 0, 1 }) |index| {
        try sendCommand(connections[index], .install_fence);
        try writePayloadFrame(connections[index], generation, fence_dir);
        try writeLease(connections[index], lease);
        try expectStatus(connections[index], .fence_ready);
    }
    try sendCommand(connections[1], .bootstrap_private);
    try routePrivateOutput(connections[1], connections[0], generation);
    std.debug.print("windows_demo_chain: private_bootstrap=ready\n", .{});
    try sendCommand(connections[0], .verify_private);
    try expectStatus(connections[0], .private_ready);
    std.debug.print("windows_demo_chain: private_verified=ready\n", .{});
    try sendCommand(connections[2], .export_fence);
    try expectStatus(connections[2], .fence_ready);
    std.debug.print("windows_demo_chain: fence=exported\n", .{});
    const fresh_lease = try readLease(connections[2]);
    for ([_]usize{ 0, 1 }) |index| {
        try sendCommand(connections[index], .install_fence);
        try writePayloadFrame(connections[index], generation, fence_dir);
        try writeLease(connections[index], fresh_lease);
        try expectStatus(connections[index], .fence_ready);
        std.debug.print("windows_demo_chain: fence_installed={d}\n", .{index});
    }
    var buy_quote: [8]u8 = undefined;
    if (live) buy_quote = try requestDemoQuote(connections[1], .buy, 5_000);
    if (live) try refreshDemoFence(&connections, generation, fence_dir);
    try sendCommand(connections[0], .prepare_okx);
    if (live) try writeAll(connections[0], &buy_quote);
    try expectStatus(connections[0], .okx_prepared);
    std.debug.print("windows_demo_chain: decision=prepared\n", .{});
    try routeLiveMarket(connections[3], connections[0], generation);
    std.debug.print("windows_demo_chain: market=ready\n", .{});
    if (!live) {
        try sendCommand(connections[0], .seal_private);
        try expectStatus(connections[0], .private_ready);
        std.debug.print("windows_demo_chain: private=sealed\n", .{});
        if (std.mem.eql(u8, init.environ_map.get("RINGWIN_DEMO_FORCE_WS_RECONNECT") orelse "", "1")) {
            try sendCommand(connections[1], .poll_private);
            try routePrivateOutput(connections[1], connections[0], generation);
        }
    }
    if (live) try runDemoRoundTrip(&connections, generation, fence_dir, &buy_quote);
    for (&connections) |pipe| {
        try sendCommand(pipe, .drain);
        try expectStatus(pipe, .draining);
    }
    for (&connections) |pipe| {
        try sendCommand(pipe, .stop);
        try expectStatus(pipe, .stopped);
    }
    for (&children) |*child| {
        const term = try child.wait(init.io);
        if (term != .exited or term.exited != 0) return error.RoleExitedUnexpectedly;
    }
    started = 0;
    const recovered = try init.gpa.create(durable_store.WindowsFileAdapter);
    defer init.gpa.destroy(recovered);
    recovered.* = try durable_store.WindowsFileAdapter.openWindowsVerification(init.io, engine_dir);
    defer recovered.close(init.io);
    const decision = try demo_authority.Owner.recover(recovered.interface(), init.io, .{ .domain = .decision_log, .id = 91 });
    if (!decision.shard.canonical_account.valid) return error.PrivateAccountNotReady;
    var stdout_buf: [160]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buf);
    if (live) {
        if (decision.shard.economicSummary().portfolio.spot.quantity != 0 or !decision.shard.oms.openOrdersClosed())
            return error.DemoDiskRecoveryMismatch;
        try demo_authority.requireZeroDemoExposure(&decision.shard.canonical_account);
        if (decision.shard.oms.order_count != 2 or decision.shard.economic_projection.canonical_fill_evidence_count < 2)
            return error.DemoEconomicEvidenceIncomplete;
        for (decision.shard.oms.orders[0..decision.shard.oms.order_count]) |order| {
            if (order.state != .filled or order.cumulative_quantity <= 0) return error.DemoEconomicEvidenceIncomplete;
            try stdout.interface.print("windows_demo_order local_id={d} client_id={s} state=filled quantity={d}\n", .{
                order.id, order.client_order_id.slice(), order.cumulative_quantity,
            });
        }
        for (decision.shard.economic_projection.canonical_fill_evidence[0..decision.shard.economic_projection.canonical_fill_evidence_count]) |fill| {
            try stdout.interface.print("windows_demo_fill identity={d} local_order_id={d} quantity={d}\n", .{ fill.identity, fill.order_id, fill.quantity });
        }
        const digest = std.fmt.bytesToHex(decision.shard.canonicalStateDigest(), .lower);
        try stdout.interface.print("windows_demo_economics fee_micros={d} replay_digest={s} strategy_identity={d} config_version={d}\n", .{
            decision.shard.economicSummary().portfolio.fee_micros, &digest,
            decision.shard.strategy_identity,                      decision.shard.strategy_config_version,
        });
        try stdout.interface.writeAll("windows_demo_live=passed rest=ok private_ws=ok public_ws=ok roles=5 terminal=ok zero_exposure=ok production_qualification=false\n");
    } else try stdout.interface.writeAll("windows_demo_readonly=passed rest=ok private_ws=ok public_ws=ok roles=5 order_writes=0 production_qualification=false\n");
    try stdout.interface.flush();
}

fn requestDemoQuote(execution_pipe: Pipe, side: host_gateway.Side, quantity: i64) ![8]u8 {
    var request: [9]u8 = undefined;
    request[0] = @intFromEnum(side);
    std.mem.writeInt(i64, request[1..9], quantity, .little);
    try sendCommand(execution_pipe, .quote_okx);
    try writeAll(execution_pipe, &request);
    try expectStatus(execution_pipe, .okx_quote);
    var encoded: [8]u8 = undefined;
    try readExact(execution_pipe, &encoded);
    return encoded;
}

fn refreshDemoFence(connections: *[5]Pipe, generation: u64, fence_dir: []const u8) !void {
    try sendCommand(connections[2], .export_fence);
    try expectStatus(connections[2], .fence_ready);
    const lease = try readLease(connections[2]);
    for ([_]usize{ 0, 1 }) |index| {
        try sendCommand(connections[index], .install_fence);
        try writePayloadFrame(connections[index], generation, fence_dir);
        try writeLease(connections[index], lease);
        try expectStatus(connections[index], .fence_ready);
    }
}

fn inspectDemoOrder(engine_pipe: Pipe) !struct { terminal: bool, quantity: i64 } {
    try sendCommand(engine_pipe, .inspect_okx);
    try expectStatus(engine_pipe, .okx_state);
    var encoded: [9]u8 = undefined;
    try readExact(engine_pipe, &encoded);
    return .{ .terminal = encoded[0] == 1, .quantity = std.mem.readInt(i64, encoded[1..9], .little) };
}

fn sendCurrentDemoOrder(connections: *[5]Pipe, generation: u64, fence_dir: []const u8, command_bytes: [8]u8) !void {
    try checkTelemetry(connections[4]);
    try sendCommand(connections[0], .export_okx_snapshot);
    try expectStatus(connections[0], .snapshot_ready);
    var storage: [durable_store.max_snapshot_bytes]u8 = undefined;
    const snapshot = try readSnapshotFrame(connections[0], generation, &storage);
    try sendCommand(connections[1], .send_okx);
    try writeAll(connections[1], &command_bytes);
    try writeSnapshotFrame(connections[1], generation, snapshot);
    try expectStatus(connections[1], .okx_send_ready);
    try sendCommand(connections[2], .export_fence);
    try expectStatus(connections[2], .fence_ready);
    const lease = try readLease(connections[2]);
    try sendCommand(connections[0], .install_fence);
    try writePayloadFrame(connections[0], generation, fence_dir);
    try writeLease(connections[0], lease);
    try expectStatus(connections[0], .fence_ready);
    try writePayloadFrame(connections[1], generation, fence_dir);
    try writeLease(connections[1], lease);
    try routePrivateOutputUntil(connections[1], connections[0], generation, .okx_sent);
    var wire_storage: [64]u8 = undefined;
    _ = try readPayloadFrame(connections[1], generation, &wire_storage);
}

fn checkTelemetry(pipe: Pipe) !void {
    try sendCommand(pipe, .probe);
    try expectStatus(pipe, .healthy);
}

fn waitDemoTerminal(connections: *[5]Pipe, generation: u64) !void {
    for (0..16) |_| {
        try sendCommand(connections[1], .poll_private);
        try routePrivateOutput(connections[1], connections[0], generation);
        if ((try inspectDemoOrder(connections[0])).terminal) return;
    }
    return error.DemoOrderTerminalUnconfirmed;
}

fn refreshDemoRest(connections: *[5]Pipe, generation: u64) !void {
    try sendCommand(connections[1], .refresh_private);
    try routePrivateOutput(connections[1], connections[0], generation);
}

fn runDemoRoundTrip(connections: *[5]Pipe, generation: u64, fence_dir: []const u8, buy_quote: *[8]u8) !void {
    for ([_]usize{ 0, 1 }) |index| {
        try sendCommand(connections[index], .enable_risk);
        try expectStatus(connections[index], .risk_enabled);
    }
    buy_quote.* = try requestDemoQuote(connections[1], .buy, 5_000);
    try refreshDemoFence(connections, generation, fence_dir);
    try sendCommand(connections[0], .activate_okx);
    try writeAll(connections[0], buy_quote);
    try expectStatus(connections[0], .okx_activated);
    try expectStatus(connections[0], .ready);
    try routeLiveMarket(connections[3], connections[0], generation);
    try refreshDemoFence(connections, generation, fence_dir);
    buy_quote.* = try requestDemoQuote(connections[1], .buy, 5_000);
    try sendCommand(connections[0], .produce_okx_intent);
    try writeAll(connections[0], buy_quote);
    try expectStatus(connections[0], .okx_command);
    var command_bytes: [8]u8 = undefined;
    try readExact(connections[0], &command_bytes);
    try refreshDemoFence(connections, generation, fence_dir);
    try sendCurrentDemoOrder(connections, generation, fence_dir, command_bytes);
    try waitDemoTerminal(connections, generation);
    var bought = try inspectDemoOrder(connections[0]);
    if (bought.quantity < 1_000) {
        try refreshDemoRest(connections, generation);
        bought = try inspectDemoOrder(connections[0]);
    }
    if (!bought.terminal or bought.quantity < 1_000) return error.DemoBuyDidNotFillMinimum;

    const sell_quote = try requestDemoQuote(connections[1], .sell, bought.quantity);
    try refreshDemoFence(connections, generation, fence_dir);
    try sendCommand(connections[0], .cleanup_okx);
    try writeAll(connections[0], &sell_quote);
    try expectStatus(connections[0], .okx_command);
    try readExact(connections[0], &command_bytes);
    try refreshDemoFence(connections, generation, fence_dir);
    try sendCurrentDemoOrder(connections, generation, fence_dir, command_bytes);
    try waitDemoTerminal(connections, generation);
    var cleaned = try inspectDemoOrder(connections[0]);
    if (cleaned.quantity != 0) {
        try refreshDemoRest(connections, generation);
        cleaned = try inspectDemoOrder(connections[0]);
    }
    if (!cleaned.terminal or cleaned.quantity != 0) return error.DemoCleanupUnconfirmed;
    try sendCommand(connections[0], .verify_okx);
    try expectStatus(connections[0], .okx_verified);
    var digest: [32]u8 = undefined;
    try readExact(connections[0], &digest);
}

pub fn runIntegration(init: std.process.Init, executable: []const u8) !void {
    if (comptime builtin.os.tag != .windows) {
        var buffer: [128]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(init.io, &buffer);
        try stdout.interface.writeAll("windows_process_chain_verified=not_run production_qualification=false\n");
        try stdout.interface.flush();
        return;
    }

    const pid = windows_api.GetCurrentProcessId();
    var root_buf: [160]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "C:\\Windows\\Temp\\ringwin-verify-{d}", .{pid});
    std.Io.Dir.cwd().deleteTree(init.io, root) catch {};
    try std.Io.Dir.createDirAbsolute(init.io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(init.io, root) catch {};

    var gen_buf: [180]u8 = undefined;
    const generation_file = try std.fmt.bufPrint(&gen_buf, "{s}\\generation.bin", .{root});
    var store_buf: [180]u8 = undefined;
    const store_dir = try std.fmt.bufPrint(&store_buf, "{s}\\store", .{root});
    var market_buf: [180]u8 = undefined;
    const market_dir = try std.fmt.bufPrint(&market_buf, "{s}\\market", .{root});
    var execution_buf: [180]u8 = undefined;
    const execution_dir = try std.fmt.bufPrint(&execution_buf, "{s}\\execution", .{root});
    var cred_buf: [180]u8 = undefined;
    const credential_dir = try std.fmt.bufPrint(&cred_buf, "{s}\\credentials", .{root});
    var fence_buf: [180]u8 = undefined;
    const fence_dir = try std.fmt.bufPrint(&fence_buf, "{s}\\fence", .{root});
    try std.Io.Dir.createDirAbsolute(init.io, store_dir, .default_dir);
    try std.Io.Dir.createDirAbsolute(init.io, market_dir, .default_dir);
    try std.Io.Dir.createDirAbsolute(init.io, execution_dir, .default_dir);
    try std.Io.Dir.createDirAbsolute(init.io, credential_dir, .default_dir);
    try failover.runWindowsFencingVerification(init.io, fence_dir);

    const password = "fixture-password\n";
    try stageCredentials(init, credential_dir, password);
    try activateCredentials(init, credential_dir, password);

    const roles = [_]Role{ .engine, .market_feed, .execution_gateway, .telemetry, .control_fence };
    var pipes: [roles.len][96]u8 = undefined;
    var pipe_names: [roles.len][]const u8 = undefined;
    for (&pipes, 0..) |*buf, index| {
        pipe_names[index] = try std.fmt.bufPrint(buf, "\\\\.\\pipe\\ringwin-verify-{d}-{d}", .{ pid, index });
    }

    var generation = try incrementGeneration(init.io, generation_file);
    if (generation != 1) return error.GenerationNotMonotonic;

    var children: [roles.len]std.process.Child = undefined;
    var connections: [roles.len]Pipe = undefined;
    var started: usize = 0;
    defer {
        for (connections[0..started]) |pipe| pipe.close();
        for (children[0..started]) |*child| child.kill(init.io);
    }

    for (roles, 0..) |role, index| {
        children[index] = try spawnRole(init, executable, role, pipe_names[index], generation, generation_file, if (role == .control_fence) fence_dir else if (role == .market_feed) market_dir else if (role == .execution_gateway) execution_dir else store_dir, credential_dir);
        started += 1;
        if (role == .engine) {
            const stdin_file = children[index].stdin orelse return error.PasswordPipeFailed;
            try stdin_file.writeStreamingAll(init.io, password);
            stdin_file.close(init.io);
            children[index].stdin = null;
        }
        connections[index] = try connectPipe(init.io, pipe_names[index]);
        try expectStatus(connections[index], .hello);
        try expectStatus(connections[index], if (index == 0) .owner_ready else .ready);
    }
    try checkTelemetry(connections[3]);

    try sendCommand(connections[4], .export_fence);
    try expectStatus(connections[4], .fence_ready);
    const shared_lease = try readLease(connections[4]);
    for ([_]usize{ 0, 2 }) |index| {
        try sendCommand(connections[index], .install_fence);
        try writePayloadFrame(connections[index], generation, fence_dir);
        try writeLease(connections[index], shared_lease);
        try expectStatus(connections[index], .fence_ready);
    }

    try sendCommand(connections[2], .bootstrap_private);
    try routePrivateOutput(connections[2], connections[0], generation);
    try sendCommand(connections[0], .verify_private);
    try expectStatus(connections[0], .private_ready);
    try sendCommand(connections[0], .prepare_okx);
    try expectStatus(connections[0], .okx_prepared);

    for (&connections, roles) |*pipe, role| {
        if (role != .engine and role != .execution_gateway) continue;
        try sendCommand(pipe.*, .enable_risk);
        try expectStatus(pipe.*, .risk_enabled);
        if (role == .engine) try expectStatus(pipe.*, .ready);
    }

    // The controller only forwards encoded canonical output. Raw bytes are
    // persisted and translated in the market-feed role before engine ingest.
    const public_frames = [_][]const u8{
        \\{"arg":{"channel":"instruments","instType":"SPOT"},"data":[{"instType":"SPOT","instId":"BTC-USDT","state":"live","ruleType":"normal","tickSz":"0.1","lotSz":"0.00000001","minSz":"0.00001","maxLmtSz":"100","maxMktSz":"10","maxLmtAmt":"1000000","maxMktAmt":"100000","ctType":"","ctVal":"","ctValCcy":"","settleCcy":"","tradeQuoteCcyList":["USDT"],"upcChg":[],"ts":"1800000000000"}]}
        ,
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"snapshot","data":[{"asks":[["50100.1","2.0","0","3"]],"bids":[["50099.9","1.5","0","2"]],"ts":"1800000000000","seqId":"100","prevSeqId":"-1","checksum":0}]}
        ,
        \\{"arg":{"channel":"index-tickers","instId":"BTC-USDT"},"data":[{"instId":"BTC-USDT","idxPx":"50120.1","ts":"1800000000200"}]}
    };
    for (public_frames[0..2]) |frame| try routeMarketFrame(connections[1], connections[0], generation, frame);
    try sendCommand(connections[0], .activate_okx);
    try expectStatus(connections[0], .okx_activated);
    try expectStatus(connections[0], .ready);
    try routeMarketFrame(connections[1], connections[0], generation, public_frames[2]);
    try sendCommand(connections[0], .produce_okx_intent);
    try expectStatus(connections[0], .okx_command);
    var command_bytes: [8]u8 = undefined;
    try readExact(connections[0], &command_bytes);
    if (std.mem.readInt(u64, &command_bytes, .little) == 0) return error.MissingDemoCommand;
    try sendCommand(connections[0], .export_okx_snapshot);
    try expectStatus(connections[0], .snapshot_ready);
    var okx_storage: [durable_store.max_snapshot_bytes]u8 = undefined;
    const okx_snapshot = try readSnapshotFrame(connections[0], generation, &okx_storage);
    try sendCommand(connections[2], .send_okx);
    try writeAll(connections[2], &command_bytes);
    try writeSnapshotFrame(connections[2], generation, okx_snapshot);
    try routePrivateOutputUntil(connections[2], connections[0], generation, .okx_sent);
    var wire_storage: [64]u8 = undefined;
    const wire_id = try readPayloadFrame(connections[2], generation, &wire_storage);
    var order_storage: [768]u8 = undefined;
    const filled_order = try std.fmt.bufPrint(&order_storage,
        \\{{"arg":{{"channel":"orders"}},"data":[{{"instId":"BTC-USDT","ordId":"1001","clOrdId":"{s}","side":"buy","ordType":"ioc","state":"filled","tdMode":"cash","posSide":"net","reduceOnly":"false","sz":"0.0002","px":"50100.1","accFillSz":"0.0002","avgPx":"50100.1","uTime":"1800000000100","tradeId":"2001","fillSz":"0.0002","fillPx":"50100.1","fillFee":"-0.000001","fillFeeCcy":"USDT","fillTime":"1800000000100","execType":"T"}}]}}
    , .{wire_id});
    try sendCommand(connections[2], .private_ws);
    try writePayloadFrame(connections[2], generation, filled_order);
    try routePrivateOutput(connections[2], connections[0], generation);
    try sendCommand(connections[0], .verify_okx);
    try expectStatus(connections[0], .okx_verified);
    var settled_digest: [32]u8 = undefined;
    try readExact(connections[0], &settled_digest);
    try sendCommand(connections[2], .private_ws);
    try writePayloadFrame(connections[2], generation, filled_order);
    try routePrivateOutput(connections[2], connections[0], generation);
    try sendCommand(connections[0], .verify_okx);
    try expectStatus(connections[0], .okx_verified);
    var duplicate_digest: [32]u8 = undefined;
    try readExact(connections[0], &duplicate_digest);
    if (!std.mem.eql(u8, &settled_digest, &duplicate_digest)) return error.DuplicatePrivateChangedState;
    try sendCommand(connections[2], .private_ws);
    try writePayloadFrame(connections[2], generation,
        \\{"arg":{"channel":"account"},"eventType":"snapshot","curPage":1,"lastPage":true,"data":[{"uTime":"1800000000101","totalEq":"25","adjEq":"25","imr":"0","mmr":"0","mgnRatio":"","isoEq":"0","details":[{"ccy":"USDT","cashBal":"14.979979","availBal":"14.979979","eq":"14.979979","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"},{"ccy":"BTC","cashBal":"0.0002","availBal":"0.0002","eq":"0.0002","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}]}]}
    );
    try routePrivateOutput(connections[2], connections[0], generation);
    try sendCommand(connections[0], .verify_okx);
    try expectStatus(connections[0], .okx_verified);
    try readExact(connections[0], &settled_digest);

    // The controller routes bytes only. The execution role verifies the
    // sealed snapshot itself; it never receives a caller-built order proof.
    try sendCommand(connections[0], .export_snapshot);
    try expectStatus(connections[0], .snapshot_ready);
    var snapshot_storage: [durable_store.max_snapshot_bytes]u8 = undefined;
    const snapshot = try readSnapshotFrame(connections[0], generation, &snapshot_storage);
    try sendCommand(connections[2], .load_snapshot);
    try writeSnapshotFrame(connections[2], generation, snapshot);
    try expectStatus(connections[2], .snapshot_accepted);

    for (&connections) |pipe| {
        try sendCommand(pipe, .drain);
        try expectStatus(pipe, .draining);
    }
    for (&connections) |pipe| {
        try sendCommand(pipe, .stop);
        try expectStatus(pipe, .stopped);
    }
    for (&children) |*child| {
        const term = try child.wait(init.io);
        if (term != .exited or term.exited != 0) return error.RoleExitedUnexpectedly;
    }
    started = 0;

    // Reopen the decision store after the engine process has exited. This
    // checks persisted state, rather than replaying the fixture in memory.
    const recovered_store = try init.gpa.create(durable_store.WindowsFileAdapter);
    defer init.gpa.destroy(recovered_store);
    recovered_store.* = try durable_store.WindowsFileAdapter.openWindowsVerification(init.io, store_dir);
    defer recovered_store.close(init.io);
    const recovered_owner = try demo_authority.Owner.recover(recovered_store.interface(), init.io, .{ .domain = .decision_log, .id = 78 });
    if (recovered_owner.shard.oms.orders[0].state != .filled or
        recovered_owner.shard.economicSummary().portfolio.swap.quantity != 10)
        return error.DecisionDiskRecoveryMismatch;
    const recovered_okx = try demo_authority.Owner.recover(recovered_store.interface(), init.io, .{ .domain = .decision_log, .id = 91 });
    if (recovered_okx.shard.oms.orders[0].state != .filled or
        recovered_okx.shard.oms.orders[0].instrument != okx_venue.btc_usdt_spot or
        recovered_okx.shard.economicSummary().portfolio.spot.quantity != 20_000 or
        !std.mem.eql(u8, &settled_digest, &recovered_okx.shard.canonicalStateDigest()))
        return error.OkxDiskRecoveryMismatch;
    const recovered_market = try init.gpa.create(durable_store.WindowsFileAdapter);
    defer init.gpa.destroy(recovered_market);
    recovered_market.* = try durable_store.WindowsFileAdapter.openWindowsVerification(init.io, market_dir);
    defer recovered_market.close(init.io);
    const MarketReplay = struct {
        count: usize = 0,
        fn consume(ptr: *anyopaque, sequence: u64, record: @import("okx_public_market.zig").RawIngressRecord, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (sequence == 0 or sequence > public_frames.len or record.source_session != 90 or
                !std.mem.eql(u8, bytes, public_frames[sequence - 1]))
                return error.MarketRawRecoveryMismatch;
            self.count += 1;
        }
    };
    var market_replay: MarketReplay = .{};
    try raw_ingress.replayCommitted(recovered_market.interface(), init.io, .{ .domain = .raw_ingress, .id = 90 }, .{
        .ptr = &market_replay,
        .consume_fn = MarketReplay.consume,
    });
    if (market_replay.count != public_frames.len) return error.MarketRawRecoveryMismatch;
    const recovered_execution = try init.gpa.create(durable_store.WindowsFileAdapter);
    defer init.gpa.destroy(recovered_execution);
    recovered_execution.* = try durable_store.WindowsFileAdapter.openWindowsVerification(init.io, execution_dir);
    defer recovered_execution.close(init.io);
    const private_raw = try recovered_execution.interface().recover(init.io, .{ .domain = .raw_ingress, .id = 93 });
    if (private_raw.gate != .open or private_raw.last_sequence < 5 or
        private_raw.last_sequence != private_raw.committed_barrier)
        return error.PrivateRawRecoveryMismatch;

    generation = try incrementGeneration(init.io, generation_file);
    if (generation != 2) return error.GenerationNotMonotonic;
    var forced = try spawnRole(init, executable, .control_fence, pipe_names[0], generation, generation_file, fence_dir, credential_dir);
    var forced_pipe = try connectPipe(init.io, pipe_names[0]);
    defer forced_pipe.close();
    try expectStatus(forced_pipe, .hello);
    try expectStatus(forced_pipe, .ready);
    try sendCommand(forced_pipe, .drain);
    try expectStatus(forced_pipe, .draining);
    try expectStatus(forced_pipe, .forced_stop);
    try expectStatus(forced_pipe, .stopped);
    const forced_term = try forced.wait(init.io);
    if (forced_term != .exited or forced_term.exited != 0) return error.ForcedStopFailed;

    generation = try incrementGeneration(init.io, generation_file);
    if (generation != 3) return error.GenerationNotMonotonic;
    var restart = try spawnRole(init, executable, .telemetry, pipe_names[4], generation, generation_file, store_dir, credential_dir);
    var restart_pipe = try connectPipe(init.io, pipe_names[4]);
    defer restart_pipe.close();
    try expectStatus(restart_pipe, .hello);
    try expectStatus(restart_pipe, .ready);
    try sendCommand(restart_pipe, .drain);
    try expectStatus(restart_pipe, .draining);
    try sendCommand(restart_pipe, .stop);
    try expectStatus(restart_pipe, .stopped);
    const restart_term = try restart.wait(init.io);
    if (restart_term != .exited or restart_term.exited != 0) return error.RestartRecoveryFailed;

    try rejectUnauthorizedSid(init.io);
    try rejectInvalidFrame(init, executable, pipe_names[3], generation, generation_file);
    try rejectSnapshotFrame(init, executable, pipe_names[2], generation, generation_file, true);
    try rejectSnapshotFrame(init, executable, pipe_names[2], generation, generation_file, false);
    try rejectSnapshotMismatch(init, executable, pipe_names[2], generation, generation_file, snapshot, true);
    try rejectSnapshotMismatch(init, executable, pipe_names[2], generation, generation_file, snapshot, false);
    const dispatch_before = try recovered_execution.interface().recover(init.io, .{ .domain = .control, .id = 92 });
    try rejectOkxSendSnapshot(init, executable, pipe_names[2], generation, generation_file, execution_dir, okx_snapshot, command_bytes, true);
    try rejectOkxSendSnapshot(init, executable, pipe_names[2], generation, generation_file, execution_dir, okx_snapshot, command_bytes, false);
    const dispatch_after = try recovered_execution.interface().recover(init.io, .{ .domain = .control, .id = 92 });
    if (dispatch_after.committed_barrier != dispatch_before.committed_barrier) return error.ReplayDispatchMutated;
    try rejectBusinessGeneration(init, executable, pipe_names[1], generation, generation_file, market_dir);
    generation = try rejectStaleRoleGeneration(init, executable, pipe_names[3], generation, generation_file);

    const evidence: production_contract.WindowsChainEvidence = .{};
    if (production_contract.isWindowsProcessChainVerified(evidence) or production_contract.windowsChainPermitsProduction(evidence))
        return error.ProductionQualificationLeak;

    var output_buffer: [512]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    const okx_digest = std.fmt.bytesToHex(settled_digest, .lower);
    try output.interface.print(
        "windows_okx_offline=passed venue=okx product=BTC-USDT-spot strategy_identity={d} config_version={d} roles=5 ipc=named_pipe market_raw_frames={d} private_raw_barrier={d} spot_atoms={d} replay_digest={s} replay_send_capability=false role_ownership=passed durable_recovery=passed\n",
        .{ recovered_okx.shard.strategy_identity, recovered_okx.shard.strategy_config_version, market_replay.count, private_raw.committed_barrier, recovered_okx.shard.economicSummary().portfolio.spot.quantity, &okx_digest },
    );
    try output.interface.print(
        "windows_process_chain_verified=blocked historical_simulated_chain=passed historical_disk_recovery=passed historical_snapshot_transfer=passed okx_market_role=offline_passed okx_private_bootstrap=offline_passed okx_host_gateway_private=offline_passed windows_fencing_store=passed offline=blocked read_only=not_run demo_live=not_run production_qualification=false revision=not_recorded environment=none venue=simulated account_scope=none product=none strategy=none configuration=none roles=5 generation={d} ipc=named_pipe bounded_queue={d} power_loss_qualified=false linux_admission_equivalent=false\n",
        .{ generation, max_control_queue },
    );
    try output.interface.flush();
}

fn routePrivateOutput(execution_pipe: Pipe, engine_pipe: Pipe, generation: u64) !void {
    return routePrivateOutputUntil(execution_pipe, engine_pipe, generation, .private_ready);
}

fn routePrivateOutputUntil(execution_pipe: Pipe, engine_pipe: Pipe, generation: u64, final: Status) !void {
    while (true) switch (try readStatus(execution_pipe)) {
        .private_ready, .okx_sent => |status| if (status == final) return else return error.PrivateBootstrapFailed,
        .private_output => {
            var count: [1]u8 = undefined;
            try readExact(execution_pipe, &count);
            if (count[0] == 0 or count[0] > canonical.max_events_per_adapter_batch) return error.InvalidPrivateBatch;
            try sendCommand(engine_pipe, .ingest_private);
            try writeAll(engine_pipe, &count);
            for (0..count[0]) |_| {
                var encoded: [4096]u8 = undefined;
                const event = try readPayloadFrame(execution_pipe, generation, &encoded);
                try writePayloadFrame(engine_pipe, generation, event);
            }
            try expectStatus(engine_pipe, .private_applied);
        },
        else => return error.PrivateBootstrapFailed,
    };
}

fn routeMarketFrame(market_pipe: Pipe, engine_pipe: Pipe, generation: u64, raw: []const u8) !void {
    try sendCommand(market_pipe, .produce_market);
    try writePayloadFrame(market_pipe, generation, raw);
    try expectStatus(market_pipe, .market_output);
    try routeMarketOutput(market_pipe, engine_pipe, generation);
}

fn routeMarketOutput(market_pipe: Pipe, engine_pipe: Pipe, generation: u64) !void {
    var count: [1]u8 = undefined;
    try readExact(market_pipe, &count);
    if (count[0] == 0 or count[0] > canonical.max_events_per_adapter_batch) return error.UnexpectedMarketOutput;
    try sendCommand(engine_pipe, .ingest_market);
    try writeAll(engine_pipe, &count);
    for (0..count[0]) |_| {
        var encoded: [4096]u8 = undefined;
        const event = try readPayloadFrame(market_pipe, generation, &encoded);
        try writePayloadFrame(engine_pipe, generation, event);
    }
    try expectStatus(engine_pipe, .market_applied);
}

fn routeLiveMarket(market_pipe: Pipe, engine_pipe: Pipe, generation: u64) !void {
    try sendCommand(market_pipe, .poll_market);
    while (true) switch (try readStatus(market_pipe)) {
        .market_output => try routeMarketOutput(market_pipe, engine_pipe, generation),
        .market_ready => return,
        else => return error.PublicMarketNotReady,
    };
}

fn rejectUnauthorizedSid(io: std.Io) !void {
    var sid: [12]u8 = .{ 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }; // S-1-0-0 null SID
    const name = "\\\\.\\pipe\\ringwin-verify-denied";
    var server = listenPipe(name, sid[0..]) catch return; // creating a pipe for another SID may fail closed
    defer server.close();
    const client = connectPipe(io, name);
    if (client) |pipe| {
        pipe.close();
        return error.UnauthorizedSidAccepted;
    } else |_| {}
}

fn rejectInvalidFrame(
    init: std.process.Init,
    executable: []const u8,
    pipe_name: []const u8,
    generation: u64,
    generation_file: []const u8,
) !void {
    var child = try spawnRole(init, executable, .telemetry, pipe_name, generation, generation_file, "", "");
    var pipe = try connectPipe(init.io, pipe_name);
    defer pipe.close();
    try expectStatus(pipe, .hello);
    try expectStatus(pipe, .ready);
    try writeAll(pipe, &[_]u8{0});
    const status = readStatus(pipe) catch {
        const term = try child.wait(init.io);
        if (term == .exited) return;
        return error.InvalidFrameNotRejected;
    };
    if (status != .failed) return error.InvalidFrameNotRejected;
    _ = child.wait(init.io) catch {};
}

fn rejectSnapshotFrame(
    init: std.process.Init,
    executable: []const u8,
    pipe_name: []const u8,
    generation: u64,
    generation_file: []const u8,
    stale: bool,
) !void {
    var child = try spawnRole(init, executable, .execution_gateway, pipe_name, generation, generation_file, "", "");
    var pipe = try connectPipe(init.io, pipe_name);
    defer pipe.close();
    try expectStatus(pipe, .hello);
    try expectStatus(pipe, .ready);
    try sendCommand(pipe, .enable_risk);
    try expectStatus(pipe, .risk_enabled);
    try sendCommand(pipe, .load_snapshot);
    if (stale) {
        var header: [52]u8 = @splat(0);
        std.mem.writeInt(u64, header[0..8], generation - 1, .little);
        std.mem.writeInt(u64, header[8..16], 1, .little);
        std.mem.writeInt(u32, header[48..52], 1, .little);
        try writeAll(pipe, &header);
    } else {
        try writeSnapshotFrame(pipe, generation, .{ .bytes = &[_]u8{0}, .barrier = 1, .digest = @splat(0) });
    }
    try expectStatus(pipe, .failed);
    const term = try child.wait(init.io);
    if (term != .exited or term.exited == 0) return error.InvalidSnapshotFrameAccepted;
}

fn rejectSnapshotMismatch(
    init: std.process.Init,
    executable: []const u8,
    pipe_name: []const u8,
    generation: u64,
    generation_file: []const u8,
    valid: SnapshotFrame,
    wrong_barrier: bool,
) !void {
    var child = try spawnRole(init, executable, .execution_gateway, pipe_name, generation, generation_file, "", "");
    var pipe = try connectPipe(init.io, pipe_name);
    defer pipe.close();
    try expectStatus(pipe, .hello);
    try expectStatus(pipe, .ready);
    try sendCommand(pipe, .enable_risk);
    try expectStatus(pipe, .risk_enabled);
    try sendCommand(pipe, .load_snapshot);
    var mismatched = valid;
    if (wrong_barrier) mismatched.barrier += 1 else mismatched.digest[0] ^= 1;
    try writeSnapshotFrame(pipe, generation, mismatched);
    try expectStatus(pipe, .failed);
    const term = try child.wait(init.io);
    if (term != .exited or term.exited == 0) return error.MismatchedSnapshotAccepted;
}

fn rejectOkxSendSnapshot(
    init: std.process.Init,
    executable: []const u8,
    pipe_name: []const u8,
    generation: u64,
    generation_file: []const u8,
    execution_dir: []const u8,
    valid: SnapshotFrame,
    command_bytes: [8]u8,
    wrong_digest: bool,
) !void {
    var child = try spawnRole(init, executable, .execution_gateway, pipe_name, generation, generation_file, execution_dir, "");
    var pipe = try connectPipe(init.io, pipe_name);
    defer pipe.close();
    try expectStatus(pipe, .hello);
    try expectStatus(pipe, .ready);
    try sendCommand(pipe, .enable_risk);
    try expectStatus(pipe, .risk_enabled);
    try sendCommand(pipe, .send_okx);
    try writeAll(pipe, &command_bytes);
    var mismatched = valid;
    if (wrong_digest) mismatched.digest[0] ^= 1;
    try writeSnapshotFrame(pipe, generation, mismatched);
    try expectStatus(pipe, .failed);
    const term = try child.wait(init.io);
    if (term != .exited or term.exited == 0) return error.MismatchedOkxSnapshotSent;
}

fn rejectBusinessGeneration(
    init: std.process.Init,
    executable: []const u8,
    pipe_name: []const u8,
    generation: u64,
    generation_file: []const u8,
    market_dir: []const u8,
) !void {
    var child = try spawnRole(init, executable, .market_feed, pipe_name, generation, generation_file, market_dir, "");
    var pipe = try connectPipe(init.io, pipe_name);
    defer pipe.close();
    try expectStatus(pipe, .hello);
    try expectStatus(pipe, .ready);
    try sendCommand(pipe, .produce_market);
    try writePayloadFrame(pipe, generation - 1, "{}");
    try expectStatus(pipe, .failed);
    const term = try child.wait(init.io);
    if (term != .exited or term.exited == 0) return error.StaleMarketGenerationAccepted;
}

fn rejectStaleRoleGeneration(
    init: std.process.Init,
    executable: []const u8,
    pipe_name: []const u8,
    generation: u64,
    generation_file: []const u8,
) !u64 {
    var child = try spawnRole(init, executable, .telemetry, pipe_name, generation, generation_file, "", "");
    var pipe = try connectPipe(init.io, pipe_name);
    defer pipe.close();
    try expectStatus(pipe, .hello);
    try expectStatus(pipe, .ready);
    const next = try incrementGeneration(init.io, generation_file);
    if (next != generation + 1) return error.GenerationNotMonotonic;
    try sendCommand(pipe, .drain);
    try expectStatus(pipe, .failed);
    const term = try child.wait(init.io);
    if (term != .exited or term.exited == 0) return error.StaleRoleGenerationAccepted;
    return next;
}

const windows_api = if (builtin.os.tag == .windows) struct {
    const BOOL = i32;
    const DWORD = u32;
    const HANDLE = std.os.windows.HANDLE;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
    extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
    extern "kernel32" fn MoveFileExW(source: [*:0]const u16, destination: [*:0]const u16, flags: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn CreateNamedPipeW(
        name: [*:0]const u16,
        open_mode: DWORD,
        pipe_mode: DWORD,
        max_instances: DWORD,
        out_buffer: DWORD,
        in_buffer: DWORD,
        default_timeout: DWORD,
        security: ?*SecurityAttributes,
    ) callconv(.winapi) HANDLE;
    extern "kernel32" fn ConnectNamedPipe(pipe: HANDLE, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn WaitNamedPipeW(name: [*:0]const u16, timeout: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn CreateFileW(
        name: [*:0]const u16,
        access: DWORD,
        share: DWORD,
        security: ?*SecurityAttributes,
        disposition: DWORD,
        flags: DWORD,
        template: ?HANDLE,
    ) callconv(.winapi) HANDLE;
    extern "kernel32" fn WriteFile(handle: HANDLE, buffer: [*]const u8, length: DWORD, written: *DWORD, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn ReadFile(handle: HANDLE, buffer: [*]u8, length: DWORD, read: *DWORD, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn PeekNamedPipe(
        pipe: HANDLE,
        buffer: ?[*]u8,
        buffer_size: DWORD,
        bytes_read: ?*DWORD,
        bytes_available: ?*DWORD,
        bytes_left: ?*DWORD,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
    extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;
    extern "kernel32" fn SetConsoleCtrlHandler(handler: *const fn (u32) callconv(.winapi) BOOL, add: BOOL) callconv(.winapi) BOOL;
    extern "kernel32" fn CreatePipe(read_pipe: *HANDLE, write_pipe: *HANDLE, attributes: ?*SecurityAttributes, size: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn GetNamedPipeClientProcessId(pipe: HANDLE, process_id: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn OpenProcess(access: DWORD, inherit: BOOL, process_id: DWORD) callconv(.winapi) ?HANDLE;
    extern "advapi32" fn OpenProcessToken(process: HANDLE, access: DWORD, token: *HANDLE) callconv(.winapi) BOOL;
    extern "advapi32" fn GetTokenInformation(token: HANDLE, class: DWORD, info: ?*anyopaque, length: DWORD, needed: *DWORD) callconv(.winapi) BOOL;
    extern "advapi32" fn GetLengthSid(sid: *anyopaque) callconv(.winapi) DWORD;
    extern "advapi32" fn CopySid(dest_len: DWORD, dest: [*]u8, source: *anyopaque) callconv(.winapi) BOOL;
    extern "advapi32" fn EqualSid(a: *anyopaque, b: *anyopaque) callconv(.winapi) BOOL;
    extern "advapi32" fn InitializeSecurityDescriptor(sd: *anyopaque, revision: DWORD) callconv(.winapi) BOOL;
    extern "advapi32" fn SetSecurityDescriptorDacl(sd: *anyopaque, present: BOOL, dacl: ?*anyopaque, defaulted: BOOL) callconv(.winapi) BOOL;
    extern "advapi32" fn SetEntriesInAclW(count: DWORD, list: *anyopaque, old_acl: ?*anyopaque, new_acl: *?*anyopaque) callconv(.winapi) DWORD;
    extern "kernel32" fn LocalFree(mem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
} else struct {
    const HANDLE = *anyopaque;
    const BOOL = i32;
    const DWORD = u32;
};

test "verification bounded queue fails closed" {
    var queue: BoundedQueue = .{};
    for (0..max_control_queue) |_| try queue.push(.drain);
    try std.testing.expectError(error.Backpressure, queue.push(.stop));
    for (0..max_control_queue) |_| try std.testing.expectEqual(Command.drain, queue.pop().?);
    try std.testing.expect(queue.pop() == null);
}

test "Windows chain evidence cannot permit production" {
    const evidence: production_contract.WindowsChainEvidence = .{ .production_qualification = true };
    try std.testing.expect(!production_contract.isWindowsProcessChainVerified(evidence));
    try std.testing.expect(!production_contract.windowsChainPermitsProduction(evidence));
}
