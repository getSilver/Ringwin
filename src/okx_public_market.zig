//! Fail-closed OKX public-data normalization boundary for the fixed first wave.
//! The libcurl transport owner passes complete REST/WS JSON messages here. Every
//! accepted frame is appended through RawSink before parsing or state mutation.
//! Local subscription resets return a health payload without fabricating raw evidence.

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const max_raw_frame_bytes = 1024 * 1024;
pub const max_book_levels = 400;
pub const max_events_per_ingress = 2;

pub const Instrument = enum(u8) {
    btc_usdt_spot,
    btc_usdt_swap,
};

pub const Decimal = struct {
    coefficient: i128,
    scale: u8,

    pub fn parse(text: []const u8) !Decimal {
        if (text.len == 0) return error.InvalidDecimal;
        var negative = false;
        var cursor: usize = 0;
        if (text[0] == '-') {
            negative = true;
            cursor = 1;
        } else if (text[0] == '+') {
            cursor = 1;
        }
        if (cursor == text.len) return error.InvalidDecimal;

        var coefficient: i128 = 0;
        var scale: u8 = 0;
        var saw_digit = false;
        var saw_dot = false;
        while (cursor < text.len) : (cursor += 1) {
            const byte = text[cursor];
            if (byte == '.') {
                if (saw_dot) return error.InvalidDecimal;
                saw_dot = true;
                continue;
            }
            if (byte < '0' or byte > '9') return error.InvalidDecimal;
            saw_digit = true;
            coefficient = std.math.mul(i128, coefficient, 10) catch
                return error.DecimalOverflow;
            coefficient = std.math.add(i128, coefficient, byte - '0') catch
                return error.DecimalOverflow;
            if (saw_dot) scale = std.math.add(u8, scale, 1) catch
                return error.DecimalOverflow;
        }
        if (!saw_digit) return error.InvalidDecimal;
        if (negative) coefficient = -coefficient;
        while (scale > 0 and @mod(coefficient, 10) == 0) {
            coefficient = @divTrunc(coefficient, 10);
            scale -= 1;
        }
        return .{ .coefficient = coefficient, .scale = scale };
    }
};

pub const Times = struct {
    receive_time_utc_ns: u64,
    monotonic_time_ns: u64,
    wall_time_utc_ns: u64,
};

pub const RawIngressRecord = struct {
    source_session: u64,
    receive_time_utc_ns: u64,
    monotonic_time_ns: u64,
    wall_time_utc_ns: u64,
    byte_len: u32,
    sha256: [Sha256.digest_length]u8,
};

pub const RawEvidenceRef = struct {
    stream_sequence: u64,
    sha256: [Sha256.digest_length]u8,
};

pub const RawSinkError = error{ Unavailable, Backpressure };

pub const RawSink = struct {
    ptr: *anyopaque,
    append_fn: *const fn (*anyopaque, RawIngressRecord, []const u8) RawSinkError!u64,

    pub fn append(
        self: RawSink,
        record: RawIngressRecord,
        bytes: []const u8,
    ) RawSinkError!RawEvidenceRef {
        const sequence = try self.append_fn(self.ptr, record, bytes);
        return .{ .stream_sequence = sequence, .sha256 = record.sha256 };
    }
};

pub const EventEnvelope = struct {
    source_time_utc_ns: ?u64,
    receive_time_utc_ns: u64,
    monotonic_time_ns: u64,
    wall_time_utc_ns: u64,
    raw_evidence: RawEvidenceRef,
    source_fact_identity: [Sha256.digest_length]u8,
};

pub const InstrumentState = enum(u8) { live, @"suspend", preopen, @"test", post_only };
pub const RuleType = enum(u8) { normal, pre_market };
pub const ContractType = enum(u8) { linear, inverse };

pub const InstrumentDefinitionObserved = struct {
    instrument: Instrument,
    state: InstrumentState,
    rule_type: RuleType,
    tick_size: Decimal,
    lot_size: Decimal,
    minimum_size: Decimal,
    maximum_limit_size: ?Decimal,
    maximum_market_size: ?Decimal,
    maximum_limit_notional: ?Decimal,
    maximum_market_notional: ?Decimal,
    contract_type: ?ContractType,
    contract_value: ?Decimal,
    contract_value_currency_btc: bool,
    settlement_currency_usdt: bool,
    trade_quote_currency_usdt: bool,
    upcoming_changes: UpcomingChanges,
};

