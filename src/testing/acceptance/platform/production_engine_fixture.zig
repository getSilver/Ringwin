//! Provision an isolated Writer for formal Linux role acceptance.
const std = @import("std");
const durable = @import("../../../persistence/durable_store.zig");
const Owner = @import("../../../runtime/demo/demo_authority.zig").Owner;
const fixture = @import("../core/multi_account_authority_acceptance.zig");

pub fn main(init: std.process.Init) !void {
    const Fixture = struct {
        failure: ?anyerror = null,

        fn run(self: *@This(), process: std.process.Init) void {
            provision(process) catch |err| {
                self.failure = err;
            };
        }
    };
    var fixture_run: Fixture = .{};
    const thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 * 1024 }, Fixture.run, .{ &fixture_run, init });
    thread.join();
    if (fixture_run.failure) |failure| return failure;
}

fn provision(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const first = args.next() orelse return error.MissingStateDirectory;
    const append_only = std.mem.eql(u8, first, "--append-capture");
    const capture_only = append_only or std.mem.eql(u8, first, "--capture");
    const path = if (capture_only) args.next() orelse return error.MissingStateDirectory else first;
    const option = args.next();
    const with_recovery = std.mem.eql(u8, option orelse "", "--with-recovery");
    const web_empty = std.mem.eql(u8, option orelse "", "--web-empty");
    const web_approved = std.mem.eql(u8, option orelse "", "--web-approved");
    if (option != null and (capture_only or !(with_recovery or web_empty or web_approved))) return error.InvalidArgument;
    if (args.next() != null or !std.fs.path.isAbsolute(path)) return error.InvalidStateDirectory;
    const store = try init.gpa.create(durable.LinuxFileAdapter);
    defer init.gpa.destroy(store);
    store.* = .{ .dir = undefined };
    try store.initLinux(init.io, path);
    defer store.close(init.io);
    if (capture_only) return provisionCapture(init.io, store, append_only);
    const owner = try init.gpa.create(Owner);
    defer init.gpa.destroy(owner);
    try Owner.bootstrapInto(owner, store.interface(), init.io, .{ .domain = .decision_log, .id = 91 });
    try fixture.initializePythonOwner(owner);
    if (web_approved) {
        try @import("../core/scanner_authorization_acceptance.zig").configurePairAssets(owner);
        _ = try owner.apply(@import("../../support/trading_shard_fixture.zig").atGroup(45, .{
            .identity = 98765,
            .payload = .{ .pair_trading_authorization = .{
                .identity = 98765,
                .strategy = 9,
                .portfolio = 10,
                .activation = 1,
                .config_version = 1,
                .expected_version = 0,
                .legs = .{
                    .{ .venue = 1, .environment = .simulation, .account = 20, .instrument = 101, .rules_version = 2 },
                    .{ .venue = 21, .environment = .simulation, .account = 30, .instrument = 102, .rules_version = 2 },
                },
                .direction = 1,
                .mode = .taker_taker,
                .enabled = true,
            } },
        }));
    }

    const source_config = if (with_recovery) ",\"recovery_sources\":[{\"venue\":1,\"raw_stream\":77,\"session\":9000}]" else "";
    var text: [256]u8 = undefined;
    const config = try std.fmt.bufPrint(&text, "{{\"decision_stream\":91,\"deployment_digest\":\"{s}\"{s}}}\n", .{ std.fmt.bytesToHex(owner.deployment_anchor.?, .lower), source_config });
    const file = try store.dir.createFile(init.io, "engine.json", .{ .exclusive = true });
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, config);
    std.debug.print("provisioned_writer_barrier={d}\n", .{owner.shard.authoritativeBarrier()});
}

fn provisionCapture(io: std.Io, store: *durable.LinuxFileAdapter, append_only: bool) !void {
    const config =
        \\{"source":{"venue":1,"raw_stream":77,"session":9000},"environment":"demo","config_version":1,"okx_binding":{"symbol":"BTC-USDT","instrument":101,"product":"spot","base":"BTC","quote":"USDT"}}
    ;
    const definitions =
        \\{"arg":{"channel":"instruments","instType":"SPOT"},"data":[{"instType":"SPOT","instId":"BTC-USDT","baseCcy":"BTC","quoteCcy":"USDT","state":"live","ruleType":"normal","tickSz":"0.1","lotSz":"0.00000001","minSz":"0.00001","maxLmtSz":"100","maxMktSz":"10","maxLmtAmt":"1000000","maxMktAmt":"100000","ctType":"","ctVal":"","ctValCcy":"","settleCcy":"","tradeQuoteCcyList":["USDT"],"upcChg":[],"ts":"1800000000000"}]}
    ;
    const book =
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"snapshot","data":[{"asks":[["50100.1","2.0","0","3"]],"bids":[["50099.9","1.5","0","2"]],"ts":"1800000000200","seqId":"100","prevSeqId":"-1","checksum":0}]}
    ;
    const next_book =
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"snapshot","data":[{"asks":[["50101.1","2.0","0","3"]],"bids":[["50100.9","1.5","0","2"]],"ts":"1800000000300","seqId":"101","prevSeqId":"-1","checksum":0}]}
    ;
    const RawSink = @import("../../../persistence/raw_ingress.zig").DurableSink;
    const stream: durable.StreamIdentity = .{ .domain = .raw_ingress, .id = 77 };
    var capture = if (append_only)
        try RawSink.recover(store.interface(), io, stream)
    else
        try RawSink.init(store.interface(), io, stream);
    const frames: []const []const u8 = if (append_only) &.{next_book} else &.{ definitions, book };
    for (frames) |frame| {
        const sequence = capture.next_sequence;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(frame, &digest, .{});
        _ = try capture.interface().append(.{
            .source_session = 9000,
            .receive_time_utc_ns = 1_800_000_001_000_000_000 + sequence,
            .monotonic_time_ns = 500 + sequence,
            .wall_time_utc_ns = 1_800_000_001_000_000_000 + sequence,
            .byte_len = @intCast(frame.len),
            .sha256 = digest,
        }, frame);
    }
    if (append_only) return;
    const file = try store.dir.createFile(io, "market-recovery.json", .{ .exclusive = true });
    defer file.close(io);
    try file.writeStreamingAll(io, config);
    std.debug.print("capture_committed_barrier={d}\n", .{capture.next_sequence - 1});
}
