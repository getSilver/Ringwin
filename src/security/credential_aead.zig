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

test "credential AEAD matches original boundaries and supports in place decrypt" {
    const key: [32]u8 = @splat(0x17);
    const nonce: [24]u8 = @splat(0x93);
    var message: [512]u8 = undefined;
    for (&message, 0..) |*byte, index| byte.* = @truncate(index);
    var metadata: [252]u8 = undefined;
    for (&metadata, 0..) |*byte, index| byte.* = @truncate(index * 3);
    var original: [512]u8 = undefined;
    var actual: [512]u8 = undefined;
    var output: [512]u8 = undefined;
    var tag: [16]u8 = undefined;
    var original_tag: [16]u8 = undefined;
    for ([_]usize{ 0, 1, 15, 16, 17, 63, 64, 65, 512 }) |length| {
        for ([_]usize{ 0, 1, 15, 16, 17, 252 }) |ad_length| {
            var observer = protected.TestingBackend{};
            const ad = metadata[0..ad_length];
            std.crypto.aead.chacha_poly.XChaCha20Poly1305.encrypt(original[0..length], &original_tag, message[0..length], ad, nonce, key);
            try encryptWithTestingBackend(actual[0..length], &tag, message[0..length], ad, nonce, &key, observer.backend());
            try std.testing.expectEqualSlices(u8, original[0..length], actual[0..length]);
            try std.testing.expectEqualSlices(u8, &original_tag, &tag);
            try std.crypto.aead.chacha_poly.XChaCha20Poly1305.decrypt(output[0..length], actual[0..length], tag, ad, nonce, key);
            try std.testing.expectEqualSlices(u8, message[0..length], output[0..length]);
            try decryptWithTestingBackend(actual[0..length], actual[0..length], original_tag, ad, nonce, &key, observer.backend());
            try std.testing.expectEqualSlices(u8, message[0..length], actual[0..length]);
            try std.testing.expect(observer.erased);
            try std.testing.expectEqual(@as(usize, 2), observer.released);
        }
    }
}