pub const ShortText = struct {
    bytes: [256]u8 = undefined,
    len: u16,

    pub fn init(text: []const u8) !ShortText {
        if (text.len > 256) return error.InvalidField;
        var result: ShortText = .{ .len = @intCast(text.len) };
        @memcpy(result.bytes[0..text.len], text);
        return result;
    }

    pub fn slice(self: *const ShortText) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const UpcomingChange = struct {
    parameter: ShortText,
    new_value: ShortText,
    effective_time_utc_ns: u64,
};

pub const UpcomingChanges = struct {
    items: [8]UpcomingChange = undefined,
    len: u8 = 0,

    pub fn slice(self: *const UpcomingChanges) []const UpcomingChange {
        return self.items[0..self.len];
    }
};

pub const BookLevel = struct {
    price: Decimal,
    quantity: Decimal,
    order_count: u32,
};

pub const BookSide = struct {
    levels: [max_book_levels]BookLevel = undefined,
    len: u16 = 0,

    pub fn slice(self: *const BookSide) []const BookLevel {
        return self.levels[0..self.len];
    }
};

pub const L2BookSnapshot = struct {
    instrument: Instrument,
    source_sequence: i64,
    bids: BookSide,
    asks: BookSide,
};

pub const L2BookDelta = struct {
    instrument: Instrument,
    previous_source_sequence: i64,
    source_sequence: i64,
    bids: BookSide,
    asks: BookSide,
};

pub const ReferencePriceKind = enum(u8) { mark, index };

pub const ReferencePrice = struct {
    instrument: Instrument,
    kind: ReferencePriceKind,
    price: Decimal,
};

pub const SettlementState = enum(u8) { processing, settled };

pub const FundingRatePublished = struct {
    instrument: Instrument,
    predicted_rate: Decimal,
    funding_time_utc_ns: u64,
    next_funding_time_utc_ns: u64,
    settled_rate: ?Decimal,
    settlement_state: ?SettlementState,
};

pub const MarketDataHealth = enum(u8) { awaiting_snapshot, healthy, gap };
pub const GapReason = enum(u8) {
    source_sequence_gap,
    source_sequence_regression,
    conflicting_duplicate,
    unknown_book_action,
    malformed_book_frame,
    resubscribed,
};

pub const MarketDataHealthChanged = struct {
    instrument: Instrument,
    health: MarketDataHealth,
    reason: ?GapReason,
    last_good_source_sequence: ?i64,
    observed_previous_source_sequence: ?i64,
    observed_source_sequence: ?i64,
};

pub const EventPayload = union(enum) {
    instrument_definition_observed: InstrumentDefinitionObserved,
    l2_book_snapshot: L2BookSnapshot,
    l2_book_delta: L2BookDelta,
    reference_price: ReferencePrice,
    funding_rate_published: FundingRatePublished,
    market_data_health_changed: MarketDataHealthChanged,
};

pub const CanonicalEvent = struct {
    envelope: EventEnvelope,
    payload: EventPayload,
};

pub const RejectReason = enum(u8) {
    malformed_json,
    malformed_envelope,
    unsupported_channel,
    unsupported_instrument,
    invalid_field,
    too_many_events,
};

pub const IngressBatch = struct {
    raw_evidence: RawEvidenceRef,
    events: [max_events_per_ingress]CanonicalEvent = undefined,
    event_count: u8 = 0,
    rejection: ?RejectReason = null,

    pub fn eventSlice(self: *const IngressBatch) []const CanonicalEvent {
        return self.events[0..self.event_count];
    }

    fn append(self: *IngressBatch, event: CanonicalEvent) !void {
        if (self.event_count == self.events.len) return error.TooManyEvents;
        self.events[self.event_count] = event;
        self.event_count += 1;
    }
};

const BookState = struct {
    health: MarketDataHealth = .awaiting_snapshot,
    last_sequence: ?i64 = null,
    last_content_hash: ?[Sha256.digest_length]u8 = null,
};

const FeedMemory = struct {
    identity: ?[Sha256.digest_length]u8 = null,
    content_hash: ?[Sha256.digest_length]u8 = null,
};

pub const Decoder = struct {
    spot_book: BookState = .{},
    swap_book: BookState = .{},
    rules_observed: [2]bool = .{ false, false },
    instrument_memory: [2]FeedMemory = .{ .{}, .{} },
    mark_memory: FeedMemory = .{},
    index_memory: FeedMemory = .{},
    funding_memory: FeedMemory = .{},

    pub fn beginSubscription(self: *Decoder, instrument: Instrument) MarketDataHealthChanged {
        const state = self.bookState(instrument);
        const last = state.last_sequence;
        state.health = .awaiting_snapshot;
        state.last_sequence = null;
        state.last_content_hash = null;
        return .{
            .instrument = instrument,
            .health = .awaiting_snapshot,
            .reason = .resubscribed,
            .last_good_source_sequence = last,
            .observed_previous_source_sequence = null,
            .observed_source_sequence = null,
        };
    }

    pub fn isBookHealthy(self: *const Decoder, instrument: Instrument) bool {
        return self.bookStateConst(instrument).health == .healthy;
    }

    pub fn isPublicMarketReady(self: *const Decoder, instrument: Instrument) bool {
        return self.rules_observed[@intFromEnum(instrument)] and self.isBookHealthy(instrument);
    }

    pub fn ingest(
        self: *Decoder,
        gpa: std.mem.Allocator,
        raw_sink: RawSink,
        source_session: u64,
        times: Times,
        raw: []const u8,
    ) (RawSinkError || error{ OutOfMemory, FrameTooLarge })!IngressBatch {
        if (raw.len > max_raw_frame_bytes or raw.len > std.math.maxInt(u32)) {
            return error.FrameTooLarge;
        }

        var raw_hash: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(raw, &raw_hash, .{});
        const raw_evidence = try raw_sink.append(.{
            .source_session = source_session,
            .receive_time_utc_ns = times.receive_time_utc_ns,
            .monotonic_time_ns = times.monotonic_time_ns,
            .wall_time_utc_ns = times.wall_time_utc_ns,
            .byte_len = @intCast(raw.len),
            .sha256 = raw_hash,
        }, raw);

        var batch: IngressBatch = .{ .raw_evidence = raw_evidence };
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, raw, .{}) catch {
            batch.rejection = .malformed_json;
            return batch;
        };
        defer parsed.deinit();

        self.decodeValue(parsed.value, times, raw_evidence, &batch) catch |err| {
            batch.rejection = switch (err) {
                error.UnsupportedChannel => .unsupported_channel,
                error.UnsupportedInstrument => .unsupported_instrument,
                error.TooManyEvents => .too_many_events,
                error.MalformedEnvelope => .malformed_envelope,
                else => .invalid_field,
            };
        };
        return batch;
    }

    fn decodeValue(
        self: *Decoder,
        root: std.json.Value,
        times: Times,
        raw_evidence: RawEvidenceRef,
        batch: *IngressBatch,
    ) !void {
        const root_object = try asObject(root);
        const arg = root_object.get("arg") orelse
            return self.decodeRest(root_object, times, raw_evidence, batch);
        const arg_object = try asObject(arg);
        const channel = try stringField(arg_object, "channel");
        const data = try asArray(try objectField(root_object, "data"));
        if (data.items.len != 1) return error.InvalidField;
        const datum = try asObject(data.items[0]);

        if (std.mem.eql(u8, channel, "books")) {
            const instrument = try parseInstrument(try stringField(arg_object, "instId"));
            const action = try stringField(root_object, "action");
            return self.decodeBook(instrument, action, datum, times, raw_evidence, batch) catch |err| {
                if (err == error.TooManyEvents) return err;
                const state = self.bookState(instrument);
                const last = state.last_sequence;
                state.health = .gap;
                state.last_content_hash = null;
                try batch.append(healthEvent(
                    times,
                    null,
                    raw_evidence,
                    instrument,
                    .gap,
                    .malformed_book_frame,
                    last,
                    null,
                    null,
                ));
                return err;
            };
        }
        if (std.mem.eql(u8, channel, "instruments")) {
            const instrument = parseInstrument(stringField(datum, "instId") catch
                return error.InvalidField) catch return error.UnsupportedInstrument;
            return self.decodeInstrument(instrument, datum, times, raw_evidence, batch) catch |err| {
                self.rules_observed[@intFromEnum(instrument)] = false;
                return err;
            };
        }
        if (std.mem.eql(u8, channel, "mark-price"))
            return self.decodeReference(.mark, .btc_usdt_swap, datum, times, raw_evidence, batch);
        if (std.mem.eql(u8, channel, "index-tickers"))
            return self.decodeReference(.index, .btc_usdt_swap, datum, times, raw_evidence, batch);
        if (std.mem.eql(u8, channel, "funding-rate"))
            return self.decodeFunding(datum, times, raw_evidence, batch);
        return error.UnsupportedChannel;
    }

    fn decodeRest(
        self: *Decoder,
        root: std.json.ObjectMap,
        times: Times,
        raw_evidence: RawEvidenceRef,
        batch: *IngressBatch,
    ) !void {
        if (!std.mem.eql(u8, try stringField(root, "code"), "0"))
            return error.InvalidField;
        const data = try asArray(try objectField(root, "data"));
        if (data.items.len != 1) return error.InvalidField;
        const datum = try asObject(data.items[0]);
        if (datum.get("tickSz") != null) {
            const instrument = try parseInstrument(try stringField(datum, "instId"));
            return self.decodeInstrument(instrument, datum, times, raw_evidence, batch) catch |err| {
                self.rules_observed[@intFromEnum(instrument)] = false;
                return err;
            };
        }
        if (datum.get("fundingRate") != null)
            return self.decodeFunding(datum, times, raw_evidence, batch);
        if (datum.get("markPx") != null)
            return self.decodeReference(.mark, .btc_usdt_swap, datum, times, raw_evidence, batch);
        if (datum.get("idxPx") != null)
            return self.decodeReference(.index, .btc_usdt_swap, datum, times, raw_evidence, batch);
        return error.UnsupportedChannel;
    }

    fn decodeInstrument(
        self: *Decoder,
        instrument: Instrument,
        datum: std.json.ObjectMap,
        times: Times,
        raw_evidence: RawEvidenceRef,
        batch: *IngressBatch,
    ) !void {
        const declared_type = try stringField(datum, "instType");
        if ((instrument == .btc_usdt_spot and !std.mem.eql(u8, declared_type, "SPOT")) or
            (instrument == .btc_usdt_swap and !std.mem.eql(u8, declared_type, "SWAP")))
            return error.InvalidField;
        const source_ms = try optionalMillis(datum, "ts");
        const definition: InstrumentDefinitionObserved = .{
            .instrument = instrument,
            .state = try parseInstrumentState(try stringField(datum, "state")),
            .rule_type = try parseRuleType(try stringField(datum, "ruleType")),
            .tick_size = try decimalField(datum, "tickSz"),
            .lot_size = try decimalField(datum, "lotSz"),
            .minimum_size = try decimalField(datum, "minSz"),
            .maximum_limit_size = try optionalDecimalField(datum, "maxLmtSz"),
            .maximum_market_size = try optionalDecimalField(datum, "maxMktSz"),
            .maximum_limit_notional = try optionalDecimalField(datum, "maxLmtAmt"),
            .maximum_market_notional = try optionalDecimalField(datum, "maxMktAmt"),
            .contract_type = try optionalContractType(datum),
            .contract_value = try optionalDecimalField(datum, "ctVal"),
            .contract_value_currency_btc = try optionalEquals(datum, "ctValCcy", "BTC"),
            .settlement_currency_usdt = try optionalEquals(datum, "settleCcy", "USDT"),
            .trade_quote_currency_usdt = try containsString(datum, "tradeQuoteCcyList", "USDT"),
            .upcoming_changes = try parseUpcomingChanges(datum),
        };
        if (instrument == .btc_usdt_swap and
            (definition.contract_type == null or definition.contract_value == null or
                !definition.contract_value_currency_btc or
                !definition.settlement_currency_usdt))
            return error.InvalidField;
        const content_hash = hashInstrument(&definition);
        const identity = if (source_ms) |timestamp|
            sourceIdentity("instrument", instrument, timestamp)
        else
            sourceIdentityFromContent("instrument", instrument, content_hash);
        if (try remember(&self.instrument_memory[@intFromEnum(instrument)], identity, content_hash)) {
            self.rules_observed[@intFromEnum(instrument)] = true;
            return;
        }
        self.rules_observed[@intFromEnum(instrument)] = true;
        try batch.append(makeEvent(times, source_ms, raw_evidence, identity, .{
            .instrument_definition_observed = definition,
        }));
    }

    fn decodeBook(
        self: *Decoder,
        instrument: Instrument,
        action: []const u8,
        datum: std.json.ObjectMap,
        times: Times,
        raw_evidence: RawEvidenceRef,
        batch: *IngressBatch,
    ) !void {
        const source_ms = try requiredMillis(datum, "ts");
        const sequence = try integerStringField(datum, "seqId");
        const previous = try integerStringField(datum, "prevSeqId");
        const bids = try parseBookSide(datum, "bids");
        const asks = try parseBookSide(datum, "asks");
        const identity = sourceIdentity("book", instrument, @bitCast(sequence));
        const content_hash = hashBook(action, previous, sequence, &bids, &asks);
        const state = self.bookState(instrument);

        if (std.mem.eql(u8, action, "snapshot")) {
            if (state.last_sequence == sequence) {
                if (state.last_content_hash) |last_hash| {
                    if (std.mem.eql(u8, &last_hash, &content_hash)) return;
                }
            }
            state.health = .healthy;
            state.last_sequence = sequence;
            state.last_content_hash = content_hash;
            try batch.append(makeEvent(times, source_ms, raw_evidence, identity, .{
                .l2_book_snapshot = .{
                    .instrument = instrument,
                    .source_sequence = sequence,
                    .bids = bids,
                    .asks = asks,
                },
            }));
            try batch.append(healthEvent(
                times,
                source_ms,
                raw_evidence,
                instrument,
                .healthy,
                null,
                sequence,
                previous,
                sequence,
            ));
            return;
        }
        if (!std.mem.eql(u8, action, "update")) {
            return self.recordGap(
                instrument,
                .unknown_book_action,
                previous,
                sequence,
                times,
                source_ms,
                raw_evidence,
                batch,
            );
        }
        if (state.health != .healthy or state.last_sequence == null) return;
        const last = state.last_sequence.?;
        if (previous == last and sequence == last and bids.len == 0 and asks.len == 0)
            return;
        if (sequence == last) {
            if (state.last_content_hash) |last_hash| {
                if (std.mem.eql(u8, &last_hash, &content_hash)) return;
            }
            return self.recordGap(
                instrument,
                .conflicting_duplicate,
                previous,
                sequence,
                times,
                source_ms,
                raw_evidence,
                batch,
            );
        }
        if (sequence < last) {
            return self.recordGap(
                instrument,
                .source_sequence_regression,
                previous,
                sequence,
                times,
                source_ms,
                raw_evidence,
                batch,
            );
        }
        if (previous != last) {
            return self.recordGap(
                instrument,
                .source_sequence_gap,
                previous,
                sequence,
                times,
                source_ms,
                raw_evidence,
                batch,
            );
        }
        state.last_sequence = sequence;
        state.last_content_hash = content_hash;
        try batch.append(makeEvent(times, source_ms, raw_evidence, identity, .{
            .l2_book_delta = .{
                .instrument = instrument,
                .previous_source_sequence = previous,
                .source_sequence = sequence,
                .bids = bids,
                .asks = asks,
            },
        }));
    }

    fn recordGap(
        self: *Decoder,
        instrument: Instrument,
        reason: GapReason,
        previous: i64,
        sequence: i64,
        times: Times,
        source_ms: u64,
        raw_evidence: RawEvidenceRef,
        batch: *IngressBatch,
    ) !void {
        const state = self.bookState(instrument);
        const last = state.last_sequence;
        state.health = .gap;
        state.last_content_hash = null;
        try batch.append(healthEvent(
            times,
            source_ms,
            raw_evidence,
            instrument,
            .gap,
            reason,
            last,
            previous,
            sequence,
        ));
    }

    fn decodeReference(
        self: *Decoder,
        kind: ReferencePriceKind,
        instrument: Instrument,
        datum: std.json.ObjectMap,
        times: Times,
        raw_evidence: RawEvidenceRef,
        batch: *IngressBatch,
    ) !void {
        const source_ms = try requiredMillis(datum, "ts");
        const declared = try parseInstrument(try stringField(datum, "instId"));
        if ((kind == .mark and declared != .btc_usdt_swap) or
            (kind == .index and declared != .btc_usdt_spot))
            return error.UnsupportedInstrument;
        const price = try decimalField(datum, if (kind == .mark) "markPx" else "idxPx");
        const discriminator = if (kind == .mark) "mark" else "index";
        const identity = sourceIdentity(discriminator, instrument, source_ms);
        const content_hash = hashDecimal(price);
        const memory = if (kind == .mark) &self.mark_memory else &self.index_memory;
        if (try remember(memory, identity, content_hash)) return;
        try batch.append(makeEvent(times, source_ms, raw_evidence, identity, .{
            .reference_price = .{ .instrument = instrument, .kind = kind, .price = price },
        }));
    }

    fn decodeFunding(
        self: *Decoder,
        datum: std.json.ObjectMap,
        times: Times,
        raw_evidence: RawEvidenceRef,
        batch: *IngressBatch,
    ) !void {
        if (try parseInstrument(try stringField(datum, "instId")) != .btc_usdt_swap)
            return error.UnsupportedInstrument;
        const source_ms = try requiredMillis(datum, "ts");
        const funding: FundingRatePublished = .{
            .instrument = .btc_usdt_swap,
            .predicted_rate = try decimalField(datum, "fundingRate"),
            .funding_time_utc_ns = try requiredMillis(datum, "fundingTime"),
            .next_funding_time_utc_ns = try requiredMillis(datum, "nextFundingTime"),
            .settled_rate = try optionalDecimalField(datum, "settFundingRate"),
            .settlement_state = try optionalSettlementState(datum),
        };
        if (funding.next_funding_time_utc_ns <= funding.funding_time_utc_ns)
            return error.InvalidField;
        const identity = sourceIdentity("funding", .btc_usdt_swap, source_ms);
        const content_hash = hashFunding(&funding);
        if (try remember(&self.funding_memory, identity, content_hash)) return;
        try batch.append(makeEvent(times, source_ms, raw_evidence, identity, .{
            .funding_rate_published = funding,
        }));
    }

    fn bookState(self: *Decoder, instrument: Instrument) *BookState {
        return switch (instrument) {
            .btc_usdt_spot => &self.spot_book,
            .btc_usdt_swap => &self.swap_book,
        };
    }

    fn bookStateConst(self: *const Decoder, instrument: Instrument) *const BookState {
        return switch (instrument) {
            .btc_usdt_spot => &self.spot_book,
            .btc_usdt_swap => &self.swap_book,
        };
    }
};

