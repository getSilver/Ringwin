//! Manually unlocked, file-backed credentials for the Linux production seam.
//! Observation admission never grants execution. Wallet signing is a separate
//! short-lived GatewayLease operation and does not grant trading authority.
//! Plain secret bytes never appear in metadata, evidence, logs, or argv/env APIs.

const builtin = @import("builtin");
const std = @import("std");
const production_contract = @import("../runtime/production_contract.zig");

const Aead = @import("credential_aead.zig");
const protected = @import("protected_memory.zig");
const credential_kdf = @import("credential_kdf.zig");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const max_text = 64;
pub const max_secret = 128;
pub const max_password = 256;
pub const max_payload = 512;
pub const max_file = 252 + max_payload + Aead.tag_length;

const magic: u32 = 0x34445243; // CRD4
const format_version: u16 = 1;
const header_len = 252;
const payload_tag_len = Aead.tag_length;

pub const CredentialKind = enum(u8) { observation, execution };
// Zero preserves old CRD4 files; new enrollment must bind an explicit venue.
pub const Venue = enum(u8) { legacy = 0, okx = 1, binance = 2, bybit = 3, hyperliquid = 4 };
pub const CredentialState = enum(u8) { staged, active, retiring, revoked };
pub const InputKind = enum { tty, restricted_fd, test_only };
pub const ProtectionMode = enum { native, test_bypass };
pub const AdmissionState = enum { ready, denied };

pub const Metadata = struct {
    venue: Venue = .legacy,
    kind: CredentialKind,
    state: CredentialState = .staged,
    version: u64 = 1,
    generation: u64 = 1,
    expires_at_unix: u64,
    account: u64,
    environment: production_contract.Environment,
    endpoint_environment: production_contract.Environment,
    credential_id: [max_text]u8 = @splat(0),
    credential_id_len: u8 = 0,
    node_id: [max_text]u8 = @splat(0),
    node_id_len: u8 = 0,
    egress_ip: [max_text]u8 = @splat(0),
    egress_ip_len: u8 = 0,
    can_read: bool = true,
    can_trade: bool = false,
    can_withdraw: bool = false,

    pub fn init(kind: CredentialKind, account: u64, environment: production_contract.Environment, expires_at_unix: u64, credential_id: []const u8, node_id: []const u8, egress_ip: []const u8) !Metadata {
        var result = Metadata{
            .kind = kind,
            .expires_at_unix = expires_at_unix,
            .account = account,
            .environment = environment,
            .endpoint_environment = environment,
        };
        result.credential_id_len = try copyText(&result.credential_id, credential_id);
        if (result.credential_id_len > 32) return error.CredentialIdTooLong;
        result.node_id_len = try copyText(&result.node_id, node_id);
        result.egress_ip_len = try copyText(&result.egress_ip, egress_ip);
        if (result.egress_ip_len == 0) return error.MissingFixedEgressIp;
        return result;
    }

    pub fn credentialId(self: *const Metadata) []const u8 {
        return self.credential_id[0..self.credential_id_len];
    }

    pub fn node(self: *const Metadata) []const u8 {
        return self.node_id[0..self.node_id_len];
    }

    pub fn ip(self: *const Metadata) []const u8 {
        return self.egress_ip[0..self.egress_ip_len];
    }
};

pub const ApiCredentials = struct {
    api_key: [max_secret]u8 = @splat(0),
    api_key_len: u8 = 0,
    secret_key: [max_secret]u8 = @splat(0),
    secret_key_len: u8 = 0,
    passphrase: [max_secret]u8 = @splat(0),
    passphrase_len: u8 = 0,

    pub fn init(api_key: []const u8, secret_key: []const u8, passphrase: []const u8) !ApiCredentials {
        var result = ApiCredentials{};
        errdefer result.clear();
        result.api_key_len = try copyText(&result.api_key, api_key);
        result.secret_key_len = try copyText(&result.secret_key, secret_key);
        if (passphrase.len != 0) result.passphrase_len = try copyText(&result.passphrase, passphrase);
        return result;
    }

    pub fn clear(self: *ApiCredentials) void {
        std.crypto.secureZero(u8, self.api_key[0..]);
        std.crypto.secureZero(u8, self.secret_key[0..]);
        std.crypto.secureZero(u8, self.passphrase[0..]);
        self.api_key_len = 0;
        self.secret_key_len = 0;
        self.passphrase_len = 0;
    }

    /// RFC 2104 state, pads and intermediate hashes stay in protected memory.
    pub fn hmac(self: *const ApiCredentials, parts: []const []const u8, output: *[32]u8) !void {
        errdefer std.crypto.secureZero(u8, output);
        const Hash = @import("credential_crypto/sha256.zig").Sha256;
        const Scratch = struct { hash: Hash, key: [64]u8, pad: [64]u8, digest: [32]u8 };
        var storage = try protected.Buffer.init(@sizeOf(Scratch));
        defer storage.deinit();
        const scratch: *Scratch = @ptrCast(@alignCast((try storage.writable()).ptr));
        const key = self.secret_key[0..self.secret_key_len];
        if (key.len > 64) {
            scratch.hash = Hash.init(.{});
            scratch.hash.update(key);
            scratch.hash.final(scratch.key[0..32]);
        } else @memcpy(scratch.key[0..key.len], key);
        for (scratch.key, 0..) |byte, i| scratch.pad[i] = byte ^ 0x36;
        scratch.hash = Hash.init(.{});
        scratch.hash.update(&scratch.pad);
        for (parts) |part| scratch.hash.update(part);
        scratch.hash.final(&scratch.digest);
        for (scratch.key, 0..) |byte, i| scratch.pad[i] = byte ^ 0x5c;
        scratch.hash = Hash.init(.{});
        scratch.hash.update(&scratch.pad);
        scratch.hash.update(&scratch.digest);
        scratch.hash.final(output);
    }
};

pub const ApiWallet = struct {
    private_key: [32]u8,
    signer: [20]u8,
    funding_account: [20]u8,
};

pub const SecretMaterial = union(enum) {
    api_credentials: ApiCredentials,
    api_wallet: ApiWallet,

    pub fn init(api_key: []const u8, secret_key: []const u8, passphrase: []const u8) !SecretMaterial {
        return .{ .api_credentials = try ApiCredentials.init(api_key, secret_key, passphrase) };
    }

    pub fn initWallet(result: *SecretMaterial, key: *const [32]u8, signer: [20]u8, funding: [20]u8) !void {
        result.clear();
        errdefer result.clear();
        const derived = try @import("wallet_crypto.zig").address(key);
        if (!std.mem.eql(u8, &derived, &signer)) return error.SignerAddressMismatch;
        if (std.mem.allEqual(u8, &funding, 0)) return error.InvalidFundingAccount;
        result.* = .{ .api_wallet = undefined };
        @memcpy(&result.api_wallet.private_key, key);
        result.api_wallet.signer = signer;
        result.api_wallet.funding_account = funding;
    }

    pub fn clear(self: *SecretMaterial) void {
        std.crypto.secureZero(u8, std.mem.asBytes(self));
        self.* = .{ .api_credentials = .{} };
    }
};

const PasswordSource = struct {
    kind: InputKind,
    bytes: []const u8,

    fn testOnly(bytes: []const u8) PasswordSource {
        return .{ .kind = .test_only, .bytes = bytes };
    }

    fn restricted(bytes: []const u8) PasswordSource {
        return .{ .kind = .restricted_fd, .bytes = bytes };
    }

    fn tty(bytes: []const u8) PasswordSource {
        return .{ .kind = .tty, .bytes = bytes };
    }
};

/// Reads one line from an interactive TTY or an inherited restricted fd.
/// There is intentionally no constructor for argv/environment/file-path input.
fn readPassword(io: std.Io, file: std.Io.File, kind: InputKind, destination: []u8) !PasswordSource {
    errdefer std.crypto.secureZero(u8, destination);
    if (kind == .test_only) return error.TestPasswordSourceNotAllowed;
    if (kind == .tty and builtin.os.tag != .windows and builtin.os.tag != .linux) return error.TtyPasswordUnsupported;
    if (kind == .tty and !(try file.isTty(io))) return error.NotATty;
    var console_mode: u32 = 0;
    var echo_disabled = false;
    var linux_mode: if (builtin.os.tag == .linux) std.posix.termios else void = undefined;
    if (kind == .tty and builtin.os.tag == .linux) {
        linux_mode = try std.posix.tcgetattr(file.handle);
        var hidden = linux_mode;
        hidden.lflag.ECHO = false;
        hidden.lflag.ECHONL = false;
        try std.posix.tcsetattr(file.handle, .FLUSH, hidden);
    }
    defer if (kind == .tty and builtin.os.tag == .linux) {
        std.posix.tcsetattr(file.handle, .FLUSH, linux_mode) catch {};
    };
    if (kind == .tty and builtin.os.tag == .windows) {
        if (windows_api.GetConsoleMode(file.handle, &console_mode) == 0) return error.NotATty;
        const ENABLE_ECHO_INPUT: u32 = 0x0004;
        if (windows_api.SetConsoleMode(file.handle, console_mode & ~ENABLE_ECHO_INPUT) == 0) return error.ConsoleEchoFailed;
        echo_disabled = true;
    }
    defer restoreConsoleMode(file, console_mode, echo_disabled);
    if (kind == .restricted_fd) {
        switch (builtin.os.tag) {
            .linux => {
                var descriptor_path: [64]u8 = undefined;
                const path = try std.fmt.bufPrint(&descriptor_path, "/proc/self/fd/{d}", .{file.handle});
                var target_buffer: [256]u8 = undefined;
                const target_len = std.Io.Dir.cwd().readLink(io, path, &target_buffer) catch
                    return error.RestrictedStreamInspectionFailed;
                const target = target_buffer[0..target_len];
                if (!std.mem.startsWith(u8, target, "pipe:[") and !std.mem.startsWith(u8, target, "socket:["))
                    return error.RestrictedStreamRequired;
            },
            .windows => {
                if (windows_api.GetFileType(file.handle) != FILE_TYPE_PIPE) return error.RestrictedStreamRequired;
            },
            else => return error.LinuxCredentialInputRequired,
        }
    }
    var length: usize = 0;
    while (true) {
        if (length == destination.len) return error.PasswordTooLong;
        const amount = file.readStreaming(io, &.{destination[length..][0..1]}) catch |err| switch (err) {
            error.EndOfStream => return error.UnterminatedPassword,
            else => return err,
        };
        if (amount == 0) return error.UnterminatedPassword;
        if (destination[length] == '\n') break;
        length += 1;
        if (length > max_password) return error.PasswordTooLong;
    }
    if (length > 0 and destination[length - 1] == '\r') length -= 1;
    if (length == 0) return error.InvalidPasswordSource;
    return .{ .kind = kind, .bytes = destination[0..length] };
}

fn restoreConsoleMode(file: std.Io.File, console_mode: u32, echo_disabled: bool) void {
    if (comptime builtin.os.tag == .windows) {
        if (echo_disabled) _ = windows_api.SetConsoleMode(file.handle, console_mode);
    }
}

fn prompt(io: std.Io, input: std.Io.File, input_kind: InputKind, label: []const u8, destination: []u8) ![]const u8 {
    if (input_kind == .tty) try std.Io.File.stderr().writeStreamingAll(io, label);
    const result = try readPassword(io, input, input_kind, destination);
    if (input_kind == .tty) try std.Io.File.stderr().writeStreamingAll(io, "\n");
    return result.bytes;
}

/// Structural parsing only. Callers must not treat this as authenticated data.
pub fn inspectEncrypted(encrypted: []const u8) !Metadata {
    var metadata: Metadata = undefined;
    var salt: [16]u8 = undefined;
    var nonce: [Aead.nonce_length]u8 = undefined;
    _ = try decodeHeader(encrypted, &metadata, &salt, &nonce);
    try validateBoundMetadata(metadata);
    return metadata;
}

pub const RuntimeContext = struct {
    venue: Venue = .legacy,
    account: u64,
    environment: production_contract.Environment,
    endpoint_environment: production_contract.Environment,
    node_id: []const u8,
    egress_ip: []const u8,
};

fn validateWalletMetadata(metadata: Metadata) !void {
    if (metadata.credential_id_len == 0 or metadata.credential_id_len > 32 or metadata.node_id_len > max_text or metadata.egress_ip_len > max_text or metadata.account == 0 or metadata.version == 0 or metadata.generation == 0) return error.InvalidCredentialMetadata;
}

pub fn validateBoundMetadata(metadata: Metadata) !void {
    try validateWalletMetadata(metadata);
    if (metadata.venue == .legacy or metadata.credential_id_len == 0 or metadata.node_id_len == 0 or metadata.egress_ip_len == 0 or
        metadata.environment != metadata.endpoint_environment or !metadata.can_read or metadata.can_withdraw or
        (metadata.kind == .observation and metadata.can_trade) or (metadata.kind == .execution and !metadata.can_trade)) return error.InvalidCredentialMetadata;
    if (metadata.venue == .hyperliquid and metadata.environment == .demo) return error.EnvironmentMismatch;
    if ((metadata.venue == .binance or metadata.venue == .bybit) and metadata.environment == .demo) return error.EnvironmentMismatch;
}

fn validateVenueMaterial(metadata: Metadata, material: *const SecretMaterial) !void {
    if (metadata.venue == .legacy) {
        if (material.* == .api_credentials and material.api_credentials.passphrase_len == 0) return error.InvalidCredential;
        return;
    }
    try validateBoundMetadata(metadata);
    switch (metadata.venue) {
        .hyperliquid => if (material.* != .api_wallet or metadata.kind != .execution) return error.WalletCredentialRequired,
        .okx, .binance, .bybit => {
            if (material.* != .api_credentials) return error.ApiCredentialRequired;
            const api = &material.api_credentials;
            if (metadata.venue == .okx and api.passphrase_len == 0) return error.InvalidCredential;
            if (metadata.venue != .okx and api.passphrase_len != 0) return error.UnexpectedPassphrase;
        },
        .legacy => unreachable,
    }
}

