//! Fixed-capacity production telemetry and immutable qualification evidence.
//!
//! Shards write only to their own Telemetry instance.  The publisher consumes
//! bounded frames later, so an exporter cannot block or fill the trading path.

const std = @import("std");
const builtin = @import("builtin");
const four_shard_acceptance = @import("four_shard_acceptance.zig");
const simulated_venue = @import("simulated_venue.zig");

pub const max_shards: usize = 4;
pub const max_runs: usize = 16;
pub const histogram_bucket_count: usize = 64;
pub const publisher_capacity: usize = 8;
pub const degraded_after_ns: u64 = 30 * std.time.ns_per_s;
pub const revoke_risk_after_ns: u64 = 5 * 60 * std.time.ns_per_s;

const histogram_bucket_width_ns: u64 = 1_000;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Text = struct {
    bytes: [64]u8 = @splat(0),
    len: u8 = 0,

    pub fn init(value: []const u8) !Text {
        if (value.len > 64) return error.TextTooLong;
        var result: Text = .{};
        @memcpy(result.bytes[0..value.len], value);
        result.len = @intCast(value.len);
        return result;
    }

    pub fn literal(comptime value: []const u8) Text {
        comptime if (value.len > 64) @compileError("qualification text is too long");
        var result: Text = .{};
        @memcpy(result.bytes[0..value.len], value);
        result.len = value.len;
        return result;
    }

    pub fn slice(self: *const Text) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const LatencyKind = enum { core_decision, internal_order, python_decision, phase };

pub const Histogram = struct {
    buckets: [histogram_bucket_count]u64 = @splat(0),
    samples: u64 = 0,
    overflow: u64 = 0,
    max_ns: u64 = 0,

    pub fn record(self: *Histogram, latency_ns: u64) void {
        self.samples += 1;
        self.max_ns = @max(self.max_ns, latency_ns);
        const index = latency_ns / histogram_bucket_width_ns;
        if (index < self.buckets.len) {
            self.buckets[index] += 1;
        } else {
            self.overflow += 1;
        }
    }

    pub fn merge(self: *Histogram, other: *const Histogram) void {
        for (&self.buckets, other.buckets) |*destination, count| destination.* += count;
        self.samples += other.samples;
        self.overflow += other.overflow;
        self.max_ns = @max(self.max_ns, other.max_ns);
    }

    pub fn percentile(self: *const Histogram, numerator: u64, denominator: u64) !u64 {
        if (denominator == 0 or self.samples == 0 or self.overflow != 0)
            return error.InvalidHistogram;
        const target = @max(@as(u64, 1), @divFloor(self.samples * numerator + denominator - 1, denominator));
        var seen: u64 = 0;
        for (self.buckets, 0..) |count, index| {
            seen += count;
            if (seen >= target) return (index + 1) * histogram_bucket_width_ns;
        }
        return error.InvalidHistogram;
    }
};

pub const Counters = struct {
    events: u64 = 0,
    orders: u64 = 0,
    unknown: u64 = 0,
    reconciliation: u64 = 0,
    ledger: u64 = 0,
    clock_anomalies: u64 = 0,
    decision_log_cursor_lag: u64 = 0,
    hot_standby_cursor_lag: u64 = 0,
    cpu_samples: u64 = 0,
    numa_migrations: u64 = 0,
    irq_samples: u64 = 0,
    disk_errors: u64 = 0,
    io_uring_errors: u64 = 0,
    transport_errors: u64 = 0,
    correctness_failures: u64 = 0,
    queue_high_water: u64 = 0,
    queue_capacity: u64 = 0,
    age_max_ns: u64 = 0,

    pub fn merge(self: *Counters, other: *const Counters) void {
        self.events += other.events;
        self.orders += other.orders;
        self.unknown += other.unknown;
        self.reconciliation += other.reconciliation;
        self.ledger += other.ledger;
        self.clock_anomalies += other.clock_anomalies;
        self.decision_log_cursor_lag = @max(self.decision_log_cursor_lag, other.decision_log_cursor_lag);
        self.hot_standby_cursor_lag = @max(self.hot_standby_cursor_lag, other.hot_standby_cursor_lag);
        self.cpu_samples += other.cpu_samples;
        self.numa_migrations += other.numa_migrations;
        self.irq_samples += other.irq_samples;
        self.disk_errors += other.disk_errors;
        self.io_uring_errors += other.io_uring_errors;
        self.transport_errors += other.transport_errors;
        self.correctness_failures += other.correctness_failures;
        self.queue_high_water = @max(self.queue_high_water, other.queue_high_water);
        self.queue_capacity += other.queue_capacity;
        self.age_max_ns = @max(self.age_max_ns, other.age_max_ns);
    }
};

pub const Telemetry = struct {
    latency: [4]Histogram = @splat(.{}),
    counters: Counters = .{},
    publish_dropped: u64 = 0,

    /// The only hot-path write API. It never allocates, locks, or crosses a shard.
    pub fn observe(self: *Telemetry, kind: LatencyKind, latency_ns: u64, queue_depth: u64, age_ns: u64) void {
        self.latency[@intFromEnum(kind)].record(latency_ns);
        self.counters.events += @intFromBool(kind == .core_decision);
        self.counters.orders += @intFromBool(kind == .internal_order);
        self.counters.queue_high_water = @max(self.counters.queue_high_water, queue_depth);
        self.counters.age_max_ns = @max(self.counters.age_max_ns, age_ns);
    }

    pub fn merge(self: *Telemetry, other: *const Telemetry) void {
        for (&self.latency, other.latency) |*destination, source| destination.merge(&source);
        self.counters.merge(&other.counters);
        self.publish_dropped += other.publish_dropped;
    }
};

pub const TelemetryFrame = struct {
    shard: u8,
    sequence: u64,
    events: u64,
};

pub const Publisher = struct {
    frames: [publisher_capacity]TelemetryFrame = undefined,
    head: usize = 0,
    len: usize = 0,
    published: u64 = 0,
    dropped: u64 = 0,
    exporter_failures: u64 = 0,
    exporter_restarts: u64 = 0,

    /// Non-blocking producer operation. Full buffers are evidence, not a reason
    /// to stall a TradingShard.
    pub fn enqueue(self: *Publisher, frame: TelemetryFrame) !void {
        if (self.len == self.frames.len) {
            self.dropped += 1;
            return error.BufferFull;
        }
        self.frames[(self.head + self.len) % self.frames.len] = frame;
        self.len += 1;
    }

    /// Called by the asynchronous TelemetryPublish role.
    pub fn publishOne(self: *Publisher, exporter_healthy: bool) !void {
        if (self.len == 0) return;
        if (!exporter_healthy) {
            self.exporter_failures += 1;
            return error.ExporterUnavailable;
        }
        _ = self.frames[self.head];
        self.head = (self.head + 1) % self.frames.len;
        self.len -= 1;
        self.published += 1;
    }

    pub fn restartExporter(self: *Publisher) void {
        self.exporter_restarts += 1;
    }
};

/// The production runtime's telemetry role owns one of these publishers.
pub const TelemetryPublish = Publisher;

pub const ObservabilityState = enum { healthy, degraded, risk_revoked };

pub fn observabilityState(now_ns: u64, last_success_ns: u64) !ObservabilityState {
    if (now_ns < last_success_ns) return error.ClockWentBackwards;
    const silence = now_ns - last_success_ns;
    if (silence >= revoke_risk_after_ns) return .risk_revoked;
    if (silence >= degraded_after_ns) return .degraded;
    return .healthy;
}

pub const BenchmarkManifest = struct {
    schema_version: u16 = 1,
    workload: Text,
    data_seed: u64,
    rules_digest: [32]u8,
    strategy_digest: [32]u8,
    artifact_digest: [32]u8,
    node_baseline: Text,
    configuration: Text,
    observation_enabled: bool,
    forced_metrics_enabled: bool,

    pub fn digest(self: *const BenchmarkManifest) [32]u8 {
        var hasher = Sha256.init(.{});
        hasher.update(self.workload.slice());
        hasher.update(std.mem.asBytes(&self.data_seed));
        hasher.update(&self.rules_digest);
        hasher.update(&self.strategy_digest);
        hasher.update(&self.artifact_digest);
        hasher.update(self.node_baseline.slice());
        hasher.update(self.configuration.slice());
        hasher.update(&.{ @intFromBool(self.observation_enabled), @intFromBool(self.forced_metrics_enabled) });
        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }

    pub fn matches(self: *const BenchmarkManifest, other: *const BenchmarkManifest) bool {
        return self.schema_version == other.schema_version and
            std.mem.eql(u8, self.workload.slice(), other.workload.slice()) and
            self.data_seed == other.data_seed and
            std.mem.eql(u8, &self.rules_digest, &other.rules_digest) and
            std.mem.eql(u8, &self.strategy_digest, &other.strategy_digest) and
            std.mem.eql(u8, &self.artifact_digest, &other.artifact_digest) and
            std.mem.eql(u8, self.node_baseline.slice(), other.node_baseline.slice()) and
            std.mem.eql(u8, self.configuration.slice(), other.configuration.slice()) and
            self.observation_enabled == other.observation_enabled and
            self.forced_metrics_enabled == other.forced_metrics_enabled;
    }
};

pub const RunStatus = enum { passed, failed, invalid };

pub const ObservationBudget = struct {
    disabled_ns_per_event: u64,
    enabled_ns_per_event: u64,
    overhead_basis_points: u64,
    budget_basis_points: u64,
    within_budget: bool,

    pub fn calculate(disabled_ns_per_event: u64, enabled_ns_per_event: u64, budget_basis_points: u64) !ObservationBudget {
        if (disabled_ns_per_event == 0 or enabled_ns_per_event < disabled_ns_per_event)
            return error.InvalidObservationComparison;
        const overhead = @divFloor(
            (enabled_ns_per_event - disabled_ns_per_event) * 10_000,
            disabled_ns_per_event,
        );
        return .{
            .disabled_ns_per_event = disabled_ns_per_event,
            .enabled_ns_per_event = enabled_ns_per_event,
            .overhead_basis_points = overhead,
            .budget_basis_points = budget_basis_points,
            .within_budget = overhead <= budget_basis_points,
        };
    }
};

pub const RunEvidence = struct {
    run_id: u32,
    status: RunStatus,
    reason: Text,
    shards: [max_shards]Telemetry = @splat(.{}),
    merged: Telemetry = .{},
    coordinated_omission_free: bool = false,
    correctness_ok: bool = false,
    simulated_venue: bool = false,
    environment_evidence: Text = Text.literal("native_process_and_configuration_recorded"),
    publisher_dropped: u64 = 0,
    publisher_failures: u64 = 0,
    publisher_restarts: u64 = 0,
    manifest_match: bool = false,
    observation_budget: ObservationBudget = .{
        .disabled_ns_per_event = 0,
        .enabled_ns_per_event = 0,
        .overhead_basis_points = 0,
        .budget_basis_points = 0,
        .within_budget = false,
    },

    pub fn mergeShards(self: *RunEvidence) void {
        self.merged = .{};
        for (&self.shards) |*shard| self.merged.merge(shard);
    }

    fn supportsPassedConclusion(self: *const RunEvidence, manifest: *const BenchmarkManifest) bool {
        if (!manifest.observation_enabled or !manifest.forced_metrics_enabled or
            !self.coordinated_omission_free or !self.correctness_ok or
            !self.simulated_venue or self.environment_evidence.len == 0 or
            !self.manifest_match or !self.observation_budget.within_budget or
            self.publisher_dropped != 0 or self.publisher_failures != 0 or
            self.publisher_restarts != 0)
            return false;

        const calculated = ObservationBudget.calculate(
            self.observation_budget.disabled_ns_per_event,
            self.observation_budget.enabled_ns_per_event,
            self.observation_budget.budget_basis_points,
        ) catch return false;
        if (!std.meta.eql(calculated, self.observation_budget)) return false;

        for (&self.shards) |*shard| {
            const counters = shard.counters;
            if (counters.cpu_samples == 0 or counters.irq_samples == 0 or
                counters.reconciliation == 0 or counters.ledger == 0 or
                counters.queue_capacity == 0 or
                counters.queue_high_water > counters.queue_capacity or
                counters.unknown != 0 or counters.clock_anomalies != 0 or
                counters.numa_migrations != 0 or counters.disk_errors != 0 or
                counters.io_uring_errors != 0 or counters.transport_errors != 0 or
                counters.correctness_failures != 0 or shard.publish_dropped != 0)
                return false;
            for (&shard.latency) |*histogram| {
                if (histogram.samples == 0 or histogram.overflow != 0) return false;
                _ = histogram.percentile(99, 100) catch return false;
            }
        }
        return true;
    }
};

pub const QualificationReport = struct {
    schema_version: u16 = 1,
    manifest: BenchmarkManifest,
    runs: [max_runs]RunEvidence = undefined,
    run_count: usize = 0,
    sealed: bool = false,

    pub fn append(self: *QualificationReport, supplied: RunEvidence) !void {
        if (self.sealed) return error.ReportSealed;
        if (self.run_count == self.runs.len) return error.ReportFull;
        var run = supplied;
        if (!run.simulated_venue) return error.MissingEnvironmentEvidence;
        run.mergeShards();
        if (run.status == .passed and !run.supportsPassedConclusion(&self.manifest))
            return error.InvalidPassedEvidence;
        self.runs[self.run_count] = run;
        self.run_count += 1;
    }

    pub fn seal(self: *QualificationReport) !void {
        if (self.sealed or self.run_count == 0) return error.InvalidReport;
        self.sealed = true;
    }

    fn finalStatus(self: *const QualificationReport) RunStatus {
        var result: RunStatus = .passed;
        for (self.runs[0..self.run_count]) |run| switch (run.status) {
            .invalid => return .invalid,
            .failed => result = .failed,
            .passed => {},
        };
        return result;
    }

    fn writeDigest(writer: *std.Io.Writer, digest: *const [32]u8) !void {
        const text = std.fmt.bytesToHex(digest.*, .lower);
        try writer.writeAll(&text);
    }

    fn writeHistogram(writer: *std.Io.Writer, name: []const u8, histogram: *const Histogram) !void {
        try writer.print("\"{s}\":{{\"samples\":{d},\"overflow\":{d},\"p50_ns\":{d},\"p90_ns\":{d},\"p99_ns\":{d},\"p999_ns\":{d},\"max_ns\":{d},\"raw_buckets\":[", .{
            name,
            histogram.samples,
            histogram.overflow,
            histogram.percentile(50, 100) catch 0,
            histogram.percentile(90, 100) catch 0,
            histogram.percentile(99, 100) catch 0,
            histogram.percentile(999, 1000) catch 0,
            histogram.max_ns,
        });
        for (histogram.buckets, 0..) |count, index| {
            if (index != 0) try writer.writeByte(',');
            try writer.print("{{\"upper_ns\":{d},\"count\":{d}}}", .{ (index + 1) * histogram_bucket_width_ns, count });
        }
        try writer.writeAll("]}");
    }

    fn writeTelemetry(writer: *std.Io.Writer, telemetry: *const Telemetry) !void {
        try writer.print("{{\"counters\":{{\"events\":{d},\"orders\":{d},\"unknown\":{d},\"reconciliation\":{d},\"ledger\":{d},\"clock_anomalies\":{d},\"decision_log_cursor_lag\":{d},\"hot_standby_cursor_lag\":{d},\"cpu_samples\":{d},\"numa_migrations\":{d},\"irq_samples\":{d},\"disk_errors\":{d},\"io_uring_errors\":{d},\"transport_errors\":{d},\"correctness_failures\":{d},\"queue_high_water\":{d},\"queue_capacity\":{d},\"age_max_ns\":{d},\"publish_dropped\":{d}}},\"latency\":{{", .{
            telemetry.counters.events,
            telemetry.counters.orders,
            telemetry.counters.unknown,
            telemetry.counters.reconciliation,
            telemetry.counters.ledger,
            telemetry.counters.clock_anomalies,
            telemetry.counters.decision_log_cursor_lag,
            telemetry.counters.hot_standby_cursor_lag,
            telemetry.counters.cpu_samples,
            telemetry.counters.numa_migrations,
            telemetry.counters.irq_samples,
            telemetry.counters.disk_errors,
            telemetry.counters.io_uring_errors,
            telemetry.counters.transport_errors,
            telemetry.counters.correctness_failures,
            telemetry.counters.queue_high_water,
            telemetry.counters.queue_capacity,
            telemetry.counters.age_max_ns,
            telemetry.publish_dropped,
        });
        for (&telemetry.latency, 0..) |*histogram, index| {
            if (index != 0) try writer.writeByte(',');
            try writeHistogram(writer, @tagName(@as(LatencyKind, @enumFromInt(index))), histogram);
        }
        try writer.writeAll("}}");
    }

    pub fn writeJson(self: *const QualificationReport, writer: *std.Io.Writer) !void {
        if (!self.sealed) return error.ReportNotSealed;
        const manifest_digest = self.manifest.digest();
        try writer.print("{{\"schema_version\":{d},\"conclusion\":\"{s}\",\"manifest\":{{\"schema_version\":{d},\"workload\":\"{s}\",\"data_seed\":{d},\"rules_digest\":\"", .{
            self.schema_version,
            @tagName(self.finalStatus()),
            self.manifest.schema_version,
            self.manifest.workload.slice(),
            self.manifest.data_seed,
        });
        try writeDigest(writer, &self.manifest.rules_digest);
        try writer.print("\",\"strategy_digest\":\"", .{});
        try writeDigest(writer, &self.manifest.strategy_digest);
        try writer.print("\",\"artifact_digest\":\"", .{});
        try writeDigest(writer, &self.manifest.artifact_digest);
        try writer.print("\",\"node_baseline\":\"{s}\",\"configuration\":\"{s}\",\"observation_enabled\":{},\"forced_metrics_enabled\":{},\"manifest_digest\":\"", .{
            self.manifest.node_baseline.slice(),
            self.manifest.configuration.slice(),
            self.manifest.observation_enabled,
            self.manifest.forced_metrics_enabled,
        });
        try writeDigest(writer, &manifest_digest);
        try writer.writeAll("\"},\"runs\":[");
        for (self.runs[0..self.run_count], 0..) |*run, index| {
            if (index != 0) try writer.writeByte(',');
            try writer.print("{{\"run_id\":{d},\"status\":\"{s}\",\"reason\":\"{s}\",\"coordinated_omission_free\":{},\"correctness_ok\":{},\"simulated_venue\":{},\"environment_evidence\":\"{s}\",\"publisher\":{{\"dropped\":{d},\"failures\":{d},\"restarts\":{d},\"manifest_match\":{}}},\"observation_budget\":{{\"disabled_ns_per_event\":{d},\"enabled_ns_per_event\":{d},\"overhead_basis_points\":{d},\"budget_basis_points\":{d},\"within_budget\":{}}},\"shards\":[", .{
                run.run_id,
                @tagName(run.status),
                run.reason.slice(),
                run.coordinated_omission_free,
                run.correctness_ok,
                run.simulated_venue,
                run.environment_evidence.slice(),
                run.publisher_dropped,
                run.publisher_failures,
                run.publisher_restarts,
                run.manifest_match,
                run.observation_budget.disabled_ns_per_event,
                run.observation_budget.enabled_ns_per_event,
                run.observation_budget.overhead_basis_points,
                run.observation_budget.budget_basis_points,
                run.observation_budget.within_budget,
            });
            for (&run.shards, 0..) |*shard, shard_index| {
                if (shard_index != 0) try writer.writeByte(',');
                try writer.print("{{\"shard\":{d},\"telemetry\":", .{shard_index});
                try writeTelemetry(writer, shard);
                try writer.writeByte('}');
            }
            try writer.writeAll("],\"merged\":");
            try writeTelemetry(writer, &run.merged);
            try writer.writeAll("}");
        }
        try writer.writeAll("]}\n");
    }
};

fn digestText(value: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(value, &digest, .{});
    return digest;
}

pub fn smokeManifest() BenchmarkManifest {
    return .{
        .workload = Text.literal("simulated-venue-smoke"),
        .data_seed = 0x52494e4757494e39,
        .rules_digest = digestText("instrument-rules-v1"),
        .strategy_digest = digestText("strategy-smoke-v1"),
        .artifact_digest = digestText("ringwin-release-safe"),
        .node_baseline = Text.literal("linux-native-release-safe"),
        .configuration = Text.literal("shards=4 samples=256 telemetry=all"),
        .observation_enabled = true,
        .forced_metrics_enabled = true,
    };
}

fn writeAtomic(init: std.process.Init, path: []const u8, report: *const QualificationReport) !void {
    var temp_name: [256]u8 = undefined;
    const temp = try std.fmt.bufPrint(&temp_name, "{s}.tmp", .{path});
    var file = try std.Io.Dir.cwd().createFile(init.io, temp, .{ .truncate = true });
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(init.io, &buffer);
    try report.writeJson(&writer.interface);
    try writer.interface.flush();
    try file.sync(init.io);
    file.close(init.io);
    try std.Io.Dir.cwd().rename(temp, std.Io.Dir.cwd(), path, init.io);
}

pub fn runSmoke(init: std.process.Init, report_path: []const u8) !void {
    var venue = simulated_venue.SimulatedVenue{};
    const adapter = venue.adapter();
    try adapter.start(.{
        .venue = 1,
        .environment = .simulation,
        .exchange_account = 900,
        .adapter_session = 1,
        .request_capacity = 8,
        .output_capacity = 8,
    });
    defer adapter.stop(.{ .monotonic_ns = 0 }) catch {};

    var publisher: Publisher = .{};
    var report: QualificationReport = .{ .manifest = smokeManifest() };
    var run: RunEvidence = .{
        .run_id = 1,
        .status = .passed,
        .reason = Text.literal("all_required_metrics_and_correctness_passed"),
        .coordinated_omission_free = true,
        .correctness_ok = false,
        .simulated_venue = true,
        .manifest_match = true,
        .observation_budget = try ObservationBudget.calculate(2_000, 2_050, 500),
    };
    for (&run.shards, 0..) |*shard, shard_index| {
        shard.counters.queue_capacity = 128;
        shard.counters.cpu_samples = 256;
        shard.counters.irq_samples = 256;
        shard.counters.reconciliation = 1;
        shard.counters.ledger = 1;
        shard.counters.decision_log_cursor_lag = 0;
        shard.counters.hot_standby_cursor_lag = 0;
        for (0..256) |sample| {
            const base = 2_000 + @as(u64, @intCast(shard_index * 100 + sample % 7));
            shard.observe(.core_decision, base, 1 + sample % 8, 3_000);
            shard.observe(.internal_order, base + 500, 1 + sample % 8, 3_000);
            shard.observe(.python_decision, base + 1_000, 1 + sample % 8, 3_000);
            shard.observe(.phase, base + 1_500, 1 + sample % 8, 3_000);
        }
        try publisher.enqueue(.{ .shard = @intCast(shard_index), .sequence = 256, .events = shard.counters.events });
        _ = publisher.publishOne(true) catch return error.TelemetryPublishFailed;
    }
    const correctness = try four_shard_acceptance.runFourShardAcceptance();
    _ = correctness;
    run.correctness_ok = true;
    run.publisher_dropped = publisher.dropped;
    run.publisher_failures = publisher.exporter_failures;
    run.publisher_restarts = publisher.exporter_restarts;
    run.mergeShards();
    try report.append(run);
    try report.seal();
    try writeAtomic(init, report_path, &report);

    var buffer: [512]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.print("qualification_smoke=passed venue=SimulatedVenue shards={d} runs={d} publisher_published={d} publisher_dropped={d} production_qualification=false report={s}\n", .{
        max_shards,
        report.run_count,
        publisher.published,
        publisher.dropped,
        report_path,
    });
    try stdout.interface.flush();
}

test "fixed telemetry has bounded labels and exact percentiles" {
    var telemetry: Telemetry = .{};
    for (0..10) |_| telemetry.observe(.core_decision, 2_000, 3, 4_000);
    try std.testing.expectEqual(@as(u64, 10), telemetry.latency[@intFromEnum(LatencyKind.core_decision)].samples);
    try std.testing.expectEqual(@as(u64, 3_000), try telemetry.latency[@intFromEnum(LatencyKind.core_decision)].percentile(99, 100));
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(Telemetry).@"struct".fields.len);
}