fn makeEvent(
    times: Times,
    source_time_utc_ns: ?u64,
    raw_evidence: RawEvidenceRef,
    identity: [Sha256.digest_length]u8,
    payload: EventPayload,
) CanonicalEvent {
    return .{
        .envelope = .{
            .source_time_utc_ns = source_time_utc_ns,
            .receive_time_utc_ns = times.receive_time_utc_ns,
            .monotonic_time_ns = times.monotonic_time_ns,
            .wall_time_utc_ns = times.wall_time_utc_ns,
            .raw_evidence = raw_evidence,
            .source_fact_identity = identity,
        },
        .payload = payload,
    };
}

fn healthEvent(
    times: Times,
    source_time_utc_ns: ?u64,
    raw_evidence: RawEvidenceRef,
    instrument: Instrument,
    health: MarketDataHealth,
    reason: ?GapReason,
    last: ?i64,
    previous: ?i64,
    sequence: ?i64,
) CanonicalEvent {
    return makeEvent(times, source_time_utc_ns, raw_evidence, healthIdentity(
        instrument,
        health,
        reason,
        last,
        previous,
        sequence,
    ), .{ .market_data_health_changed = .{
        .instrument = instrument,
        .health = health,
        .reason = reason,
        .last_good_source_sequence = last,
        .observed_previous_source_sequence = previous,
        .observed_source_sequence = sequence,
    } });
}

