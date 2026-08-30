//! Benchmark orchestration for deterministic TradingShard fixtures.
const std = @import("std");
const builtin = @import("builtin");
const engine = @import("trading_shard.zig");
const fixture = @import("trading_shard_fixture.zig");
const journal = engine.journal;
const Sha256 = std.crypto.hash.sha2.Sha256;
const InputEvent = engine.CoreEvent;
const TradingShard = engine.TradingShard;
const LiveRun = fixture.LiveRun;
const applyLive = engine.applyStable;
const deltaAt = fixture.deltaAt;
const atGroup = fixture.atGroup;
const runHappyPath = fixture.runHappyPath;
const assertExpectedDigest = engine.assertExpectedDigest;
const expected_happy_digest = engine.expected_happy_digest;
const happy_order_quantity: i64 = 100;
const benchmark_samples: usize = 1_000_000;
const benchmark_warmup: usize = 50_000;
const LatencyHistogram = struct {
    const bucket_width_ns: u64 = 500;
    const bucket_count = 40_000;
    const tail_bucket_width_ns: u64 = std.time.ns_per_ms;
    const tail_bucket_count = 1_000;
    const primary_range_ns = bucket_width_ns * bucket_count;

    buckets: [bucket_count]u64 = @splat(0),
    tail_buckets: [tail_bucket_count]u64 = @splat(0),
    samples: u64 = 0,
    overflow: u64 = 0,
    max_ns: u64 = 0,

    fn record(self: *LatencyHistogram, nanoseconds: u64) void {
        self.samples += 1;
        self.max_ns = @max(self.max_ns, nanoseconds);
        const index = nanoseconds / bucket_width_ns;
        if (index < self.buckets.len) {
            self.buckets[index] += 1;
            return;
        }
        const tail_index = (nanoseconds - primary_range_ns) / tail_bucket_width_ns;
        if (tail_index < self.tail_buckets.len)
            self.tail_buckets[tail_index] += 1
        else
            self.overflow += 1;
    }

    fn percentile(self: *const LatencyHistogram, numerator: u64, denominator: u64) !u64 {
        if (self.samples == 0 or self.overflow != 0) return error.InvalidHistogram;
        const target = @divFloor(self.samples * numerator + denominator - 1, denominator);
        var seen: u64 = 0;
        for (self.buckets, 0..) |count, index| {
            seen += count;
            if (seen >= target) return (index + 1) * bucket_width_ns;
        }
        for (self.tail_buckets, 0..) |count, index| {
            seen += count;
            if (seen >= target)
                return primary_range_ns + (index + 1) * tail_bucket_width_ns;
        }
        return error.InvalidHistogram;
    }

    fn merge(self: *LatencyHistogram, other: *const LatencyHistogram) void {
        for (&self.buckets, other.buckets) |*destination, count| destination.* += count;
        for (&self.tail_buckets, other.tail_buckets) |*destination, count|
            destination.* += count;
        self.samples += other.samples;
        self.overflow += other.overflow;
        self.max_ns = @max(self.max_ns, other.max_ns);
    }
};

const BenchmarkTelemetry = struct {
    events: u64 = 0,
    commands: u64 = 0,
    correctness_failures: u64 = 0,
    queue_current: usize = 0,
    queue_high_water: usize = 0,
    queue_capacity: usize,

    fn enqueue(self: *BenchmarkTelemetry) !void {
        if (self.queue_current == self.queue_capacity) return error.BenchmarkQueueFull;
        self.queue_current += 1;
        self.queue_high_water = @max(self.queue_high_water, self.queue_current);
    }

    fn dequeue(self: *BenchmarkTelemetry) void {
        std.debug.assert(self.queue_current > 0);
        self.queue_current -= 1;
    }
};

const BenchmarkResult = struct {
    name: []const u8,
    histogram: LatencyHistogram,
    telemetry: BenchmarkTelemetry,
    elapsed_ns: u64,
};

const MarketBenchmarkWork = struct {
    input: InputEvent,
    enqueued_ns: u64,
};

fn nowNs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn initializedBenchmarkRun() !LiveRun {
    return fixture.initializedBenchmarkRun();
}

