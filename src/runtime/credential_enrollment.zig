//! Native secret entry for the existing control plane. Only ciphertext and
//! public binding metadata may leave this process.
const std = @import("std");
const credentials = @import("../security/credential_store.zig");

pub const Config = struct {
    venue: credentials.Venue,
    kind: credentials.CredentialKind,
    account: u64,
    environment: @import("production_contract.zig").Environment,
    expires_at_unix: u64,
    credential_id: []const u8,
    node_id: []const u8,
    egress_ip: []const u8,
    version: u64 = 1,
    generation: u64 = 1,
    state: credentials.CredentialState = .staged,

    pub fn metadata(self: Config) !credentials.Metadata {
        var result = try credentials.Metadata.init(self.kind, self.account, self.environment, self.expires_at_unix, self.credential_id, self.node_id, self.egress_ip);
        result.venue = self.venue;
        result.can_trade = self.kind == .execution;
        result.version = self.version;
        result.generation = self.generation;
        result.state = self.state;
        try credentials.validateBoundMetadata(result);
        return result;
    }
};

pub fn run(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    const operation = args.next() orelse return error.CredentialOperationRequired;
    const input_path = args.next() orelse return error.CredentialMetadataOrPackageRequired;
    const root = args.next() orelse return error.AbsoluteCredentialRootRequired;
    if (!std.fs.path.isAbsolute(root)) return error.AbsoluteCredentialRootRequired;
    var kind: credentials.InputKind = .tty;
    if (args.next()) |flag| {
        if (!std.mem.eql(u8, flag, "--restricted-input")) return error.UnknownArgument;
        kind = .restricted_fd;
    }
    if (args.next() != null) return error.UnknownArgument;
    const is_import = std.mem.eql(u8, operation, "import");
    const is_enroll = std.mem.eql(u8, operation, "enroll");
    if (!is_import and !is_enroll and !std.mem.eql(u8, operation, "activate") and !std.mem.eql(u8, operation, "retire") and !std.mem.eql(u8, operation, "revoke")) return error.UnknownCredentialOperation;
    // The file contains public JSON or ciphertext, never plaintext secrets.
    const input = try std.Io.Dir.cwd().readFileAlloc(init.io, input_path, init.gpa, .limited(8192));
    defer init.gpa.free(input);
    var parsed: ?std.json.Parsed(Config) = null;
    defer if (parsed) |*value| value.deinit();
    var metadata = if (is_import) try credentials.inspectEncrypted(input) else blk: {
        parsed = try std.json.parseFromSlice(Config, init.gpa, input, .{});
        break :blk try parsed.?.value.metadata();
    };
    const now = std.Io.Clock.real.now(init.io).toSeconds();
    if (now < 0) return error.ClockOutOfRange;
    if (is_enroll and (metadata.state != .staged or metadata.generation != 1 or metadata.expires_at_unix <= now)) return error.InvalidInitialState;
    var store = try credentials.CredentialStore.openScoped(init.io, init.gpa, root, metadata);
    defer store.close(init.io);
    const stdin = std.Io.File.stdin();
    if (is_enroll) {
        try store.enroll(init.io, metadata, stdin, kind);
    } else if (is_import) {
        metadata = try store.importEncrypted(init.io, input, stdin, kind, @intCast(now));
    } else {
        var password: [credentials.max_password]u8 = undefined;
        if (kind == .tty) try std.Io.File.stderr().writeStreamingAll(init.io, "Encryption password: ");
        if (std.mem.eql(u8, operation, "activate")) {
            try store.activate(init.io, metadata.kind, stdin, kind, &password, metadata);
            metadata.state = .active;
        } else if (std.mem.eql(u8, operation, "retire")) {
            try store.retire(init.io, metadata.kind, stdin, kind, &password, metadata);
            metadata.state = .retiring;
        } else {
            try store.revoke(init.io, metadata.kind, stdin, kind, &password, metadata);
            metadata.state = .revoked;
        }
        metadata.generation += 1;
    }
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try std.json.Stringify.value(.{
        .venue = @tagName(metadata.venue),
        .account = metadata.account,
        .credential_id = metadata.credentialId(),
        .version = metadata.version,
        .generation = metadata.generation,
        .state = @tagName(metadata.state),
        .authenticated = true,
        .trading_enabled = false,
    }, .{}, &stdout.interface);
    try stdout.interface.writeAll("\n");
    try stdout.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    try run(init, &args);
}

test "enrollment configuration binds venue account purpose and environment" {
    const base: Config = .{ .venue = .binance, .kind = .execution, .account = 7, .environment = .testnet, .expires_at_unix = 4_000_000_000, .credential_id = "key-7", .node_id = "node", .egress_ip = "203.0.113.7" };
    const metadata = try base.metadata();
    try std.testing.expect(metadata.can_trade and !metadata.can_withdraw and metadata.venue == .binance);
    var invalid = base;
    invalid.venue = .legacy;
    try std.testing.expectError(error.InvalidCredentialMetadata, invalid.metadata());
    invalid = base;
    invalid.account = 0;
    try std.testing.expectError(error.InvalidCredentialMetadata, invalid.metadata());
}