fn parseInstrument(text: []const u8) !Instrument {
    if (std.mem.eql(u8, text, "BTC-USDT")) return .btc_usdt_spot;
    if (std.mem.eql(u8, text, "BTC-USDT-SWAP")) return .btc_usdt_swap;
    return error.UnsupportedInstrument;
}

fn parseInstrumentState(text: []const u8) !InstrumentState {
    if (std.mem.eql(u8, text, "live")) return .live;
    if (std.mem.eql(u8, text, "suspend")) return .@"suspend";
    if (std.mem.eql(u8, text, "preopen")) return .preopen;
    if (std.mem.eql(u8, text, "test")) return .@"test";
    if (std.mem.eql(u8, text, "post_only")) return .post_only;
    return error.InvalidField;
}

fn parseRuleType(text: []const u8) !RuleType {
    if (std.mem.eql(u8, text, "normal")) return .normal;
    if (std.mem.eql(u8, text, "pre_market")) return .pre_market;
    return error.InvalidField;
}

fn asObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.MalformedEnvelope,
    };
}

fn asArray(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => error.MalformedEnvelope,
    };
}

fn objectField(object: std.json.ObjectMap, name: []const u8) !std.json.Value {
    return object.get(name) orelse error.MalformedEnvelope;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return switch (try objectField(object, name)) {
        .string => |text| text,
        else => error.InvalidField,
    };
}

fn decimalField(object: std.json.ObjectMap, name: []const u8) !Decimal {
    return Decimal.parse(try stringField(object, name));
}

fn optionalDecimalField(object: std.json.ObjectMap, name: []const u8) !?Decimal {
    const value = object.get(name) orelse return null;
    const text = switch (value) {
        .string => |text| text,
        .null => return null,
        else => return error.InvalidField,
    };
    if (text.len == 0) return null;
    return @as(?Decimal, try Decimal.parse(text));
}

fn parseUpcomingChanges(object: std.json.ObjectMap) !UpcomingChanges {
    const value = object.get("upcChg") orelse return .{};
    const array = try asArray(value);
    if (array.items.len > 8) return error.InvalidField;
    var changes: UpcomingChanges = .{};
    for (array.items) |item| {
        const change = try asObject(item);
        changes.items[changes.len] = .{
            .parameter = try ShortText.init(try stringField(change, "param")),
            .new_value = try ShortText.init(try stringField(change, "newValue")),
            .effective_time_utc_ns = try requiredMillis(change, "effTime"),
        };
        changes.len += 1;
    }
    return changes;
}

