//! Shared Windows/Linux real files for the shared 500-combination synthetic workload.
const std = @import("std");
const builtin = @import("builtin");
const observation = @import("core_observation_capacity_acceptance.zig");
const durable = @import("durable_store.zig");
const demo = @import("demo_authority.zig");
const trading = @import("trading_shard.zig");
const execution = @import("execution_gateway.zig");
const codec = @import("snapshot_codec.zig");
const history = @import("business_history.zig");

fn require(ok: bool) !void {
    if (!ok) return error.WindowsObservationInvariant;
}

const RouteContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: *durable.LinuxFileAdapter,
    owner: *demo.Owner,
    gateway: *execution.Gateway,
    scratch: []u8,
    feed: observation.OfflineFeed,
    adapter: observation.RestingVenue,
    recovery_ns: i128 = 0,

    fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8, route: usize, seed: bool) !*@This() {
        const self = try allocator.create(@This());
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.io = io;
        self.recovery_ns = 0;
        self.feed = .{ .source = .{ .venue_identity = observation.venues[route], .stream = 200 + route } };
        self.adapter = .{ .source = .{ .venue_identity = observation.venues[route], .account = 100 + route, .stream = 300 + route } };
        self.file = try allocator.create(durable.LinuxFileAdapter);
        errdefer allocator.destroy(self.file);
        @memset(std.mem.asBytes(self.file), 0);
        if (!seed) {
            const existing = try std.Io.Dir.openDirAbsolute(io, path, .{});
            existing.close(io);
        }
        if (builtin.os.tag == .linux) try self.file.initLinux(io, path) else try self.file.initWindowsVerification(io, path);
        errdefer self.file.close(io);
        if (seed) {
            const directory = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
            defer directory.close(io);
            var entries = directory.iterate();
            if (try entries.next(io) != null) return error.SeedDirectoryNotEmpty;
        }
        self.owner = try allocator.create(demo.Owner);
        errdefer allocator.destroy(self.owner);
        self.gateway = try allocator.create(execution.Gateway);
        errdefer allocator.destroy(self.gateway);
        self.gateway.init();
        self.scratch = try allocator.alloc(u8, durable.max_snapshot_bytes);
        errdefer allocator.free(self.scratch);
        self.gateway.dispatch_snapshot_buffer = self.scratch;
        const decision: durable.StreamIdentity = .{ .domain = .decision_log, .id = 100 + route };
        if (seed) {
            try demo.Owner.bootstrapInto(self.owner, self.file.interface(), io, decision);
            try observation.initializeRoute(self.owner, &self.feed, &self.adapter, self.gateway, route);
            try observation.placeSelected(self.owner, &self.feed, &self.adapter, self.gateway, route);
            try self.owner.checkpointWithScratch(self.scratch);
            try self.gateway.checkpointDurableDispatchWithBuffer(self.scratch);
        } else {
            const start = std.Io.Clock.awake.now(io).nanoseconds;
            try demo.Owner.recoverInto(self.owner, self.file.interface(), io, decision);
            try self.adapter.adapter().start(.{ .venue = observation.venues[route], .environment = .simulation, .exchange_account = 100 + route, .adapter_session = 1, .request_capacity = 1, .output_capacity = 1 });
            try self.gateway.add(.{ .account = 100 + route, .adapter = self.adapter.adapter(), .venue_identity = observation.venues[route], .environment = .simulation, .supported_products = 3, .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1, .supports_venue_reduce_only = true } });
            try self.gateway.attachRecoveredDurableDispatch(self.file.interface(), io, .{ .domain = .control, .id = 400 + route });
            self.recovery_ns = std.Io.Clock.awake.now(io).nanoseconds - start;
            try require(self.adapter.sends == 0);
        }
        return self;
    }

    fn close(self: *@This()) void {
        self.file.close(self.io);
        self.allocator.destroy(self.file);
        self.allocator.destroy(self.owner);
        self.allocator.destroy(self.gateway);
        self.allocator.free(self.scratch);
        self.allocator.destroy(self);
    }
};

pub const ShardReport = struct {
    shard: usize,
    venue: u64,
    account: u128,
    observed: u16 = 125,
    spot_observed: u16 = 75,
    perpetual_observed: u16 = 50,
    selected_live: u16 = 25,
    live: u16,
    terminal: u16,
    adapter_queue: u8,
    snapshot_bytes: usize,
    stored_bytes: u64,
    stored_files: u64,
    barrier: u64,
    recovery_ns: i128,
    digest: [64]u8,
    economic_digest: [64]u8,
    ledger_digest: [64]u8,
    ownership_digest: [64]u8,
    mapping_digest: [64]u8,
    history_root: [64]u8,
    history_generation: u64,
    reservation_atoms: i128,
    cash_atoms: i128,
    exchange_cash_atoms: i128,
    inventory_atoms: i128,
    spot_quantity: i64,
    funding_perpetual_quantity: i64,
    cross_perpetual_quantity: i64,
    fee_atoms: i128,
    ledger_count: u8,
    accepted: u16,
    unknown: u16,
    sends: usize,
    recovery_sends: u64 = 0,
};