fn runMarketBenchmark(
    io: std.Io,
    name: []const u8,
    samples: usize,
    burst_size: usize,
) !BenchmarkResult {
    const queue_capacity = 128;
    if (burst_size == 0 or burst_size > queue_capacity) return error.InvalidBurstSize;
    var run = try initializedBenchmarkRun();
    var queued: [queue_capacity]MarketBenchmarkWork = undefined;
    var histogram: LatencyHistogram = .{};
    var telemetry: BenchmarkTelemetry = .{ .queue_capacity = queue_capacity };
    var source_sequence: u64 = 101;
    var completed: usize = 0;
    const run_started = nowNs(io);

    while (completed < samples) {
        const batch_size = @min(burst_size, samples - completed);
        if (run.shard.trace.len + batch_size > run.shard.trace.events.len) {
            run.shard.trace.len = 0;
            run.decision_journal = journal.Journal.init();
        }
        const journal_records_before = run.decision_journal.records;
        for (queued[0..batch_size]) |*work| {
            const previous = source_sequence;
            source_sequence += 1;
            work.* = .{
                .input = deltaAt(
                    15 + source_sequence,
                    previous,
                    source_sequence,
                    49_850_000_000 + @as(i64, @intCast(source_sequence % 10)),
                ),
                .enqueued_ns = nowNs(io),
            };
            try telemetry.enqueue();
        }
        for (queued[0..batch_size], 0..) |work, index| {
            if (try applyLive(&run.shard, &run.decision_journal, work.input) != null)
                return error.UnexpectedCommand;
            const finished_ns = nowNs(io);
            histogram.record(finished_ns - work.enqueued_ns);
            telemetry.dequeue();
            telemetry.events += 1;
            if (run.shard.market_health != .healthy or
                run.shard.expected_source_sequence != source_sequence - batch_size + index + 1 or
                run.decision_journal.records != journal_records_before + index + 1)
                return error.BenchmarkCorrectnessFailure;
        }
        completed += batch_size;
    }
    return .{
        .name = name,
        .histogram = histogram,
        .telemetry = telemetry,
        .elapsed_ns = nowNs(io) - run_started,
    };
}

const OrderBenchmarkWork = struct {
    shard: TradingShard,
    decision_journal: journal.Journal,
    input: InputEvent,
    enqueued_ns: u64,
};

fn runOrderBenchmark(io: std.Io, samples: usize, burst_size: usize) !BenchmarkResult {
    const queue_capacity = 16;
    if (burst_size == 0 or burst_size > queue_capacity) return error.InvalidBurstSize;
    const base = try initializedBenchmarkRun();
    var queued: [queue_capacity]OrderBenchmarkWork = undefined;
    var histogram: LatencyHistogram = .{};
    var telemetry: BenchmarkTelemetry = .{ .queue_capacity = queue_capacity };
    var completed: usize = 0;
    const run_started = nowNs(io);

    while (completed < samples) {
        const batch_size = @min(burst_size, samples - completed);
        for (queued[0..batch_size], 0..) |*work, index| {
            work.* = .{
                .shard = base.shard,
                .decision_journal = journal.Journal.init(),
                .input = atGroup(completed + index + 15, .{
                    .identity = completed + index + 1,
                    .payload = .{ .timer = .{ .quantity = happy_order_quantity } },
                }),
                .enqueued_ns = nowNs(io),
            };
            try telemetry.enqueue();
        }
        for (queued[0..batch_size]) |*work| {
            const command = (try applyLive(
                &work.shard,
                &work.decision_journal,
                work.input,
            )) orelse return error.MissingOrderCommand;
            const finished_ns = nowNs(io);
            histogram.record(finished_ns - work.enqueued_ns);
            telemetry.dequeue();
            telemetry.events += 1;
            telemetry.commands += 1;
            if (command.reservation.atoms != 11_397_750 or
                work.shard.order_state != .pending_submit or
                work.decision_journal.records != 5)
                return error.BenchmarkCorrectnessFailure;
        }
        completed += batch_size;
    }
    return .{
        .name = "order-burst",
        .histogram = histogram,
        .telemetry = telemetry,
        .elapsed_ns = nowNs(io) - run_started,
    };
}