fn integerStringField(object: std.json.ObjectMap, name: []const u8) !i64 {
    return std.fmt.parseInt(i64, try stringField(object, name), 10) catch
        return error.InvalidField;
}

fn requiredMillis(object: std.json.ObjectMap, name: []const u8) !u64 {
    const millis = std.fmt.parseInt(u64, try stringField(object, name), 10) catch
        return error.InvalidField;
    return std.math.mul(u64, millis, std.time.ns_per_ms) catch error.InvalidField;
}

fn optionalMillis(object: std.json.ObjectMap, name: []const u8) !?u64 {
    if (object.get(name) == null) return null;
    return @as(?u64, try requiredMillis(object, name));
}

fn optionalContractType(object: std.json.ObjectMap) !?ContractType {
    const value = object.get("ctType") orelse return null;
    const text = switch (value) {
        .string => |text| text,
        .null => return null,
        else => return error.InvalidField,
    };
    if (text.len == 0) return null;
    if (std.mem.eql(u8, text, "linear")) return .linear;
    if (std.mem.eql(u8, text, "inverse")) return .inverse;
    return error.InvalidField;
}

fn optionalSettlementState(object: std.json.ObjectMap) !?SettlementState {
    const value = object.get("settState") orelse return null;
    const text = switch (value) {
        .string => |text| text,
        .null => return null,
        else => return error.InvalidField,
    };
    if (text.len == 0) return null;
    if (std.mem.eql(u8, text, "processing")) return .processing;
    if (std.mem.eql(u8, text, "settled")) return .settled;
    return error.InvalidField;
}

fn optionalEquals(object: std.json.ObjectMap, name: []const u8, expected: []const u8) !bool {
    const value = object.get(name) orelse return false;
    const text = switch (value) {
        .string => |text| text,
        .null => return false,
        else => return error.InvalidField,
    };
    if (text.len == 0) return false;
    if (!std.mem.eql(u8, text, expected)) return error.InvalidField;
    return true;
}

fn containsString(object: std.json.ObjectMap, name: []const u8, expected: []const u8) !bool {
    const value = object.get(name) orelse return false;
    const array = try asArray(value);
    for (array.items) |item| {
        const text = switch (item) {
            .string => |text| text,
            else => return error.InvalidField,
        };
        if (std.mem.eql(u8, text, expected)) return true;
    }
    return false;
}

fn parseBookSide(object: std.json.ObjectMap, name: []const u8) !BookSide {
    const array = try asArray(try objectField(object, name));
    if (array.items.len > max_book_levels) return error.InvalidField;
    var side: BookSide = .{};
    for (array.items) |item| {
        const tuple = try asArray(item);
        if (tuple.items.len != 4) return error.InvalidField;
        const price = try valueDecimal(tuple.items[0]);
        const quantity = try valueDecimal(tuple.items[1]);
        _ = try valueString(tuple.items[2]);
        const order_count = std.fmt.parseInt(u32, try valueString(tuple.items[3]), 10) catch
            return error.InvalidField;
        if (price.coefficient <= 0 or quantity.coefficient < 0) return error.InvalidField;
        side.levels[side.len] = .{
            .price = price,
            .quantity = quantity,
            .order_count = order_count,
        };
        side.len += 1;
    }
    return side;
}

fn valueString(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => error.InvalidField,
    };
}

fn valueDecimal(value: std.json.Value) !Decimal {
    return Decimal.parse(try valueString(value));
}

fn sourceIdentity(
    discriminator: []const u8,
    instrument: Instrument,
    cursor: u64,
) [Sha256.digest_length]u8 {
    var hasher = Sha256.init(.{});
    hasher.update(discriminator);
    hasher.update(&.{@intFromEnum(instrument)});
    var encoded_cursor: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded_cursor, cursor, .little);
    hasher.update(&encoded_cursor);
    return hasher.finalResult();
}

fn sourceIdentityFromContent(
    discriminator: []const u8,
    instrument: Instrument,
    content_hash: [Sha256.digest_length]u8,
) [Sha256.digest_length]u8 {
    var hasher = Sha256.init(.{});
    hasher.update(discriminator);
    hasher.update(&.{@intFromEnum(instrument)});
    hasher.update(&content_hash);
    return hasher.finalResult();
}

fn healthIdentity(
    instrument: Instrument,
    health: MarketDataHealth,
    reason: ?GapReason,
    last: ?i64,
    previous: ?i64,
    sequence: ?i64,
) [Sha256.digest_length]u8 {
    var hasher = Sha256.init(.{});
    hasher.update("health");
    hasher.update(&.{ @intFromEnum(instrument), @intFromEnum(health) });
    if (reason) |value| {
        hasher.update(&.{ 1, @intFromEnum(value) });
    } else {
        hasher.update(&.{0});
    }
    hashOptionalI64(&hasher, last);
    hashOptionalI64(&hasher, previous);
    hashOptionalI64(&hasher, sequence);
    return hasher.finalResult();
}

fn hashOptionalI64(hasher: *Sha256, value: ?i64) void {
    if (value) |integer| {
        hasher.update(&.{1});
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(i64, &bytes, integer, .little);
        hasher.update(&bytes);
    } else {
        hasher.update(&.{0});
    }
}

fn hashDecimal(value: Decimal) [Sha256.digest_length]u8 {
    var hasher = Sha256.init(.{});
    hashDecimalInto(&hasher, value);
    return hasher.finalResult();
}

fn hashDecimalInto(hasher: *Sha256, value: Decimal) void {
    var coefficient: [16]u8 = undefined;
    std.mem.writeInt(i128, &coefficient, value.coefficient, .little);
    hasher.update(&coefficient);
    hasher.update(&.{value.scale});
}

fn hashOptionalDecimal(hasher: *Sha256, value: ?Decimal) void {
    if (value) |decimal| {
        hasher.update(&.{1});
        hashDecimalInto(hasher, decimal);
    } else {
        hasher.update(&.{0});
    }
}

