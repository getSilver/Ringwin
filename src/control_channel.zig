//! Control-plane command channel: signed command envelopes delivered over
//! localhost TCP pull or an emergency directory drop, verified once at the
//! host seam and applied through each TradingShard's authoritative journal.
//!
//! Envelope wire format (all integers little-endian):
//!   u8   envelope_version (=1)
//!   [32]u8 HMAC-SHA256 over (version byte || canonical command bytes)
//!   canonical command bytes, matching the shard control_command codec order.
//!
//! Frame format on the wire: u32 payload length, then payload; length 0 is
//! the end-of-poll terminator.

const std = @import("std");
const operational = @import("operational.zig");

pub const ControlCommand = operational.ControlCommand;
pub const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
pub const Sha256 = std.crypto.hash.sha2.Sha256;

pub const envelope_version: u8 = 1;
pub const mac_len = Hmac.mac_length;
/// 5 x u128 + 2 x u64 + 1 x i64 + 2 x u8 = 106 bytes.
pub const command_bytes_len = @sizeOf(u128) * 5 +
    @sizeOf(u64) * 2 + @sizeOf(i64) + @sizeOf(u8) * 2;
pub const envelope_len = 1 + mac_len + command_bytes_len;
pub const key_len = 32;

pub const ChannelError = error{
    BadEnvelopeLength,
    BadEnvelopeVersion,
    AuthenticationFailed,
    UnknownCommandKind,
    ContentHashMismatch,
};

fn putInt(buffer: []u8, offset: *usize, comptime T: type, value: T) void {
    std.mem.writeInt(T, buffer[offset.*..][0..@sizeOf(T)], value, .little);
    offset.* += @sizeOf(T);
}

fn getInt(buffer: []const u8, offset: *usize, comptime T: type) !T {
    if (buffer.len - offset.* < @sizeOf(T)) return error.UnknownCommandKind;
    const value = std.mem.readInt(T, buffer[offset.*..][0..@sizeOf(T)], .little);
    offset.* += @sizeOf(T);
    return value;
}

/// Encodes the canonical command bytes; matches trading_shard's codec order.
pub fn encodeCommand(dest: *[command_bytes_len]u8, command: ControlCommand) void {
    var offset: usize = 0;
    putInt(dest, &offset, u128, command.command_identity);
    putInt(dest, &offset, u128, command.content_hash);
    putInt(dest, &offset, u128, command.target_identity);
    putInt(dest, &offset, u64, command.expected_version);
    putInt(dest, &offset, u64, command.expires_at);
    putInt(dest, &offset, u8, @intFromEnum(command.kind));
    putInt(dest, &offset, i64, command.target_position);
    putInt(dest, &offset, u128, command.referenced_latch_identity);
    putInt(dest, &offset, u8, @intFromBool(command.risk_warning_acknowledged));
    putInt(dest, &offset, u128, command.risk_warning_identity);
}

pub fn decodeCommand(src: *const [command_bytes_len]u8) ChannelError!ControlCommand {
    var offset: usize = 0;
    return .{
        .command_identity = try getInt(src, &offset, u128),
        .content_hash = try getInt(src, &offset, u128),
        .target_identity = try getInt(src, &offset, u128),
        .expected_version = try getInt(src, &offset, u64),
        .expires_at = try getInt(src, &offset, u64),
        .kind = std.enums.fromInt(operational.CommandKind, try getInt(src, &offset, u8)) orelse return error.UnknownCommandKind,
        .target_position = try getInt(src, &offset, i64),
        .referenced_latch_identity = try getInt(src, &offset, u128),
        .risk_warning_acknowledged = (try getInt(src, &offset, u8)) == 1,
        .risk_warning_identity = try getInt(src, &offset, u128),
    };
}

/// Deterministic content hash bound to every business field except itself.
pub fn contentHash(command_in: ControlCommand) u128 {
    var command = command_in;
    command.content_hash = 0;
    var encoded: [command_bytes_len]u8 = undefined;
    encodeCommand(&encoded, command);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(&encoded, &digest, .{});
    return std.mem.readInt(u128, digest[0..@sizeOf(u128)], .little);
}

fn macMessage(version_byte: u8, command_bytes: *const [command_bytes_len]u8) [1 + command_bytes_len]u8 {
    var message: [1 + command_bytes_len]u8 = undefined;
    message[0] = version_byte;
    @memcpy(message[1..], command_bytes);
    return message;
}