pub fn walletSession(metadata: Metadata, signer: [20]u8, funding: [20]u8, scope: u8, owner_token: u64) !u64 {
    try validateWalletMetadata(metadata);
    var hash = std.crypto.hash.sha3.Keccak256.init(.{});
    hash.update("WalletSignerSessionV1");
    hash.update(&signer);
    hash.update(&funding);
    hash.update(&.{ scope, @intFromEnum(metadata.environment), @intFromEnum(metadata.endpoint_environment) });
    if (metadata.venue != .legacy) hash.update(&.{@intFromEnum(metadata.venue)});
    for ([_][]const u8{ metadata.credentialId(), metadata.node(), metadata.ip() }) |text| {
        hash.update(&.{@intCast(text.len)});
        hash.update(text);
    }
    for ([_]u64{ metadata.account, metadata.version, metadata.generation, metadata.expires_at_unix, owner_token }) |value| {
        var encoded: [8]u8 = undefined;
        std.mem.writeInt(u64, &encoded, value, .big);
        hash.update(&encoded);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return @max(1, std.mem.readInt(u64, digest[0..8], .big));
}

pub const WalletSignature = struct { nonce: u64, digest: [32]u8, signature: @import("wallet_crypto.zig").Signature };
pub const WalletSigningRequest = struct {
    signer: [20]u8,
    funding: [20]u8,
    scope: u8,
    session: u64,
    owner_token: u64,
    guard: *@import("../runtime/failover.zig").GatewayLeaseGuard,
    command_identity: u128,
    now_ms: u64,
    now_monotonic_ns: u64,
    increases_risk: bool = true,

    fn check(self: WalletSigningRequest, metadata: Metadata) !void {
        if (self.command_identity == 0 or self.now_ms == 0) return error.InvalidSigningRequest;
        if (self.owner_token == 0 or self.guard.lease.key.exchange_account != metadata.account) return error.StaleFencingToken;
        if (self.session != try walletSession(metadata, self.signer, self.funding, self.scope, self.owner_token)) return error.StaleSignerSession;
        try self.guard.check(self.now_monotonic_ns, self.owner_token, self.increases_risk);
    }

    fn checkElapsed(self: WalletSigningRequest, metadata: Metadata, io: std.Io, started_ns: i96) !void {
        const elapsed = std.Io.Clock.awake.now(io).nanoseconds - started_ns;
        if (elapsed < 0 or elapsed > std.math.maxInt(u64)) return error.SigningClockInvalid;
        var current = self;
        current.now_monotonic_ns = std.math.add(u64, self.now_monotonic_ns, @intCast(elapsed)) catch return error.PrimaryLeaseExpired;
        current.now_ms = std.math.add(u64, self.now_ms, @intCast(@divTrunc(elapsed, std.time.ns_per_ms))) catch return error.CredentialExpired;
        if (metadata.expires_at_unix <= current.now_ms / 1000) return error.CredentialExpired;
        try current.check(metadata);
    }
};

pub const ProtectionReport = struct {
    locked: bool,
    dont_dump: bool,
    access_protected: bool,
    wipe_on_release: bool,

    pub fn accepted(self: ProtectionReport) bool {
        return self.locked and self.dont_dump and self.access_protected and self.wipe_on_release;
    }
};

/// The lease owns the only secret copy produced by an unlock. Its fields are
/// private; callers can only ask the execution-gateway callback to consume it.
pub const GatewayLease = struct {
    secret: Secret,
    metadata: Metadata,
    encrypted_digest: [32]u8,

    pub fn deinit(self: *GatewayLease) void {
        self.secret.deinit();
        self.metadata = undefined;
    }

    pub fn report(self: *const GatewayLease) ProtectionReport {
        return self.secret.report();
    }

    pub fn metadataView(self: *const GatewayLease) Metadata {
        return self.metadata;
    }

    pub fn withReadOnlyMaterial(self: *GatewayLease, comptime callback: fn (*const SecretMaterial) void) void {
        if (self.secret.material().* == .api_wallet) return;
        self.secret.expose(callback);
    }

    fn signWalletDigest(self: *GatewayLease, digest: [32]u8, signer: [20]u8, funding: [20]u8) !@import("wallet_crypto.zig").Signature {
        try self.checkWalletBinding(signer, funding);
        return @import("wallet_crypto.zig").sign(&self.secret.material().api_wallet.private_key, digest);
    }

    fn checkWalletBinding(self: *GatewayLease, signer: [20]u8, funding: [20]u8) !void {
        const wallet = switch (self.secret.material().*) {
            .api_wallet => |*value| value,
            else => return error.WalletCredentialRequired,
        };
        if (!std.mem.eql(u8, &wallet.signer, &signer) or !std.mem.eql(u8, &wallet.funding_account, &funding)) return error.WalletBindingMismatch;
    }
};

/// Gateway-owned API session. A changed file closes the session, including
/// retirement/revocation; every execution use also checks the current fence.
pub const ApiSession = struct {
    store: *CredentialStore,
    lease: GatewayLease,
    owner_token: u64,

    pub fn deinit(self: *ApiSession) void {
        self.lease.deinit();
    }

    pub fn venue(self: *const ApiSession) Venue {
        return self.lease.metadata.venue;
    }

    pub fn useNow(self: *ApiSession, io: std.Io, guard: ?*@import("../runtime/failover.zig").GatewayLeaseGuard, increases_risk: bool, context: anytype) !void {
        const unix = std.math.cast(u64, std.Io.Clock.real.now(io).toSeconds()) orelse return error.SigningClockInvalid;
        const monotonic = std.math.cast(u64, std.Io.Clock.awake.now(io).nanoseconds) orelse return error.SigningClockInvalid;
        try self.use(io, unix, monotonic, guard, increases_risk, context);
    }

    pub fn use(self: *ApiSession, io: std.Io, now_unix: u64, now_monotonic_ns: u64, guard: ?*@import("../runtime/failover.zig").GatewayLeaseGuard, increases_risk: bool, context: anytype) !void {
        const writer = try self.store.acquireWriter(io);
        defer writer.close(io);
        const started = std.Io.Clock.awake.now(io).nanoseconds;
        try self.check(io, now_unix, now_monotonic_ns, guard, increases_risk);
        try context.use(&self.lease.secret.material().api_credentials);
        const elapsed = std.Io.Clock.awake.now(io).nanoseconds - started;
        if (elapsed < 0 or elapsed > std.math.maxInt(u64)) return error.SigningClockInvalid;
        const current_ns = std.math.add(u64, now_monotonic_ns, @intCast(elapsed)) catch return error.PrimaryLeaseExpired;
        const current_unix = std.math.add(u64, now_unix, @intCast(@divTrunc(elapsed, std.time.ns_per_s))) catch return error.CredentialExpired;
        try self.check(io, current_unix, current_ns, guard, increases_risk);
    }

    fn check(self: *ApiSession, io: std.Io, now_unix: u64, now_monotonic_ns: u64, guard: ?*@import("../runtime/failover.zig").GatewayLeaseGuard, increases_risk: bool) !void {
        if (!self.store.admission_gate) return error.SecurityGateClosed;
        const metadata = self.lease.metadata;
        if (metadata.expires_at_unix <= now_unix) return error.CredentialExpired;
        if (metadata.kind == .execution) {
            const fence = guard orelse return error.ExecutionFenceRequired;
            if (self.owner_token == 0 or fence.lease.key.exchange_account != metadata.account) return error.StaleFencingToken;
            try fence.check(now_monotonic_ns, self.owner_token, increases_risk);
        } else if (increases_risk) return error.ReadOnlyPolicyViolation;
        var bytes: [max_file]u8 = undefined;
        const length = try readFile(self.store.dir, io, fileName(metadata.kind), &bytes);
        var digest: [32]u8 = undefined;
        Sha256.hash(bytes[0..length], &digest, .{});
        if (!std.mem.eql(u8, &digest, &self.lease.encrypted_digest)) return error.StaleCredentialSession;
    }
};

pub const Admission = struct {
    state: AdmissionState,
    kind: CredentialKind,
    credential_id: [max_text]u8,
    credential_id_len: u8,
    send_capability: bool = false,
    trading_enabled: bool = false,

    pub fn isReady(self: Admission) bool {
        return self.state == .ready;
    }

    pub fn credentialId(self: *const Admission) []const u8 {
        return self.credential_id[0..self.credential_id_len];
    }
};

pub const GatewayAllowlist = enum { account_read, account_reconciliation, order_write, funds_transfer, credential_management };

pub fn allowsReadOnly(operation: GatewayAllowlist) bool {
    return operation == .account_read or operation == .account_reconciliation;
}

pub const SecuritySelfCheck = struct {
    lock_memory: bool = true,
    dont_dump: bool = true,
    zeroize: bool = true,
    gateway_owner: bool = true,

    pub fn passes(self: SecuritySelfCheck) bool {
        return self.lock_memory and self.dont_dump and self.zeroize and self.gateway_owner;
    }

    pub fn passesWindowsVerification(self: SecuritySelfCheck) bool {
        return self.lock_memory and self.zeroize and self.gateway_owner;
    }
};

pub const CredentialStore = struct {
    dir: std.Io.Dir,
    allocator: Allocator,
    admission_gate: bool = true,

    pub fn open(io: std.Io, allocator: Allocator, absolute_path: []const u8) !CredentialStore {
        if (builtin.os.tag != .linux and builtin.os.tag != .windows) return error.UnsupportedCredentialStorePlatform;
        std.Io.Dir.createDirAbsolute(io, absolute_path, if (builtin.os.tag == .linux) @enumFromInt(0o700) else .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        var dir = try std.Io.Dir.openDirAbsolute(io, absolute_path, .{ .iterate = true, .follow_symlinks = false });
        errdefer dir.close(io);
        if (builtin.os.tag == .linux) try dir.setPermissions(io, @enumFromInt(0o700));
        if (builtin.os.tag == .windows) try protected.configureNativeLockBudget(24 * 1024 * 1024);
        return .{ .dir = dir, .allocator = allocator };
    }

    pub fn close(self: *CredentialStore, io: std.Io) void {
        self.dir.close(io);
    }

    /// Separate stores let accounts, venues and versions coexist without
    /// overwriting an older identity or its irreversible revocation history.
    pub fn openScoped(io: std.Io, allocator: Allocator, root: []const u8, metadata: Metadata) !CredentialStore {
        try validateBoundMetadata(metadata);
        var parent = try CredentialStore.open(io, allocator, root);
        defer parent.close(io);
        var name_buffer: [192]u8 = undefined;
        var identity: [32]u8 = @splat(0);
        @memcpy(identity[0..metadata.credential_id_len], metadata.credentialId());
        const name = try std.fmt.bufPrint(&name_buffer, "{s}-{d}-{s}-{s}-v{d}", .{
            @tagName(metadata.venue),             metadata.account, @tagName(metadata.environment),
            std.fmt.bytesToHex(identity, .lower), metadata.version,
        });
        const path = try std.fs.path.join(allocator, &.{ root, name });
        defer allocator.free(path);
        return CredentialStore.open(io, allocator, path);
    }

    pub fn stage(self: *CredentialStore, io: std.Io, metadata: Metadata, material: *SecretMaterial, file: std.Io.File, input_kind: InputKind, password_buffer: []u8) !void {
        defer material.clear();
        defer std.crypto.secureZero(u8, password_buffer);
        var password_storage = try protected.Buffer.init(max_password + 1);
        defer password_storage.deinit();
        const password = try readPassword(io, file, input_kind, try password_storage.writable());
        try password_storage.freeze();
        try self.stageWithPassword(io, metadata, material, password);
    }

    /// Interactive fields and both password entries stay in protected owners.
    /// restricted_fd is for an inherited native provisioner, never a text file.
    pub fn enroll(self: *CredentialStore, io: std.Io, metadata: Metadata, input: std.Io.File, input_kind: InputKind) !void {
        try validateBoundMetadata(metadata);
        var fields = try protected.Buffer.init(6 * (max_password + 1));
        defer fields.deinit();
        const bytes = try fields.writable();
        var material = try Secret.empty(.native);
        defer material.deinit();
        const destination = try material.writableMaterial();
        if (metadata.venue == .hyperliquid) {
            const key_text = try prompt(io, input, input_kind, "Agent private key (64 hex): ", bytes[0..257]);
            const signer_text = try prompt(io, input, input_kind, "Agent address (40 hex): ", bytes[257..514]);
            const funding_text = try prompt(io, input, input_kind, "Funding address (40 hex): ", bytes[514..771]);
            const key: *[32]u8 = bytes[771..803];
            const signer: *[20]u8 = bytes[803..823];
            const funding: *[20]u8 = bytes[823..843];
            if (key_text.len != 64 or signer_text.len != 40 or funding_text.len != 40) return error.InvalidWalletInput;
            _ = try std.fmt.hexToBytes(key, key_text);
            _ = try std.fmt.hexToBytes(signer, signer_text);
            _ = try std.fmt.hexToBytes(funding, funding_text);
            try destination.initWallet(key, signer.*, funding.*);
        } else {
            const key = try prompt(io, input, input_kind, "API key: ", bytes[0..257]);
            const secret = try prompt(io, input, input_kind, "Secret key: ", bytes[257..514]);
            const pass = if (metadata.venue == .okx) try prompt(io, input, input_kind, "Passphrase: ", bytes[514..771]) else "";
            destination.* = .{ .api_credentials = .{} };
            destination.api_credentials.api_key_len = try copyText(&destination.api_credentials.api_key, key);
            destination.api_credentials.secret_key_len = try copyText(&destination.api_credentials.secret_key, secret);
            if (pass.len != 0) destination.api_credentials.passphrase_len = try copyText(&destination.api_credentials.passphrase, pass);
        }
        const password = try prompt(io, input, input_kind, "Encryption password (at least 12 bytes): ", bytes[1028..1285]);
        const confirmation = try prompt(io, input, input_kind, "Confirm encryption password: ", bytes[1285..1542]);
        if (password.len < 12) return error.WeakEncryptionPassword;
        if (std.crypto.timing_safe.compare(u8, bytes[1028..1285], bytes[1285..1542], .little) != .eq) return error.PasswordConfirmationMismatch;
        if (password.len != confirmation.len) return error.PasswordConfirmationMismatch;
        try fields.freeze();
        try self.stageWithPassword(io, metadata, destination, .{ .kind = input_kind, .bytes = password });
    }

    pub fn openApiSession(self: *CredentialStore, io: std.Io, input: std.Io.File, input_kind: InputKind, expected: Metadata, runtime: RuntimeContext, now_unix: u64, owner_token: u64) !ApiSession {
        try validateBoundMetadata(expected);
        if (!self.admission_gate or !matchesRuntime(expected, runtime)) return error.RuntimeContextMismatch;
        if (expected.expires_at_unix <= now_unix) return error.CredentialExpired;
        if (expected.venue == .hyperliquid) return error.ApiCredentialRequired;
        if (expected.kind == .execution and owner_token == 0) return error.ExecutionFenceRequired;
        var password = try protected.Buffer.init(max_password + 1);
        defer password.deinit();
        const source = try readPassword(io, input, input_kind, try password.writable());
        try password.freeze();
        var lease = try self.unlock(io, expected.kind, source, expected, .native, true);
        errdefer lease.deinit();
        if (!protectionAccepted(lease.report())) return error.SecurityGateClosed;
        return .{ .store = self, .lease = lease, .owner_token = owner_token };
    }

    /// An imported header is only a hint until AEAD authentication succeeds.
    pub fn importEncrypted(self: *CredentialStore, io: std.Io, encrypted: []const u8, input: std.Io.File, input_kind: InputKind, now_unix: u64) !Metadata {
        if (!self.admission_gate) return error.SecurityGateClosed;
        var password = try protected.Buffer.init(max_password + 1);
        defer password.deinit();
        const source = try prompt(io, input, input_kind, "Encryption password: ", try password.writable());
        try password.freeze();
        var plaintext = try protected.Buffer.init(max_payload);
        defer plaintext.deinit();
        var metadata: Metadata = undefined;
        const length = try decrypt(io, encrypted, source, &metadata, try plaintext.writable());
        try validateBoundMetadata(metadata);
        if (metadata.state != .staged or metadata.generation != 1) return error.InvalidInitialState;
        if (metadata.expires_at_unix <= now_unix) return error.CredentialExpired;
        var secret = try Secret.empty(.native);
        defer secret.deinit();
        try decodeMaterial(plaintext.bytes()[0..length], try secret.writableMaterial());
        try validateVenueMaterial(metadata, secret.material());
        const writer = try self.acquireWriter(io);
        defer writer.close(io);
        try writeAtomic(self.dir, io, fileName(metadata.kind), encrypted, false);
        if (secret.material().* == .api_wallet) try @import("../persistence/signer_nonce.zig").provision(self.dir, io, secret.material().api_wallet.signer);
        return metadata;
    }

    pub fn activate(self: *CredentialStore, io: std.Io, kind: CredentialKind, file: std.Io.File, input_kind: InputKind, password_buffer: []u8, expected: Metadata) !void {
        defer std.crypto.secureZero(u8, password_buffer);
        var password_storage = try protected.Buffer.init(max_password + 1);
        defer password_storage.deinit();
        const password = try readPassword(io, file, input_kind, try password_storage.writable());
        try password_storage.freeze();
        try self.activateWithPassword(io, kind, password, expected);
    }

    pub fn retire(self: *CredentialStore, io: std.Io, kind: CredentialKind, file: std.Io.File, input_kind: InputKind, password_buffer: []u8, expected: Metadata) !void {
        defer std.crypto.secureZero(u8, password_buffer);
        var password_storage = try protected.Buffer.init(max_password + 1);
        defer password_storage.deinit();
        const password = try readPassword(io, file, input_kind, try password_storage.writable());
        try password_storage.freeze();
        try self.retireWithPassword(io, kind, password, expected);
    }

    pub fn revoke(self: *CredentialStore, io: std.Io, kind: CredentialKind, file: std.Io.File, input_kind: InputKind, password_buffer: []u8, expected: Metadata) !void {
        defer std.crypto.secureZero(u8, password_buffer);
        var password_storage = try protected.Buffer.init(max_password + 1);
        defer password_storage.deinit();
        const password = try readPassword(io, file, input_kind, try password_storage.writable());
        try password_storage.freeze();
        try self.revokeWithPassword(io, kind, password, expected);
    }

    pub fn admitObservationReadOnly(self: *CredentialStore, io: std.Io, file: std.Io.File, input_kind: InputKind, password_buffer: []u8, expected: Metadata, runtime: RuntimeContext, now_unix: u64, self_check: SecuritySelfCheck) !Admission {
        defer std.crypto.secureZero(u8, password_buffer);
        var password_storage = try protected.Buffer.init(max_password + 1);
        defer password_storage.deinit();
        const password = try readPassword(io, file, input_kind, try password_storage.writable());
        try password_storage.freeze();
        return self.admitObservationWithPassword(io, password, expected, runtime, now_unix, .native, self_check);
    }

    fn stageWithPassword(self: *CredentialStore, io: std.Io, metadata: Metadata, material: *SecretMaterial, password: PasswordSource) !void {
        defer material.clear();
        if (!self.admission_gate) return error.SecurityGateClosed;
        if (metadata.state != .staged) return error.InvalidInitialState;
        try validateVenueMaterial(metadata, material);
        if (material.* == .api_wallet and (metadata.kind != .execution or !metadata.can_trade or metadata.can_withdraw or metadata.environment == .demo or metadata.environment != metadata.endpoint_environment)) return error.WalletPolicyViolation;
        const writer = try self.acquireWriter(io);
        defer writer.close(io);
        try self.writeEncrypted(io, metadata, material, password, false);
        if (material.* == .api_wallet) try @import("../persistence/signer_nonce.zig").provision(self.dir, io, material.api_wallet.signer);
    }

    fn activateWithPassword(self: *CredentialStore, io: std.Io, kind: CredentialKind, password: PasswordSource, expected: Metadata) !void {
        try self.transition(io, kind, password, expected, .active);
    }

    fn retireWithPassword(self: *CredentialStore, io: std.Io, kind: CredentialKind, password: PasswordSource, expected: Metadata) !void {
        try self.transition(io, kind, password, expected, .retiring);
    }

    fn revokeWithPassword(self: *CredentialStore, io: std.Io, kind: CredentialKind, password: PasswordSource, expected: Metadata) !void {
        try self.transition(io, kind, password, expected, .revoked);
    }

    fn admitObservationWithPassword(self: *CredentialStore, io: std.Io, password: PasswordSource, expected: Metadata, runtime: RuntimeContext, now_unix: u64, protection: ProtectionMode, self_check: SecuritySelfCheck) !Admission {
        if (protection == .test_bypass and !builtin.is_test) return error.TestProtectionModeNotAllowed;
        if (!self.admission_gate or !selfCheckPasses(self_check)) return error.SecurityGateClosed;
        if (expected.kind != .observation or expected.state != .active) return error.ObservationCredentialRequired;
        if (!expected.can_read or expected.can_trade or expected.can_withdraw) return error.ReadOnlyPolicyViolation;
        if (expected.environment != .production or expected.endpoint_environment != .production) return error.EnvironmentMismatch;
        if (expected.expires_at_unix <= now_unix) return error.CredentialExpired;
        var lease = try self.unlock(io, .observation, password, expected, protection, true);
        defer lease.deinit();
        if (!matchesRuntime(lease.metadataView(), runtime)) return error.RuntimeContextMismatch;
        if (!protectionAccepted(lease.report())) return error.SecurityGateClosed;
        return .{ .state = .ready, .kind = .observation, .credential_id = expected.credential_id, .credential_id_len = expected.credential_id_len };
    }

    /// Execution credentials remain a separate file and authority. Ticket 04
    /// cannot turn them into a send-capable gateway.
    pub fn admitExecution(_: *CredentialStore) !Admission {
        return error.ExecutionAdmissionOutOfScope;
    }

    /// Only this operation can consume a wallet lease: fencing, session and
    /// durable request consumption cannot be skipped by a digest callback.
    pub fn signWallet(self: *CredentialStore, io: std.Io, file: std.Io.File, input_kind: InputKind, password_buffer: []u8, expected: Metadata, runtime: RuntimeContext, request: WalletSigningRequest, digest_context: anytype) !WalletSignature {
        defer std.crypto.secureZero(u8, password_buffer);
        if (!self.admission_gate) return error.SecurityGateClosed;
        try validateWalletMetadata(expected);
        if (expected.kind != .execution or expected.state != .active or !expected.can_trade or expected.can_withdraw) return error.WalletPolicyViolation;
        if (expected.environment != expected.endpoint_environment or !matchesRuntime(expected, runtime)) return error.RuntimeContextMismatch;
        if (expected.expires_at_unix <= request.now_ms / 1000) return error.CredentialExpired;
        try request.check(expected);
        const started_ns = std.Io.Clock.awake.now(io).nanoseconds;
        var password_storage = try protected.Buffer.init(max_password + 1);
        defer password_storage.deinit();
        const password = try readPassword(io, file, input_kind, try password_storage.writable());
        try password_storage.freeze();
        const writer = try self.acquireWriter(io);
        defer writer.close(io);
        var lease = try self.unlock(io, .execution, password, expected, .native, true);
        defer lease.deinit();
        if (!protectionAccepted(lease.report())) return error.SecurityGateClosed;
        try lease.checkWalletBinding(request.signer, request.funding);
        try request.checkElapsed(expected, io, started_ns);
        const nonce = try @import("../persistence/signer_nonce.zig").reserve(self.dir, io, request.signer, expected.account, request.command_identity, request.now_ms);
        const digest = try digest_context.digest(nonce);
        const signature = try lease.signWalletDigest(digest, request.signer, request.funding);
        try request.checkElapsed(expected, io, started_ns);
        return .{ .nonce = nonce, .digest = digest, .signature = signature };
    }

    fn transition(self: *CredentialStore, io: std.Io, kind: CredentialKind, password: PasswordSource, expected: Metadata, next: CredentialState) !void {
        if (!self.admission_gate) return error.SecurityGateClosed;
        const allowed = switch (expected.state) {
            .staged => next == .active or next == .revoked,
            .active => next == .retiring or next == .revoked,
            .retiring => next == .revoked,
            .revoked => false,
        };
        if (!allowed or expected.kind != kind) return error.InvalidCredentialTransition;
        const writer = try self.acquireWriter(io);
        defer writer.close(io);
        const protection: ProtectionMode = if (builtin.is_test) .test_bypass else .native;
        var lease = try self.unlock(io, kind, password, expected, protection, false);
        defer lease.deinit();
        var next_metadata = expected;
        next_metadata.state = next;
        next_metadata.generation = std.math.add(u64, expected.generation, 1) catch return error.CredentialGenerationExhausted;
        try self.writeEncrypted(io, next_metadata, lease.secret.material(), password, true);
    }

    fn unlock(self: *CredentialStore, io: std.Io, kind: CredentialKind, password: PasswordSource, expected: Metadata, protection: ProtectionMode, require_active: bool) !GatewayLease {
        if (password.kind == .test_only and protection == .native) return error.TestPasswordSourceNotAllowed;
        if (password.bytes.len == 0 or password.bytes.len > max_password) return error.InvalidPasswordSource;
        if (expected.kind != kind) return error.CredentialKindMismatch;
        var file_bytes: [max_file]u8 = undefined;
        const file_len = try readFile(self.dir, io, fileName(kind), &file_bytes);
        var metadata: Metadata = undefined;
        var plaintext = try protected.Buffer.init(max_payload);
        defer plaintext.deinit();
        const plaintext_len = try decrypt(io, file_bytes[0..file_len], password.bytes, &metadata, try plaintext.writable());
        if (metadata.state == .revoked) return error.CredentialRevoked;
        if (!sameImmutableMetadata(metadata, expected) or metadata.state != expected.state or metadata.generation != expected.generation) return error.MetadataMismatch;
        if (require_active and metadata.state != .active) return error.CredentialNotActive;
        var secret = try Secret.empty(protection);
        errdefer secret.deinit();
        try decodeMaterial(plaintext.bytes()[0..plaintext_len], try secret.writableMaterial());
        try validateVenueMaterial(metadata, secret.material());
        try secret.storage.freeze();
        var digest: [32]u8 = undefined;
        Sha256.hash(file_bytes[0..file_len], &digest, .{});
        return .{ .secret = secret, .metadata = metadata, .encrypted_digest = digest };
    }

    // This inode is never renamed or deleted: locking the replaced credential
    // itself would let a second writer lock the old inode and overwrite revoke.
    fn acquireWriter(self: *CredentialStore, io: std.Io) !std.Io.File {
        return self.dir.createFile(io, "credential.writer.lock", .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .permissions = if (builtin.os.tag == .linux) @enumFromInt(0o600) else .default_file,
        }) catch |err| switch (err) {
            error.WouldBlock => error.CredentialWriterBusy,
            else => err,
        };
    }

    fn writeEncrypted(self: *CredentialStore, io: std.Io, metadata: Metadata, material: *const SecretMaterial, password: PasswordSource, replace: bool) !void {
        if (password.kind == .test_only and !builtin.is_test) return error.TestPasswordSourceNotAllowed;
        if (password.bytes.len == 0 or password.bytes.len > max_password) return error.InvalidPasswordSource;
        var owned_material = try Secret.init(self.allocator, material, .native);
        defer owned_material.deinit();
        var owned_password = try protected.Buffer.init(password.bytes.len);
        defer owned_password.deinit();
        @memcpy(try owned_password.writable(), password.bytes);
        try owned_password.freeze();
        var payload = try protected.Buffer.init(max_payload);
        defer payload.deinit();
        const payload_len = encodeMaterial(owned_material.material(), try payload.writable()) catch |err| {
            self.admission_gate = false;
            return err;
        };
        var bytes: [max_file]u8 = undefined;
        var salt: [16]u8 = undefined;
        var nonce: [Aead.nonce_length]u8 = undefined;
        io.random(&salt);
        io.random(&nonce);
        encodeHeader(&bytes, metadata, salt, nonce, @intCast(payload_len));
        var key = try protected.Buffer.init(Aead.key_length);
        defer key.deinit();
        try credential_kdf.derive(io, owned_password.bytes(), &salt, (try key.writable())[0..Aead.key_length]);
        var tag: [payload_tag_len]u8 = undefined;
        try Aead.encrypt(bytes[header_len .. header_len + payload_len], &tag, payload.bytes()[0..payload_len], bytes[0..header_len], nonce, key.bytes()[0..Aead.key_length]);
        @memcpy(bytes[header_len + payload_len ..][0..payload_tag_len], &tag);
        try writeAtomic(self.dir, io, fileName(metadata.kind), bytes[0 .. header_len + payload_len + payload_tag_len], replace);
    }
};

/// Owns a credential payload in a dedicated page. The payload is readable only
/// through `expose`; the page is read-only while the Secret is alive and is
/// restored, wiped, unlocked, and freed by `deinit`.
const Secret = struct {
    storage: protected.Buffer,

    fn empty(mode: ProtectionMode) !Secret {
        if (mode == .test_bypass and !builtin.is_test) return error.TestProtectionModeNotAllowed;
        // Legacy test mode never bypasses native mapping protection.
        return .{ .storage = try protected.Buffer.init(@sizeOf(SecretMaterial)) };
    }

    fn init(_: Allocator, secret_material: *const SecretMaterial, mode: ProtectionMode) !Secret {
        var result = try empty(mode);
        errdefer result.deinit();
        @memcpy(try result.storage.writable(), std.mem.asBytes(secret_material));
        try result.storage.freeze();
        return result;
    }

    fn writableMaterial(self: *Secret) !*SecretMaterial {
        return @ptrCast(@alignCast((try self.storage.writable()).ptr));
    }

    fn expose(self: *const Secret, comptime callback: fn (*const SecretMaterial) void) void {
        callback(self.material());
    }

    fn material(self: *const Secret) *const SecretMaterial {
        return @ptrCast(@alignCast(self.storage.bytes().ptr));
    }

    fn report(self: *const Secret) ProtectionReport {
        const native = self.storage.report();
        return .{ .locked = native.locked, .dont_dump = native.dont_dump, .access_protected = native.read_only, .wipe_on_release = true };
    }

    fn deinit(self: *Secret) void {
        self.storage.deinit();
    }
};

fn copyText(destination: []u8, source: []const u8) !u8 {
    if (source.len == 0 or source.len > destination.len) return error.InvalidText;
    @memcpy(destination[0..source.len], source);
    return @intCast(source.len);
}

fn fileName(kind: CredentialKind) []const u8 {
    return if (kind == .observation) "observation.credential" else "execution.credential";
}

fn sameImmutableMetadata(a: Metadata, b: Metadata) bool {
    return a.venue == b.venue and a.kind == b.kind and a.version == b.version and
        a.expires_at_unix == b.expires_at_unix and a.account == b.account and a.environment == b.environment and
        a.endpoint_environment == b.endpoint_environment and a.credential_id_len == b.credential_id_len and
        a.node_id_len == b.node_id_len and a.egress_ip_len == b.egress_ip_len and
        std.mem.eql(u8, a.credentialId(), b.credentialId()) and std.mem.eql(u8, a.node(), b.node()) and
        std.mem.eql(u8, a.ip(), b.ip()) and a.can_read == b.can_read and a.can_trade == b.can_trade and a.can_withdraw == b.can_withdraw;
}

fn matchesRuntime(metadata: Metadata, runtime: RuntimeContext) bool {
    return metadata.venue == runtime.venue and metadata.account == runtime.account and metadata.environment == runtime.environment and
        metadata.endpoint_environment == runtime.endpoint_environment and std.mem.eql(u8, metadata.node(), runtime.node_id) and
        std.mem.eql(u8, metadata.ip(), runtime.egress_ip);
}

fn put(comptime T: type, destination: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, destination[offset..][0..@sizeOf(T)], value, .little);
}