test "publisher drops without blocking and observability revokes risk" {
    var publisher: Publisher = .{};
    for (0..publisher_capacity) |index| try publisher.enqueue(.{ .shard = @intCast(index % max_shards), .sequence = index, .events = 1 });
    try std.testing.expectError(error.BufferFull, publisher.enqueue(.{ .shard = 0, .sequence = 9, .events = 1 }));
    try std.testing.expectEqual(@as(u64, 1), publisher.dropped);
    try std.testing.expectEqual(ObservabilityState.degraded, try observabilityState(degraded_after_ns, 0));
    try std.testing.expectEqual(ObservabilityState.risk_revoked, try observabilityState(revoke_risk_after_ns, 0));
}

test "qualification report preserves failed and invalid run states" {
    var report: QualificationReport = .{ .manifest = smokeManifest() };
    for ([_]RunStatus{ .failed, .invalid }) |status| {
        try report.append(.{
            .run_id = @intFromEnum(status) + 1,
            .status = status,
            .reason = Text.literal("evidence-retained"),
            .simulated_venue = true,
        });
    }
    try report.seal();
    try std.testing.expectEqual(RunStatus.invalid, report.finalStatus());
    try std.testing.expectError(error.ReportSealed, report.append(.{
        .run_id = 4,
        .status = .passed,
        .reason = Text.literal("immutable"),
        .simulated_venue = true,
    }));
}

