//! Ethereum secp256k1 signing with protected RFC6979/HMAC/scalar workspace.
//! Raw key bytes are borrowed; owned secret storage is wiped on every exit.
//! Arithmetic stack/register temporaries still require target qualification.
const std = @import("std");
const protected = @import("protected_memory.zig");
const Curve = std.crypto.ecc.Secp256k1;
const Sha256 = @import("credential_crypto/sha256.zig").Sha256;
const Scalar = Curve.scalar.Scalar;
const Keccak = std.crypto.hash.sha3.Keccak256;

pub const Signature = struct { r: [32]u8, s: [32]u8, v: u8 };

fn validate(key: *const [32]u8) !void {
    if (std.mem.allEqual(u8, key, 0)) return error.InvalidPrivateKey;
    if (std.mem.order(u8, key, &order_bytes) != .lt) return error.InvalidPrivateKey;
}

pub fn address(key: *const [32]u8) ![20]u8 {
    try validate(key);
    var storage = try protected.Buffer.init(@sizeOf(Scratch));
    defer storage.deinit();
    const state: *Scratch = @ptrCast(@alignCast((try storage.writable()).ptr));
    multiplyBase(state, key);
    const encoded = state.point.toUncompressedSec1();
    var hash: [32]u8 = undefined;
    Keccak.hash(encoded[1..], &hash, .{});
    return hash[12..32].*;
}

pub fn recover(digest: [32]u8, signature: Signature) ![20]u8 {
    if (signature.v != 27 and signature.v != 28) return error.InvalidSignature;
    const r = try Curve.scalar.Scalar.fromBytes(signature.r, .big);
    const s = try Curve.scalar.Scalar.fromBytes(signature.s, .big);
    if (r.isZero() or s.isZero()) return error.InvalidSignature;
    const point = try Curve.fromSec1(&(@as([1]u8, .{signature.v - 25}) ++ signature.r));
    const z = Curve.scalar.Scalar.fromBytes64(@as([32]u8, @splat(0)) ++ digest, .big);
    const inverse = r.invert();
    const public = try Curve.mulDoubleBasePublic(point, s.mul(inverse).toBytes(.big), Curve.basePoint, z.neg().mul(inverse).toBytes(.big), .big);
    const encoded = public.toUncompressedSec1();
    var hash: [32]u8 = undefined;
    Keccak.hash(encoded[1..], &hash, .{});
    return hash[12..].*;
}

const order_bytes = bytes: {
    var encoded: [32]u8 = undefined;
    std.mem.writeInt(u256, &encoded, Curve.scalar.field_order, .big);
    break :bytes encoded;
};

const Scratch = struct {
    k: [32]u8,
    v: [32]u8,
    candidate: [32]u8,
    reduced_digest: [32]u8,
    inner_pad: [64]u8,
    outer_pad: [64]u8,
    inner: Sha256,
    outer: Sha256,
    mac_digest: [32]u8,
    private_scalar: Scalar,
    nonce_scalar: Scalar,
    temporary_scalar: Scalar,
    inverse: Scalar,
    z: Scalar,
    r: Scalar,
    s: Scalar,
    point: Curve,
    added: Curve,
};

// The byte string is borrowed; no raw-key array or key-pair value is copied to
// a stdlib Signer/HMAC/curve-mul frame. Only arithmetic temporaries are by value.
fn scalarInto(state: *Scratch, output: *Scalar, bytes: *const [32]u8) void {
    output.* = Scalar.zero;
    for (bytes) |byte| {
        var bit: usize = 8;
        while (bit > 0) {
            bit -= 1;
            output.* = output.dbl();
            state.temporary_scalar = output.add(Scalar.one);
            output.fe.cMov(state.temporary_scalar.fe, @truncate(byte >> @as(u3, @intCast(bit))));
        }
    }
}

// Fixed 256-bit double/add schedule, using pinned stdlib field cMov and curve
// formulas. Secret scalar bytes and selected points stay in the protected owner.
fn multiplyBase(state: *Scratch, bytes: *const [32]u8) void {
    state.point = Curve.identityElement;
    for (bytes) |byte| {
        var bit: usize = 8;
        while (bit > 0) {
            bit -= 1;
            state.point = state.point.dbl();
            state.added = state.point.add(Curve.basePoint);
            const selected: u1 = @truncate(byte >> @as(u3, @intCast(bit)));
            state.point.x.cMov(state.added.x, selected);
            state.point.y.cMov(state.added.y, selected);
            state.point.z.cMov(state.added.z, selected);
        }
    }
}

fn hmac(state: *Scratch, output: *[32]u8, key: *const [32]u8, parts: []const []const u8) void {
    @memset(&state.inner_pad, 0x36);
    @memset(&state.outer_pad, 0x5c);
    for (key, 0..) |byte, i| {
        state.inner_pad[i] ^= byte;
        state.outer_pad[i] ^= byte;
    }
    state.inner = Sha256.init(.{});
    state.inner.update(&state.inner_pad);
    for (parts) |part| state.inner.update(part);
    state.inner.final(&state.mac_digest);
    state.outer = Sha256.init(.{});
    state.outer.update(&state.outer_pad);
    state.outer.update(&state.mac_digest);
    state.outer.final(output);
}