fn get(comptime T: type, source: []const u8, offset: usize) T {
    return std.mem.readInt(T, source[offset..][0..@sizeOf(T)], .little);
}

fn encodeHeader(destination: []u8, metadata: Metadata, salt: [16]u8, nonce: [Aead.nonce_length]u8, payload_len: u16) void {
    @memset(destination[0..header_len], 0);
    put(u32, destination, 0, magic);
    put(u16, destination, 4, if (metadata.venue == .legacy) format_version else 2);
    destination[6] = @intFromEnum(metadata.kind);
    destination[7] = @intFromEnum(metadata.state);
    destination[8] = (if (metadata.can_read) @as(u8, 1) else 0) | (if (metadata.can_trade) @as(u8, 2) else 0) | (if (metadata.can_withdraw) @as(u8, 4) else 0);
    destination[9] = @intFromEnum(metadata.venue);
    put(u64, destination, 10, metadata.version);
    put(u64, destination, 18, metadata.generation);
    put(u64, destination, 26, metadata.expires_at_unix);
    put(u64, destination, 34, metadata.account);
    destination[42] = @intFromEnum(metadata.environment);
    destination[43] = @intFromEnum(metadata.endpoint_environment);
    destination[44] = metadata.credential_id_len;
    destination[45] = metadata.node_id_len;
    destination[46] = metadata.egress_ip_len;
    @memcpy(destination[48..80], metadata.credential_id[0..32]);
    @memcpy(destination[80..144], &metadata.node_id);
    @memcpy(destination[144..208], &metadata.egress_ip);
    @memcpy(destination[208..224], &salt);
    @memcpy(destination[224..248], &nonce);
    put(u16, destination, 248, payload_len);
}