fn runRecoveryBenchmark(io: std.Io, samples: usize) !BenchmarkResult {
    var run = try initializedBenchmarkRun();
    var histogram: LatencyHistogram = .{};
    var telemetry: BenchmarkTelemetry = .{ .queue_capacity = 6 };
    var completed: usize = 0;
    var source_sequence: u64 = 101;
    const run_started = nowNs(io);

    while (completed < samples) {
        const cycle = @min(@as(usize, 3), samples - completed);
        const snapshot_sequence = source_sequence + 100;
        const inputs = [_]InputEvent{
            deltaAt(15 + completed, source_sequence + 1, source_sequence + 2, 49_860_000_000),
            engine.snapshotAt(16 + completed, snapshot_sequence),
            deltaAt(
                17 + completed,
                snapshot_sequence,
                snapshot_sequence + 1,
                49_850_000_000,
            ),
        };
        run.shard.trace.len = 0;
        run.decision_journal = journal.Journal.init();
        var enqueued: [3]u64 = undefined;
        for (inputs[0..cycle], 0..) |_, index| {
            enqueued[index] = nowNs(io);
            try telemetry.enqueue();
        }
        for (inputs[0..cycle], 0..) |input, index| {
            if (try applyLive(&run.shard, &run.decision_journal, input) != null)
                return error.UnexpectedCommand;
            histogram.record(nowNs(io) - enqueued[index]);
            telemetry.dequeue();
            telemetry.events += 1;
            const expected_records = [_]u64{ 2, 3, 5 };
            if (run.decision_journal.records != expected_records[index])
                return error.BenchmarkCorrectnessFailure;
        }
        source_sequence = snapshot_sequence + 1;
        completed += cycle;
    }
    if (run.shard.market_health != .healthy) return error.RecoveryDidNotComplete;
    return .{
        .name = "exception-recovery",
        .histogram = histogram,
        .telemetry = telemetry,
        .elapsed_ns = nowNs(io) - run_started,
    };
}

fn printBenchmarkResult(
    out: *std.Io.Writer,
    result: *const BenchmarkResult,
    raw: bool,
) !void {
    const throughput = @divFloor(
        result.telemetry.events * std.time.ns_per_s,
        result.elapsed_ns,
    );
    try out.print(
        "{s}: samples={d} p50_ns={d} p99_ns={d} p999_ns={d} max_ns={d} throughput_eps={d} queue_hwm={d}/{d} overflow={d} correctness_failures={d}\n",
        .{
            result.name,
            result.histogram.samples,
            try result.histogram.percentile(50, 100),
            try result.histogram.percentile(99, 100),
            try result.histogram.percentile(999, 1000),
            result.histogram.max_ns,
            throughput,
            result.telemetry.queue_high_water,
            result.telemetry.queue_capacity,
            result.histogram.overflow,
            result.telemetry.correctness_failures,
        },
    );
    if (raw) {
        try out.print("{s}.raw_bucket_ns_upper=count:", .{result.name});
        for (result.histogram.buckets, 0..) |count, index| {
            if (count != 0) try out.print(" {d}={d}", .{
                (index + 1) * LatencyHistogram.bucket_width_ns,
                count,
            });
        }
        for (result.histogram.tail_buckets, 0..) |count, index| {
            if (count != 0) try out.print(" {d}={d}", .{
                LatencyHistogram.primary_range_ns +
                    (index + 1) * LatencyHistogram.tail_bucket_width_ns,
                count,
            });
        }
        try out.writeByte('\n');
    }
}

fn benchmark(init: std.process.Init, raw: bool) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout.interface;

    _ = try runMarketBenchmark(init.io, "warmup", benchmark_warmup, 1);
    const steady = try runMarketBenchmark(init.io, "steady", benchmark_samples, 1);
    const market_burst = try runMarketBenchmark(
        init.io,
        "market-burst",
        benchmark_samples,
        64,
    );
    const order_burst = try runOrderBenchmark(init.io, benchmark_samples, 8);
    const recovery = try runRecoveryBenchmark(init.io, benchmark_samples + 2);
    try out.print(
        "single_shard_benchmark: zig={s} mode={s} os={s} samples_per_scenario={d} timer=monotonic queue=bounded journal=crc32c telemetry=fixed_histogram correctness=continuous network=excluded\n",
        .{
            builtin.zig_version_string,
            @tagName(builtin.mode),
            @tagName(builtin.os.tag),
            benchmark_samples,
        },
    );
    try printBenchmarkResult(out, &steady, raw);
    try printBenchmarkResult(out, &market_burst, raw);
    try printBenchmarkResult(out, &order_burst, raw);
    try printBenchmarkResult(out, &recovery, raw);
    try out.flush();
}