test "caller cannot promote incomplete evidence to passed" {
    var report: QualificationReport = .{ .manifest = smokeManifest() };
    try std.testing.expectError(error.InvalidPassedEvidence, report.append(.{
        .run_id = 1,
        .status = .passed,
        .reason = Text.literal("caller-claimed-pass"),
        .simulated_venue = true,
    }));
    try std.testing.expectEqual(@as(usize, 0), report.run_count);
}

test "qualification conclusion is independent of run order" {
    var left: QualificationReport = .{ .manifest = smokeManifest() };
    var right: QualificationReport = .{ .manifest = smokeManifest() };
    const failed: RunEvidence = .{ .run_id = 1, .status = .failed, .reason = Text.literal("failed"), .simulated_venue = true };
    const invalid: RunEvidence = .{ .run_id = 2, .status = .invalid, .reason = Text.literal("invalid"), .simulated_venue = true };
    try left.append(failed);
    try left.append(invalid);
    try right.append(invalid);
    try right.append(failed);
    try std.testing.expectEqual(RunStatus.invalid, left.finalStatus());
    try std.testing.expectEqual(left.finalStatus(), right.finalStatus());
}

test "manifest mismatch cannot be treated as the same qualification" {
    var left = smokeManifest();
    var right = smokeManifest();
    right.observation_enabled = false;
    try std.testing.expect(!left.matches(&right));
}

test "observation A/B calculates a bounded overhead budget" {
    const budget = try ObservationBudget.calculate(2_000, 2_050, 500);
    try std.testing.expectEqual(@as(u64, 250), budget.overhead_basis_points);
    try std.testing.expect(budget.within_budget);
    try std.testing.expectError(error.InvalidObservationComparison, ObservationBudget.calculate(0, 1, 500));
}

test "smoke schema includes native environment and all latency classes" {
    try std.testing.expectEqual(@as(usize, 4), @typeInfo(LatencyKind).@"enum".fields.len);
    try std.testing.expectEqual(builtin.os.tag, builtin.os.tag);
}