pub const Envelope = struct {
    bytes: [envelope_len]u8,

    /// Prepends the u32 length prefix for framed transport.
    pub fn frame(self: *const Envelope, dest: *[4 + envelope_len]u8) []const u8 {
        std.mem.writeInt(u32, dest[0..4], envelope_len, .little);
        @memcpy(dest[4 .. 4 + envelope_len], &self.bytes);
        return dest[0 .. 4 + envelope_len];
    }
};

/// Signs one command; the deterministic content hash is computed here so a
/// signed envelope is always self-consistent.
pub fn sign(command_in: ControlCommand, key: *const [key_len]u8) Envelope {
    var command = command_in;
    command.content_hash = contentHash(command_in);
    var envelope: Envelope = .{ .bytes = undefined };
    var command_bytes: [command_bytes_len]u8 = undefined;
    encodeCommand(&command_bytes, command);
    envelope.bytes[0] = envelope_version;
    @memcpy(envelope.bytes[1 + mac_len ..], &command_bytes);
    const message = macMessage(envelope.bytes[0], &command_bytes);
    Hmac.create(envelope.bytes[1 .. 1 + mac_len], &message, key);
    return envelope;
}

/// Verifies MAC, decodes and checks the content hash binding.
pub fn verify(bytes: []const u8, key: *const [key_len]u8) ChannelError!ControlCommand {
    if (bytes.len != envelope_len) return error.BadEnvelopeLength;
    if (bytes[0] != envelope_version) return error.BadEnvelopeVersion;
    var expected: [mac_len]u8 = undefined;
    var command_bytes: [command_bytes_len]u8 = undefined;
    @memcpy(&command_bytes, bytes[1 + mac_len ..]);
    const message = macMessage(bytes[0], &command_bytes);
    Hmac.create(&expected, &message, key);
    if (!std.crypto.timing_safe.eql([mac_len]u8, expected, bytes[1 .. 1 + mac_len].*))
        return error.AuthenticationFailed;
    const command = try decodeCommand(&command_bytes);
    if (command.content_hash != contentHash(command)) return error.ContentHashMismatch;
    return command;
}

/// Transport-independent expiry precheck before any shard sees the command.
pub fn checkExpiry(command: ControlCommand, now: u64) error{ControlCommandExpired}!void {
    if (now > command.expires_at) return error.ControlCommandExpired;
}

/// One authoritative destination shard for routed commands.
pub const ShardApplier = struct {
    context: *anyopaque,
    apply: *const fn (context: *anyopaque, command: ControlCommand) anyerror!void,
};

pub const Route = struct {
    target_identity: u128,
    applier: ShardApplier,
};

/// Routes a verified command to its owning shard by target identity.
pub const Router = struct {
    routes: []const Route,

    pub fn deliver(self: *const Router, command: ControlCommand) anyerror!void {
        for (self.routes) |route| {
            if (route.target_identity == command.target_identity)
                return route.applier.apply(route.applier.context, command);
        }
        return error.CrossShardDelivery;
    }
};

pub const Stats = struct {
    accepted: u32 = 0,
    duplicate: u32 = 0,
    expired: u32 = 0,
    rejected: u32 = 0,
};

/// Verifies and applies one framed payload, classifying the outcome.
pub fn ingestPayload(
    payload: []const u8,
    key: *const [key_len]u8,
    now: u64,
    router: *const Router,
    stats: *Stats,
) void {
    const command = verify(payload, key) catch |err| {
        if (@import("builtin").mode == .Debug)
            std.debug.print("[channel] verify reject: {}\n", .{err});
        stats.rejected += 1;
        return;
    };
    checkExpiry(command, now) catch {
        stats.expired += 1;
        return;
    };
    if (router.deliver(command)) {
        stats.accepted += 1;
    } else |err| switch (err) {
        // An already-applied duplicate leaves no fact to journal.
        error.InputProducedNoFact => stats.duplicate += 1,
        else => stats.rejected += 1,
    }
}

/// One poll round against the control plane: send the request byte, then read
/// frames until the zero-length terminator or connection end.
pub fn pullOnce(
    io: std.Io,
    stream: std.Io.net.Stream,
    key: *const [key_len]u8,
    now: u64,
    router: *const Router,
    stats: *Stats,
) !void {
    var write_buffer: [64]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll("P");
    try writer.interface.flush();

    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var length_bytes: [4]u8 = undefined;
    var payload: [envelope_len]u8 = undefined;
    while (true) {
        reader.interface.readSliceAll(&length_bytes) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        const length = std.mem.readInt(u32, &length_bytes, .little);
        if (length == 0) return;
        if (length != envelope_len) return error.UnexpectedFrameLength;
        try reader.interface.readSliceAll(&payload);
        ingestPayload(&payload, key, now, router, stats);
    }
}