const ShardInbox = struct {
    const capacity = 8;

    events: [capacity]InputEvent = undefined,
    head: usize = 0,
    len: usize = 0,
    high_water: usize = 0,

    fn push(self: *ShardInbox, event: InputEvent) !void {
        if (self.len == self.events.len) return error.ShardQueueFull;
        self.events[(self.head + self.len) % self.events.len] = event;
        self.len += 1;
        self.high_water = @max(self.high_water, self.len);
    }

    fn pop(self: *ShardInbox) ?InputEvent {
        if (self.len == 0) return null;
        const event = self.events[self.head];
        self.head = (self.head + 1) % self.events.len;
        self.len -= 1;
        return event;
    }
};

const QualifiedShard = struct {
    decision_domain: u8,
    run: LiveRun,
    inbox: ShardInbox = .{},
};

const SharedMarketRouter = struct {
    normalized_events: u64 = 0,
    routed_deliveries: u64 = 0,

    fn route(
        self: *SharedMarketRouter,
        shards: *[4]QualifiedShard,
        target_domain: u8,
        normalized_event: InputEvent,
    ) !void {
        self.normalized_events += 1;
        if (target_domain >= shards.len) return error.UnknownDecisionDomain;
        try shards[target_domain].inbox.push(normalized_event);
        self.routed_deliveries += 1;
    }
};

fn drainOne(shard: *QualifiedShard) !void {
    const input = shard.inbox.pop() orelse return error.EmptyShardQueue;
    if (try applyLive(&shard.run.shard, &shard.run.decision_journal, input) != null)
        return error.UnexpectedCommand;
}

fn assertFourShardIsolation() ![4][Sha256.digest_length]u8 {
    var digests: [4][Sha256.digest_length]u8 = undefined;
    for (&digests) |*digest| {
        const run = try runHappyPath();
        digest.* = try fixture.replayDigest(run);
        try assertExpectedDigest(digest.*, expected_happy_digest);
    }

    var shards: [4]QualifiedShard = undefined;
    for (&shards, 0..) |*shard, index| {
        shard.* = .{
            .decision_domain = @intCast(index),
            .run = try initializedBenchmarkRun(),
        };
    }
    var router: SharedMarketRouter = .{};

    try router.route(
        &shards,
        0,
        deltaAt(15, 102, 103, 49_860_000_000),
    );
    try drainOne(&shards[0]);
    if (shards[0].run.shard.market_health != .gap or
        shards[0].run.shard.trace.len != 2)
        return error.GapIsolationFailed;

    try shards[0].inbox.push(atGroup(16, .{
        .identity = 1,
        .payload = .{ .timer = .{ .quantity = happy_order_quantity } },
    }));
    while (shards[0].inbox.len < ShardInbox.capacity) {
        try shards[0].inbox.push(deltaAt(16, 103, 104, 49_860_000_000));
    }
    if (shards[0].inbox.push(deltaAt(17, 104, 105, 49_860_000_000))) |_|
        return error.QueueSaturationNotDetected
    else |err| if (err != error.ShardQueueFull) return err;

    for (1..4) |index| {
        try router.route(
            &shards,
            @intCast(index),
            deltaAt(15, 101, 102, 49_850_000_000 + @as(i64, @intCast(index))),
        );
    }
    for (1..4) |index| try drainOne(&shards[index]);

    if (router.normalized_events != 4 or router.routed_deliveries != 4 or
        shards[0].inbox.len != ShardInbox.capacity or
        shards[0].inbox.high_water != ShardInbox.capacity)
        return error.RouterIsolationFailed;
    for (1..4) |index| {
        if (shards[index].run.shard.market_health != .healthy or
            shards[index].run.shard.expected_source_sequence != 102 or
            shards[index].run.shard.trace.len != 1 or
            shards[index].run.decision_journal.records != 1 or
            shards[index].inbox.len != 0)
            return error.HealthyShardWasAffected;
    }
    return digests;
}

const FourShardWorker = struct {
    io: std.Io,
    queue: *SpscQueue,
    ready: *std.atomic.Value(u8),
    start: *std.atomic.Value(bool),
    result: ?BenchmarkResult = null,
    failure: ?anyerror = null,

    fn run(self: *FourShardWorker) void {
        _ = runMarketBenchmark(self.io, "warmup", benchmark_warmup, 1) catch |err| {
            self.failure = err;
            _ = self.ready.fetchAdd(1, .release);
            return;
        };
        _ = self.ready.fetchAdd(1, .release);
        while (!self.start.load(.acquire)) std.Thread.yield() catch {};
        self.result = runRoutedShardBenchmark(self) catch |err| {
            self.failure = err;
            return;
        };
    }
};

