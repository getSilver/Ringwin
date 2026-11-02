//! Generic Ethereum secp256k1 signing. Owned key-pair storage is locked,
//! read-only during signing, and wiped on every exit. Standard-library curve
//! and signing temporaries require separate target-platform qualification.
const std = @import("std");
const protected = @import("protected_memory.zig");
const Curve = std.crypto.ecc.Secp256k1;
const Ecdsa = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256;
const Keccak = std.crypto.hash.sha3.Keccak256;

pub const Signature = struct { r: [32]u8, s: [32]u8, v: u8 };

fn validate(key: *const [32]u8) !void {
    if (std.mem.allEqual(u8, key, 0)) return error.InvalidPrivateKey;
    Curve.scalar.rejectNonCanonical(key.*, .big) catch return error.InvalidPrivateKey;
}

pub fn address(key: *const [32]u8) ![20]u8 {
    try validate(key);
    const point = try Curve.basePoint.mul(key.*, .big);
    const encoded = point.toUncompressedSec1();
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

pub fn sign(key: *const [32]u8, digest: [32]u8) !Signature {
    try validate(key);
    var storage = try protected.Buffer.init(@sizeOf(Ecdsa.KeyPair));
    defer storage.deinit();
    const pair: *Ecdsa.KeyPair = @ptrCast(@alignCast((try storage.writable()).ptr));
    pair.* = try Ecdsa.KeyPair.fromSecretKey(try Ecdsa.SecretKey.fromBytes(key.*));
    try storage.freeze();
    var sig = try pair.signPrehashed(digest, null);
    if (std.mem.readInt(u256, &sig.s, .big) > Curve.scalar.field_order / 2)
        sig.s = try Curve.scalar.neg(sig.s, .big);
    const expected = try address(key);
    for ([_]u8{ 27, 28 }) |v| {
        const result = Signature{ .r = sig.r, .s = sig.s, .v = v };
        const recovered = recover(digest, result) catch continue;
        if (std.mem.eql(u8, &recovered, &expected)) return result;
    }
    return error.InvalidSignature;
}
