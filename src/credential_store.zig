//! Manually unlocked, file-backed credentials for the Linux production seam.
//! The module deliberately exposes only a read-only admission in this ticket.
//! Plain secret bytes never appear in metadata, evidence, logs, or argv/env APIs.

const builtin = @import("builtin");
const std = @import("std");
const production_contract = @import("production_contract.zig");

const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const argon2 = std.crypto.pwhash.argon2;
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
    if (kind == .test_only) return error.TestPasswordSourceNotAllowed;
    if (kind == .tty and !(try file.isTty(io))) return error.NotATty;
    var length: usize = 0;
    while (length < destination.len) {
        const amount = file.readStreaming(io, &.{destination[length..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (amount == 0) break;
        length += amount;
        if (destination[length - 1] == '\n') break;
    }
    while (length > 0 and (destination[length - 1] == '\n' or destination[length - 1] == '\r')) : (length -= 1) {}
    if (length == 0) return error.InvalidPasswordSource;
    return .{ .kind = kind, .bytes = destination[0..length] };
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
};

pub const CredentialStore = struct {
    dir: std.Io.Dir,
    allocator: Allocator,
    admission_gate: bool = true,

    pub fn open(io: std.Io, allocator: Allocator, absolute_path: []const u8) !CredentialStore {
        if (builtin.os.tag != .linux) return error.LinuxCredentialStoreRequired;
        std.Io.Dir.createDirAbsolute(io, absolute_path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        return .{ .dir = try std.Io.Dir.openDirAbsolute(io, absolute_path, .{}), .allocator = allocator };
    }

    pub fn close(self: *CredentialStore, io: std.Io) void {
        self.dir.close(io);
    }

    pub fn stage(self: *CredentialStore, io: std.Io, metadata: Metadata, material: *SecretMaterial, file: std.Io.File, input_kind: InputKind, password_buffer: []u8) !void {
        const password = try readPassword(io, file, input_kind, password_buffer);
        defer std.crypto.secureZero(u8, password_buffer);
        try self.stageWithPassword(io, metadata, material, password);
    }

    pub fn activate(self: *CredentialStore, io: std.Io, kind: CredentialKind, file: std.Io.File, input_kind: InputKind, password_buffer: []u8, expected: Metadata) !void {
        const password = try readPassword(io, file, input_kind, password_buffer);
        defer std.crypto.secureZero(u8, password_buffer);
        try self.activateWithPassword(io, kind, password, expected);
    }

    pub fn retire(self: *CredentialStore, io: std.Io, kind: CredentialKind, file: std.Io.File, input_kind: InputKind, password_buffer: []u8, expected: Metadata) !void {
        const password = try readPassword(io, file, input_kind, password_buffer);
        defer std.crypto.secureZero(u8, password_buffer);
        try self.retireWithPassword(io, kind, password, expected);
    }

    pub fn revoke(self: *CredentialStore, io: std.Io, kind: CredentialKind, file: std.Io.File, input_kind: InputKind, password_buffer: []u8, expected: Metadata) !void {
        const password = try readPassword(io, file, input_kind, password_buffer);
        defer std.crypto.secureZero(u8, password_buffer);
        try self.revokeWithPassword(io, kind, password, expected);
    }

    pub fn admitObservationReadOnly(self: *CredentialStore, io: std.Io, file: std.Io.File, input_kind: InputKind, password_buffer: []u8, expected: Metadata, runtime: RuntimeContext, now_unix: u64, self_check: SecuritySelfCheck) !Admission {
        const password = try readPassword(io, file, input_kind, password_buffer);
        defer std.crypto.secureZero(u8, password_buffer);
        return self.admitObservationWithPassword(io, password, expected, runtime, now_unix, .native, self_check);
    }

    fn stageWithPassword(self: *CredentialStore, io: std.Io, metadata: Metadata, material: *SecretMaterial, password: PasswordSource) !void {
        if (!self.admission_gate) return error.SecurityGateClosed;
        if (metadata.state != .staged) return error.InvalidInitialState;
        defer material.clear();
        try self.writeEncrypted(io, metadata, material, password);
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
        if (!self.admission_gate or !self_check.passes()) return error.SecurityGateClosed;
        if (expected.kind != .observation or expected.state != .active) return error.ObservationCredentialRequired;
        if (!expected.can_read or expected.can_trade or expected.can_withdraw) return error.ReadOnlyPolicyViolation;
        if (expected.environment != .production or expected.endpoint_environment != .production) return error.EnvironmentMismatch;
        if (expected.expires_at_unix <= now_unix) return error.CredentialExpired;
        var lease = try self.unlock(io, .observation, password, expected, protection, true);
        defer lease.deinit();
        if (!matchesRuntime(lease.metadataView(), runtime)) return error.RuntimeContextMismatch;
        if (!lease.report().accepted()) return error.SecurityGateClosed;
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
        const protection: ProtectionMode = if (builtin.is_test) .test_bypass else .native;
        var lease = try self.unlock(io, kind, password, expected, protection, false);
        defer lease.deinit();
        var next_metadata = expected;
        next_metadata.state = next;
        next_metadata.generation += 1;
        try self.writeEncrypted(io, next_metadata, lease.secret.material(), password);
    }

    fn unlock(self: *CredentialStore, io: std.Io, kind: CredentialKind, password: PasswordSource, expected: Metadata, protection: ProtectionMode, require_active: bool) !GatewayLease {
        if (password.kind == .test_only and protection == .native) return error.TestPasswordSourceNotAllowed;
        if (password.bytes.len == 0 or password.bytes.len > max_password) return error.InvalidPasswordSource;
        if (expected.kind != kind) return error.CredentialKindMismatch;
        var file_bytes: [max_file]u8 = undefined;
        const file_len = try readFile(self.dir, io, fileName(kind), &file_bytes);
        var metadata: Metadata = undefined;
        var plaintext: [max_payload]u8 = undefined;
        defer std.crypto.secureZero(u8, &plaintext);
        const plaintext_len = try decrypt(self.allocator, io, file_bytes[0..file_len], password.bytes, &metadata, &plaintext);
        if (metadata.state == .revoked) return error.CredentialRevoked;
        if (!sameImmutableMetadata(metadata, expected) or metadata.state != expected.state or metadata.generation != expected.generation) return error.MetadataMismatch;
        if (require_active and metadata.state != .active) return error.CredentialNotActive;
        var material = try decodeMaterial(plaintext[0..plaintext_len]);
        errdefer material.clear();
        const secret = try Secret.init(self.allocator, material, protection);
        material.clear();
        return .{ .secret = secret, .metadata = metadata };
    }

    fn writeEncrypted(self: *CredentialStore, io: std.Io, metadata: Metadata, material: *const SecretMaterial, password: PasswordSource) !void {
        if (password.kind == .test_only and !builtin.is_test) return error.TestPasswordSourceNotAllowed;
        if (password.bytes.len == 0 or password.bytes.len > max_password) return error.InvalidPasswordSource;
        var payload: [max_payload]u8 = undefined;
        defer std.crypto.secureZero(u8, &payload);
        const payload_len = encodeMaterial(material, &payload) catch |err| {
            self.admission_gate = false;
            return err;
        };
        var bytes: [max_file]u8 = undefined;
        var salt: [16]u8 = undefined;
        var nonce: [Aead.nonce_length]u8 = undefined;
        io.random(&salt);
        io.random(&nonce);
        encodeHeader(&bytes, metadata, salt, nonce, @intCast(payload_len));
        var key: [Aead.key_length]u8 = undefined;
        defer std.crypto.secureZero(u8, &key);
        try deriveKey(self.allocator, io, password.bytes, &salt, &key);
        var tag: [payload_tag_len]u8 = undefined;
        Aead.encrypt(bytes[header_len .. header_len + payload_len], &tag, payload[0..payload_len], bytes[0..header_len], nonce, key);
        @memcpy(bytes[header_len + payload_len ..][0..payload_tag_len], &tag);
        try writeAtomic(self.dir, io, fileName(metadata.kind), bytes[0 .. header_len + payload_len + payload_tag_len]);
    }
};

/// Owns a credential payload in a dedicated page. The payload is readable only
/// through `expose`; the page is read-only while the Secret is alive and is
/// restored, wiped, unlocked, and freed by `deinit`.
const Secret = struct {
    allocator: Allocator,
    storage: []align(std.heap.page_size_min) u8,
    protection_report: ProtectionReport,

    fn init(allocator: Allocator, secret_material: SecretMaterial, mode: ProtectionMode) !Secret {
        var owned_material = secret_material;
        defer owned_material.clear();
        const storage = try allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), std.heap.page_size_min);
        var locked = false;
        var access_protected = false;
        errdefer {
            if (access_protected) std.process.protectMemory(storage, .{ .read = true, .write = true }) catch {};
            std.crypto.secureZero(u8, storage);
            if (locked) std.process.unlockMemory(storage) catch {};
            allocator.free(storage);
        }
        @memset(storage, 0);
        @memcpy(storage[0..@sizeOf(SecretMaterial)], std.mem.asBytes(&owned_material));
        var protection_report = ProtectionReport{ .locked = mode == .test_bypass, .dont_dump = mode == .test_bypass, .access_protected = false, .wipe_on_release = true };
        if (mode == .native) {
            if (builtin.os.tag != .linux) return error.LinuxProtectedMemoryRequired;
            std.process.lockMemory(storage, .{}) catch return error.MemoryLockFailed;
            locked = true;
            std.posix.madvise(storage.ptr, storage.len, std.os.linux.MADV.DONTDUMP) catch return error.DontDumpFailed;
            protection_report.locked = true;
            protection_report.dont_dump = true;
        }
        std.process.protectMemory(storage, .{ .read = true }) catch return error.MemoryProtectionFailed;
        access_protected = true;
        protection_report.access_protected = true;
        if (!protection_report.accepted()) return error.SecurityGateClosed;
        return .{ .allocator = allocator, .storage = storage, .protection_report = protection_report };
    }

    fn expose(self: *const Secret, comptime callback: fn (*const SecretMaterial) void) void {
        callback(self.material());
    }

    fn material(self: *const Secret) *const SecretMaterial {
        return @ptrCast(@alignCast(self.storage.ptr));
    }

    fn report(self: *const Secret) ProtectionReport {
        return self.protection_report;
    }

    fn deinit(self: *Secret) void {
        std.process.protectMemory(self.storage, .{ .read = true, .write = true }) catch |err|
            std.debug.panic("credential memory protection restore failed: {s}", .{@errorName(err)});
        std.crypto.secureZero(u8, self.storage);
        if (self.protection_report.locked and builtin.os.tag == .linux) std.process.unlockMemory(self.storage) catch {};
        self.allocator.free(self.storage);
        self.protection_report.wipe_on_release = true;
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

fn deriveKey(allocator: Allocator, io: std.Io, password: []const u8, salt: []const u8, key: *[Aead.key_length]u8) !void {
    try argon2.kdf(allocator, key[0..], password, salt, argon2.Params.owasp_2id, .argon2id, io);
}

fn encodeMaterial(material: *const SecretMaterial, destination: []u8) !usize {
    const total = 3 + @as(usize, material.api_key_len) + material.secret_key_len + material.passphrase_len;
    if (total > destination.len or material.api_key_len == 0 or material.secret_key_len == 0 or material.passphrase_len == 0) return error.InvalidCredential;
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

fn decodeMaterial(source: []const u8) !SecretMaterial {
    if (source.len < 6) return error.InvalidCredential;
    const lengths = [_]u8{ source[0], source[1], source[2] };
    const total = 3 + @as(usize, lengths[0]) + lengths[1] + lengths[2];
    if (source.len != total or lengths[0] == 0 or lengths[1] == 0 or lengths[2] == 0) return error.InvalidCredential;
    var result = SecretMaterial{};
    result.api_key_len = lengths[0];
    result.secret_key_len = lengths[1];
    result.passphrase_len = lengths[2];
    var offset: usize = 3;
    @memcpy(result.api_key[0..lengths[0]], source[offset..][0..lengths[0]]);
    offset += lengths[0];
    @memcpy(result.secret_key[0..lengths[1]], source[offset..][0..lengths[1]]);
    offset += lengths[1];
    @memcpy(result.passphrase[0..lengths[2]], source[offset..][0..lengths[2]]);
    return result;
}

fn decrypt(allocator: Allocator, io: std.Io, source: []const u8, password: []const u8, metadata: *Metadata, plaintext: []u8) !usize {
    var salt: [16]u8 = undefined;
    var nonce: [Aead.nonce_length]u8 = undefined;
    const payload_len = try decodeHeader(source, metadata, &salt, &nonce);
    var key: [Aead.key_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    try deriveKey(allocator, io, password, &salt, &key);
    const ciphertext = source[header_len .. header_len + payload_len];
    const tag: [payload_tag_len]u8 = source[header_len + payload_len ..][0..payload_tag_len].*;
    try Aead.decrypt(plaintext[0..payload_len], ciphertext, tag, source[0..header_len], nonce, key);
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

fn writeAtomic(dir: std.Io.Dir, io: std.Io, name: []const u8, bytes: []const u8) !void {
    var temp: [96]u8 = undefined;
    const temp_name = try std.fmt.bufPrint(&temp, "{s}.tmp", .{name});
    var file = try dir.createFile(io, temp_name, .{ .truncate = true, .permissions = if (builtin.os.tag == .linux) @enumFromInt(0o600) else .default_file });
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);
    file.close(io);
    try dir.rename(temp_name, dir, name, io);
    syncDirectory(dir) catch return error.DirectorySyncFailed;
}

fn syncDirectory(dir: std.Io.Dir) !void {
    if (builtin.os.tag == .linux) switch (std.os.linux.errno(std.os.linux.fsync(dir.handle))) {
        .SUCCESS => {},
        .INVAL, .BADF, .OPNOTSUPP => std.posix.sync(),
        else => return error.DirectorySyncFailed,
    };
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
    const absolute_path = try std.fmt.bufPrint(&path, "/tmp/ringwin-credential-store-{d}", .{std.os.linux.getpid()});
    std.Io.Dir.createDirAbsolute(init.io, absolute_path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteTree(init.io, absolute_path) catch {};
    var store = try CredentialStore.open(init.io, init.gpa, absolute_path);
    defer store.close(init.io);
    var metadata = try Metadata.init(.observation, 42, .production, 4_000_000_000, "obs-prod-42", "linux-node-1", "198.51.100.42");
    var material = try SecretMaterial.init("observation-key", "observation-secret", "observation-pass");
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
    var password_bytes: [max_password]u8 = undefined;
    defer std.crypto.secureZero(u8, &password_bytes);
    const password = try readPassword(init.io, read_file, .restricted_fd, &password_bytes);
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

test "credential metadata and secret payload are authenticated" {
    if (builtin.os.tag != .linux) return;
    var store = try CredentialStore.open(std.testing.io, std.testing.allocator, "/tmp/ringwin-credential-store-test");
    defer store.close(std.testing.io);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, "/tmp/ringwin-credential-store-test") catch {};
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
    if (builtin.os.tag != .linux) return;
    var store = try CredentialStore.open(std.testing.io, std.testing.allocator, "/tmp/ringwin-credential-store-policy-test");
    defer store.close(std.testing.io);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, "/tmp/ringwin-credential-store-policy-test") catch {};
    var metadata = try Metadata.init(.observation, 8, .production, 4_000_000_000, "obs", "node", "203.0.113.8");
    var material = try SecretMaterial.init("key", "secret", "pass");
    const password = PasswordSource.testOnly("password");
    try store.stageWithPassword(std.testing.io, metadata, &material, password);
    try store.activateWithPassword(std.testing.io, .observation, password, metadata);
    metadata.state = .active;
    metadata.generation += 1;
    var check = SecuritySelfCheck{};
    check.dont_dump = false;
    const runtime = RuntimeContext{ .account = 8, .environment = .production, .endpoint_environment = .production, .node_id = "node", .egress_ip = "203.0.113.8" };
    try std.testing.expectError(error.SecurityGateClosed, store.admitObservationWithPassword(std.testing.io, password, metadata, runtime, 1, .test_bypass, check));
    try std.testing.expect(!allowsReadOnly(.order_write));
    try std.testing.expect(!allowsReadOnly(.funds_transfer));
    try std.testing.expectError(error.ExecutionAdmissionOutOfScope, store.admitExecution());
    try store.revokeWithPassword(std.testing.io, .observation, password, metadata);
    try std.testing.expectError(error.InvalidCredentialTransition, store.activateWithPassword(std.testing.io, .observation, password, metadata));
}

test "Secret exposes only read-only material and reports page protection" {
    if (builtin.os.tag != .linux) return;
    var material = try SecretMaterial.init("key", "secret", "pass");
    defer material.clear();
    var secret = try Secret.init(std.testing.allocator, material, .test_bypass);
    defer secret.deinit();

    try std.testing.expect(secret.report().accepted());
    secret.expose(assertTestSecretMaterial);
}

fn assertTestSecretMaterial(material: *const SecretMaterial) void {
    std.debug.assert(std.mem.eql(u8, material.api_key[0..material.api_key_len], "key"));
    std.debug.assert(std.mem.eql(u8, material.secret_key[0..material.secret_key_len], "secret"));
    std.debug.assert(std.mem.eql(u8, material.passphrase[0..material.passphrase_len], "pass"));
}