const SpscQueue = struct {
    const capacity = 4_096;

    items: [capacity]MarketBenchmarkWork = undefined,
    read_index: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    write_index: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    high_water: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    full_observations: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn push(self: *SpscQueue, work: MarketBenchmarkWork) bool {
        const write_index = self.write_index.load(.monotonic);
        const read_index = self.read_index.load(.acquire);
        if (write_index - read_index == self.items.len) {
            _ = self.full_observations.fetchAdd(1, .monotonic);
            return false;
        }
        self.items[write_index % self.items.len] = work;
        self.write_index.store(write_index + 1, .release);
        _ = self.high_water.fetchMax(write_index - read_index + 1, .monotonic);
        return true;
    }

    fn pop(self: *SpscQueue) ?MarketBenchmarkWork {
        const read_index = self.read_index.load(.monotonic);
        const write_index = self.write_index.load(.acquire);
        if (read_index == write_index) return null;
        const work = self.items[read_index % self.items.len];
        self.read_index.store(read_index + 1, .release);
        return work;
    }
};

fn runRoutedShardBenchmark(worker: *FourShardWorker) !BenchmarkResult {
    var run = try initializedBenchmarkRun();
    var histogram: LatencyHistogram = .{};
    var telemetry: BenchmarkTelemetry = .{ .queue_capacity = SpscQueue.capacity };
    var expected_source_sequence: u64 = 101;
    const started_ns = nowNs(worker.io);

    while (telemetry.events < benchmark_samples) {
        const work = worker.queue.pop() orelse {
            std.Thread.yield() catch {};
            continue;
        };
        if (run.shard.trace.len == run.shard.trace.events.len) {
            run.shard.trace.len = 0;
            run.decision_journal = journal.Journal.init();
        }
        const records_before = run.decision_journal.records;
        if (try applyLive(&run.shard, &run.decision_journal, work.input) != null)
            return error.UnexpectedCommand;
        histogram.record(nowNs(worker.io) - work.enqueued_ns);
        telemetry.events += 1;
        expected_source_sequence += 1;
        if (run.shard.market_health != .healthy or
            run.shard.expected_source_sequence != expected_source_sequence or
            run.decision_journal.records != records_before + 1)
            return error.BenchmarkCorrectnessFailure;
    }
    telemetry.queue_high_water = worker.queue.high_water.load(.acquire);
    return .{
        .name = "four-shard-routed",
        .histogram = histogram,
        .telemetry = telemetry,
        .elapsed_ns = nowNs(worker.io) - started_ns,
    };
}

fn percentChangeBasisPoints(current: u64, baseline: u64) i64 {
    return @intCast(@divTrunc(
        (@as(i128, current) - baseline) * 10_000,
        baseline,
    ));
}