fn decodeHeader(source: []const u8, metadata: *Metadata, salt: *[16]u8, nonce: *[Aead.nonce_length]u8) !u16 {
    if (source.len < header_len + payload_tag_len or get(u32, source, 0) != magic) return error.InvalidCredentialFile;
    const version = get(u16, source, 4);
    if (version != format_version and version != 2) return error.InvalidCredentialFile;
    if ((version == 1 and source[9] != 0) or (version == 2 and (source[9] == 0 or source[9] > @intFromEnum(Venue.hyperliquid)))) return error.InvalidCredentialMetadata;
    if (source[8] & ~@as(u8, 7) != 0 or source[47] != 0 or source[250] != 0 or source[251] != 0) return error.InvalidCredentialMetadata;
    if (source[6] > @intFromEnum(CredentialKind.execution) or source[7] > @intFromEnum(CredentialState.revoked)) return error.InvalidCredentialMetadata;
    if (source[44] > 32 or source[45] > max_text or source[46] > max_text) return error.InvalidCredentialMetadata;
    if (source[42] > @intFromEnum(production_contract.Environment.production) or source[43] > @intFromEnum(production_contract.Environment.production)) return error.InvalidCredentialMetadata;
    metadata.* = .{
        .venue = @enumFromInt(source[9]),
        .kind = @enumFromInt(source[6]),
        .state = @enumFromInt(source[7]),
        .version = get(u64, source, 10),
        .generation = get(u64, source, 18),
        .expires_at_unix = get(u64, source, 26),
        .account = get(u64, source, 34),
        .environment = @enumFromInt(source[42]),
        .endpoint_environment = @enumFromInt(source[43]),
        .credential_id_len = source[44],
        .node_id_len = source[45],
        .egress_ip_len = source[46],
        .can_read = source[8] & 1 != 0,
        .can_trade = source[8] & 2 != 0,
        .can_withdraw = source[8] & 4 != 0,
    };
    @memset(&metadata.credential_id, 0);
    @memcpy(metadata.credential_id[0..32], source[48..80]);
    @memcpy(&metadata.node_id, source[80..144]);
    @memcpy(&metadata.egress_ip, source[144..208]);
    @memcpy(salt, source[208..224]);
    @memcpy(nonce, source[224..248]);
    const payload_len = get(u16, source, 248);
    if (payload_len > max_payload or source.len != header_len + payload_len + payload_tag_len) return error.InvalidCredentialFile;
    return payload_len;
}

test "venue enrollment imports authenticated packages and closes API sessions on revoke" {
    var root_buffer: [256]u8 = undefined;
    const root = try lifecycleTestPath(&root_buffer);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    var target_buffer: [256]u8 = undefined;
    const target = try lifecycleTestPath(&target_buffer);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, target) catch {};
    for ([_]Venue{ .okx, .binance, .bybit }) |venue| {
        var metadata = try Metadata.init(.execution, 7, .testnet, 4_000_000_000, "enrolled", "node", "203.0.113.7");
        metadata.venue = venue;
        metadata.can_trade = true;
        var source_store = try CredentialStore.openScoped(std.testing.io, std.testing.allocator, root, metadata);
        defer source_store.close(std.testing.io);
        const secret_input = if (venue == .okx) "key\nsecret\npass\nlifecycle-fixture-password\nlifecycle-fixture-password\n" else "key\nsecret\nlifecycle-fixture-password\nlifecycle-fixture-password\n";
        var enrollment = try lifecycleInputPipe(std.testing.io, secret_input);
        defer enrollment.close(std.testing.io);
        try source_store.enroll(std.testing.io, metadata, enrollment, .restricted_fd);
        var encrypted: [max_file]u8 = undefined;
        const length = try readFile(source_store.dir, std.testing.io, "execution.credential", &encrypted);
        try std.testing.expectEqual(@as(u16, 2), get(u16, &encrypted, 4));
        try std.testing.expectEqual(venue, (try inspectEncrypted(encrypted[0..length])).venue);
        var imported = try CredentialStore.openScoped(std.testing.io, std.testing.allocator, target, metadata);
        defer imported.close(std.testing.io);
        var wrong = try lifecycleInputPipe(std.testing.io, "wrong password\n");
        defer wrong.close(std.testing.io);
        try std.testing.expectError(error.AuthenticationFailed, imported.importEncrypted(std.testing.io, encrypted[0..length], wrong, .restricted_fd, 1));
        var password_input = try lifecyclePasswordPipe(std.testing.io);
        defer password_input.close(std.testing.io);
        _ = try imported.importEncrypted(std.testing.io, encrypted[0..length], password_input, .restricted_fd, 1);
        var duplicate = try lifecyclePasswordPipe(std.testing.io);
        defer duplicate.close(std.testing.io);
        try std.testing.expectError(error.CredentialAlreadyRegistered, imported.importEncrypted(std.testing.io, encrypted[0..length], duplicate, .restricted_fd, 1));
        try lifecycleTransition(&imported, metadata, .active);
        metadata.state = .active;
        metadata.generation = 2;
        const runtime: RuntimeContext = .{ .venue = venue, .account = 7, .environment = .testnet, .endpoint_environment = .testnet, .node_id = "node", .egress_ip = "203.0.113.7" };
        var invalid_runtime = runtime;
        invalid_runtime.venue = .hyperliquid;
        var session_input = try lifecyclePasswordPipe(std.testing.io);
        defer session_input.close(std.testing.io);
        try std.testing.expectError(error.RuntimeContextMismatch, imported.openApiSession(std.testing.io, session_input, .restricted_fd, metadata, invalid_runtime, 1, 1));
        const failover = @import("../runtime/failover.zig");
        var authority = failover.FencingAuthority{ .durable = true };
        var owner = try authority.acquire(.{ .exchange_account = 7, .decision_domain = 1 }, 1, 0);
        owner.expires_at_ns = std.math.maxInt(u64);
        var guard = failover.GatewayLeaseGuard{ .authority = &authority, .lease = &owner };
        var session = try imported.openApiSession(std.testing.io, session_input, .restricted_fd, metadata, runtime, 1, owner.token);
        defer session.deinit();
        const Consumer = struct {
            used: bool = false,
            pub fn use(self: *@This(), api: *const ApiCredentials) !void {
                try std.testing.expectEqualStrings("key", api.api_key[0..api.api_key_len]);
                try std.testing.expectEqualStrings("secret", api.secret_key[0..api.secret_key_len]);
                self.used = true;
            }
        };
        var consumer: Consumer = .{};
        try std.testing.expectError(error.ExecutionFenceRequired, session.use(std.testing.io, 1, 1, null, true, &consumer));
        try std.testing.expect(!consumer.used);
        try session.use(std.testing.io, 1, 1, &guard, true, &consumer);
        try std.testing.expect(consumer.used);
        switch (venue) {
            .okx => {
                var signed = try @import("../adapters/okx/okx_rest_auth.zig").storedHeaders(&session, std.testing.io, &guard, true, "2026-11-06T00:00:00.000Z", "GET", "/api/v5/account/config", "");
                defer signed.clear();
                try std.testing.expectEqualStrings("OK-ACCESS-KEY: key", signed.slices()[0]);
            },
            .binance => {
                var auth = @import("../adapters/binance/binance_venue_adapter.zig").StoredAuthenticator{ .session = &session, .io = std.testing.io, .guard = &guard };
                const signature = try (try auth.interface()).sign(1000, "symbol=BTCUSDT&timestamp=1000");
                var expected: [32]u8 = undefined;
                std.crypto.auth.hmac.sha2.HmacSha256.create(&expected, "symbol=BTCUSDT&timestamp=1000", "secret");
                try std.testing.expectEqual(expected, signature);
            },
            .bybit => {
                var auth = @import("../adapters/bybit/bybit_venue_adapter.zig").StoredAuthenticator{ .session = &session, .io = std.testing.io, .guard = &guard };
                const signature = try (try auth.interface()).sign(1000, "{}");
                var expected: [32]u8 = undefined;
                std.crypto.auth.hmac.sha2.HmacSha256.create(&expected, "1000key5000{}", "secret");
                try std.testing.expectEqual(expected, signature);
            },
            else => unreachable,
        }
        try lifecycleTransition(&imported, metadata, .revoked);
        consumer.used = false;
        try std.testing.expectError(error.StaleCredentialSession, session.use(std.testing.io, 1, 1, &guard, true, &consumer));
        try std.testing.expect(!consumer.used);
    }
}

test "venue enrollment rejects password mismatch and wrong material without writing" {
    var path_buffer: [256]u8 = undefined;
    const path = try lifecycleTestPath(&path_buffer);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
    var metadata = try Metadata.init(.execution, 7, .testnet, 4_000_000_000, "mismatch", "node", "203.0.113.7");
    metadata.venue = .binance;
    metadata.can_trade = true;
    var store = try CredentialStore.openScoped(std.testing.io, std.testing.allocator, path, metadata);
    defer store.close(std.testing.io);
    var input = try lifecycleInputPipe(std.testing.io, "key\nsecret\nlifecycle-fixture-password\ndifferent-confirmation\n");
    defer input.close(std.testing.io);
    try std.testing.expectError(error.PasswordConfirmationMismatch, store.enroll(std.testing.io, metadata, input, .restricted_fd));
    var bytes: [max_file]u8 = undefined;
    try std.testing.expectError(error.FileNotFound, readFile(store.dir, std.testing.io, "execution.credential", &bytes));
    var material = try SecretMaterial.init("key", "secret", "unexpected");
    try std.testing.expectError(error.UnexpectedPassphrase, validateVenueMaterial(metadata, &material));
    metadata.venue = .okx;
    material.clear();
    material = try SecretMaterial.init("key", "secret", "");
    defer material.clear();
    try std.testing.expectError(error.InvalidCredential, validateVenueMaterial(metadata, &material));
}

test "venue enrollment carries Hyperliquid wallet signing through encrypted import" {
    var source_buffer: [256]u8 = undefined;
    const source = try lifecycleTestPath(&source_buffer);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, source) catch {};
    var target_buffer: [256]u8 = undefined;
    const target = try lifecycleTestPath(&target_buffer);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, target) catch {};
    var metadata = try Metadata.init(.execution, 7, .testnet, 4_000_000_000, "wallet-enrolled", "node", "203.0.113.7");
    metadata.venue = .hyperliquid;
    metadata.can_trade = true;
    var producer = try CredentialStore.openScoped(std.testing.io, std.testing.allocator, source, metadata);
    defer producer.close(std.testing.io);
    var input = try lifecycleInputPipe(std.testing.io, "0000000000000000000000000000000000000000000000000000000000000001\n" ++
        "7e5f4552091a69125d5dfcb7b8c2659029395bdf\n" ++
        "0202020202020202020202020202020202020202\n" ++
        "lifecycle-fixture-password\nlifecycle-fixture-password\n");
    defer input.close(std.testing.io);
    try producer.enroll(std.testing.io, metadata, input, .restricted_fd);
    var encrypted: [max_file]u8 = undefined;
    const length = try readFile(producer.dir, std.testing.io, "execution.credential", &encrypted);
    var consumer = try CredentialStore.openScoped(std.testing.io, std.testing.allocator, target, metadata);
    defer consumer.close(std.testing.io);
    var password = try lifecyclePasswordPipe(std.testing.io);
    defer password.close(std.testing.io);
    _ = try consumer.importEncrypted(std.testing.io, encrypted[0..length], password, .restricted_fd, 1);
    try lifecycleTransition(&consumer, metadata, .active);
    metadata.state = .active;
    metadata.generation = 2;
    var signer: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&signer, "7e5f4552091a69125d5dfcb7b8c2659029395bdf");
    var context = WalletTestContext{ .signer = signer };
    try walletTestUse(&consumer, metadata, &context);
    try std.testing.expect(context.used);
    try lifecycleTransition(&consumer, metadata, .revoked);
    try std.testing.expectError(error.CredentialRevoked, walletTestUse(&consumer, metadata, &context));
}