/// Drains every pending `*.cmd` envelope from an emergency drop directory;
/// accepted files are renamed to `.done`, rejected files stay for audit.
pub fn drainDropDirectory(
    io: std.Io,
    dir: std.Io.Dir,
    key: *const [key_len]u8,
    now: u64,
    router: *const Router,
    stats: *Stats,
) !void {
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".cmd")) continue;
        var file = dir.openFile(io, entry.name, .{ .mode = .read_only }) catch continue;
        var read_buffer: [envelope_len]u8 = undefined;
        var reader = file.reader(io, &read_buffer);
        var payload: [envelope_len]u8 = undefined;
        const read_ok = blk: {
            reader.interface.readSliceAll(&payload) catch break :blk false;
            break :blk true;
        };
        // Close before renaming: Windows denies rename of open files.
        file.close(io);
        if (!read_ok) {
            stats.rejected += 1;
            continue;
        }
        const before = stats.*;
        ingestPayload(&payload, key, now, router, stats);
        if (stats.accepted == before.accepted and stats.duplicate == before.duplicate) continue;
        var done_name_buffer: [256]u8 = undefined;
        if (entry.name.len + 5 > done_name_buffer.len) {
            stats.rejected += 1;
            continue;
        }
        @memcpy(done_name_buffer[0..entry.name.len], entry.name);
        @memcpy(done_name_buffer[entry.name.len..][0..5], ".done");
        dir.rename(entry.name, dir, done_name_buffer[0 .. entry.name.len + 5], io) catch {};
    }
}

const trading = @import("trading_shard.zig");

const test_key: [key_len]u8 = blk: {
    var key_bytes: [key_len]u8 = undefined;
    @memset(&key_bytes, 0x42);
    break :blk key_bytes;
};

fn testKey() *const [key_len]u8 {
    return &test_key;
}

test "sign and verify roundtrip rejects tampering and wrong keys" {
    const key = testKey();
    const command: ControlCommand = .{
        .command_identity = 11,
        .content_hash = 0,
        .target_identity = 7,
        .expected_version = 3,
        .expires_at = 100,
        .kind = .kill_switch,
        .referenced_latch_identity = 99,
    };
    const envelope = sign(command, key);
    const verified = try verify(&envelope.bytes, key);
    try std.testing.expectEqual(command.command_identity, verified.command_identity);
    try std.testing.expectEqual(@as(u128, contentHash(command)), verified.content_hash);

    // Tampered command byte fails authentication.
    var tampered = envelope;
    tampered.bytes[1 + mac_len] ^= 1;
    try std.testing.expectError(error.AuthenticationFailed, verify(&tampered.bytes, key));

    // Wrong channel key fails authentication.
    var other_key: [key_len]u8 = testKey().*;
    other_key[0] ^= 0xFF;
    try std.testing.expectError(error.AuthenticationFailed, verify(&envelope.bytes, &other_key));

    // A stale content hash fails the binding check even under a valid MAC.
    var forged_command_bytes: [command_bytes_len]u8 = undefined;
    @memcpy(&forged_command_bytes, envelope.bytes[1 + mac_len ..]);
    const decoded_command = try decodeCommand(&forged_command_bytes);
    var stale_command = decoded_command;
    stale_command.content_hash = 1;
    encodeCommand(&forged_command_bytes, stale_command);
    var forged: Envelope = .{ .bytes = undefined };
    forged.bytes[0] = envelope_version;
    @memcpy(forged.bytes[1 + mac_len ..], &forged_command_bytes);
    const message = macMessage(forged.bytes[0], &forged_command_bytes);
    Hmac.create(forged.bytes[1 .. 1 + mac_len], &message, key);
    try std.testing.expectError(error.ContentHashMismatch, verify(&forged.bytes, key));

    // Expiry precheck.
    try checkExpiry(verified, 100);
    try std.testing.expectError(error.ControlCommandExpired, checkExpiry(verified, 101));
}