fn benchmarkFourShards(init: std.process.Init, raw: bool) !void {
    const target_events_per_second: u64 = 2_000_000;
    const digests = try assertFourShardIsolation();
    const single = try runMarketBenchmark(
        init.io,
        "single-shard-reference",
        benchmark_samples,
        1,
    );

    var ready = std.atomic.Value(u8).init(0);
    var start = std.atomic.Value(bool).init(false);
    const workers = try init.gpa.alloc(FourShardWorker, 4);
    defer init.gpa.free(workers);
    const queues = try init.gpa.alloc(SpscQueue, 4);
    defer init.gpa.free(queues);
    for (queues) |*queue| queue.* = .{};
    var threads: [4]std.Thread = undefined;
    var spawned: usize = 0;
    errdefer {
        start.store(true, .release);
        for (threads[0..spawned]) |thread| thread.join();
    }
    for (workers, 0..) |*worker, index| {
        worker.* = .{
            .io = init.io,
            .queue = &queues[index],
            .ready = &ready,
            .start = &start,
        };
        threads[index] = try std.Thread.spawn(
            .{ .stack_size = 2 * 1024 * 1024 },
            FourShardWorker.run,
            .{worker},
        );
        spawned += 1;
    }
    while (ready.load(.acquire) != 4) std.Thread.yield() catch {};
    for (workers) |*worker| if (worker.failure) |err| return err;

    const started_ns = nowNs(init.io);
    start.store(true, .release);
    var source_sequences: [4]u64 = @splat(101);
    var routed_events: u64 = 0;
    var producer_late_max_ns: u64 = 0;
    while (routed_events < 4 * benchmark_samples) : (routed_events += 1) {
        const scheduled_ns = started_ns +
            @divFloor(routed_events * std.time.ns_per_s, target_events_per_second);
        var actual_ns = nowNs(init.io);
        while (actual_ns < scheduled_ns) {
            std.atomic.spinLoopHint();
            actual_ns = nowNs(init.io);
        }
        producer_late_max_ns = @max(producer_late_max_ns, actual_ns - scheduled_ns);
        const target: usize = @intCast(routed_events % 4);
        const previous = source_sequences[target];
        source_sequences[target] += 1;
        const work: MarketBenchmarkWork = .{
            .input = deltaAt(
                15 + routed_events,
                previous,
                source_sequences[target],
                49_850_000_000 + @as(i64, @intCast(routed_events % 10)),
            ),
            .enqueued_ns = actual_ns,
        };
        while (!queues[target].push(work)) std.Thread.yield() catch {};
    }
    for (threads) |thread| thread.join();
    spawned = 0;
    const elapsed_ns = nowNs(init.io) - started_ns;

    var merged: LatencyHistogram = .{};
    var total_events: u64 = 0;
    for (workers) |*worker| {
        if (worker.failure) |err| return err;
        const result = worker.result orelse return error.MissingShardBenchmarkResult;
        merged.merge(&result.histogram);
        total_events += result.telemetry.events;
    }
    const aggregate_throughput = @divFloor(
        total_events * std.time.ns_per_s,
        elapsed_ns,
    );
    const single_p99 = try single.histogram.percentile(99, 100);
    const merged_p99 = try merged.percentile(99, 100);
    const single_throughput = @divFloor(
        single.telemetry.events * std.time.ns_per_s,
        single.elapsed_ns,
    );
    const owned_bytes_per_shard = @sizeOf(TradingShard) +
        @sizeOf(journal.Journal) +
        @sizeOf(SpscQueue) +
        @sizeOf(LatencyHistogram) +
        @sizeOf(BenchmarkTelemetry);
    var queue_full_observations: u64 = 0;
    for (queues) |*queue|
        queue_full_observations += queue.full_observations.load(.acquire);

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout.interface;
    try out.print(
        "four_shard_qualification: zig={s} mode={s} os={s} shards=4 samples_per_shard={d} shared_router=1 execution_gateway_scope=shared_periphery risk_allocator_scope=shared_periphery correctness=continuous network=excluded\n",
        .{
            builtin.zig_version_string,
            @tagName(builtin.mode),
            @tagName(builtin.os.tag),
            benchmark_samples,
        },
    );
    for (digests, 0..) |digest, index| {
        const digest_hex = std.fmt.bytesToHex(digest, .lower);
        try out.print(
            "shard={d} decision_domain={d} replay=equivalent digest={s}\n",
            .{ index, index, &digest_hex },
        );
    }
    try out.print(
        "isolation=ok targeted_fanout=ok stalled_shard=0 gap_local=ok queue_saturation_local=ok healthy_shards_ordered=3\n",
        .{},
    );
    try printBenchmarkResult(out, &single, raw);
    for (workers) |*worker|
        try printBenchmarkResult(out, &worker.result.?, raw);
    try out.print(
        "four_shard_merged: samples={d} target_throughput_eps={d} p50_ns={d} p99_ns={d} p999_ns={d} max_ns={d} aggregate_throughput_eps={d} producer_late_max_ns={d} p99_change_bp={d} throughput_change_bp={d} queue_full_observations={d} core_state_bytes={d} journal_bytes={d} queue_bytes={d} histogram_bytes={d} owned_bytes_per_shard={d} owned_bytes_four={d}\n",
        .{
            merged.samples,
            target_events_per_second,
            try merged.percentile(50, 100),
            merged_p99,
            try merged.percentile(999, 1000),
            merged.max_ns,
            aggregate_throughput,
            producer_late_max_ns,
            percentChangeBasisPoints(merged_p99, single_p99),
            percentChangeBasisPoints(aggregate_throughput, single_throughput),
            queue_full_observations,
            @sizeOf(TradingShard),
            @sizeOf(journal.Journal),
            @sizeOf(SpscQueue),
            @sizeOf(LatencyHistogram),
            owned_bytes_per_shard,
            owned_bytes_per_shard * 4,
        },
    );
    try out.flush();
}

/// Temporary benchmark dispatch seam while benchmark orchestration is extracted.
pub fn runBenchmark(init: std.process.Init, four_shards: bool, raw: bool) !void {
    return if (four_shards) benchmarkFourShards(init, raw) else benchmark(init, raw);
}

test "four shards replay and isolate overload" {
    _ = try assertFourShardIsolation();
}