test "venue enrollment observation sessions reject risk increases and expiry" {
    var path_buffer: [256]u8 = undefined;
    const path = try lifecycleTestPath(&path_buffer);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
    var metadata = try Metadata.init(.observation, 7, .testnet, 4_000_000_000, "observation", "node", "203.0.113.7");
    metadata.venue = .binance;
    var store = try CredentialStore.openScoped(std.testing.io, std.testing.allocator, path, metadata);
    defer store.close(std.testing.io);
    var input = try lifecycleInputPipe(std.testing.io, "key\nsecret\nlifecycle-fixture-password\nlifecycle-fixture-password\n");
    defer input.close(std.testing.io);
    try store.enroll(std.testing.io, metadata, input, .restricted_fd);
    try lifecycleTransition(&store, metadata, .active);
    metadata.state = .active;
    metadata.generation = 2;
    var password = try lifecyclePasswordPipe(std.testing.io);
    defer password.close(std.testing.io);
    var session = try store.openApiSession(std.testing.io, password, .restricted_fd, metadata, .{
        .venue = .binance,
        .account = 7,
        .environment = .testnet,
        .endpoint_environment = .testnet,
        .node_id = "node",
        .egress_ip = "203.0.113.7",
    }, 1, 0);
    defer session.deinit();
    const Context = struct {
        used: bool = false,
        pub fn use(self: *@This(), _: *const ApiCredentials) !void {
            self.used = true;
        }
    };
    var context: Context = .{};
    try std.testing.expectError(error.ReadOnlyPolicyViolation, session.use(std.testing.io, 1, 1, null, true, &context));
    try std.testing.expect(!context.used);
    try std.testing.expectError(error.CredentialExpired, session.use(std.testing.io, metadata.expires_at_unix, 1, null, false, &context));
    try std.testing.expect(!context.used);
    try session.use(std.testing.io, 1, 1, null, false, &context);
    try std.testing.expect(context.used);
}

// Payload v1 is the unchanged API triple. Prefix 0 cannot be a valid v1
// api_key length; 0,2 identifies the wallet payload without weakening old readers.
fn encodeMaterial(material: *const SecretMaterial, destination: []u8) !usize {
    switch (material.*) {
        .api_credentials => |*api| return encodeApiCredentials(api, destination),
        .api_wallet => |*wallet| {
            if (destination.len < 74) return error.InvalidCredential;
            const derived = try @import("wallet_crypto.zig").address(&wallet.private_key);
            if (!std.mem.eql(u8, &derived, &wallet.signer) or std.mem.allEqual(u8, &wallet.funding_account, 0)) return error.InvalidCredential;
            destination[0..2].* = .{ 0, 2 };
            @memcpy(destination[2..34], &wallet.private_key);
            @memcpy(destination[34..54], &wallet.signer);
            @memcpy(destination[54..74], &wallet.funding_account);
            return 74;
        },
    }
}

fn decodeMaterial(source: []const u8, result: *SecretMaterial) !void {
    result.* = .{ .api_credentials = .{} };
    errdefer result.clear();
    if (source.len != 0 and source[0] == 0) {
        if (source.len != 74 or source[1] != 2) return error.InvalidCredential;
        try result.initWallet(source[2..34], source[34..54].*, source[54..74].*);
    } else try decodeApiCredentials(source, &result.api_credentials);
}

fn encodeApiCredentials(material: *const ApiCredentials, destination: []u8) !usize {
    const total = 3 + @as(usize, material.api_key_len) + material.secret_key_len + material.passphrase_len;
    if (material.api_key_len > max_secret or material.secret_key_len > max_secret or material.passphrase_len > max_secret or total > destination.len or material.api_key_len == 0 or material.secret_key_len == 0) return error.InvalidCredential;
    destination[0] = material.api_key_len;
    destination[1] = material.secret_key_len;
    destination[2] = material.passphrase_len;
    var offset: usize = 3;
    @memcpy(destination[offset..][0..material.api_key_len], material.api_key[0..material.api_key_len]);
    offset += material.api_key_len;
    @memcpy(destination[offset..][0..material.secret_key_len], material.secret_key[0..material.secret_key_len]);
    offset += material.secret_key_len;
    @memcpy(destination[offset..][0..material.passphrase_len], material.passphrase[0..material.passphrase_len]);
    return total;
}

fn decodeApiCredentials(source: []const u8, result: *ApiCredentials) !void {
    errdefer result.clear();
    if (source.len < 5) return error.InvalidCredential;
    const lengths = [_]u8{ source[0], source[1], source[2] };
    const total = 3 + @as(usize, lengths[0]) + lengths[1] + lengths[2];
    if (lengths[0] > max_secret or lengths[1] > max_secret or lengths[2] > max_secret or source.len != total or lengths[0] == 0 or lengths[1] == 0) return error.InvalidCredential;
    result.* = .{};
    result.api_key_len = lengths[0];
    result.secret_key_len = lengths[1];
    result.passphrase_len = lengths[2];
    var offset: usize = 3;
    @memcpy(result.api_key[0..lengths[0]], source[offset..][0..lengths[0]]);
    offset += lengths[0];
    @memcpy(result.secret_key[0..lengths[1]], source[offset..][0..lengths[1]]);
    offset += lengths[1];
    @memcpy(result.passphrase[0..lengths[2]], source[offset..][0..lengths[2]]);
}

fn decrypt(io: std.Io, source: []const u8, password: []const u8, metadata: *Metadata, plaintext: []u8) !usize {
    var salt: [16]u8 = undefined;
    var nonce: [Aead.nonce_length]u8 = undefined;
    const payload_len = try decodeHeader(source, metadata, &salt, &nonce);
    var owned_password = try protected.Buffer.init(password.len);
    defer owned_password.deinit();
    @memcpy(try owned_password.writable(), password);
    try owned_password.freeze();
    var key = try protected.Buffer.init(Aead.key_length);
    defer key.deinit();
    try credential_kdf.derive(io, owned_password.bytes(), &salt, (try key.writable())[0..Aead.key_length]);
    const ciphertext = source[header_len .. header_len + payload_len];
    const tag: [payload_tag_len]u8 = source[header_len + payload_len ..][0..payload_tag_len].*;
    try Aead.decrypt(plaintext[0..payload_len], ciphertext, tag, source[0..header_len], nonce, key.bytes()[0..Aead.key_length]);
    return payload_len;
}

