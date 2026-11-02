//! Hyperliquid L1 action signing; no transport or trading authorization.
const std = @import("std");
const Keccak = std.crypto.hash.sha3.Keccak256;
pub const Environment = @import("../../runtime/production_contract.zig").Environment;
const credentials = @import("../../security/credential_store.zig");
const crypto = @import("../../security/wallet_crypto.zig");
const failover = @import("../../runtime/failover.zig");
const nonces = @import("../../persistence/signer_nonce.zig");

pub const AccountKind = enum { master, subaccount };
pub const Request = struct {
    /// Original durable Gateway dispatch identity; never mint one for a retry.
    command_identity: u128,
    session: u64,
    environment: Environment,
    action: []const u8,
    now_ms: u64,
    now_monotonic_ns: u64,
    fencing_token: u64,
    expires_after: ?u64 = null,
};

/// This value is signing output, not permission to transmit. The execution
/// Gateway must still validate its DispatchProof immediately before sending.
pub const SignedAction = struct {
    nonce: u64,
    digest: [32]u8,
    signature: crypto.Signature,
    session: u64,
    funding_account: [20]u8,
    subaccount: ?[20]u8,
};

pub const Signer = struct {
    metadata: credentials.Metadata,
    signer_address: [20]u8,
    funding_account: [20]u8,
    account_kind: AccountKind,
    owner_token: u64,

    pub fn init(metadata: credentials.Metadata, signer_address: [20]u8, funding_account: [20]u8, account_kind: AccountKind, owner_token: u64) !Signer {
        if (metadata.environment == .demo or metadata.environment != metadata.endpoint_environment) return error.UnsupportedEnvironment;
        if (metadata.account == 0 or owner_token == 0 or metadata.version == 0 or metadata.generation == 0 or
            metadata.credential_id_len == 0 or metadata.credential_id_len > 32 or metadata.node_id_len > credentials.max_text or
            metadata.egress_ip_len > credentials.max_text or std.mem.allEqual(u8, &funding_account, 0) or
            std.mem.allEqual(u8, &signer_address, 0)) return error.InvalidSignerBinding;
        return .{ .metadata = metadata, .signer_address = signer_address, .funding_account = funding_account, .account_kind = account_kind, .owner_token = owner_token };
    }

    /// Query/private subscriptions always use the real funding account.
    pub fn queryAccount(self: Signer) [20]u8 {
        return self.funding_account;
    }

    pub fn session(self: Signer) u64 {
        var hash = Keccak.init(.{});
        hash.update("HyperliquidSignerSessionV1");
        hash.update(&self.signer_address);
        hash.update(&self.funding_account);
        hash.update(&.{ @intFromEnum(self.account_kind), @intFromEnum(self.metadata.environment) });
        for ([_][]const u8{ self.metadata.credentialId(), self.metadata.node(), self.metadata.ip() }) |text| {
            hash.update(&.{@intCast(text.len)});
            hash.update(text);
        }
        for ([_]u64{ self.metadata.account, self.metadata.version, self.metadata.generation, self.metadata.expires_at_unix, self.owner_token }) |value| {
            var encoded: [8]u8 = undefined;
            std.mem.writeInt(u64, &encoded, value, .big);
            hash.update(&encoded);
        }
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        return @max(1, std.mem.readInt(u64, digest[0..8], .big));
    }

    fn check(self: Signer, guard: *failover.GatewayLeaseGuard, request: Request) !void {
        if (request.session != self.session()) return error.StaleSignerSession;
        if (request.environment != self.metadata.environment) return error.EnvironmentMismatch;
        if (request.fencing_token != self.owner_token or guard.lease.key.exchange_account != self.metadata.account) return error.StaleFencingToken;
        try guard.check(request.now_monotonic_ns, request.fencing_token, true);
    }

    pub fn sign(self: Signer, store: *credentials.CredentialStore, io: std.Io, password_file: std.Io.File, input_kind: credentials.InputKind, password_buffer: []u8, runtime: credentials.RuntimeContext, guard: *failover.GatewayLeaseGuard, request: Request) !SignedAction {
        defer std.crypto.secureZero(u8, password_buffer);
        try self.check(guard, request);
        if (request.action.len == 0 or request.action.len > 65536 or request.command_identity == 0 or request.now_ms == 0) return error.InvalidSigningRequest;
        if (request.expires_after) |expiry| if (expiry <= request.now_ms) return error.SignatureExpired;
        var context = SigningContext{ .signer = self, .io = io, .request = request, .guard = guard };
        try store.withWallet(io, password_file, input_kind, password_buffer, self.metadata, runtime, request.now_ms / 1000, &context);
        return context.result.?;
    }
};

const SigningContext = struct {
    signer: Signer,
    io: std.Io,
    request: Request,
    guard: *failover.GatewayLeaseGuard,
    result: ?SignedAction = null,

    pub fn consume(self: *@This(), lease: *credentials.GatewayLease, dir: std.Io.Dir) !void {
        // Binding validation precedes durable consumption and any signature.
        try lease.checkWalletBinding(self.signer.signer_address, self.signer.funding_account);
        try self.signer.check(self.guard, self.request);
        const nonce = try nonces.reserve(dir, self.io, self.signer.signer_address, self.signer.metadata.account, self.request.command_identity, self.request.now_ms);
        const subaccount: ?[20]u8 = if (self.signer.account_kind == .subaccount) self.signer.funding_account else null;
        const digest = try typedDigest(actionHash(self.request.action, nonce, subaccount, self.request.expires_after), self.request.environment);
        const signature = try lease.signWalletDigest(digest, self.signer.signer_address, self.signer.funding_account);
        try self.signer.check(self.guard, self.request);
        self.result = .{ .nonce = nonce, .digest = digest, .signature = signature, .session = self.signer.session(), .funding_account = self.signer.funding_account, .subaccount = subaccount };
    }
};