const ShardFixture = struct {
    shard: trading.TradingShard = .{},
    journal: trading.journal.Journal,
    now: u64 = fixture_time_base,
    next_identity: u64 = fixture_identity_base,

    fn create() ShardFixture {
        return .{ .journal = trading.journal.Journal.init() };
    }

    fn applyCommand(self: *ShardFixture, command: ControlCommand) anyerror!void {
        defer self.next_identity += 1;
        _ = try trading.applyStable(&self.shard, &self.journal, .{
            .identity = self.next_identity,
            .source_time = self.now,
            .receive_time = self.now,
            .monotonic_time = self.now,
            .wall_time = self.now,
            .time_presence = .{ .source = true, .receive = true, .monotonic = true, .wall = true },
            .payload = .{ .control_command = command },
        });
    }

    fn applier(self: *ShardFixture) ShardApplier {
        return .{ .context = self, .apply = applierApply };
    }

    fn applierApply(context: *anyopaque, command: ControlCommand) anyerror!void {
        const self: *ShardFixture = @ptrCast(@alignCast(context));
        return self.applyCommand(command);
    }
};

const fixture_time_base: u64 = 1_000_000;
const fixture_identity_base: u64 = 5000;

/// Bootstraps one shard from stopped to an authorized trading mode.
fn bootstrapTrading(fixture: *ShardFixture) !void {
    fixture.shard.fencing_token = 7;
    fixture.shard.risk_lease_micros = 100_000;
    try fixture.applyCommand(.{ .command_identity = 1, .content_hash = 1, .target_identity = fixtureTarget(), .expected_version = 0, .expires_at = std.math.maxInt(u64), .kind = .start_recovery });
    const recovery_identity = fixture.next_identity;
    fixture.next_identity += 1;
    _ = try trading.applyStable(&fixture.shard, &fixture.journal, .{
        .identity = recovery_identity,
        .source_time = fixture.now,
        .receive_time = fixture.now,
        .monotonic_time = fixture.now,
        .wall_time = fixture.now,
        .time_presence = .{ .source = true, .receive = true, .monotonic = true, .wall = true },
        .payload = .recovery_completed,
    });
    try fixture.applyCommand(.{ .command_identity = 2, .content_hash = 2, .target_identity = fixtureTarget(), .expected_version = 2, .expires_at = std.math.maxInt(u64), .kind = .enable_trading });
    try std.testing.expect(fixture.shard.operational_state.effectiveTradingAuthority());
}

fn fixtureTarget() u128 {
    return 100;
}

test "routed kill switch revokes authority and replays identically" {
    const key = testKey();
    var primary = ShardFixture.create();
    var mirror = ShardFixture.create();
    try bootstrapTrading(&primary);
    try bootstrapTrading(&mirror);

    var routes = [_]Route{
        .{ .target_identity = 100, .applier = primary.applier() },
    };
    var router = Router{ .routes = &routes };

    // Unknown target is rejected before any shard sees it.
    var stats: Stats = .{};
    const stranger = sign(.{ .command_identity = 9, .content_hash = 9, .target_identity = 999, .expected_version = 0, .expires_at = std.math.maxInt(u64), .kind = .cancel_open_orders }, key);
    ingestPayload(&stranger.bytes, key, fixture_time_base + 5, &router, &stats);
    try std.testing.expectEqual(@as(u32, 0), stats.accepted);
    try std.testing.expectEqual(@as(u32, 1), stats.rejected);

    // Kill switch is accepted, cancels orders and latches authority off.
    // Note: sign() overwrites content_hash with the deterministic binding,
    // so the mirrored fact must use the signed command, not the raw literal.
    const kill_envelope = sign(.{ .command_identity = 10, .content_hash = 10, .target_identity = 100, .expected_version = 3, .expires_at = std.math.maxInt(u64), .kind = .kill_switch, .referenced_latch_identity = 77 }, key);
    const kill_command = try verify(&kill_envelope.bytes, key);
    ingestPayload(&kill_envelope.bytes, key, fixture_time_base + 6, &router, &stats);
    try std.testing.expectEqual(@as(u32, 1), stats.accepted);
    try std.testing.expect(!primary.shard.operational_state.effectiveTradingAuthority());
    try std.testing.expect(primary.shard.operational_state.mayReduceOnly());

    // Duplicate delivery of the same identity is idempotent.
    const before = primary.shard.canonicalStateDigest();
    ingestPayload(&kill_envelope.bytes, key, fixture_time_base + 7, &router, &stats);
    try std.testing.expectEqual(@as(u32, 1), stats.duplicate);
    try std.testing.expectEqualSlices(u8, &before, &primary.shard.canonicalStateDigest());

    // The mirror shard fed identical facts directly (no envelopes) produces
    // the same canonical digest: the channel adds no second truth.
    try mirror.applyCommand(kill_command);
    try std.testing.expectEqualSlices(u8, &before, &mirror.shard.canonicalStateDigest());

    // Expired commands are classified separately.
    const late = sign(.{ .command_identity = 11, .content_hash = 11, .target_identity = 100, .expected_version = 4, .expires_at = fixture_time_base, .kind = .resolve_latch, .referenced_latch_identity = 77 }, key);
    ingestPayload(&late.bytes, key, fixture_time_base + 8, &router, &stats);
    try std.testing.expectEqual(@as(u32, 1), stats.expired);
}