fn report(context: *RouteContext, route: usize, path: []const u8) !ShardReport {
    const shard = &context.owner.shard;
    const economic = &shard.economic_projection;
    try require(shard.exchange_account_identity == 100 + route);
    try require(shard.instrument_registry.count == 125 and shard.oms.order_count == 26);
    try require(shard.oms.liveOrderCount() == 25 and shard.oms.retainedTerminalOrderCount() == 1);
    var mapping = std.crypto.hash.sha2.Sha256.init(.{});
    var ownership = std.crypto.hash.sha2.Sha256.init(.{});
    var bytes: [16 * 1024]u8 = undefined;
    var spot_count: u16 = 0;
    var perpetual_count: u16 = 0;
    for (0..125) |index| {
        const entry = shard.instrument_registry.get(observation.instrument(route, index)) orelse return error.MissingObservedInstrument;
        try require(entry.venue == observation.venues[route]);
        try require(entry.trading_enabled == observation.selected(index));
        if (index < 75) {
            try require(entry.product == .spot);
            spot_count += 1;
        } else {
            try require(entry.product == .isolated_linear_usdt);
            perpetual_count += 1;
        }
        const price = shard.canonical_market.get(entry.instrument) orelse return error.MissingObservedMarket;
        try require(price.health == .healthy);
        const encoded = try codec.encodeBare(&bytes, .{ entry.venue, entry.product, entry.instrument });
        mapping.update(encoded);
        // The identity encodes Venue and product; explicitly reject aliasing
        // with any prior route or instrument in the same 500-key namespace.
        for (0..route + 1) |prior_route| {
            const stop: usize = if (prior_route == route) index else 125;
            for (0..stop) |prior_index| try require(entry.instrument != observation.instrument(prior_route, prior_index));
        }
    }
    try require(spot_count == 75 and perpetual_count == 50);
    for (shard.oms.command_history[0..shard.oms.command_history_count]) |command| {
        try require(command.authority.exchange_account == 100 + route);
        try require(command.authority.virtual_portfolio == shard.portfolio_identity);
        try require(command.authority.complete());
        const entry = shard.instrument_registry.get(command.instrument) orelse return error.MissingCommandInstrument;
        try require(entry.venue == observation.venues[route]);
        const client = context.gateway.acceptedClientOrderIdFromShard(shard, command.command_id) orelse return error.MissingPersistedDispatch;
        ownership.update(try codec.encodeBare(&bytes, .{ command, client }));
    }
    const spot = shard.instrument_registry.get(observation.instrument(route, 0)).?;
    const perpetual = shard.instrument_registry.get(observation.instrument(route, 75)).?;
    try require(spot.rules.base_asset == perpetual.rules.base_asset);
    try require(@as(i128, 100_000) * spot.rules.quantity_numerator * perpetual.rules.quantity_denominator == @as(i128, 10) * perpetual.rules.quantity_numerator * spot.rules.quantity_denominator);
    const spot_quantity = economic.portfolio.positionForInstrument(spot.instrument).quantity;
    const funding_quantity = economic.portfolio.positionForInstrument(perpetual.instrument).quantity;
    const cross_quantity = economic.portfolio.positionForInstrument(observation.instrument(route, 76)).quantity;
    try require(spot_quantity == 100_000 and funding_quantity == -10);
    try require(cross_quantity == (if (route == 1) @as(i64, -10) else 10));
    try require(economic.portfolio.spotInventoryAtoms(1000) == 99_999);
    try require(economic.exchange.spotInventoryAtoms(1000) == 99_999);
    var mapping_digest: [32]u8 = undefined;
    var ownership_digest: [32]u8 = undefined;
    mapping.final(&mapping_digest);
    ownership.final(&ownership_digest);
    const ledger = try codec.encodeBare(&bytes, economic.ledger_summary);
    const encoded = try context.owner.committedSnapshot(context.scratch);
    const archive = try context.file.interface().archiveReceipt(context.io, context.owner.stream);
    const dir = try std.Io.Dir.openDirAbsolute(context.io, path, .{ .iterate = true });
    defer dir.close(context.io);
    var iterator = dir.iterate();
    var stored_bytes: u64 = 0;
    var stored_files: u64 = 0;
    while (try iterator.next(context.io)) |entry| {
        if (entry.kind != .file) return error.UnexpectedObservationStoreEntry;
        stored_bytes += try @import("file_acceptance_runtime.zig").fileBytes(dir, context.io, entry.name);
        stored_files += 1;
    }
    return .{ .shard = route, .venue = observation.venues[route], .account = shard.exchange_account_identity, .live = shard.oms.liveOrderCount(), .terminal = shard.oms.retainedTerminalOrderCount(), .adapter_queue = @intFromBool(context.adapter.source.pending != null), .snapshot_bytes = encoded.len, .stored_bytes = stored_bytes, .stored_files = stored_files, .barrier = shard.authoritativeBarrier(), .recovery_ns = context.recovery_ns, .digest = std.fmt.bytesToHex(shard.canonicalStateDigest(), .lower), .economic_digest = std.fmt.bytesToHex(economic.digest(), .lower), .ledger_digest = std.fmt.bytesToHex(history.hash(ledger), .lower), .ownership_digest = std.fmt.bytesToHex(ownership_digest, .lower), .mapping_digest = std.fmt.bytesToHex(mapping_digest, .lower), .history_root = std.fmt.bytesToHex(archive.ordered_root, .lower), .history_generation = shard.checkpointGeneration(), .reservation_atoms = try shard.activeReservationAtoms(), .cash_atoms = economic.portfolio.usdt_balance_atoms, .exchange_cash_atoms = economic.exchange.usdt_balance_atoms, .inventory_atoms = economic.portfolio.spotInventoryAtoms(1000), .spot_quantity = spot_quantity, .funding_perpetual_quantity = funding_quantity, .cross_perpetual_quantity = cross_quantity, .fee_atoms = economic.portfolio.fee_atoms, .ledger_count = economic.ledger_count, .accepted = context.gateway.accepted_dispatch_count, .unknown = context.gateway.uncertain_dispatch_count, .sends = context.adapter.sends };
}