/// Exact ordered MessagePack bytes from the request encoder, never JSON.
/// A present account is a subaccount address in the protocol's vaultAddress
/// field. Vault trading itself is not supported by the runtime scope.
pub fn actionHash(action: []const u8, nonce: u64, subaccount: ?[20]u8, expires_after: ?u64) [32]u8 {
    var hasher = Keccak.init(.{});
    hasher.update(action);
    var number: [8]u8 = undefined;
    std.mem.writeInt(u64, &number, nonce, .big);
    hasher.update(&number);
    hasher.update(&.{if (subaccount != null) @as(u8, 1) else 0});
    if (subaccount) |account| hasher.update(&account);
    if (expires_after) |expiry| {
        hasher.update(&.{0});
        std.mem.writeInt(u64, &number, expiry, .big);
        hasher.update(&number);
    }
    var result: [32]u8 = undefined;
    hasher.final(&result);
    return result;
}

pub fn typedDigest(connection_id: [32]u8, environment: Environment) ![32]u8 {
    if (environment == .demo) return error.UnsupportedEnvironment;
    var domain: [160]u8 = @splat(0);
    Keccak.hash("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)", domain[0..32], .{});
    Keccak.hash("Exchange", domain[32..64], .{});
    Keccak.hash("1", domain[64..96], .{});
    std.mem.writeInt(u256, domain[96..128], 1337, .big);
    var message: [96]u8 = undefined;
    Keccak.hash("Agent(string source,bytes32 connectionId)", message[0..32], .{});
    Keccak.hash(if (environment == .production) "a" else "b", message[32..64], .{});
    @memcpy(message[64..96], &connection_id);
    var preimage: [66]u8 = undefined;
    preimage[0..2].* = .{ 0x19, 0x01 };
    Keccak.hash(&domain, preimage[2..34], .{});
    Keccak.hash(&message, preimage[34..66], .{});
    var digest: [32]u8 = undefined;
    Keccak.hash(&preimage, &digest, .{});
    return digest;
}

test "L1 signing matches pinned SDK public action hash" {
    // SDK 2fdb18f9517675ea03695a0962bd19eece9c83f0 signing_test.py.
    const encoded_action = "\x83\xa4type\xa5order\xa6orders\x91\x86\xa1a\x04\xa1b\xc3\xa1p\xa61670.1\xa1s\xa60.0147\xa1r\xc2\xa1t\x81\xa5limit\x81\xa3tif\xa3Ioc\xa8grouping\xa2na";
    const expected = try hex32("0fcbeda5ae3c4950a548021552a4fea2226858c4453571bf3f24ba017eac2908");
    try std.testing.expectEqual(expected, actionHash(encoded_action, 1677777606040, null, null));
    try std.testing.expectEqual(try hex32("eb995f6f09994a13de522ce0cc454871e81500e01de770e09d9fa6f5d2742601"), try typedDigest(expected, .testnet));
    try std.testing.expectEqual(try hex32("be5eb0697b77c2acfeaa07a3d4913ae5d06489c63bfd143c5d3d66540a196c43"), try typedDigest(expected, .production));
    try std.testing.expectError(error.UnsupportedEnvironment, typedDigest(expected, .demo));
    const subaccount_hash = actionHash(encoded_action, 1677777606040, @as([20]u8, @splat(2)), 1677777666040);
    try std.testing.expectEqual(try hex32("cbc30667a8526a0747f48910bea2245fa4d923d97449895b58de5c6df949cf30"), subaccount_hash);
    try std.testing.expectEqual(try hex32("b2e767be3b6331b38893a253fcd3faf7adb9f50a3b89b0f9ebda0f98d717408c"), try typedDigest(subaccount_hash, .testnet));
}

fn hex32(text: []const u8) ![32]u8 {
    var result: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&result, text);
    return result;
}

test "signer sessions bind credential funding environment and owner without agent query fallback" {
    const metadata = try credentials.Metadata.init(.execution, 7, .testnet, 4000000000, "wallet", "node", "203.0.113.7");
    const original = try Signer.init(metadata, @splat(1), @splat(2), .master, 1);
    try std.testing.expectEqual(@as([20]u8, @splat(2)), original.queryAccount());
    var changed = original;
    changed.metadata.generation += 1;
    try std.testing.expect(changed.session() != original.session());
    changed = original;
    changed.metadata.version += 1;
    try std.testing.expect(changed.session() != original.session());
    changed = original;
    changed.metadata.environment = .production;
    changed.metadata.endpoint_environment = .production;
    try std.testing.expect(changed.session() != original.session());
    changed = original;
    changed.metadata.account += 1;
    try std.testing.expect(changed.session() != original.session());
    changed = original;
    changed.funding_account = @splat(3);
    try std.testing.expect(changed.session() != original.session());
    changed = original;
    changed.signer_address = @splat(3);
    try std.testing.expect(changed.session() != original.session());
    changed = original;
    changed.owner_token += 1;
    try std.testing.expect(changed.session() != original.session());
}