fn readFile(dir: std.Io.Dir, io: std.Io, name: []const u8, destination: []u8) !usize {
    var file = try dir.openFile(io, name, .{});
    defer file.close(io);
    var offset: usize = 0;
    while (offset < destination.len) {
        const amount = file.readStreaming(io, &.{destination[offset..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (amount == 0) break;
        offset += amount;
    }
    if (offset == destination.len) return error.FileTooLarge;
    return offset;
}

fn writeAtomic(dir: std.Io.Dir, io: std.Io, name: []const u8, bytes: []const u8, replace: bool) !void {
    var temporary_buffer: [96]u8 = undefined;
    var temporary_name: []const u8 = undefined;
    var file: std.Io.File = undefined;
    while (true) {
        var random: [16]u8 = undefined;
        io.random(&random);
        temporary_name = try std.fmt.bufPrint(&temporary_buffer, "{s}.{s}.tmp", .{ name, std.fmt.bytesToHex(random, .lower) });
        file = dir.createFile(io, temporary_name, .{
            .exclusive = true,
            .permissions = if (builtin.os.tag == .linux) @enumFromInt(0o600) else .default_file,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        break;
    }
    var file_open = true;
    defer {
        if (file_open) file.close(io);
        dir.deleteFile(io, temporary_name) catch {};
    }
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);
    file.close(io);
    file_open = false;
    if (replace) {
        try dir.rename(temporary_name, dir, name, io);
    } else if (builtin.os.tag == .linux) {
        // linkat creates the destination exclusively and atomically, including
        // on Linux ABIs lacking renameat2(RENAME_NOREPLACE), such as WSL1.
        dir.hardLink(temporary_name, dir, name, io, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => return error.CredentialAlreadyRegistered,
            else => return err,
        };
        try dir.deleteFile(io, temporary_name);
    } else {
        dir.renamePreserve(temporary_name, dir, name, io) catch |err| switch (err) {
            error.PathAlreadyExists => return error.CredentialAlreadyRegistered,
            else => return err,
        };
    }
    syncDirectory(dir) catch return error.DirectorySyncFailed;
}

fn syncDirectory(dir: std.Io.Dir) !void {
    if (builtin.os.tag == .linux) switch (std.os.linux.errno(std.os.linux.fsync(dir.handle))) {
        .SUCCESS => {},
        else => return error.DirectorySyncFailed,
    };
    if (builtin.os.tag == .windows) {
        // NT directory handles reject FlushFileBuffers (INVALID_HANDLE /
        // INVALID_PARAMETER / NOT_SUPPORTED). Files in writeAtomic already
        // called File.sync, which is FlushFileBuffers. This is Windows
        // functional verification only, not directory/power-loss qualification.
        _ = windows_flush(dir.handle);
    }
}

fn selfCheckPasses(check: SecuritySelfCheck) bool {
    return if (builtin.os.tag == .windows) check.passesWindowsVerification() else check.passes();
}

fn protectionAccepted(report: ProtectionReport) bool {
    if (builtin.os.tag == .windows) return report.locked and report.access_protected and report.wipe_on_release;
    return report.accepted();
}

fn testStorePath(comptime name: []const u8) []const u8 {
    return if (builtin.os.tag == .windows) "C:\\Windows\\Temp\\" ++ name else "/tmp/" ++ name;
}

const FILE_TYPE_PIPE: u32 = 3;
const windows_api = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn GetFileType(handle: std.os.windows.HANDLE) callconv(.winapi) u32;
    extern "kernel32" fn GetConsoleMode(handle: std.os.windows.HANDLE, mode: *u32) callconv(.winapi) i32;
    extern "kernel32" fn SetConsoleMode(handle: std.os.windows.HANDLE, mode: u32) callconv(.winapi) i32;
    extern "kernel32" fn CreatePipe(
        read_pipe: *std.os.windows.HANDLE,
        write_pipe: *std.os.windows.HANDLE,
        attributes: ?*anyopaque,
        size: u32,
    ) callconv(.winapi) i32;
    extern "kernel32" fn WriteFile(
        handle: std.os.windows.HANDLE,
        buffer: [*]const u8,
        length: u32,
        written: *u32,
        overlapped: ?*anyopaque,
    ) callconv(.winapi) i32;
    extern "kernel32" fn FlushFileBuffers(handle: std.os.windows.HANDLE) callconv(.winapi) i32;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
} else struct {};

fn windows_flush(handle: std.os.windows.HANDLE) i32 {
    if (builtin.os.tag != .windows) return 1;
    return windows_api.FlushFileBuffers(handle);
}

pub const AcceptanceEvidence = struct {
    observation_state: AdmissionState,
    send_capability: bool,
    execution_separate: bool,
    encrypted_file: bool,
    authenticated_metadata: bool,
    lifecycle_persisted: bool,
};

pub fn runLinuxAcceptance(init: std.process.Init) !void {
    if (builtin.os.tag != .linux) return error.LinuxCredentialStoreRequired;
    var path: [128]u8 = undefined;
    var random: [16]u8 = undefined;
    init.io.random(&random);
    const absolute_path = try std.fmt.bufPrint(&path, "/tmp/ringwin-credential-store-{s}", .{std.fmt.bytesToHex(random, .lower)});
    try std.Io.Dir.createDirAbsolute(init.io, absolute_path, if (builtin.os.tag == .linux) @enumFromInt(0o700) else .default_dir);
    defer std.Io.Dir.cwd().deleteTree(init.io, absolute_path) catch {};
    var store = try CredentialStore.open(init.io, init.gpa, absolute_path);
    defer store.close(init.io);
    var metadata = try Metadata.init(.observation, 42, .production, 4_000_000_000, "obs-prod-42", "linux-node-1", "198.51.100.42");
    var material = try SecretMaterial.init("observation-key", "observation-secret", "observation-pass");
    var created_regular_file = try store.dir.createFile(init.io, "password.txt", .{ .truncate = true });
    created_regular_file.close(init.io);
    var regular_file = try store.dir.openFile(init.io, "password.txt", .{});
    defer regular_file.close(init.io);
    var rejected_material = try SecretMaterial.init("rejected-key", "rejected-secret", "rejected-pass");
    var rejected_password: [max_password]u8 = undefined;
    @memset(&rejected_password, 0xa5);
    var restricted_rejected = false;
    store.stage(init.io, metadata, &rejected_material, regular_file, .restricted_fd, &rejected_password) catch |err| switch (err) {
        error.RestrictedStreamRequired => restricted_rejected = true,
        else => return err,
    };
    if (!restricted_rejected) return error.RegularPasswordFileAccepted;
    if (rejected_material.api_credentials.api_key_len != 0 or rejected_material.api_credentials.secret_key_len != 0 or rejected_material.api_credentials.passphrase_len != 0)
        return error.RejectedSecretNotCleared;
    for (rejected_password) |byte| if (byte != 0) return error.RejectedPasswordNotCleared;
    var password_pipe: [2]std.posix.fd_t = undefined;
    if (std.os.linux.errno(std.os.linux.pipe(&password_pipe)) != .SUCCESS)
        return error.PasswordPipeFailed;
    var read_file: std.Io.File = .{
        .handle = password_pipe[0],
        .flags = .{ .nonblocking = false },
    };
    defer read_file.close(init.io);
    const fixture_password = "fixture-password\n";
    const write_result = std.os.linux.write(
        password_pipe[1],
        fixture_password.ptr,
        fixture_password.len,
    );
    _ = std.os.linux.close(password_pipe[1]);
    if (std.os.linux.errno(write_result) != .SUCCESS or write_result != fixture_password.len)
        return error.PasswordPipeFailed;
    var password_bytes = try protected.Buffer.init(max_password + 1);
    defer password_bytes.deinit();
    const password = try readPassword(init.io, read_file, .restricted_fd, try password_bytes.writable());
    try password_bytes.freeze();
    try store.stageWithPassword(init.io, metadata, &material, password);
    try store.activateWithPassword(init.io, .observation, password, metadata);
    metadata.state = .active;
    metadata.generation += 1;
    const runtime = RuntimeContext{ .account = 42, .environment = .production, .endpoint_environment = .production, .node_id = "linux-node-1", .egress_ip = "198.51.100.42" };
    const admission = try store.admitObservationWithPassword(init.io, password, metadata, runtime, 1_700_000_000, .native, .{});
    if (!admission.isReady() or admission.send_capability or admission.trading_enabled) return error.SecurityGateClosed;
    try store.revokeWithPassword(init.io, .observation, password, metadata);
    const revoked = store.admitObservationWithPassword(init.io, password, metadata, runtime, 1_700_000_000, .native, .{});
    if (revoked != error.CredentialRevoked) return error.RevocationNotPersistent;
    const evidence = AcceptanceEvidence{ .observation_state = admission.state, .send_capability = admission.send_capability, .execution_separate = true, .encrypted_file = true, .authenticated_metadata = true, .lifecycle_persisted = true };
    var output: [2048]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &output);
    try stdout.interface.print("credential_admission: state={s}, mode=read_only, send_capability={}, execution_separate={}, encrypted_file={}, metadata_authenticated={}, lifecycle_persisted={}\n", .{ @tagName(evidence.observation_state), evidence.send_capability, evidence.execution_separate, evidence.encrypted_file, evidence.authenticated_metadata, evidence.lifecycle_persisted });
    try stdout.interface.flush();
}

pub fn runWindowsAcceptance(init: std.process.Init) !void {
    if (builtin.os.tag != .windows) return error.WindowsCredentialStoreRequired;
    var path: [260]u8 = undefined;
    var random: [16]u8 = undefined;
    init.io.random(&random);
    const absolute_path = try std.fmt.bufPrint(&path, "C:\\Windows\\Temp\\ringwin-credential-store-{s}", .{std.fmt.bytesToHex(random, .lower)});
    try std.Io.Dir.createDirAbsolute(init.io, absolute_path, if (builtin.os.tag == .linux) @enumFromInt(0o700) else .default_dir);
    defer std.Io.Dir.cwd().deleteTree(init.io, absolute_path) catch {};
    var store = try CredentialStore.open(init.io, init.gpa, absolute_path);
    defer store.close(init.io);
    var metadata = try Metadata.init(.observation, 42, .production, 4_000_000_000, "obs-win-42", "windows-node-1", "198.51.100.42");
    var material = try SecretMaterial.init("observation-key", "observation-secret", "observation-pass");
    var created_regular_file = try store.dir.createFile(init.io, "password.txt", .{ .truncate = true });
    created_regular_file.close(init.io);
    var regular_file = try store.dir.openFile(init.io, "password.txt", .{});
    defer regular_file.close(init.io);
    var rejected_material = try SecretMaterial.init("rejected-key", "rejected-secret", "rejected-pass");
    var rejected_password: [max_password]u8 = undefined;
    @memset(&rejected_password, 0xa5);
    var restricted_rejected = false;
    store.stage(init.io, metadata, &rejected_material, regular_file, .restricted_fd, &rejected_password) catch |err| switch (err) {
        error.RestrictedStreamRequired => restricted_rejected = true,
        else => return err,
    };
    if (!restricted_rejected) return error.RegularPasswordFileAccepted;
    var read_handle: std.os.windows.HANDLE = undefined;
    var write_handle: std.os.windows.HANDLE = undefined;
    if (windows_api.CreatePipe(&read_handle, &write_handle, null, 0) == 0) return error.PasswordPipeFailed;
    var read_file: std.Io.File = .{ .handle = read_handle, .flags = .{ .nonblocking = false } };
    defer read_file.close(init.io);
    const fixture_password = "fixture-password\n";
    var written: u32 = 0;
    if (windows_api.WriteFile(write_handle, fixture_password.ptr, @intCast(fixture_password.len), &written, null) == 0)
        return error.PasswordPipeFailed;
    std.os.windows.CloseHandle(write_handle);
    var password_bytes = try protected.Buffer.init(max_password + 1);
    defer password_bytes.deinit();
    const password = try readPassword(init.io, read_file, .restricted_fd, try password_bytes.writable());
    try password_bytes.freeze();
    try store.stageWithPassword(init.io, metadata, &material, password);
    try store.activateWithPassword(init.io, .observation, password, metadata);
    metadata.state = .active;
    metadata.generation += 1;
    const runtime = RuntimeContext{ .account = 42, .environment = .production, .endpoint_environment = .production, .node_id = "windows-node-1", .egress_ip = "198.51.100.42" };
    const admission = try store.admitObservationWithPassword(init.io, password, metadata, runtime, 1_700_000_000, .native, .{ .dont_dump = false });
    if (!admission.isReady() or admission.send_capability or admission.trading_enabled) return error.SecurityGateClosed;
    try store.revokeWithPassword(init.io, .observation, password, metadata);
    const revoked = store.admitObservationWithPassword(init.io, password, metadata, runtime, 1_700_000_000, .native, .{ .dont_dump = false });
    if (revoked != error.CredentialRevoked) return error.RevocationNotPersistent;
    if (store.admitExecution()) |_| return error.ExecutionAdmissionOutOfScope else |err| if (err != error.ExecutionAdmissionOutOfScope) return err;
    var output: [2048]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &output);
    try stdout.interface.print(
        "credential_admission: state={s}, mode=read_only, send_capability=false, trading_enabled=false, protection=windows_virtual_lock, linux_admission_equivalent=false\n",
        .{@tagName(admission.state)},
    );
    try stdout.interface.flush();
}

test "credential metadata and secret payload are authenticated" {
    if (builtin.os.tag != .linux and builtin.os.tag != .windows) return;
    var path_buffer: [256]u8 = undefined;
    const path = try lifecycleTestPath(&path_buffer);
    var store = try CredentialStore.open(std.testing.io, std.testing.allocator, path);
    defer store.close(std.testing.io);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
    const metadata = try Metadata.init(.observation, 7, .production, 4_000_000_000, "obs", "node", "203.0.113.7");
    var material = try SecretMaterial.init("key", "secret", "pass");
    const password = PasswordSource.testOnly("password");
    try store.stageWithPassword(std.testing.io, metadata, &material, password);
    try store.activateWithPassword(std.testing.io, .observation, password, metadata);
    var active = metadata;
    active.state = .active;
    active.generation += 1;
    const runtime = RuntimeContext{ .account = 7, .environment = .production, .endpoint_environment = .production, .node_id = "node", .egress_ip = "203.0.113.7" };
    const admission = try store.admitObservationWithPassword(std.testing.io, password, active, runtime, 1, .test_bypass, .{});
    try std.testing.expect(admission.isReady());
    try std.testing.expect(!admission.send_capability);
    var wrong_runtime = runtime;
    wrong_runtime.egress_ip = "203.0.113.99";
    try std.testing.expectError(error.RuntimeContextMismatch, store.admitObservationWithPassword(std.testing.io, password, active, wrong_runtime, 1, .test_bypass, .{}));
    try std.testing.expectError(error.CredentialExpired, store.admitObservationWithPassword(std.testing.io, password, active, runtime, 4_000_000_000, .test_bypass, .{}));
    try std.testing.expectError(error.AuthenticationFailed, store.admitObservationWithPassword(std.testing.io, PasswordSource.testOnly("wrong"), active, runtime, 1, .test_bypass, .{}));
}

test "policy, lifecycle, and security failures close admission" {
    if (builtin.os.tag != .linux and builtin.os.tag != .windows) return;
    var path_buffer: [256]u8 = undefined;
    const path = try lifecycleTestPath(&path_buffer);
    var store = try CredentialStore.open(std.testing.io, std.testing.allocator, path);
    defer store.close(std.testing.io);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
    var metadata = try Metadata.init(.observation, 8, .production, 4_000_000_000, "obs", "node", "203.0.113.8");
    var material = try SecretMaterial.init("key", "secret", "pass");
    const password = PasswordSource.testOnly("password");
    try store.stageWithPassword(std.testing.io, metadata, &material, password);
    try store.activateWithPassword(std.testing.io, .observation, password, metadata);
    metadata.state = .active;
    metadata.generation += 1;
    var check = SecuritySelfCheck{};
    check.lock_memory = false;
    const runtime = RuntimeContext{ .account = 8, .environment = .production, .endpoint_environment = .production, .node_id = "node", .egress_ip = "203.0.113.8" };
    try std.testing.expectError(error.SecurityGateClosed, store.admitObservationWithPassword(std.testing.io, password, metadata, runtime, 1, .test_bypass, check));
    try std.testing.expect(!allowsReadOnly(.order_write));
    try std.testing.expect(!allowsReadOnly(.funds_transfer));
    try std.testing.expectError(error.ExecutionAdmissionOutOfScope, store.admitExecution());
    try store.revokeWithPassword(std.testing.io, .observation, password, metadata);
    try std.testing.expectError(error.InvalidCredentialTransition, store.activateWithPassword(std.testing.io, .observation, password, metadata));
}

test "Secret exposes only read-only material and reports page protection" {
    if (builtin.os.tag != .linux and builtin.os.tag != .windows) return;
    var material = try SecretMaterial.init("key", "secret", "pass");
    defer material.clear();
    var secret = try Secret.init(std.testing.allocator, &material, .test_bypass);
    defer secret.deinit();

    try std.testing.expect(protectionAccepted(secret.report()));
    secret.expose(assertTestSecretMaterial);
}

fn assertTestSecretMaterial(material: *const SecretMaterial) void {
    std.debug.assert(std.mem.eql(u8, material.api_credentials.api_key[0..material.api_credentials.api_key_len], "key"));
    std.debug.assert(std.mem.eql(u8, material.api_credentials.secret_key[0..material.api_credentials.secret_key_len], "secret"));
    std.debug.assert(std.mem.eql(u8, material.api_credentials.passphrase[0..material.api_credentials.passphrase_len], "pass"));
}

/// Real inherited pipe; public lifecycle APIs own and wipe the supplied buffer.
fn lifecyclePasswordPipe(io: std.Io) !std.Io.File {
    return lifecycleInputPipe(io, "lifecycle-fixture-password\n");
}

fn lifecycleInputPipe(io: std.Io, input: []const u8) !std.Io.File {
    if (builtin.os.tag == .windows) {
        var reader: std.os.windows.HANDLE = undefined;
        var writer: std.os.windows.HANDLE = undefined;
        if (windows_api.CreatePipe(&reader, &writer, null, 0) == 0) return error.PasswordPipeFailed;
        var file: std.Io.File = .{ .handle = reader, .flags = .{ .nonblocking = false } };
        errdefer file.close(io);
        defer std.os.windows.CloseHandle(writer);
        var written: u32 = 0;
        if (windows_api.WriteFile(writer, input.ptr, @intCast(input.len), &written, null) == 0 or written != input.len)
            return error.PasswordPipeFailed;
        return file;
    } else {
        var descriptors: [2]std.posix.fd_t = undefined;
        if (std.os.linux.errno(std.os.linux.pipe(&descriptors)) != .SUCCESS) return error.PasswordPipeFailed;
        var file: std.Io.File = .{ .handle = descriptors[0], .flags = .{ .nonblocking = false } };
        errdefer file.close(io);
        defer _ = std.os.linux.close(descriptors[1]);
        const written = std.os.linux.write(descriptors[1], input.ptr, input.len);
        if (std.os.linux.errno(written) != .SUCCESS or written != input.len) return error.PasswordPipeFailed;
        return file;
    }
}

fn lifecycleStage(store: *CredentialStore, metadata: Metadata) !void {
    var pipe = try lifecyclePasswordPipe(std.testing.io);
    defer pipe.close(std.testing.io);
    var password: [max_password]u8 = @splat(0xa5);
    var material = try SecretMaterial.init("fixture-key", "fixture-secret", "fixture-pass");
    defer {
        std.debug.assert(material.api_credentials.api_key_len == 0 and material.api_credentials.secret_key_len == 0 and material.api_credentials.passphrase_len == 0);
        for (password) |byte| std.debug.assert(byte == 0);
    }
    try store.stage(std.testing.io, metadata, &material, pipe, .restricted_fd, &password);
}

fn lifecycleTransition(store: *CredentialStore, expected: Metadata, next: CredentialState) !void {
    var pipe = try lifecyclePasswordPipe(std.testing.io);
    defer pipe.close(std.testing.io);
    var password: [max_password]u8 = undefined;
    switch (next) {
        .active => try store.activate(std.testing.io, expected.kind, pipe, .restricted_fd, &password, expected),
        .retiring => try store.retire(std.testing.io, expected.kind, pipe, .restricted_fd, &password, expected),
        .revoked => try store.revoke(std.testing.io, expected.kind, pipe, .restricted_fd, &password, expected),
        .staged => unreachable,
    }
}

fn lifecycleTestPath(buffer: []u8) ![]const u8 {
    var random: [16]u8 = undefined;
    std.testing.io.random(&random);
    return std.fmt.bufPrint(buffer, "{s}{x}", .{ testStorePath("ringwin-lifecycle-"), std.fmt.bytesToHex(random, .lower) });
}

test "public lifecycle refuses restaging revoked identity and preserves revocation" {
    if (builtin.os.tag != .linux and builtin.os.tag != .windows) return;
    var path_buffer: [256]u8 = undefined;
    const path = try lifecycleTestPath(&path_buffer);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
    var store = try CredentialStore.open(std.testing.io, std.testing.allocator, path);
    defer store.close(std.testing.io);
    var metadata = try Metadata.init(.observation, 71, .production, 4_000_000_000, "revoked", "node", "203.0.113.71");
    try lifecycleStage(&store, metadata);
    try lifecycleTransition(&store, metadata, .active);
    metadata.state = .active;
    metadata.generation = 2;
    try lifecycleTransition(&store, metadata, .revoked);
    var before: [max_file]u8 = undefined;
    const before_len = try readFile(store.dir, std.testing.io, "observation.credential", &before);
    var initial = metadata;
    initial.state = .staged;
    initial.generation = 1;
    try std.testing.expectError(error.CredentialAlreadyRegistered, lifecycleStage(&store, initial));
    var after: [max_file]u8 = undefined;
    const after_len = try readFile(store.dir, std.testing.io, "observation.credential", &after);
    try std.testing.expectEqualSlices(u8, before[0..before_len], after[0..after_len]);
    try std.testing.expectError(error.CredentialRevoked, lifecycleTransition(&store, metadata, .retiring));
}

test "public stage preserves corrupt existing file and unrelated temporary file" {
    if (builtin.os.tag != .linux and builtin.os.tag != .windows) return;
    var path_buffer: [256]u8 = undefined;
    const path = try lifecycleTestPath(&path_buffer);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
    var store = try CredentialStore.open(std.testing.io, std.testing.allocator, path);
    defer store.close(std.testing.io);
    try store.dir.writeFile(std.testing.io, .{ .sub_path = "observation.credential", .data = "corrupt-original" });
    try store.dir.writeFile(std.testing.io, .{ .sub_path = "observation.credential.tmp", .data = "another-writer-owned" });
    const metadata = try Metadata.init(.observation, 72, .production, 4_000_000_000, "new", "node", "203.0.113.72");
    try std.testing.expectError(error.CredentialAlreadyRegistered, lifecycleStage(&store, metadata));
    var bytes: [max_file]u8 = undefined;
    const len = try readFile(store.dir, std.testing.io, "observation.credential", &bytes);
    try std.testing.expectEqualStrings("corrupt-original", bytes[0..len]);
    const sentinel_len = try readFile(store.dir, std.testing.io, "observation.credential.tmp", &bytes);
    try std.testing.expectEqualStrings("another-writer-owned", bytes[0..sentinel_len]);
    var iterator = store.dir.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |entry| {
        try std.testing.expect(std.mem.eql(u8, entry.name, "observation.credential") or
            std.mem.eql(u8, entry.name, "observation.credential.tmp") or
            std.mem.eql(u8, entry.name, "credential.writer.lock"));
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "public lifecycle independent writer lock prevents stale revoke overwrite" {
    if (builtin.os.tag != .linux and builtin.os.tag != .windows) return;
    var path_buffer: [256]u8 = undefined;
    const path = try lifecycleTestPath(&path_buffer);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
    var store = try CredentialStore.open(std.testing.io, std.testing.allocator, path);
    defer store.close(std.testing.io);
    var other = try CredentialStore.open(std.testing.io, std.testing.allocator, path);
    defer other.close(std.testing.io);
    var metadata = try Metadata.init(.observation, 73, .production, 4_000_000_000, "locked", "node", "203.0.113.73");
    try lifecycleStage(&store, metadata);
    {
        // Independently opened OS lock, including across replacement of the
        // credential path. The lock file must remain the same inode.
        var lock = try store.dir.createFile(std.testing.io, "credential.writer.lock", .{ .read = true, .truncate = false });
        defer lock.close(std.testing.io);
        try lock.lock(std.testing.io, .exclusive);
        try std.testing.expectError(error.CredentialWriterBusy, lifecycleTransition(&other, metadata, .active));
        try std.testing.expectError(error.CredentialWriterBusy, lifecycleStage(&other, metadata));
    }
    try lifecycleTransition(&store, metadata, .active);
    try std.testing.expectError(error.MetadataMismatch, lifecycleTransition(&other, metadata, .revoked));
    metadata.state = .active;
    metadata.generation = 2;
    try lifecycleTransition(&store, metadata, .revoked);
    try std.testing.expectError(error.CredentialRevoked, lifecycleTransition(&other, metadata, .retiring));
}

const LifecycleRace = struct {
    store: *CredentialStore,
    metadata: Metadata,
    start: *std.atomic.Value(bool),
    result: ?anyerror = null,

    fn run(self: *LifecycleRace) void {
        while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
        lifecycleStage(self.store, self.metadata) catch |err| {
            self.result = err;
        };
    }
};

test "public stage concurrent first registration admits one authenticated identity" {
    if (builtin.os.tag != .linux and builtin.os.tag != .windows) return;
    var path_buffer: [256]u8 = undefined;
    const path = try lifecycleTestPath(&path_buffer);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
    var first = try CredentialStore.open(std.testing.io, std.testing.allocator, path);
    defer first.close(std.testing.io);
    var second = try CredentialStore.open(std.testing.io, std.testing.allocator, path);
    defer second.close(std.testing.io);
    var start = std.atomic.Value(bool).init(false);
    var a = LifecycleRace{ .store = &first, .metadata = try Metadata.init(.observation, 74, .production, 4_000_000_000, "winner-a", "node", "203.0.113.74"), .start = &start };
    var b = LifecycleRace{ .store = &second, .metadata = try Metadata.init(.observation, 74, .production, 4_000_000_000, "winner-b", "node", "203.0.113.74"), .start = &start };
    const one = try std.Thread.spawn(.{}, LifecycleRace.run, .{&a});
    const two = std.Thread.spawn(.{}, LifecycleRace.run, .{&b}) catch |err| {
        start.store(true, .release);
        one.join();
        return err;
    };
    start.store(true, .release);
    one.join();
    two.join();
    try std.testing.expect((a.result == null) != (b.result == null));
    const rejected: anyerror = if (a.result) |err| err else b.result.?;
    try std.testing.expect(rejected == error.CredentialWriterBusy or rejected == error.CredentialAlreadyRegistered);
    const winner = if (a.result == null) a.metadata else b.metadata;
    try lifecycleTransition(&first, winner, .active);
}

test "public stage rejects existing encrypted identity even with another password" {
    if (builtin.os.tag != .linux and builtin.os.tag != .windows) return;
    var path_buffer: [256]u8 = undefined;
    const path = try lifecycleTestPath(&path_buffer);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
    var store = try CredentialStore.open(std.testing.io, std.testing.allocator, path);
    defer store.close(std.testing.io);
    const metadata = try Metadata.init(.observation, 75, .production, 4_000_000_000, "original", "node", "203.0.113.75");
    try lifecycleStage(&store, metadata);
    var pipe = try lifecycleInputPipe(std.testing.io, "another-password\n");
    defer pipe.close(std.testing.io);
    var buffer: [max_password]u8 = undefined;
    var material = try SecretMaterial.init("replacement", "replacement", "replacement");
    var changed = metadata;
    changed.version = 2;
    try std.testing.expectError(error.CredentialAlreadyRegistered, store.stage(std.testing.io, changed, &material, pipe, .restricted_fd, &buffer));
    try lifecycleTransition(&store, metadata, .active);
}

test "public lifecycle reads and revokes original CRD4 v1 synthetic audit fixture" {
    if (builtin.os.tag != .linux and builtin.os.tag != .windows) return;
    var path_buffer: [256]u8 = undefined;
    const path = try lifecycleTestPath(&path_buffer);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
    var store = try CredentialStore.open(std.testing.io, std.testing.allocator, path);
    defer store.close(std.testing.io);
    try store.dir.writeFile(std.testing.io, .{ .sub_path = "observation.credential", .data = @embedFile("testdata/credential-store-crd4-v1-synthetic.credential") });
    var metadata = try Metadata.init(.observation, 7, .production, 4_000_000_000, "review-obs", "review-node", "203.0.113.7");
    metadata.state = .active;
    metadata.generation = 2;
    const runtime = RuntimeContext{ .account = 7, .environment = .production, .endpoint_environment = .production, .node_id = "review-node", .egress_ip = "203.0.113.7" };
    var password: [max_password]u8 = undefined;
    var wrong = try lifecycleInputPipe(std.testing.io, "incorrect-password\n");
    defer wrong.close(std.testing.io);
    try std.testing.expectError(error.AuthenticationFailed, store.admitObservationReadOnly(std.testing.io, wrong, .restricted_fd, &password, metadata, runtime, 1, .{}));
    var correct = try lifecycleInputPipe(std.testing.io, "synthetic-review-password\n");
    defer correct.close(std.testing.io);
    const admission = try store.admitObservationReadOnly(std.testing.io, correct, .restricted_fd, &password, metadata, runtime, 1, .{});
    try std.testing.expect(admission.isReady());
    try std.testing.expect(!admission.send_capability and !admission.trading_enabled);
    var revoke = try lifecycleInputPipe(std.testing.io, "synthetic-review-password\n");
    defer revoke.close(std.testing.io);
    try store.revoke(std.testing.io, .observation, revoke, .restricted_fd, &password, metadata);
    var stale = try lifecycleInputPipe(std.testing.io, "synthetic-review-password\n");
    defer stale.close(std.testing.io);
    try std.testing.expectError(error.CredentialRevoked, store.admitObservationReadOnly(std.testing.io, stale, .restricted_fd, &password, metadata, runtime, 1, .{}));
}

test "public stage rejects overlong pipe password and wipes caller buffers" {
    var path_buffer: [256]u8 = undefined;
    const path = try lifecycleTestPath(&path_buffer);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
    var store = try CredentialStore.open(std.testing.io, std.testing.allocator, path);
    defer store.close(std.testing.io);
    const metadata = try Metadata.init(.observation, 81, .production, 4_000_000_000, "input", "node", "203.0.113.81");
    var input: [max_password + 2]u8 = @splat('p');
    input[input.len - 1] = '\n';
    var pipe = try lifecycleInputPipe(std.testing.io, &input);
    defer pipe.close(std.testing.io);
    var password: [max_password]u8 = @splat(0xa5);
    var material = try SecretMaterial.init("key", "secret", "pass");
    try std.testing.expectError(error.PasswordTooLong, store.stage(std.testing.io, metadata, &material, pipe, .restricted_fd, &password));
    try std.testing.expect(std.mem.allEqual(u8, &password, 0));
    try std.testing.expectEqual(@as(u8, 0), material.api_credentials.api_key_len);
}

test "public store rejects unterminated input and malformed material without publication" {
    var path_buffer: [256]u8 = undefined;
    const path = try lifecycleTestPath(&path_buffer);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
    var store = try CredentialStore.open(std.testing.io, std.testing.allocator, path);
    defer store.close(std.testing.io);
    const metadata = try Metadata.init(.observation, 82, .production, 4_000_000_000, "input", "node", "203.0.113.82");
    var pipe = try lifecycleInputPipe(std.testing.io, "no-newline");
    defer pipe.close(std.testing.io);
    var password: [max_password]u8 = @splat(0xa5);
    var material = try SecretMaterial.init("key", "secret", "pass");
    try std.testing.expectError(error.UnterminatedPassword, store.stage(std.testing.io, metadata, &material, pipe, .restricted_fd, &password));
    try std.testing.expect(std.mem.allEqual(u8, &password, 0));
    try std.testing.expectEqual(@as(u8, 0), material.api_credentials.api_key_len);
    var malformed = try SecretMaterial.init("key", "secret", "pass");
    malformed.api_credentials.api_key_len = max_secret + 1;
    var complete = try lifecyclePasswordPipe(std.testing.io);
    defer complete.close(std.testing.io);
    try std.testing.expectError(error.InvalidCredential, store.stage(std.testing.io, metadata, &malformed, complete, .restricted_fd, &password));
    try std.testing.expect(std.mem.allEqual(u8, &password, 0));
    try std.testing.expectEqual(@as(u8, 0), malformed.api_credentials.api_key_len);
    try std.testing.expectError(error.SecurityGateClosed, lifecycleStage(&store, metadata));
}

test "public Linux store rejects a pipe presented as TTY and tightens private directory" {
    if (builtin.os.tag != .linux) return;
    var path_buffer: [256]u8 = undefined;
    const path = try lifecycleTestPath(&path_buffer);
    try std.Io.Dir.createDirAbsolute(std.testing.io, path, @enumFromInt(0o755));
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
    var store = try CredentialStore.open(std.testing.io, std.testing.allocator, path);
    defer store.close(std.testing.io);
    if (builtin.cpu.arch == .x86_64) {
        // WSL1 lacks statx, used by Io.Dir.stat. Linux x86_64 fstat ABI has
        // st_mode at offset24 in its144-byte structure (test observation only).
        var stat_bytes: [144]u8 align(8) = @splat(0);
        const result = std.os.linux.syscall2(.fstat, @intCast(store.dir.handle), @intFromPtr(&stat_bytes));
        try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(result));
        try std.testing.expectEqual(@as(u32, 0o700), std.mem.readInt(u32, stat_bytes[24..28], .little) & 0o777);
    }
    var tty = try lifecyclePasswordPipe(std.testing.io);
    defer tty.close(std.testing.io);
    const metadata = try Metadata.init(.observation, 83, .production, 4_000_000_000, "tty", "node", "203.0.113.83");
    var password: [max_password]u8 = @splat(0xa5);
    var material = try SecretMaterial.init("key", "secret", "pass");
    try std.testing.expectError(error.NotATty, store.stage(std.testing.io, metadata, &material, tty, .tty, &password));
    try std.testing.expect(std.mem.allEqual(u8, &password, 0));
    try std.testing.expectEqual(@as(u8, 0), material.api_credentials.api_key_len);
}

test "public admission rejects authenticated oversized decoded fields without panic" {
    var path_buffer: [256]u8 = undefined;
    const path = try lifecycleTestPath(&path_buffer);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
    var store = try CredentialStore.open(std.testing.io, std.testing.allocator, path);
    defer store.close(std.testing.io);
    var metadata = try Metadata.init(.observation, 84, .production, 4_000_000_000, "decode", "node", "203.0.113.84");
    metadata.state = .active;
    metadata.generation = 2;
    // Fixture construction is independent AEAD, not a call to decodeMaterial.
    const salt: [16]u8 = @splat(0x23);
    const nonce: [Aead.nonce_length]u8 = @splat(0x17);
    var malformed: [134]u8 = @splat(0x61);
    malformed[0] = 129;
    malformed[1] = 1;
    malformed[2] = 1;
    var key = try protected.Buffer.init(32);
    defer key.deinit();
    var fixture_password = try protected.Buffer.init("lifecycle-fixture-password".len);
    defer fixture_password.deinit();
    @memcpy(try fixture_password.writable(), "lifecycle-fixture-password");
    try credential_kdf.derive(std.testing.io, fixture_password.bytes(), &salt, (try key.writable())[0..32]);
    var encoded: [header_len + malformed.len + payload_tag_len]u8 = undefined;
    encodeHeader(&encoded, metadata, salt, nonce, malformed.len);
    var tag: [payload_tag_len]u8 = undefined;
    std.crypto.aead.chacha_poly.XChaCha20Poly1305.encrypt(encoded[header_len..][0..malformed.len], &tag, &malformed, encoded[0..header_len], nonce, key.bytes()[0..32].*);
    @memcpy(encoded[header_len + malformed.len ..], &tag);
    try store.dir.writeFile(std.testing.io, .{ .sub_path = "observation.credential", .data = &encoded });
    var pipe = try lifecyclePasswordPipe(std.testing.io);
    defer pipe.close(std.testing.io);
    var password: [max_password]u8 = @splat(0xa5);
    const runtime = RuntimeContext{ .account = 84, .environment = .production, .endpoint_environment = .production, .node_id = "node", .egress_ip = "203.0.113.84" };
    try std.testing.expectError(error.InvalidCredential, store.admitObservationReadOnly(std.testing.io, pipe, .restricted_fd, &password, metadata, runtime, 1, .{}));
    try std.testing.expect(std.mem.allEqual(u8, &password, 0));
}

test "public native stage refuses insufficient Linux memlock and wipes inputs" {
    if (builtin.os.tag != .linux) return;
    if ((try std.posix.getrlimit(.MEMLOCK)).cur >= credential_kdf.workspace_bytes + 16 * std.heap.pageSize()) return;
    var path_buffer: [256]u8 = undefined;
    const path = try lifecycleTestPath(&path_buffer);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
    var store = try CredentialStore.open(std.testing.io, std.testing.allocator, path);
    defer store.close(std.testing.io);
    const metadata = try Metadata.init(.observation, 85, .production, 4_000_000_000, "memlock", "node", "203.0.113.85");
    var pipe = try lifecyclePasswordPipe(std.testing.io);
    defer pipe.close(std.testing.io);
    var password: [max_password]u8 = @splat(0xa5);
    var material = try SecretMaterial.init("key", "secret", "pass");
    try std.testing.expectError(error.MemoryLockFailed, store.stage(std.testing.io, metadata, &material, pipe, .restricted_fd, &password));
    try std.testing.expect(std.mem.allEqual(u8, &password, 0));
    try std.testing.expectEqual(@as(u8, 0), material.api_credentials.api_key_len);
    try std.testing.expectError(error.FileNotFound, store.dir.openFile(std.testing.io, "observation.credential", .{}));
    std.debug.print("public store refused insufficient native memlock and cleared caller inputs\n", .{});
}

test "API wallet material rejects invalid keys and binds separate signer and funds" {
    var key: [32]u8 = @splat(0);
    defer std.crypto.secureZero(u8, &key);
    var material: SecretMaterial = undefined;
    try std.testing.expectError(error.InvalidPrivateKey, material.initWallet(&key, @splat(1), @splat(2)));
    key[31] = 1; // Public synthetic secp256k1 scalar, never a deployed wallet.
    const signer = try @import("wallet_crypto.zig").address(&key);
    try material.initWallet(&key, signer, @splat(2));
    defer material.clear();
    try std.testing.expectEqual(signer, material.api_wallet.signer);
    try std.testing.expectError(error.SignerAddressMismatch, material.initWallet(&key, @splat(1), @splat(2)));
    @memset(&key, 255);
    try std.testing.expectError(error.InvalidPrivateKey, material.initWallet(&key, signer, @splat(2)));
}

test "wallet credential public lifecycle preserves binding and revokes signing access" {
    var path_buffer: [256]u8 = undefined;
    const path = try lifecycleTestPath(&path_buffer);
    var store = try CredentialStore.open(std.testing.io, std.testing.allocator, path);
    defer store.close(std.testing.io);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
    var metadata = try Metadata.init(.execution, 7, .testnet, 4_000_000_000, "wallet", "node", "203.0.113.7");
    metadata.can_trade = true;
    var key: [32]u8 = @splat(0);
    defer std.crypto.secureZero(u8, &key);
    key[31] = 1;
    const signer = try @import("wallet_crypto.zig").address(&key);
    var material: SecretMaterial = undefined;
    try material.initWallet(&key, signer, @splat(2));
    var pipe = try lifecyclePasswordPipe(std.testing.io);
    defer pipe.close(std.testing.io);
    var password: [max_password]u8 = undefined;
    try store.stage(std.testing.io, metadata, &material, pipe, .restricted_fd, &password);
    try lifecycleTransition(&store, metadata, .active);
    metadata.state = .active;
    metadata.generation += 1;
    var context = WalletTestContext{ .signer = signer };
    var invalid = metadata;
    invalid.can_withdraw = true;
    try std.testing.expectError(error.WalletPolicyViolation, walletTestUse(&store, invalid, &context));
    invalid = metadata;
    invalid.expires_at_unix = 1;
    try std.testing.expectError(error.CredentialExpired, walletTestUse(&store, invalid, &context));
    invalid = metadata;
    invalid.account = 8;
    try std.testing.expectError(error.RuntimeContextMismatch, walletTestUse(&store, invalid, &context));
    invalid = metadata;
    invalid.credential_id_len = max_text + 1;
    try std.testing.expectError(error.InvalidCredentialMetadata, walletTestUse(&store, invalid, &context));
    try walletTestUse(&store, metadata, &context);
    try std.testing.expect(context.used);
    context.command_identity = 2;
    context.expire_during_digest = true;
    try std.testing.expectError(error.PrimaryLeaseExpired, walletTestUse(&store, metadata, &context));
    context.expire_during_digest = false;
    try std.testing.expectError(error.RequestAlreadyConsumed, walletTestUse(&store, metadata, &context));
    try lifecycleTransition(&store, metadata, .revoked);
    try std.testing.expectError(error.CredentialRevoked, walletTestUse(&store, metadata, &context));
}

const WalletTestContext = struct {
    signer: [20]u8,
    used: bool = false,
    command_identity: u128 = 1,
    expire_during_digest: bool = false,
    guard: ?*@import("../runtime/failover.zig").GatewayLeaseGuard = null,
    pub fn digest(self: *@This(), _: u64) ![32]u8 {
        self.used = true;
        if (self.expire_during_digest) self.guard.?.lease.expires_at_ns = 0;
        var result: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&result, "eb995f6f09994a13de522ce0cc454871e81500e01de770e09d9fa6f5d2742601");
        return result;
    }
};

fn walletTestUse(store: *CredentialStore, metadata: Metadata, context: *WalletTestContext) !void {
    var pipe = try lifecyclePasswordPipe(std.testing.io);
    defer pipe.close(std.testing.io);
    var password: [max_password]u8 = undefined;
    const failover = @import("../runtime/failover.zig");
    var authority = failover.FencingAuthority{ .durable = true };
    var lease = try authority.acquire(.{ .exchange_account = 7, .decision_domain = 1 }, 1, 0);
    lease.expires_at_ns = std.time.ns_per_hour;
    var guard = failover.GatewayLeaseGuard{ .authority = &authority, .lease = &lease };
    context.guard = &guard;
    defer context.guard = null;
    const session_id = try walletSession(metadata, context.signer, @splat(2), 0, lease.token);
    const result = try store.signWallet(std.testing.io, pipe, .restricted_fd, &password, metadata, .{
        .venue = metadata.venue,
        .account = 7,
        .environment = .testnet,
        .endpoint_environment = .testnet,
        .node_id = "node",
        .egress_ip = "203.0.113.7",
    }, .{ .signer = context.signer, .funding = @splat(2), .scope = 0, .session = session_id, .owner_token = lease.token, .guard = &guard, .command_identity = context.command_identity, .now_ms = 1000, .now_monotonic_ns = 1 }, context);
    try std.testing.expectEqual(context.signer, try @import("wallet_crypto.zig").recover(result.digest, result.signature));
    var signature_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&(result.signature.r ++ result.signature.s ++ [_]u8{result.signature.v}), &signature_hash, .{});
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "5149cc2ecf929663bdeeaf9a1287d5220ca2bf0be091fcb662d9488aff1eb156");
    try std.testing.expectEqual(expected, signature_hash);
}

