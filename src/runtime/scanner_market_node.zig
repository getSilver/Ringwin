//! Read-only public feed worker. Bounded private pipes; no execution adapter.
const std = @import("std");
const builtin = @import("builtin");
const durable = @import("../persistence/durable_store.zig");
const raw_ingress = @import("../persistence/raw_ingress.zig");
const capture = @import("../persistence/public_market_capture.zig");
const c = @import("../model/canonical_event.zig");
const market = @import("../market/market_feed_adapter.zig");
const okx = @import("../adapters/okx/okx_market_feed.zig");
const protocol = @import("../adapters/okx/okx_public_market.zig");
const hl = @import("../adapters/hyperliquid/hyperliquid_market_feed.zig");
const projection = @import("../market/market_projection.zig");
const depth = @import("../market/depth_snapshot.zig");

const Configuration = struct {
    schema: u16,
    session: u64,
    venue: u64,
    environment: market.Environment,
    instrument: u128,
    rules_version: u64,
    okx_instrument: protocol.Instrument = .btc_usdc_spot,
    tick: []const u8,
    lot: []const u8,
    contract_value: ?[]const u8 = null,
    binding: ?hl.Binding = null,
    raw_budget_bytes: u64 = 4 * 1024 * 1024,
};
const Request = struct {
    schema: u16,
    session: u64,
    sequence: u64,
    operation: enum { metadata, subscribe, book, disconnected, expired, audit },
    epoch: u64,
    monotonic_ns: u64,
    utc_ns: u64,
    payload: []const u8,
};
const Raw = struct {
    sink: capture.Sink,
    allocator: std.mem.Allocator,
    configuration: Configuration,
    fn append(self: *Raw, header: anytype, bytes: []const u8) !u64 {
        const metadata = try std.json.Stringify.valueAlloc(self.allocator, .{ .configuration = self.configuration, .record = header }, .{});
        defer self.allocator.free(metadata);
        return self.sink.append(self.allocator, metadata, .{
            .source_session = self.configuration.session,
            .receive_time_utc_ns = header.times.receive_time_utc_ns,
            .monotonic_time_ns = header.times.monotonic_time_ns,
            .wall_time_utc_ns = header.times.wall_time_utc_ns,
            .byte_len = @intCast(bytes.len),
            .sha256 = header.sha256,
        }, bytes);
    }
    fn ok(ptr: *anyopaque, header: protocol.RawIngressRecord, bytes: []const u8) protocol.RawSinkError!u64 {
        const self: *Raw = @ptrCast(@alignCast(ptr));
        const metadata = std.json.Stringify.valueAlloc(self.allocator, .{ .configuration = self.configuration, .record = header }, .{}) catch return error.Unavailable;
        defer self.allocator.free(metadata);
        return self.sink.append(self.allocator, metadata, header, bytes);
    }
    fn hyper(ptr: *anyopaque, header: hl.RawRecord, bytes: []const u8) hl.RawError!u64 {
        const self: *Raw = @ptrCast(@alignCast(ptr));
        return self.append(header, bytes) catch return error.Unavailable;
    }
};

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const raw_path = args.next() orelse return error.RawPathRequired;
    const storage = try init.gpa.alloc(u8, 256 * 1024 + 4);
    defer init.gpa.free(storage);
    var input = std.Io.File.stdin().reader(init.io, storage);
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    const config_len = try input.interface.takeInt(u32, .little);
    if (config_len == 0 or config_len > 65536) return error.ConfigurationCapacity;
    const parsed = try std.json.parseFromSlice(Configuration, init.gpa, try input.interface.take(config_len), .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const cfg = parsed.value;
    if (cfg.schema != 1 or cfg.session == 0 or cfg.instrument == 0 or cfg.rules_version == 0 or
        (cfg.venue != 1 and cfg.venue != 21) or
        (cfg.venue == 1 and cfg.environment != .production and cfg.environment != .demo) or
        (cfg.venue == 21 and cfg.environment != .production and cfg.environment != .testnet)) return error.InvalidConfiguration;
    if (cfg.raw_budget_bytes < 2048 or cfg.raw_budget_bytes > 4 * 1024 * 1024) return error.InvalidRawBudget;
    const store = try init.gpa.create(durable.LinuxFileAdapter);
    defer init.gpa.destroy(store);
    store.* = .{ .dir = undefined };
    if (builtin.os.tag == .windows) try store.initWindowsVerification(init.io, raw_path) else try store.initLinux(init.io, raw_path);
    defer store.close(init.io);
    var raw: Raw = .{ .allocator = init.gpa, .configuration = cfg, .sink = .{ .durable_sink = try raw_ingress.DurableSink.init(store.interface(), init.io, .{ .domain = .raw_ingress, .id = cfg.session }), .budget = cfg.raw_budget_bytes } };
    var ofeed = okx.OkxMarketFeed.init(.{ .ptr = &raw, .append_fn = Raw.ok });
    ofeed.decoder.rest_book_instrument = cfg.okx_instrument;
    var hfeed: hl.HyperliquidMarketFeed = undefined;
    if (cfg.venue == 21) hfeed = hl.HyperliquidMarketFeed.init(cfg.binding orelse return error.MissingBinding, .{ .ptr = &raw, .append_fn = Raw.hyper }, 0);
    const adapter = if (cfg.venue == 1) ofeed.adapter() else hfeed.adapter();
    try adapter.start(.{ .venue = cfg.venue, .environment = cfg.environment, .subscription_set = cfg.session, .config_version = cfg.rules_version, .session = cfg.session, .output_capacity = 32 });
    var state: projection.Projection = .{};
    var sequence: u64 = 0;
    var last_time: u64 = 0;
    var book_time: u64 = 0;
    try output.interface.writeAll("{\"ready\":true,\"schema\":1}\n");
    try output.interface.flush();
    while (true) {
        const len = input.interface.takeInt(u32, .little) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        if (len == 0 or len > 256 * 1024) return error.RequestCapacity;
        const request = try std.json.parseFromSlice(Request, init.gpa, try input.interface.take(len), .{});
        defer request.deinit();
        const r = request.value;
        if (r.schema != 1 or r.session != cfg.session or r.sequence != sequence + 1 or r.monotonic_ns < last_time) return error.InvalidInputIdentity;
        sequence = r.sequence;
        last_time = r.monotonic_ns;
        if (r.operation == .audit) {
            var audit: capture.Audit = .{ .allocator = init.gpa };
            try audit.run(store.interface(), init.io, raw.sink.durable_sink.stream);
            try std.json.Stringify.value(.{ .schema = 1, .session = cfg.session, .sequence = sequence, .captures = audit.captures, .records = audit.records, .digest = std.fmt.bytesToHex(audit.last_digest, .lower) }, .{}, &output.interface);
            try output.interface.writeByte('\n');
            try output.interface.flush();
            continue;
        }
        const times: hl.Times = .{ .receive_time_utc_ns = r.utc_ns, .wall_time_utc_ns = r.utc_ns, .monotonic_time_ns = r.monotonic_ns };
        var failure: ?[]const u8 = null;
        if (cfg.venue == 1) {
            const t: protocol.Times = .{ .receive_time_utc_ns = r.utc_ns, .wall_time_utc_ns = r.utc_ns, .monotonic_time_ns = r.monotonic_ns };
            if (r.operation == .subscribe or r.operation == .disconnected or r.operation == .expired) {
                ofeed.beginSubscription(cfg.okx_instrument, t, r.payload) catch |err| {
                    failure = @errorName(err);
                };
            } else ofeed.ingest(init.gpa, t, r.payload) catch |err| {
                failure = @errorName(err);
            };
            if (r.operation == .metadata and failure == null) {
                const rules = ofeed.rules[@intFromEnum(cfg.okx_instrument)];
                if (rules) |v| {
                    const tick = try c.Decimal.parse(cfg.tick);
                    const lot = try c.Decimal.parse(cfg.lot);
                    if (v.state != .live) failure = "InstrumentNotLive";
                    if (cfg.okx_instrument == .btc_usdt_swap) {
                        const expected = if (cfg.contract_value) |text| try c.Decimal.parse(text) else return error.MissingContractValue;
                        if (v.contract_value == null or !std.meta.eql(expected, v.contract_value.?)) failure = "ContractValueMismatch";
                    }
                    if (!std.meta.eql(tick, v.tick_size) or !std.meta.eql(lot, v.lot_size)) failure = "InstrumentRulesMismatch";
                } else failure = "MissingInstrumentRules";
            }
        } else hfeed.ingest(init.gpa, r.epoch, switch (r.operation) {
            .metadata => .metadata,
            .subscribe => .subscribe,
            .book => .book,
            .disconnected => .disconnected,
            .expired => .expired,
            .audit => unreachable,
        }, times, r.payload) catch |err| {
            failure = @errorName(err);
        };
        // Request tags are deliberately mapped by name, not shared enum ordinals.
        if (try adapter.tryDrain()) |batch| for (batch.slice()) |record| {
            if (record.event == .l2_book_snapshot or record.event == .l2_book_delta) {
                const source = record.envelope.times.source_utc_ns;
                if (source == null or source.? > r.utc_ns or r.utc_ns - source.? > 5_000_000_000) {
                    failure = "StaleSourceTime";
                } else book_time = r.monotonic_ns;
            }
            state.apply(record.event) catch |err| {
                if (failure == null) failure = @errorName(err);
            };
            if (record.event == .instrument_definition_observed) state.activateRules(record.event.instrument_definition_observed.instrument, cfg.rules_version) catch |err| {
                failure = @errorName(err);
            };
        };
        if (failure != null) state.invalidateBook(cfg.instrument) catch {};
        var wire: [depth.wire_len]u8 = undefined;
        var hex: [depth.wire_len * 2]u8 = undefined;
        var payload: ?[]const u8 = null;
        var healthy = false;
        if (state.get(cfg.instrument)) |entry| {
            healthy = entry.health == .healthy and failure == null;
            if (entry.last_book) |book| {
                var snapshot = book;
                snapshot.depth.?.visible_at_ns = book_time;
                _ = try depth.encode(&wire, snapshot);
                hex = std.fmt.bytesToHex(wire, .lower);
                payload = &hex;
            }
        }
        try std.json.Stringify.value(.{ .schema = 1, .session = cfg.session, .sequence = sequence, .healthy = healthy, .depth = payload, .failure = failure, .raw_sequence = raw.sink.durable_sink.next_sequence - 1, .raw_sha256 = std.fmt.bytesToHex(raw.sink.digest, .lower) }, .{}, &output.interface);
        try output.interface.writeByte('\n');
        try output.interface.flush();
    }
}

test {
    _ = okx;
    _ = hl;
    _ = projection;
    _ = market;
    _ = capture;
}