fn hashInstrument(value: *const InstrumentDefinitionObserved) [Sha256.digest_length]u8 {
    var hasher = Sha256.init(.{});
    hasher.update(&.{
        @intFromEnum(value.instrument),
        @intFromEnum(value.state),
        @intFromEnum(value.rule_type),
    });
    hashDecimalInto(&hasher, value.tick_size);
    hashDecimalInto(&hasher, value.lot_size);
    hashDecimalInto(&hasher, value.minimum_size);
    hashOptionalDecimal(&hasher, value.maximum_limit_size);
    hashOptionalDecimal(&hasher, value.maximum_market_size);
    hashOptionalDecimal(&hasher, value.maximum_limit_notional);
    hashOptionalDecimal(&hasher, value.maximum_market_notional);
    if (value.contract_type) |contract_type| {
        hasher.update(&.{ 1, @intFromEnum(contract_type) });
    } else {
        hasher.update(&.{0});
    }
    hashOptionalDecimal(&hasher, value.contract_value);
    hasher.update(&.{
        @intFromBool(value.contract_value_currency_btc),
        @intFromBool(value.settlement_currency_usdt),
        @intFromBool(value.trade_quote_currency_usdt),
    });
    hasher.update(&.{value.upcoming_changes.len});
    for (value.upcoming_changes.slice()) |*change| {
        hasher.update(change.parameter.slice());
        hasher.update(&.{0});
        hasher.update(change.new_value.slice());
        var effective_time: [8]u8 = undefined;
        std.mem.writeInt(u64, &effective_time, change.effective_time_utc_ns, .little);
        hasher.update(&effective_time);
    }
    return hasher.finalResult();
}

fn hashFunding(value: *const FundingRatePublished) [Sha256.digest_length]u8 {
    var hasher = Sha256.init(.{});
    hasher.update(&.{@intFromEnum(value.instrument)});
    hashDecimalInto(&hasher, value.predicted_rate);
    var time_bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, time_bytes[0..8], value.funding_time_utc_ns, .little);
    std.mem.writeInt(u64, time_bytes[8..16], value.next_funding_time_utc_ns, .little);
    hasher.update(&time_bytes);
    hashOptionalDecimal(&hasher, value.settled_rate);
    if (value.settlement_state) |state| {
        hasher.update(&.{ 1, @intFromEnum(state) });
    } else {
        hasher.update(&.{0});
    }
    return hasher.finalResult();
}

fn hashBook(
    action: []const u8,
    previous: i64,
    sequence: i64,
    bids: *const BookSide,
    asks: *const BookSide,
) [Sha256.digest_length]u8 {
    var hasher = Sha256.init(.{});
    hasher.update(action);
    var sequence_bytes: [16]u8 = undefined;
    std.mem.writeInt(i64, sequence_bytes[0..8], previous, .little);
    std.mem.writeInt(i64, sequence_bytes[8..16], sequence, .little);
    hasher.update(&sequence_bytes);
    hashBookSide(&hasher, bids);
    hashBookSide(&hasher, asks);
    return hasher.finalResult();
}

fn hashBookSide(hasher: *Sha256, side: *const BookSide) void {
    var len_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &len_bytes, side.len, .little);
    hasher.update(&len_bytes);
    for (side.slice()) |level| {
        hashDecimalInto(hasher, level.price);
        hashDecimalInto(hasher, level.quantity);
        var count_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &count_bytes, level.order_count, .little);
        hasher.update(&count_bytes);
    }
}

fn remember(
    memory: *FeedMemory,
    identity: [Sha256.digest_length]u8,
    content_hash: [Sha256.digest_length]u8,
) !bool {
    if (memory.identity) |known_identity| {
        if (std.mem.eql(u8, &known_identity, &identity)) {
            if (memory.content_hash) |known_content| {
                if (std.mem.eql(u8, &known_content, &content_hash)) return true;
            }
            return error.ConflictingDuplicate;
        }
    }
    memory.* = .{ .identity = identity, .content_hash = content_hash };
    return false;
}

const TestRawSink = struct {
    append_count: u64 = 0,
    fail: bool = false,

    fn sink(self: *TestRawSink) RawSink {
        return .{ .ptr = self, .append_fn = append };
    }

    fn append(ptr: *anyopaque, record: RawIngressRecord, bytes: []const u8) RawSinkError!u64 {
        const self: *TestRawSink = @ptrCast(@alignCast(ptr));
        if (self.fail) return error.Backpressure;
        var actual: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(bytes, &actual, .{});
        if (!std.mem.eql(u8, &actual, &record.sha256)) return error.Unavailable;
        self.append_count += 1;
        return self.append_count;
    }
};

const test_times: Times = .{
    .receive_time_utc_ns = 1_800_000_000_000_000_001,
    .monotonic_time_ns = 10_000_001,
    .wall_time_utc_ns = 1_800_000_000_000_000_002,
};

fn ingestTest(decoder: *Decoder, sink: *TestRawSink, raw: []const u8) !IngressBatch {
    return decoder.ingest(std.testing.allocator, sink.sink(), 7, test_times, raw);
}

test "raw evidence is committed before malformed input is rejected" {
    var decoder: Decoder = .{};
    var sink: TestRawSink = .{};
    const batch = try ingestTest(&decoder, &sink, "not json");
    try std.testing.expectEqual(@as(u64, 1), sink.append_count);
    try std.testing.expectEqual(RejectReason.malformed_json, batch.rejection.?);
    try std.testing.expectEqual(@as(u8, 0), batch.event_count);

    sink.fail = true;
    try std.testing.expectError(
        error.Backpressure,
        ingestTest(&decoder, &sink, "{}"),
    );
}

test "instrument mark index and funding frames normalize without floats" {
    var decoder: Decoder = .{};
    var sink: TestRawSink = .{};
    const instrument = try ingestTest(&decoder, &sink,
        \\{"arg":{"channel":"instruments","instType":"SWAP"},"data":[{"instType":"SWAP","instId":"BTC-USDT-SWAP","state":"live","ruleType":"normal","tickSz":"0.1","lotSz":"0.01","minSz":"0.01","maxLmtSz":"1000000","maxMktSz":"10000","maxLmtAmt":"","maxMktAmt":"","ctType":"linear","ctVal":"0.01","ctValCcy":"BTC","settleCcy":"USDT","tradeQuoteCcyList":[],"upcChg":[{"param":"tickSz","newValue":"0.01","effTime":"1800003600000"}],"ts":"1800000000000"}]}
    );
    try std.testing.expectEqual(@as(u8, 1), instrument.event_count);
    const definition = instrument.events[0].payload.instrument_definition_observed;
    try std.testing.expectEqual(Instrument.btc_usdt_swap, definition.instrument);
    try std.testing.expectEqual(Decimal{ .coefficient = 1, .scale = 2 }, definition.contract_value.?);
    try std.testing.expectEqual(@as(u8, 1), definition.upcoming_changes.len);
    try std.testing.expectEqualStrings("tickSz", definition.upcoming_changes.items[0].parameter.slice());

    const mark = try ingestTest(&decoder, &sink,
        \\{"arg":{"channel":"mark-price","instId":"BTC-USDT-SWAP"},"data":[{"instId":"BTC-USDT-SWAP","markPx":"50123.40","ts":"1800000000100"}]}
    );
    const mark_fact = mark.events[0].payload.reference_price;
    try std.testing.expectEqual(ReferencePriceKind.mark, mark_fact.kind);
    try std.testing.expectEqual(Decimal{ .coefficient = 501234, .scale = 1 }, mark_fact.price);

    const index = try ingestTest(&decoder, &sink,
        \\{"arg":{"channel":"index-tickers","instId":"BTC-USDT"},"data":[{"instId":"BTC-USDT","idxPx":"50120.1","ts":"1800000000200"}]}
    );
    try std.testing.expectEqual(ReferencePriceKind.index, index.events[0].payload.reference_price.kind);

    const funding = try ingestTest(&decoder, &sink,
        \\{"arg":{"channel":"funding-rate","instId":"BTC-USDT-SWAP"},"data":[{"instId":"BTC-USDT-SWAP","fundingRate":"0.00010000","fundingTime":"1800003600000","nextFundingTime":"1800032400000","settFundingRate":"0.00009","settState":"settled","ts":"1800000000300"}]}
    );
    const funding_fact = funding.events[0].payload.funding_rate_published;
    try std.testing.expectEqual(Decimal{ .coefficient = 1, .scale = 4 }, funding_fact.predicted_rate);
    try std.testing.expectEqual(SettlementState.settled, funding_fact.settlement_state.?);
    try std.testing.expect(funding_fact.next_funding_time_utc_ns > funding_fact.funding_time_utc_ns);
}