test "Hyperliquid signer consumes Unknown across restart and fences old owner" {
    const signing = @import("../adapters/hyperliquid/hyperliquid_signer.zig");
    const failover = @import("../runtime/failover.zig");
    var path_buffer: [256]u8 = undefined;
    const path = try lifecycleTestPath(&path_buffer);
    var store = try CredentialStore.open(std.testing.io, std.testing.allocator, path);
    defer store.close(std.testing.io);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
    var metadata = try Metadata.init(.execution, 7, .testnet, 4_000_000_000, "wallet", "node", "203.0.113.7");
    metadata.can_trade = true;
    var key: [32]u8 = @splat(0);
    defer std.crypto.secureZero(u8, &key);
    key[31] = 1;
    const address = try @import("wallet_crypto.zig").address(&key);
    var material: SecretMaterial = undefined;
    try material.initWallet(&key, address, @splat(2));
    var pipe = try lifecyclePasswordPipe(std.testing.io);
    defer pipe.close(std.testing.io);
    var password: [max_password]u8 = undefined;
    try store.stage(std.testing.io, metadata, &material, pipe, .restricted_fd, &password);
    try lifecycleTransition(&store, metadata, .active);
    metadata.state = .active;
    metadata.generation += 1;
    var authority = failover.FencingAuthority{ .durable = true };
    var lease = try authority.acquire(.{ .exchange_account = 7, .decision_domain = 1 }, 1, 0);
    lease.expires_at_ns = std.time.ns_per_hour;
    var guard = failover.GatewayLeaseGuard{ .authority = &authority, .lease = &lease };
    const signer = try signing.Signer.init(metadata, address, @splat(2), .master, lease.token);
    var request = signing.Request{ .command_identity = 1, .session = signer.session(), .environment = .testnet, .action = "\x81\xa4type\xa5order", .now_ms = 1000000, .now_monotonic_ns = 1, .fencing_token = lease.token };
    const runtime = RuntimeContext{ .account = 7, .environment = .testnet, .endpoint_environment = .testnet, .node_id = "node", .egress_ip = "203.0.113.7" };
    var invalid_input = try lifecyclePasswordPipe(std.testing.io);
    defer invalid_input.close(std.testing.io);
    request.environment = .production;
    try std.testing.expectError(error.EnvironmentMismatch, signer.sign(&store, std.testing.io, invalid_input, .restricted_fd, &password, runtime, &guard, request));
    request.environment = .testnet;
    request.session += 1;
    try std.testing.expectError(error.StaleSignerSession, signer.sign(&store, std.testing.io, invalid_input, .restricted_fd, &password, runtime, &guard, request));
    request.session = signer.session();
    const wrong_binding = try signing.Signer.init(metadata, address, @splat(3), .master, lease.token);
    var wrong_request = request;
    wrong_request.session = wrong_binding.session();
    try std.testing.expectError(error.WalletBindingMismatch, wrong_binding.sign(&store, std.testing.io, invalid_input, .restricted_fd, &password, runtime, &guard, wrong_request));
    var input = try lifecyclePasswordPipe(std.testing.io);
    defer input.close(std.testing.io);
    const first = try signer.sign(&store, std.testing.io, input, .restricted_fd, &password, runtime, &guard, request);
    try std.testing.expectEqual(@as(u64, 1000000), first.nonce);
    try std.testing.expectEqual(address, try @import("wallet_crypto.zig").recover(first.digest, first.signature));
    // A new store object and later timestamp do not make an Unknown retry safe.
    var reopened = try CredentialStore.open(std.testing.io, std.testing.allocator, path);
    defer reopened.close(std.testing.io);
    var retry = try lifecyclePasswordPipe(std.testing.io);
    defer retry.close(std.testing.io);
    request.now_ms += 1;
    try std.testing.expectError(error.RequestAlreadyConsumed, signer.sign(&reopened, std.testing.io, retry, .restricted_fd, &password, runtime, &guard, request));
    var next = try lifecyclePasswordPipe(std.testing.io);
    defer next.close(std.testing.io);
    request.command_identity = 2;
    request.now_ms -= 10; // Clock rollback advances the persisted high-water mark.
    const second = try signer.sign(&reopened, std.testing.io, next, .restricted_fd, &password, runtime, &guard, request);
    try std.testing.expectEqual(first.nonce + 1, second.nonce);
    request.command_identity = 3;
    // Inject competition at the OS lock boundary, as another signer process.
    const writer = try store.dir.createFile(std.testing.io, "credential.writer.lock", .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true });
    var competing = try lifecyclePasswordPipe(std.testing.io);
    defer competing.close(std.testing.io);
    const competition = signer.sign(&reopened, std.testing.io, competing, .restricted_fd, &password, runtime, &guard, request);
    writer.close(std.testing.io);
    try std.testing.expectError(error.CredentialWriterBusy, competition);
    var skewed = try lifecyclePasswordPipe(std.testing.io);
    defer skewed.close(std.testing.io);
    // The actual skew here is below the one-hour limit, so move the persisted
    // high-water forward first, then refuse an excessive rollback.
    request.now_ms = 10000000;
    _ = try signer.sign(&reopened, std.testing.io, skewed, .restricted_fd, &password, runtime, &guard, request);
    request.command_identity = 4;
    request.now_ms = 1;
    var rollback = try lifecyclePasswordPipe(std.testing.io);
    defer rollback.close(std.testing.io);
    try std.testing.expectError(error.NonceClockSkew, signer.sign(&reopened, std.testing.io, rollback, .restricted_fd, &password, runtime, &guard, request));
    request.now_ms = 10000000;
    request.now_monotonic_ns = lease.expires_at_ns;
    var expired = try lifecyclePasswordPipe(std.testing.io);
    defer expired.close(std.testing.io);
    try std.testing.expectError(error.PrimaryLeaseExpired, signer.sign(&store, std.testing.io, expired, .restricted_fd, &password, runtime, &guard, request));
    // Recovery-only permits a separately identified cancellation, never a new-risk signature.
    request.increases_risk = false;
    request.action = "\x82\xa4type\xadcancelByCloid\xa7cancels\x90";
    var cancel_input = try lifecyclePasswordPipe(std.testing.io);
    defer cancel_input.close(std.testing.io);
    const authorization_module = @import("../adapters/hyperliquid/hyperliquid_venue_adapter.zig");
    var cancellation_authorization: authorization_module.WalletAuthorization = .{ .wallet = signer, .store = &store, .io = std.testing.io, .password_file = cancel_input, .input_kind = .restricted_fd, .password_buffer = &password, .runtime = runtime, .guard = &guard };
    const cancel_authorizer = cancellation_authorization.interface();
    const canceled = try cancel_authorizer.sign_fn(cancel_authorizer.ptr, request);
    try cancel_authorizer.check_fn(cancel_authorizer.ptr, request.now_monotonic_ns, lease.token, false);
    try std.testing.expectEqual(address, try @import("wallet_crypto.zig").recover(canceled.digest, canceled.signature));
    request.increases_risk = true;
    request.now_monotonic_ns = 1;
    try authority.revoke(&lease);
    var replacement = try authority.acquire(.{ .exchange_account = 7, .decision_domain = 1 }, 2, 2);
    replacement.expires_at_ns = std.time.ns_per_hour;
    var stale = try lifecyclePasswordPipe(std.testing.io);
    defer stale.close(std.testing.io);
    request.command_identity = 3;
    try std.testing.expectError(error.StaleFencingToken, signer.sign(&store, std.testing.io, stale, .restricted_fd, &password, runtime, &guard, request));
    const new_signer = try signing.Signer.init(metadata, address, @splat(2), .master, replacement.token);
    var new_guard = failover.GatewayLeaseGuard{ .authority = &authority, .lease = &replacement };
    request.session = new_signer.session();
    request.fencing_token = replacement.token;
    request.now_monotonic_ns = 3;
    var old_unknown = try lifecyclePasswordPipe(std.testing.io);
    defer old_unknown.close(std.testing.io);
    request.command_identity = 1;
    try std.testing.expectError(error.RequestAlreadyConsumed, new_signer.sign(&reopened, std.testing.io, old_unknown, .restricted_fd, &password, runtime, &new_guard, request));
    const ledger_name = std.fmt.bytesToHex(address, .lower) ++ ".signer-nonces".*;
    var ledger = try store.dir.openFile(std.testing.io, &ledger_name, .{ .mode = .read_write });
    // A torn tail cannot be trimmed or reset to mint a fresh nonce.
    try ledger.writePositionalAll(std.testing.io, &.{0}, (try ledger.stat(std.testing.io)).size);
    ledger.close(std.testing.io);
    var corrupt = try lifecyclePasswordPipe(std.testing.io);
    defer corrupt.close(std.testing.io);
    request.command_identity = 5;
    try std.testing.expectError(error.CorruptNonceLedger, new_signer.sign(&reopened, std.testing.io, corrupt, .restricted_fd, &password, runtime, &new_guard, request));
    try store.dir.deleteFile(std.testing.io, &ledger_name);
    var missing = try lifecyclePasswordPipe(std.testing.io);
    defer missing.close(std.testing.io);
    try std.testing.expectError(error.FileNotFound, new_signer.sign(&reopened, std.testing.io, missing, .restricted_fd, &password, runtime, &new_guard, request));
}