pub fn sign(key: *const [32]u8, digest: [32]u8) !Signature {
    return signOwned(key, digest, null);
}

pub fn signWithTestingBackend(key: *const [32]u8, digest: [32]u8, backend: protected.Backend) !Signature {
    if (!@import("builtin").is_test) @compileError("wallet crypto backend is test-only");
    return signOwned(key, digest, backend);
}

fn signOwned(key: *const [32]u8, digest: [32]u8, backend: ?protected.Backend) !Signature {
    try validate(key);
    var storage = if (@import("builtin").is_test and backend != null)
        try protected.Buffer.initForTesting(@sizeOf(Scratch), backend.?)
    else
        try protected.Buffer.init(@sizeOf(Scratch));
    defer storage.deinit();
    const state: *Scratch = @ptrCast(@alignCast((try storage.writable()).ptr));
    state.z = Scalar.fromBytes64(@as([32]u8, @splat(0)) ++ digest, .big);
    state.reduced_digest = state.z.toBytes(.big);
    scalarInto(state, &state.private_scalar, key);
    @memset(&state.k, 0);
    @memset(&state.v, 1);
    // RFC 6979 section 3.2, with HMAC state/pads/schedules in protected storage.
    for ([_]u8{ 0, 1 }) |separator| {
        hmac(state, &state.k, &state.k, &.{ &state.v, &.{separator}, key, &state.reduced_digest });
        hmac(state, &state.v, &state.k, &.{&state.v});
    }
    while (true) {
        hmac(state, &state.v, &state.k, &.{&state.v});
        if (!std.mem.allEqual(u8, &state.v, 0) and std.mem.order(u8, &state.v, &order_bytes) == .lt) {
            scalarInto(state, &state.nonce_scalar, &state.v);
            multiplyBase(state, &state.v);
            state.candidate = state.point.affineCoordinates().x.toBytes(.big);
            // Recovery IDs 2/3 cannot be represented by Ethereum v=27/28.
            if (std.mem.order(u8, &state.candidate, &order_bytes) == .lt) {
                state.r = try Scalar.fromBytes(state.candidate, .big);
                state.inverse = state.nonce_scalar.invert();
                state.temporary_scalar = state.r.mul(state.private_scalar);
                state.s = state.inverse.mul(state.z.add(state.temporary_scalar));
                if (!state.r.isZero() and !state.s.isZero()) {
                    var result = Signature{ .r = state.r.toBytes(.big), .s = state.s.toBytes(.big), .v = 27 + @as(u8, @intFromBool(state.point.affineCoordinates().y.isOdd())) };
                    if (std.mem.readInt(u256, &result.s, .big) > Curve.scalar.field_order / 2) {
                        state.s = state.s.neg();
                        result.s = state.s.toBytes(.big);
                        result.v = 27 + ((result.v - 27) ^ 1);
                    }
                    return result;
                }
            }
        }
        hmac(state, &state.k, &state.k, &.{ &state.v, &.{0} });
        hmac(state, &state.v, &state.k, &.{&state.v});
    }
}

test "wallet signing workspace is erased on success and native protection failure" {
    var key: [32]u8 = @splat(0);
    defer std.crypto.secureZero(u8, &key);
    key[31] = 1;
    var observer = protected.TestingBackend{};
    const signature = try signWithTestingBackend(&key, @splat(3), observer.backend());
    const expected_address = [_]u8{ 0x7e, 0x5f, 0x45, 0x52, 0x09, 0x1a, 0x69, 0x12, 0x5d, 0x5d, 0xfc, 0xb7, 0xb8, 0xc2, 0x65, 0x90, 0x29, 0x39, 0x5b, 0xdf };
    try std.testing.expectEqual(expected_address, try recover(@splat(3), signature));
    try std.testing.expect(observer.erased);
    try std.testing.expectEqual(@as(usize, 1), observer.released);
    observer = .{ .fail = .lock };
    try std.testing.expectError(error.MemoryLockFailed, signWithTestingBackend(&key, @splat(3), observer.backend()));
    try std.testing.expect(observer.erased);
    try std.testing.expectEqual(@as(usize, 1), observer.released);
}

test "wallet RFC6979 matches independent zero and maximum scalar digest edges" {
    // eth-account 0.13.7 _sign_hash + _recover_hash, public synthetic scalars.
    for ([_]struct { scalar: u256, digest_byte: u8, signature_hash: []const u8 }{
        .{ .scalar = 1, .digest_byte = 0, .signature_hash = "bf0a07f83d9bc6d8116d68d8f677816382621084a58f832d905318cef7779d0e" },
        .{ .scalar = Curve.scalar.field_order - 1, .digest_byte = 255, .signature_hash = "ddfb99c8c43477b94e399c78cc2b29ef2201433d734e76184110ace9a027ecff" },
    }) |vector| {
        var key: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &key);
        std.mem.writeInt(u256, &key, vector.scalar, .big);
        const signature = try sign(&key, @splat(vector.digest_byte));
        var actual: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&(signature.r ++ signature.s ++ [_]u8{signature.v}), &actual, .{});
        var expected: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expected, vector.signature_hash);
        try std.testing.expectEqual(expected, actual);
    }
}