test "credential AEAD rejects tampering and securely clears output on every failure" {
    const key: [32]u8 = @splat(0x47);
    const nonce: [24]u8 = @splat(0x42);
    const message = "synthetic plaintext";
    var ciphertext: [message.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    try encrypt(&ciphertext, &tag, message, "AAD", nonce, &key);
    var output: [message.len]u8 = undefined;
    for (0..5) |change| {
        var bad_ciphertext = ciphertext;
        var bad_tag = tag;
        var bad_nonce = nonce;
        var bad_key = key;
        var bad_ad: [3]u8 = "AAD".*;
        switch (change) {
            0 => bad_ciphertext[0] ^= 1,
            1 => bad_tag[0] ^= 1,
            2 => bad_nonce[0] ^= 1,
            3 => bad_key[0] ^= 1,
            4 => bad_ad[0] ^= 1,
            else => unreachable,
        }
        var observer = protected.TestingBackend{};
        @memset(&output, 0x73);
        try std.testing.expectError(error.AuthenticationFailed, decryptWithTestingBackend(&output, &bad_ciphertext, bad_tag, &bad_ad, bad_nonce, &bad_key, observer.backend()));
        try std.testing.expect(std.mem.allEqual(u8, &output, 0));
        try std.testing.expect(observer.erased);
        try std.testing.expectEqual(@as(usize, 1), observer.released);
    }
    @memset(&output, 0x71);
    try std.testing.expectError(error.InvalidLength, decrypt(output[0..1], &ciphertext, tag, "AAD", nonce, &key));
    try std.testing.expectEqual(@as(u8, 0), output[0]);
    try std.testing.expect(std.mem.allEqual(u8, &key, 0x47));
}

test "credential AEAD protection failures clear caller outputs without a bypass" {
    const key: [32]u8 = @splat(0x22);
    const nonce: [24]u8 = @splat(0x91);
    const failures = [_]protected.TestingBackend{ .{ .fail = .allocation }, .{ .fail = .lock }, .{ .fail = .dump }, .{ .fail = .protection } };
    const errors = [_]protected.Error{ error.OutOfMemory, error.MemoryLockFailed, error.DontDumpFailed, error.MemoryProtectionFailed };
    for (failures, errors) |failure, expected| {
        var observer = failure;
        var ciphertext: [4]u8 = @splat(0x55);
        var tag: [16]u8 = @splat(0x72);
        try std.testing.expectError(expected, encryptWithTestingBackend(&ciphertext, &tag, "test", "", nonce, &key, observer.backend()));
        try std.testing.expect(std.mem.allEqual(u8, &ciphertext, 0));
        try std.testing.expect(std.mem.allEqual(u8, &tag, 0));
        var output: [4]u8 = @splat(0x44);
        try std.testing.expectError(expected, decryptWithTestingBackend(&output, &ciphertext, tag, "", nonce, &key, observer.backend()));
        try std.testing.expect(std.mem.allEqual(u8, &output, 0));
        try std.testing.expect(observer.erased);
        try std.testing.expectEqual(@as(usize, if (failure.fail == .allocation) 0 else 2), observer.released);
    }
}

test "credential AEAD known XChaCha vector and RFC Poly1305 vector" {
    const message = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
    const expected_hex = "994D2DD32333F48E53650C02C7A2ABB8E018B0836D7175AEC779F52E961780768F815C58F1AA52D211498DB89B9216763F569C9433A6BBFCEFB4D4A49387A4C5207FBB3B5A92B5941294DF30588C6740D39DC16FA1F0E634F7246CF7CDCB978E44347D89381B7A74EB7084F754B90BDE9AAF5A94B8F2A85EFD0B50692AE2D425E234";
    var expected: [message.len + 16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, expected_hex);
    var ciphertext: [message.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    const key: [32]u8 = @splat(69);
    const nonce: [24]u8 = @splat(42);
    try encrypt(&ciphertext, &tag, message, "Additional data", nonce, &key);
    try std.testing.expectEqualSlices(u8, expected[0..message.len], &ciphertext);
    try std.testing.expectEqualSlices(u8, expected[message.len..], &tag);
    var memory = try protected.Buffer.init(@sizeOf(Poly1305));
    defer memory.deinit();
    const mac: *Poly1305 = @ptrCast(@alignCast((try memory.writable()).ptr));
    const poly_key = "\x85\xd6\xbe\x78\x57\x55\x6d\x33\x7f\x44\x52\xfe\x42\xd5\x06\xa8" ++ "\x01\x03\x80\x8a\xfb\x0d\xb2\xfd\x4a\xbf\xf6\xaf\x41\x49\xf5\x1b";
    mac.reset(poly_key);
    mac.update("Cryptographic Forum Research Group");
    mac.final(&tag);
    try std.testing.expectEqualSlices(u8, "\xa8\x06\x1d\xc1\x30\x51\x36\xc6\xc2\x2b\x8b\xaf\x0c\x01\x27\xa9", &tag);
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(mac), 0));
}

test "credential AEAD native operates on protected key and plaintext owners" {
    var key = try protected.Buffer.init(32);
    defer key.deinit();
    @memset(try key.writable(), 0x29);
    try key.freeze();
    var plaintext = try protected.Buffer.init(512);
    defer plaintext.deinit();
    @memset(try plaintext.writable(), 0x17);
    var ciphertext: [512]u8 = undefined;
    var tag: [16]u8 = undefined;
    const key_pointer: *const [32]u8 = key.bytes()[0..32];
    try encrypt(&ciphertext, &tag, plaintext.bytes(), "metadata", @splat(0x83), key_pointer);
    @memset(try plaintext.writable(), 0);
    try decrypt(try plaintext.writable(), &ciphertext, tag, "metadata", @splat(0x83), key_pointer);
    try std.testing.expect(std.mem.allEqual(u8, plaintext.bytes(), 0x17));
    try std.testing.expect(key.report().locked and plaintext.report().locked);
}