pub const Report = struct {
    schema: u16 = 1,
    mode: []const u8,
    seed: u64 = 0x20261008,
    unique_combinations: u16 = 500,
    funding_pairs: u8 = 4,
    cross_venue_pairs: u8 = 1,
    market_making_live: u16 = 90,
    independent_risk: bool = true,
    synthetic_fencing: bool = true,
    production_qualification: bool = false,
    shards: [4]ShardReport,
    send_count: usize = 0,
    recovery_send_count: u64 = 0,
};

pub fn runProtocol(allocator: std.mem.Allocator, io: std.Io, mode: []const u8, path: []const u8) !Report {
    if (builtin.os.tag != .windows and builtin.os.tag != .linux) return error.NativeFilePlatformRequired;
    if (!std.fs.path.isAbsolute(path)) return error.AbsoluteDirectoryRequired;
    const seed = std.mem.eql(u8, mode, "seed");
    if (!seed and !std.mem.eql(u8, mode, "recover")) return error.InvalidWindowsObservationMode;
    if (seed) std.Io.Dir.createDirAbsolute(io, path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var result: Report = .{ .mode = mode, .shards = undefined };
    for (0..4) |route| {
        var child_buffer: [1024]u8 = undefined;
        const child = try std.fmt.bufPrint(&child_buffer, "{s}{s}shard-{d}", .{ path, std.fs.path.sep_str, route });
        const context = try RouteContext.open(allocator, io, child, route, seed);
        defer context.close();
        result.shards[route] = try report(context, route, child);
        result.send_count += context.adapter.sends;
    }
    try require(result.shards[0].venue != result.shards[1].venue);
    try require(result.shards[0].cross_perpetual_quantity == -result.shards[1].cross_perpetual_quantity);
    var live: u16 = 0;
    var terminal: u16 = 0;
    for (result.shards) |shard| {
        live += shard.live;
        terminal += shard.terminal;
    }
    try require(live == 100 and terminal == 4);
    if (!seed) try require(result.send_count == 0);
    return result;
}

pub fn run(init: std.process.Init, mode: []const u8, path: []const u8) !void {
    return @import("file_acceptance_runtime.zig").run(runCurrentThread, init, mode, path);
}

fn runCurrentThread(init: std.process.Init, mode: []const u8, path: []const u8) !void {
    const result = try runProtocol(init.gpa, init.io, mode, path);
    var buffer: [16 * 1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    try std.json.Stringify.value(result, .{}, &output.interface);
    try output.interface.writeByte('\n');
    try output.interface.flush();
}

test "Native file observation file protocol reuses the public 500 combination route seam" {
    _ = observation.initializeRoute;
    _ = observation.placeSelected;
}

test "Native file observation file 500 distinct combinations recover three actual synthetic categories" {
    if (builtin.os.tag != .windows and builtin.os.tag != .linux) return error.SkipZigTest;
    var temp = std.testing.tmpDir(.{});
    var completed = false;
    defer if (completed) temp.cleanup();
    var path_buffer: [1024]u8 = undefined;
    const path = path_buffer[0..try temp.dir.realPath(std.testing.io, &path_buffer)];
    const seeded = try runProtocol(std.testing.allocator, std.testing.io, "seed", path);
    const recovered = try runProtocol(std.testing.allocator, std.testing.io, "recover", path);
    try std.testing.expectEqual(@as(usize, 108), seeded.send_count);
    try std.testing.expectEqual(@as(usize, 0), recovered.send_count);
    for (seeded.shards, recovered.shards) |before, after| {
        try std.testing.expectEqualSlices(u8, &before.digest, &after.digest);
        try std.testing.expectEqualSlices(u8, &before.economic_digest, &after.economic_digest);
        try std.testing.expectEqualSlices(u8, &before.ownership_digest, &after.ownership_digest);
        try std.testing.expectEqualSlices(u8, &before.mapping_digest, &after.mapping_digest);
        try std.testing.expectEqualSlices(u8, &before.ledger_digest, &after.ledger_digest);
    }
    completed = true;
}