test "pull once drains framed envelopes over localhost tcp" {
    const io = std.testing.io;
    const key = testKey();
    var fixture = ShardFixture.create();
    try bootstrapTrading(&fixture);
    var routes = [_]Route{.{ .target_identity = 100, .applier = fixture.applier() }};
    var router = Router{ .routes = &routes };

    const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    const ServerContext = struct {
        io: std.Io,
        server: *std.Io.net.Server,
        frames: [][4 + envelope_len]u8,

        fn run(context: *@This()) void {
            const stream = context.server.accept(context.io) catch return;
            var request: [1]u8 = undefined;
            var read_total: usize = 0;
            while (read_total < request.len) {
                var chunks = [1][]u8{request[read_total..]};
                const n = stream.read(context.io, &chunks) catch return;
                if (n == 0) return;
                read_total += n;
            }
            var write_buffer: [512]u8 = undefined;
            var writer = stream.writer(context.io, &write_buffer);
            for (context.frames) |*frame| {
                writer.interface.writeAll(frame) catch return;
            }
            writer.interface.writeAll(&[_]u8{ 0, 0, 0, 0 }) catch return;
            writer.interface.flush() catch return;
            stream.close(context.io);
        }
    };

    const enable_envelope = sign(.{ .command_identity = 20, .content_hash = 20, .target_identity = 100, .expected_version = 3, .expires_at = std.math.maxInt(u64), .kind = .cancel_open_orders }, key);
    var frames: [1][4 + envelope_len]u8 = undefined;
    _ = enable_envelope.frame(&frames[0]);

    var server_context: ServerContext = .{ .io = io, .server = &server, .frames = &frames };
    const thread = try std.Thread.spawn(.{}, ServerContext.run, .{&server_context});

    const address_with_port = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
    var stream = try address_with_port.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);

    var stats: Stats = .{};
    try pullOnce(io, stream, key, fixture_time_base + 5, &router, &stats);
    thread.join();

    try std.testing.expectEqual(@as(u32, 1), stats.accepted);
    try std.testing.expectEqual(@as(u32, 0), stats.rejected);
}

test "drop directory applies signed files and renames them done" {
    const io = std.testing.io;
    const key = testKey();
    var fixture = ShardFixture.create();
    try bootstrapTrading(&fixture);
    var routes = [_]Route{.{ .target_identity = 100, .applier = fixture.applier() }};
    var router = Router{ .routes = &routes };

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const kill = sign(.{ .command_identity = 30, .content_hash = 30, .target_identity = 100, .expected_version = 3, .expires_at = std.math.maxInt(u64), .kind = .kill_switch, .referenced_latch_identity = 55 }, key);
    var framed: [4 + envelope_len]u8 = undefined;
    const frame_bytes = kill.frame(&framed);
    var file = try tmp.dir.createFile(io, "cmd-30.cmd", .{});
    {
        defer file.close(io);
        var write_buffer: [512]u8 = undefined;
        var writer = file.writer(io, &write_buffer);
        writer.interface.writeAll(frame_bytes[4..]) catch |err| {
            std.debug.print("writeAll failed: {}\n", .{err});
            return err;
        };
        writer.interface.flush() catch |err| {
            std.debug.print("flush failed: {}\n", .{err});
            return err;
        };
    }

    var stats: Stats = .{};
    try drainDropDirectory(io, tmp.dir, key, fixture_time_base + 5, &router, &stats);
    try std.testing.expectEqual(@as(u32, 1), stats.accepted);
    try std.testing.expect(!fixture.shard.operational_state.effectiveTradingAuthority());

    // The consumed file no longer matches *.cmd, so a re-drain is a no-op.
    var second_stats: Stats = .{};
    try drainDropDirectory(io, tmp.dir, key, fixture_time_base + 6, &router, &second_stats);
    try std.testing.expectEqual(@as(u32, 0), second_stats.accepted);
}