test "rule observations are candidates and later changes remain explicit facts" {
    var decoder: Decoder = .{};
    var sink: TestRawSink = .{};
    const first = try ingestTest(&decoder, &sink,
        \\{"arg":{"channel":"instruments","instType":"SPOT"},"data":[{"instType":"SPOT","instId":"BTC-USDT","state":"live","ruleType":"normal","tickSz":"0.1","lotSz":"0.00000001","minSz":"0.00001","maxLmtSz":"100","maxMktSz":"10","maxLmtAmt":"1000000","maxMktAmt":"100000","ctType":"","ctVal":"","ctValCcy":"","settleCcy":"","tradeQuoteCcyList":["USDT"],"upcChg":[],"ts":"1800000000000"}]}
    );
    try std.testing.expectEqual(@as(u8, 1), first.event_count);
    try std.testing.expect(!decoder.isPublicMarketReady(.btc_usdt_spot));

    const changed = try ingestTest(&decoder, &sink,
        \\{"arg":{"channel":"instruments","instType":"SPOT"},"data":[{"instType":"SPOT","instId":"BTC-USDT","state":"live","ruleType":"normal","tickSz":"0.01","lotSz":"0.00000001","minSz":"0.00001","maxLmtSz":"100","maxMktSz":"10","maxLmtAmt":"1000000","maxMktAmt":"100000","ctType":"","ctVal":"","ctValCcy":"","settleCcy":"","tradeQuoteCcyList":["USDT"],"upcChg":[],"ts":"1800000001000"}]}
    );
    try std.testing.expectEqual(@as(u8, 1), changed.event_count);
    try std.testing.expectEqual(
        Decimal{ .coefficient = 1, .scale = 2 },
        changed.events[0].payload.instrument_definition_observed.tick_size,
    );

    const conflicting = try ingestTest(&decoder, &sink,
        \\{"arg":{"channel":"instruments","instType":"SPOT"},"data":[{"instType":"SPOT","instId":"BTC-USDT","state":"live","ruleType":"normal","tickSz":"0.001","lotSz":"0.00000001","minSz":"0.00001","maxLmtSz":"100","maxMktSz":"10","maxLmtAmt":"1000000","maxMktAmt":"100000","ctType":"","ctVal":"","ctValCcy":"","settleCcy":"","tradeQuoteCcyList":["USDT"],"upcChg":[],"ts":"1800000001000"}]}
    );
    try std.testing.expectEqual(RejectReason.invalid_field, conflicting.rejection.?);
    try std.testing.expect(!decoder.rules_observed[@intFromEnum(Instrument.btc_usdt_spot)]);
}

test "public REST bootstrap shape preserves absent source time" {
    var decoder: Decoder = .{};
    var sink: TestRawSink = .{};
    const batch = try ingestTest(&decoder, &sink,
        \\{"code":"0","data":[{"instType":"SPOT","instId":"BTC-USDT","state":"live","ruleType":"normal","tickSz":"0.1","lotSz":"0.00000001","minSz":"0.00001","maxLmtSz":"9999999999","maxMktSz":"1000000","maxLmtAmt":"20000000","maxMktAmt":"1000000","ctType":"","ctVal":"","ctValCcy":"","settleCcy":"","tradeQuoteCcyList":["USDT"],"upcChg":[]}],"msg":""}
    );
    try std.testing.expectEqual(@as(u8, 1), batch.event_count);
    try std.testing.expectEqual(@as(?u64, null), batch.events[0].envelope.source_time_utc_ns);
    try std.testing.expect(decoder.rules_observed[@intFromEnum(Instrument.btc_usdt_spot)]);
}

test "book duplicates are idempotent and gaps require a fresh snapshot" {
    var decoder: Decoder = .{};
    var sink: TestRawSink = .{};
    const snapshot_frame =
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"snapshot","data":[{"asks":[["50100.1","2.0","0","3"]],"bids":[["50099.9","1.5","0","2"]],"ts":"1800000000000","seqId":"100","prevSeqId":"-1","checksum":0}]}
    ;
    const snapshot = try ingestTest(&decoder, &sink, snapshot_frame);
    try std.testing.expectEqual(@as(u8, 2), snapshot.event_count);
    try std.testing.expect(decoder.isBookHealthy(.btc_usdt_spot));
    try std.testing.expectEqual(@as(i64, 100), snapshot.events[0].payload.l2_book_snapshot.source_sequence);

    const delta_frame =
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"update","data":[{"asks":[],"bids":[["50099.9","1.0","0","1"]],"ts":"1800000000100","seqId":"105","prevSeqId":"100","checksum":0}]}
    ;
    const delta = try ingestTest(&decoder, &sink, delta_frame);
    try std.testing.expectEqual(@as(u8, 1), delta.event_count);
    try std.testing.expectEqual(@as(i64, 105), delta.events[0].payload.l2_book_delta.source_sequence);

    const duplicate = try ingestTest(&decoder, &sink, delta_frame);
    try std.testing.expectEqual(@as(u8, 0), duplicate.event_count);

    const gap = try ingestTest(&decoder, &sink,
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"update","data":[{"asks":[],"bids":[["50099.8","1.0","0","1"]],"ts":"1800000000200","seqId":"110","prevSeqId":"108","checksum":0}]}
    );
    try std.testing.expectEqual(@as(u8, 1), gap.event_count);
    try std.testing.expectEqual(GapReason.source_sequence_gap, gap.events[0].payload.market_data_health_changed.reason.?);
    try std.testing.expect(!decoder.isBookHealthy(.btc_usdt_spot));

    const ignored = try ingestTest(&decoder, &sink,
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"update","data":[{"asks":[],"bids":[["50099.7","1.0","0","1"]],"ts":"1800000000300","seqId":"111","prevSeqId":"110","checksum":0}]}
    );
    try std.testing.expectEqual(@as(u8, 0), ignored.event_count);
    try std.testing.expect(!decoder.isBookHealthy(.btc_usdt_spot));

    const recovered = try ingestTest(&decoder, &sink,
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"snapshot","data":[{"asks":[["50100.2","2.0","0","3"]],"bids":[["50099.8","1.5","0","2"]],"ts":"1800000000400","seqId":"200","prevSeqId":"-1","checksum":0}]}
    );
    try std.testing.expectEqual(@as(u8, 2), recovered.event_count);
    try std.testing.expect(decoder.isBookHealthy(.btc_usdt_spot));
}

