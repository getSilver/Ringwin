//! Durable consume-before-sign ledger, shared by every user of a signer.
//! Caller holds CredentialStore's stable writer lock across reserve and sign.
const std = @import("std");
const builtin = @import("builtin");
const Crc = std.hash.crc.Crc32Iscsi;
const header_size = 28;
const record_size = 36;
// shortcut: bounded linear scan of 65536 consumed requests; replace with an
// indexed durable ledger before qualifying higher-volume signing workloads.
const max_records = 65536;

fn name(signer: [20]u8) [54]u8 {
    return std.fmt.bytesToHex(signer, .lower) ++ ".signer-nonces".*;
}

pub fn provision(dir: std.Io.Dir, io: std.Io, signer: [20]u8) !void {
    var file = try dir.createFile(io, &name(signer), .{
        .exclusive = true,
        .permissions = if (builtin.os.tag == .linux) @enumFromInt(0o600) else .default_file,
    });
    defer file.close(io);
    var header: [header_size]u8 = undefined;
    header[0..4].* = "SN01".*;
    @memcpy(header[4..24], &signer);
    std.mem.writeInt(u32, header[24..28], Crc.hash(header[0..24]), .little);
    try file.writeStreamingAll(io, &header);
    try file.sync(io);
    if (builtin.os.tag == .linux and std.os.linux.errno(std.os.linux.fsync(dir.handle)) != .SUCCESS) return error.DirectorySyncFailed;
}

pub fn reserve(dir: std.Io.Dir, io: std.Io, signer: [20]u8, account: u64, command: u128, now_ms: u64) !u64 {
    if (account == 0 or command == 0 or now_ms == 0) return error.InvalidSigningRequest;
    var file = try dir.openFile(io, &name(signer), .{ .mode = .read_write });
    defer file.close(io);
    var header: [header_size]u8 = undefined;
    if (try file.readPositionalAll(io, &header, 0) != header.len or
        !std.mem.eql(u8, header[0..4], "SN01") or !std.mem.eql(u8, header[4..24], &signer) or
        std.mem.readInt(u32, header[24..28], .little) != Crc.hash(header[0..24])) return error.CorruptNonceLedger;
    const size = (try file.stat(io)).size;
    if (size < header_size or (size - header_size) % record_size != 0 or
        (size - header_size) / record_size > max_records) return error.CorruptNonceLedger;
    var previous: u64 = 0;
    var offset: u64 = header_size;
    var record: [record_size]u8 = undefined;
    while (offset < size) : (offset += record_size) {
        if (try file.readPositionalAll(io, &record, offset) != record.len or
            std.mem.readInt(u32, record[32..36], .little) != Crc.hash(record[0..32])) return error.CorruptNonceLedger;
        const nonce = std.mem.readInt(u64, record[0..8], .little);
        if (nonce <= previous or std.mem.readInt(u64, record[8..16], .little) == 0 or
            std.mem.readInt(u128, record[16..32], .little) == 0) return error.CorruptNonceLedger;
        previous = nonce;
        if (std.mem.readInt(u64, record[8..16], .little) == account and
            std.mem.readInt(u128, record[16..32], .little) == command) return error.RequestAlreadyConsumed;
    }
    if ((size - header_size) / record_size == max_records) return error.NonceLedgerFull;
    const next = @max(now_ms, std.math.add(u64, previous, 1) catch return error.NonceExhausted);
    // Conservative local bound inside the exchange's one-day future window.
    if (next - now_ms >= std.time.ms_per_hour) return error.NonceClockSkew;
    std.mem.writeInt(u64, record[0..8], next, .little);
    std.mem.writeInt(u64, record[8..16], account, .little);
    std.mem.writeInt(u128, record[16..32], command, .little);
    std.mem.writeInt(u32, record[32..36], Crc.hash(record[0..32]), .little);
    try file.writePositionalAll(io, &record, size);
    try file.sync(io);
    return next;
}
