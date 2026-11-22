//! Execution role for committed DecisionDomain commands in a simulation deployment.
const std = @import("std");
const canonical = @import("../model/canonical_event.zig");
const durable = @import("../persistence/durable_store.zig");
const execution = @import("../execution/execution_gateway.zig");
const trading = @import("../trading/trading_shard.zig");
const shard_event = @import("../trading/trading_shard_event.zig");
const SimulatedVenue = @import("../adapters/simulated/simulated_venue.zig").SimulatedVenue;

const Config = struct {
    environment: enum { simulation },
    deployment_digest: []const u8,
    dispatch_stream: u64,
    initialize_dispatch: bool = false,
    ioc_fee_atoms: i128 = 0,
    reducing_ioc_rebate_atoms: i128 = 0,
};

pub const GatewayRole = struct {
    store: durable.LinuxFileAdapter,
    gateway: execution.Gateway,
    shard: trading.TradingShard,
    view: trading.TradingShard,
    adapters: [execution.max_routes]SimulatedVenue = undefined,
    accounts: [execution.max_routes]u128 = @splat(0),
    count: usize = 0,
    barrier: u64 = 0,
    digest: [32]u8,
    ioc_fee_atoms: i128,
    reducing_ioc_rebate_atoms: i128,

    pub fn open(init: std.process.Init, dir: std.Io.Dir, path: []const u8) !?*GatewayRole {
        var buffer: [1024]u8 = undefined;
        const bytes = dir.readFile(init.io, "gateway.json", &buffer) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        if (bytes.len == buffer.len) return error.InvalidGatewayConfiguration;
        const parsed = try std.json.parseFromSlice(Config, init.gpa, bytes, .{});
        defer parsed.deinit();
        if (parsed.value.dispatch_stream == 0 or parsed.value.ioc_fee_atoms < 0 or parsed.value.reducing_ioc_rebate_atoms < 0)
            return error.InvalidGatewayConfiguration;
        const role = try init.gpa.create(GatewayRole);
        errdefer init.gpa.destroy(role);
        role.count = 0;
        role.barrier = 0;
        role.ioc_fee_atoms = parsed.value.ioc_fee_atoms;
        role.reducing_ioc_rebate_atoms = parsed.value.reducing_ioc_rebate_atoms;
        _ = try std.fmt.hexToBytes(&role.digest, parsed.value.deployment_digest);
        role.store = .{ .dir = undefined };
        try role.store.initLinux(init.io, path);
        errdefer role.store.close(init.io);
        role.gateway.init();
        try role.gateway.pinDeploymentDigest(role.digest);
        const stream: durable.StreamIdentity = .{ .domain = .control, .id = parsed.value.dispatch_stream };
        // Recovery preserves sent command identities. An unavailable or
        // inconsistent dispatch store cannot be used as a new origin.
        if (parsed.value.initialize_dispatch) {
            const marker = dir.createFile(init.io, "dispatch-initialized", .{ .exclusive = true }) catch |err| switch (err) {
                error.PathAlreadyExists => null,
                else => return err,
            };
            if (marker) |file| {
                defer file.close(init.io);
                try file.sync(init.io);
                try role.gateway.bootstrapDurableDispatch(role.store.interface(), init.io, stream);
                return role;
            }
        }
        try role.gateway.attachRecoveredDurableDispatch(role.store.interface(), init.io, stream);
        return role;
    }

    pub fn close(self: *GatewayRole, init: std.process.Init) void {
        self.store.close(init.io);
        init.gpa.destroy(self);
    }

    pub fn dispatch(self: *GatewayRole, io: std.Io, snapshot: []const u8, id: u64) !canonical.AdapterOutputBatch {
        const barrier = try trading.TradingShard.restoreSnapshotInto(&self.shard, snapshot);
        const deployment = self.shard.deployment.header orelse return error.DeploymentConfigurationRequired;
        if (barrier < self.barrier or !self.shard.deployment.sealed or self.shard.decision_domain_identity == 0 or
            !std.mem.eql(u8, &deployment.expected_digest, &self.digest)) return error.InvalidDispatchSnapshot;
        self.barrier = barrier;
        const command = self.shard.oms.findCommand(id) orelse return error.UnknownCommand;
        const account = command.authority.exchange_account;
        const deployed = self.shard.deployment.account(account) orelse return error.InvalidDispatchSnapshot;
        if (deployed.environment != .simulation) return error.UnsupportedExecutionEnvironment;
        const instrument = self.shard.pairInstrument(account, command.instrument) orelse return error.InvalidDispatchSnapshot;
        const capability = instrument.capability orelse return error.InvalidDispatchSnapshot;
        try self.shard.copyAccountViewInto(&self.view, account);
        const pos = self.view.currentNetExchangePosition(command.instrument) orelse return error.InvalidDispatchSnapshot;
        const index = for (self.accounts[0..self.count], 0..) |known, index| {
            if (known == account) break index;
        } else try self.addRoute(account, deployed.venue, instrument, capability);
        for (self.shard.canonical_ingress_cursors[0..self.shard.canonical_ingress_cursor_count]) |cursor| {
            if (cursor.scope.venue == deployed.venue and cursor.scope.account == account and cursor.identity.stream == 1)
                self.adapters[index].next_event_identity = @max(self.adapters[index].next_event_identity, try std.math.add(u64, cursor.identity.sequence, 1));
        }
        const monotonic: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
        if (monotonic > command.authority.dispatch_deadline_monotonic_ns) return error.CommittedDispatchExpired;
        const utc: u64 = @intCast(std.Io.Clock.real.now(io).nanoseconds);
        self.adapters[index].receipt_times = .{
            .receive_utc_ns = utc,
            .monotonic_ns = monotonic,
            .audit_utc_ns = utc,
            .source_utc_ns = utc,
        };
        try self.gateway.observeAuthorityFromShard(&self.shard, .{
            .account = account,
            .effective_trading_authority = self.view.operational_state.effectiveTradingAuthority(),
            .reservation_identity = command.reservation_identity,
            .reservation = command.reservation,
            .primary_lease_expires_at_monotonic_ns = command.authority.dispatch_deadline_monotonic_ns,
            .fencing_token = self.shard.fencing_token,
            .exchange_position = pos,
            .authority_barrier = barrier,
        });
        if (try self.gateway.sendFromShard(&self.shard, id, monotonic) != .accepted) return error.DispatchNotAccepted;
        var batch = (try self.adapters[index].adapter().tryDrain()) orelse return error.MissingVenueResult;
        for (batch.events[0..batch.len]) |*record| {
            if (record.event == .fill) record.event.fill.venue_fill_time_utc_ns = utc;
        }
        return batch;
    }

    fn addRoute(self: *GatewayRole, account: u128, venue: u64, instrument: trading.InstrumentEntry, capability: shard_event.CapabilityProfileActivation) !usize {
        if (self.count == self.adapters.len) return error.GatewayRouteCapacity;
        const index = self.count;
        const adapter = &self.adapters[index];
        adapter.* = .{
            .ioc_fee_atoms = self.ioc_fee_atoms,
            .reducing_ioc_rebate_atoms = self.reducing_ioc_rebate_atoms,
        };
        const interface = adapter.adapter();
        try interface.start(.{
            .environment = .simulation,
            .venue = venue,
            .exchange_account = account,
            .adapter_session = capability.adapter_session,
            .request_capacity = 1,
            .output_capacity = 1,
            .asset_definitions = self.view.activatedAssets(),
            .instrument_definitions = self.view.instrument_registry,
            .native_settlement_atoms = instrument.margin.native_settlement_atoms,
        });
        try self.gateway.add(.{
            .account = account,
            .adapter = interface,
            .venue_identity = venue,
            .supported_products = execution.productMask(@enumFromInt(@intFromEnum(instrument.product))),
            .capability = .{
                .version = capability.version,
                .rules_version = capability.rules_version,
                .config_version = capability.config_version,
                .session = capability.adapter_session,
                .supports_place = capability.supports_place,
                .supports_cancel = capability.supports_cancel,
                .supports_native_amend = capability.supports_native_amend,
                .supports_venue_reduce_only = capability.supports_venue_reduce_only,
                .supports_post_only = capability.supports_post_only,
                .supports_market_protection = capability.supports_market_protection,
            },
        });
        self.accounts[index] = account;
        self.count += 1;
        return index;
    }
};
