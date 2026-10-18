//! Credential AEAD. Caller key/plaintext must already be protected; keys are
//! borrowed by pointer. No sensitive context is returned by value.
const std = @import("std");
const builtin = @import("builtin");
const protected = @import("protected_memory.zig");
const core = @import("credential_aead_crypto/chacha20_core.zig").core;
const Poly1305 = @import("credential_aead_crypto/poly1305.zig").Poly1305;
pub const key_length = 32;
pub const nonce_length = 24;
pub const tag_length = 16;

const Scratch = struct {
    subkey: [32]u8,
    context: [16]u32,
    working: [16]u32,
    stream: [64]u8,
    poly_key: [32]u8,
    mac: Poly1305,
    computed_tag: [16]u8,
    lengths: [16]u8,
};

pub const workspace_bytes = @sizeOf(Scratch);

pub fn encrypt(c: []u8, tag: *[16]u8, m: []const u8, ad: []const u8, nonce: [24]u8, key: *const [32]u8) !void {
    return encryptOwned(c, tag, m, ad, nonce, key, null);
}

pub fn decrypt(m: []u8, c: []const u8, tag: [16]u8, ad: []const u8, nonce: [24]u8, key: *const [32]u8) !void {
    return decryptOwned(m, c, tag, ad, nonce, key, null);
}

pub fn encryptWithTestingBackend(c: []u8, tag: *[16]u8, m: []const u8, ad: []const u8, nonce: [24]u8, key: *const [32]u8, backend: protected.Backend) !void {
    if (!builtin.is_test) @compileError("AEAD test backend is test-only");
    return encryptOwned(c, tag, m, ad, nonce, key, backend);
}

pub fn decryptWithTestingBackend(m: []u8, c: []const u8, tag: [16]u8, ad: []const u8, nonce: [24]u8, key: *const [32]u8, backend: protected.Backend) !void {
    if (!builtin.is_test) @compileError("AEAD test backend is test-only");
    return decryptOwned(m, c, tag, ad, nonce, key, backend);
}

fn acquire(backend: ?protected.Backend) !protected.Buffer {
    if (builtin.is_test) {
        if (backend) |value| return protected.Buffer.initForTesting(workspace_bytes, value);
    }
    return protected.Buffer.init(workspace_bytes);
}

fn checkLengths(out_len: usize, in_len: usize) !void {
    if (out_len != in_len or in_len > 64 * (@as(u64, 1 << 32) - 1)) return error.InvalidLength;
}

fn encryptOwned(c: []u8, tag: *[16]u8, m: []const u8, ad: []const u8, nonce: [24]u8, key: *const [32]u8, backend: ?protected.Backend) !void {
    errdefer {
        std.crypto.secureZero(u8, c);
        std.crypto.secureZero(u8, tag);
    }
    try checkLengths(c.len, m.len);
    var memory = try acquire(backend);
    defer memory.deinit();
    const state: *Scratch = @ptrCast(@alignCast((try memory.writable()).ptr));
    defer std.crypto.secureZero(u8, std.mem.asBytes(state));
    initialize(state, key, &nonce);
    xor(state, c, m);
    authenticate(state, &state.computed_tag, c, ad);
    @memcpy(tag, &state.computed_tag);
}

fn decryptOwned(m: []u8, c: []const u8, tag: [16]u8, ad: []const u8, nonce: [24]u8, key: *const [32]u8, backend: ?protected.Backend) !void {
    errdefer std.crypto.secureZero(u8, m);
    try checkLengths(m.len, c.len);
    var memory = try acquire(backend);
    defer memory.deinit();
    const state: *Scratch = @ptrCast(@alignCast((try memory.writable()).ptr));
    defer std.crypto.secureZero(u8, std.mem.asBytes(state));
    initialize(state, key, &nonce);
    authenticate(state, &state.computed_tag, c, ad);
    if (!std.crypto.timing_safe.eql([16]u8, state.computed_tag, tag)) return error.AuthenticationFailed;
    xor(state, m, c);
}

fn contextKey(state: *Scratch, key: *const [32]u8) void {
    const constant = "expand 32-byte k";
    for (0..4) |i| state.context[i] = std.mem.readInt(u32, constant[i * 4 ..][0..4], .little);
    for (0..8) |i| state.context[4 + i] = std.mem.readInt(u32, key[i * 4 ..][0..4], .little);
}

fn initialize(state: *Scratch, key: *const [32]u8, nonce: *const [24]u8) void {
    // HChaCha20: same scalar core and output indices as pinned stdlib.
    contextKey(state, key);
    for (0..4) |i| state.context[12 + i] = std.mem.readInt(u32, nonce[i * 4 ..][0..4], .little);
    core(&state.working, &state.context);
    for (0..4) |i| {
        std.mem.writeInt(u32, state.subkey[i * 4 ..][0..4], state.working[i], .little);
        std.mem.writeInt(u32, state.subkey[16 + i * 4 ..][0..4], state.working[12 + i], .little);
    }
    // XChaCha's IETF nonce is 0^32 || original_nonce[16..24].
    contextKey(state, &state.subkey);
    state.context[13] = 0;
    state.context[14] = std.mem.readInt(u32, nonce[16..20], .little);
    state.context[15] = std.mem.readInt(u32, nonce[20..24], .little);
    block(state, 0);
    @memcpy(&state.poly_key, state.stream[0..32]);
    state.mac.reset(&state.poly_key);
    std.crypto.secureZero(u8, &state.poly_key);
    std.crypto.secureZero(u8, &state.stream);
}

fn block(state: *Scratch, counter: u32) void {
    state.context[12] = counter;
    core(&state.working, &state.context);
    for (0..16) |i| {
        state.working[i] +%= state.context[i];
        std.mem.writeInt(u32, state.stream[i * 4 ..][0..4], state.working[i], .little);
    }
}

fn xor(state: *Scratch, out: []u8, in: []const u8) void {
    var offset: usize = 0;
    var counter: u32 = 1;
    while (offset < in.len) {
        block(state, counter);
        const amount = @min(64, in.len - offset);
        for (0..amount) |i| out[offset + i] = in[offset + i] ^ state.stream[i];
        offset += amount;
        counter +%= 1;
    }
}

fn authenticate(state: *Scratch, tag: *[16]u8, c: []const u8, ad: []const u8) void {
    state.mac.update(ad);
    state.mac.pad();
    state.mac.update(c);
    state.mac.pad();
    std.mem.writeInt(u64, state.lengths[0..8], ad.len, .little);
    std.mem.writeInt(u64, state.lengths[8..16], c.len, .little);
    state.mac.update(&state.lengths);
    state.mac.final(tag);
}

test "credential AEAD matches original XChaCha20 Poly1305 bytes" {
    const key: [32]u8 = @splat(0x69);
    const nonce: [24]u8 = @splat(0x42);
    const message = "synthetic credential plaintext";
    var actual: [message.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    var original: [message.len]u8 = undefined;
    var original_tag: [16]u8 = undefined;
    std.crypto.aead.chacha_poly.XChaCha20Poly1305.encrypt(&original, &original_tag, message, "metadata", nonce, key);
    try encrypt(&actual, &tag, message, "metadata", nonce, &key);
    try std.testing.expectEqualSlices(u8, &original, &actual);
    try std.testing.expectEqualSlices(u8, &original_tag, &tag);
}
