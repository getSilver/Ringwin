//! Manually unlocked, file-backed credentials for the Linux production seam.
//! The module deliberately exposes only a read-only admission in this ticket.
//! Plain secret bytes never appear in metadata, evidence, logs, or argv/env APIs.

const builtin = @import("builtin");
const std = @import("std");
const production_contract = @import("production_contract.zig");

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
pub const CredentialState = enum(u8) { staged, active, retiring, revoked };
pub const InputKind = enum { tty, restricted_fd, test_only };
pub const ProtectionMode = enum { native, test_bypass };
pub const AdmissionState = enum { ready, denied };

pub const Metadata = struct {
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

pub const SecretMaterial = struct {
    api_key: [max_secret]u8 = @splat(0),
    api_key_len: u8 = 0,
    secret_key: [max_secret]u8 = @splat(0),
    secret_key_len: u8 = 0,
    passphrase: [max_secret]u8 = @splat(0),
    passphrase_len: u8 = 0,

    pub fn init(api_key: []const u8, secret_key: []const u8, passphrase: []const u8) !SecretMaterial {
        var result = SecretMaterial{};
        errdefer result.clear();
        result.api_key_len = try copyText(&result.api_key, api_key);
        result.secret_key_len = try copyText(&result.secret_key, secret_key);
        result.passphrase_len = try copyText(&result.passphrase, passphrase);
        return result;
    }

    pub fn clear(self: *SecretMaterial) void {
        std.crypto.secureZero(u8, self.api_key[0..]);
        std.crypto.secureZero(u8, self.secret_key[0..]);
        std.crypto.secureZero(u8, self.passphrase[0..]);
        self.api_key_len = 0;
        self.secret_key_len = 0;
        self.passphrase_len = 0;
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
    if (kind == .tty and builtin.os.tag != .windows) return error.TtyPasswordUnsupported;
    if (kind == .tty and !(try file.isTty(io))) return error.NotATty;
    var console_mode: u32 = 0;
    var echo_disabled = false;
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

pub const RuntimeContext = struct {
    account: u64,
    environment: production_contract.Environment,
    endpoint_environment: production_contract.Environment,
    node_id: []const u8,
    egress_ip: []const u8,
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
        self.secret.expose(callback);
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

    pub fn stage(self: *CredentialStore, io: std.Io, metadata: Metadata, material: *SecretMaterial, file: std.Io.File, input_kind: InputKind, password_buffer: []u8) !void {
        defer material.clear();
        defer std.crypto.secureZero(u8, password_buffer);
        var password_storage = try protected.Buffer.init(max_password + 1);
        defer password_storage.deinit();
        const password = try readPassword(io, file, input_kind, try password_storage.writable());
        try password_storage.freeze();
        try self.stageWithPassword(io, metadata, material, password);
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
        const writer = try self.acquireWriter(io);
        defer writer.close(io);
        try self.writeEncrypted(io, metadata, material, password, false);
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
        try secret.storage.freeze();
        return .{ .secret = secret, .metadata = metadata };
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
    return a.kind == b.kind and a.version == b.version and
        a.expires_at_unix == b.expires_at_unix and a.account == b.account and a.environment == b.environment and
        a.endpoint_environment == b.endpoint_environment and a.credential_id_len == b.credential_id_len and
        a.node_id_len == b.node_id_len and a.egress_ip_len == b.egress_ip_len and
        std.mem.eql(u8, a.credentialId(), b.credentialId()) and std.mem.eql(u8, a.node(), b.node()) and
        std.mem.eql(u8, a.ip(), b.ip()) and a.can_read == b.can_read and a.can_trade == b.can_trade and a.can_withdraw == b.can_withdraw;
}

fn matchesRuntime(metadata: Metadata, runtime: RuntimeContext) bool {
    return metadata.account == runtime.account and metadata.environment == runtime.environment and
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
    put(u16, destination, 4, format_version);
    destination[6] = @intFromEnum(metadata.kind);
    destination[7] = @intFromEnum(metadata.state);
    destination[8] = (if (metadata.can_read) @as(u8, 1) else 0) | (if (metadata.can_trade) @as(u8, 2) else 0) | (if (metadata.can_withdraw) @as(u8, 4) else 0);
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
    if (source.len < header_len + payload_tag_len or get(u32, source, 0) != magic or get(u16, source, 4) != format_version) return error.InvalidCredentialFile;
    if (source[6] > @intFromEnum(CredentialKind.execution) or source[7] > @intFromEnum(CredentialState.revoked)) return error.InvalidCredentialMetadata;
    if (source[44] > 32 or source[45] > max_text or source[46] > max_text) return error.InvalidCredentialMetadata;
    if (source[42] > @intFromEnum(production_contract.Environment.production) or source[43] > @intFromEnum(production_contract.Environment.production)) return error.InvalidCredentialMetadata;
    metadata.* = .{
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

fn encodeMaterial(material: *const SecretMaterial, destination: []u8) !usize {
    const total = 3 + @as(usize, material.api_key_len) + material.secret_key_len + material.passphrase_len;
    if (material.api_key_len > max_secret or material.secret_key_len > max_secret or material.passphrase_len > max_secret or total > destination.len or material.api_key_len == 0 or material.secret_key_len == 0 or material.passphrase_len == 0) return error.InvalidCredential;
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

fn decodeMaterial(source: []const u8, result: *SecretMaterial) !void {
    errdefer result.clear();
    if (source.len < 6) return error.InvalidCredential;
    const lengths = [_]u8{ source[0], source[1], source[2] };
    const total = 3 + @as(usize, lengths[0]) + lengths[1] + lengths[2];
    if (lengths[0] > max_secret or lengths[1] > max_secret or lengths[2] > max_secret or source.len != total or lengths[0] == 0 or lengths[1] == 0 or lengths[2] == 0) return error.InvalidCredential;
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
    if (rejected_material.api_key_len != 0 or rejected_material.secret_key_len != 0 or rejected_material.passphrase_len != 0)
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
    std.debug.assert(std.mem.eql(u8, material.api_key[0..material.api_key_len], "key"));
    std.debug.assert(std.mem.eql(u8, material.secret_key[0..material.secret_key_len], "secret"));
    std.debug.assert(std.mem.eql(u8, material.passphrase[0..material.passphrase_len], "pass"));
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
        std.debug.assert(material.api_key_len == 0 and material.secret_key_len == 0 and material.passphrase_len == 0);
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
    try std.testing.expectEqual(@as(u8, 0), material.api_key_len);
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
    try std.testing.expectEqual(@as(u8, 0), material.api_key_len);
    var malformed = try SecretMaterial.init("key", "secret", "pass");
    malformed.api_key_len = max_secret + 1;
    var complete = try lifecyclePasswordPipe(std.testing.io);
    defer complete.close(std.testing.io);
    try std.testing.expectError(error.InvalidCredential, store.stage(std.testing.io, metadata, &malformed, complete, .restricted_fd, &password));
    try std.testing.expect(std.mem.allEqual(u8, &password, 0));
    try std.testing.expectEqual(@as(u8, 0), malformed.api_key_len);
    try std.testing.expectError(error.SecurityGateClosed, lifecycleStage(&store, metadata));
}

test "public Linux store refuses a real TTY before reading and tightens private directory" {
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
    var tty = try std.Io.Dir.openFileAbsolute(std.testing.io, "/dev/ptmx", .{ .mode = .read_write });
    defer tty.close(std.testing.io);
    try std.testing.expect(try tty.isTty(std.testing.io));
    const metadata = try Metadata.init(.observation, 83, .production, 4_000_000_000, "tty", "node", "203.0.113.83");
    var password: [max_password]u8 = @splat(0xa5);
    var material = try SecretMaterial.init("key", "secret", "pass");
    try std.testing.expectError(error.TtyPasswordUnsupported, store.stage(std.testing.io, metadata, &material, tty, .tty, &password));
    try std.testing.expect(std.mem.allEqual(u8, &password, 0));
    try std.testing.expectEqual(@as(u8, 0), material.api_key_len);
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
    try std.testing.expectEqual(@as(u8, 0), material.api_key_len);
    try std.testing.expectError(error.FileNotFound, store.dir.openFile(std.testing.io, "observation.credential", .{}));
    std.debug.print("public store refused insufficient native memlock and cleared caller inputs\n", .{});
}