test "conflicting duplicate and out-of-order book updates fail closed" {
    var decoder: Decoder = .{};
    var sink: TestRawSink = .{};
    _ = try ingestTest(&decoder, &sink,
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"snapshot","data":[{"asks":[["50100","2","0","3"]],"bids":[["50099","1","0","2"]],"ts":"1800000000000","seqId":"10","prevSeqId":"-1","checksum":0}]}
    );
    _ = try ingestTest(&decoder, &sink,
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"update","data":[{"asks":[],"bids":[["50099","2","0","2"]],"ts":"1800000000100","seqId":"11","prevSeqId":"10","checksum":0}]}
    );
    const conflict = try ingestTest(&decoder, &sink,
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"update","data":[{"asks":[],"bids":[["50099","3","0","2"]],"ts":"1800000000101","seqId":"11","prevSeqId":"10","checksum":0}]}
    );
    try std.testing.expectEqual(
        GapReason.conflicting_duplicate,
        conflict.events[0].payload.market_data_health_changed.reason.?,
    );

    _ = try ingestTest(&decoder, &sink,
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"snapshot","data":[{"asks":[["50100","2","0","3"]],"bids":[["50099","1","0","2"]],"ts":"1800000000200","seqId":"20","prevSeqId":"-1","checksum":0}]}
    );
    const regression = try ingestTest(&decoder, &sink,
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"update","data":[{"asks":[],"bids":[["50099","2","0","2"]],"ts":"1800000000300","seqId":"19","prevSeqId":"18","checksum":0}]}
    );
    try std.testing.expectEqual(
        GapReason.source_sequence_regression,
        regression.events[0].payload.market_data_health_changed.reason.?,
    );
    try std.testing.expect(!decoder.isBookHealthy(.btc_usdt_spot));
}

test "raw backpressure cannot advance book sequence" {
    var decoder: Decoder = .{};
    var sink: TestRawSink = .{};
    _ = try ingestTest(&decoder, &sink,
        \\{"arg":{"channel":"books","instId":"BTC-USDT-SWAP"},"action":"snapshot","data":[{"asks":[["50100","2","0","3"]],"bids":[["50099","1","0","2"]],"ts":"1800000000000","seqId":"30","prevSeqId":"-1","checksum":0}]}
    );
    const delta =
        \\{"arg":{"channel":"books","instId":"BTC-USDT-SWAP"},"action":"update","data":[{"asks":[],"bids":[["50099","2","0","2"]],"ts":"1800000000100","seqId":"31","prevSeqId":"30","checksum":0}]}
    ;
    sink.fail = true;
    try std.testing.expectError(error.Backpressure, ingestTest(&decoder, &sink, delta));
    try std.testing.expectEqual(@as(?i64, 30), decoder.swap_book.last_sequence);
    sink.fail = false;
    const accepted = try ingestTest(&decoder, &sink, delta);
    try std.testing.expectEqual(@as(u8, 1), accepted.event_count);
    try std.testing.expectEqual(@as(?i64, 31), decoder.swap_book.last_sequence);
}

test "empty same-sequence update is heartbeat and resubscribe blocks deltas" {
    var decoder: Decoder = .{};
    var sink: TestRawSink = .{};
    _ = try ingestTest(&decoder, &sink,
        \\{"arg":{"channel":"books","instId":"BTC-USDT-SWAP"},"action":"snapshot","data":[{"asks":[["50100","2","0","3"]],"bids":[["50099","1","0","2"]],"ts":"1800000000000","seqId":"10","prevSeqId":"-1","checksum":0}]}
    );
    const heartbeat = try ingestTest(&decoder, &sink,
        \\{"arg":{"channel":"books","instId":"BTC-USDT-SWAP"},"action":"update","data":[{"asks":[],"bids":[],"ts":"1800000060000","seqId":"10","prevSeqId":"10","checksum":0}]}
    );
    try std.testing.expectEqual(@as(u8, 0), heartbeat.event_count);
    try std.testing.expect(decoder.isBookHealthy(.btc_usdt_swap));

    const resubscribed = decoder.beginSubscription(.btc_usdt_swap);
    try std.testing.expectEqual(GapReason.resubscribed, resubscribed.reason.?);
    try std.testing.expectEqual(@as(?i64, 10), resubscribed.last_good_source_sequence);
    const ignored = try ingestTest(&decoder, &sink,
        \\{"arg":{"channel":"books","instId":"BTC-USDT-SWAP"},"action":"update","data":[{"asks":[],"bids":[["50099","2","0","2"]],"ts":"1800000060100","seqId":"11","prevSeqId":"10","checksum":0}]}
    );
    try std.testing.expectEqual(@as(u8, 0), ignored.event_count);
    try std.testing.expect(!decoder.isBookHealthy(.btc_usdt_swap));
}

test "malformed book frame revokes health after raw commit" {
    var decoder: Decoder = .{};
    var sink: TestRawSink = .{};
    _ = try ingestTest(&decoder, &sink,
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"snapshot","data":[{"asks":[["50100","2","0","3"]],"bids":[["50099","1","0","2"]],"ts":"1800000000000","seqId":"10","prevSeqId":"-1","checksum":0}]}
    );
    const malformed = try ingestTest(&decoder, &sink,
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"update","data":[{"asks":[],"bids":[["not-a-price","1","0","2"]],"ts":"1800000000100","seqId":"11","prevSeqId":"10","checksum":0}]}
    );
    try std.testing.expectEqual(@as(u64, 2), sink.append_count);
    try std.testing.expectEqual(RejectReason.invalid_field, malformed.rejection.?);
    try std.testing.expectEqual(@as(u8, 1), malformed.event_count);
    const health = malformed.events[0].payload.market_data_health_changed;
    try std.testing.expectEqual(GapReason.malformed_book_frame, health.reason.?);
    try std.testing.expect(!decoder.isBookHealthy(.btc_usdt_spot));
}
