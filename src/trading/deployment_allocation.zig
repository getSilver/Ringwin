//! Complete immutable allocation of one deployment. Account observations never
//! grant a second copy of these budgets. Rows are staged in the decision stream
//! so even the largest supported manifest fits the bounded journal record size.
const std = @import("std");
const codec = @import("../persistence/snapshot_codec.zig");
const history = @import("../persistence/business_history.zig");
pub const Digest = [32]u8;
pub const max_accounts = 4;
pub const max_domains = 4;
pub const max_assets = 128;
pub const max_ownerships = 500;
pub const max_account_limits = max_accounts * max_assets;
pub const max_slices = max_account_limits * max_domains;
pub const Environment = enum(u8) { simulation, demo, testnet, production };

pub const Header = struct {
    identity: u128,
    epoch: u64,
    domain_count: u8,
    account_count: u8,
    asset_count: u16,
    account_limit_count: u16,
    ownership_count: u16,
    slice_count: u16,
    expected_digest: Digest,
};
pub const Domain = struct { identity: u128 = 0, stream: u64 = 0, portfolio: u128 = 0 };
pub const Account = struct { identity: u128 = 0, venue: u64 = 0, environment: Environment = .simulation };
pub const AssetLimit = struct { asset: u64 = 0, atoms: i128 = 0 };
pub const AccountLimit = struct { account: u128 = 0, asset: u64 = 0, atoms: i128 = 0 };
pub const Ownership = struct { account: u128 = 0, instrument: u128 = 0, domain: u128 = 0 };
pub const Slice = struct { account: u128 = 0, asset: u64 = 0, domain: u128 = 0, atoms: i128 = 0 };
pub const Input = union(enum(u8)) {
    begin: Header,
    domain: Domain,
    account: Account,
    asset_limit: AssetLimit,
    account_limit: AccountLimit,
    ownership: Ownership,
    slice: Slice,
    seal,
};

pub const DomainBinding = struct { domain: u128, stream: u64, receipt: ?history.Receipt = null, proof: ?history.LookupProof = null };
pub const BindingRecord = struct {
    domain: u128,
    stream: u64,
    portfolio: u128,
    deployment: u128,
    epoch: u64,
    configuration_digest: Digest,
    pub fn digest(self: @This()) Digest {
        var bytes: [256]u8 = undefined;
        return history.hash(codec.encodeBare(&bytes, self) catch unreachable);
    }
    pub fn origin(self: @This()) history.Origin {
        return .{ .stream = .{ .domain = .decision_log, .id = self.stream }, .account = 0, .scope = .{ .decision_domain = .{ .identity = self.domain, .deployment = self.deployment, .epoch = self.epoch, .configuration_digest = self.configuration_digest } } };
    }
};

pub const Configuration = struct {
    header: ?Header = null,
    domains: [max_domains]Domain = @splat(.{}),
    domain_count: u8 = 0,
    accounts: [max_accounts]Account = @splat(.{}),
    account_count: u8 = 0,
    asset_limits: [max_assets]AssetLimit = @splat(.{}),
    asset_count: u16 = 0,
    account_limits: [max_account_limits]AccountLimit = @splat(.{}),
    account_limit_count: u16 = 0,
    ownerships: [max_ownerships]Ownership = @splat(.{}),
    ownership_count: u16 = 0,
    slices: [max_slices]Slice = @splat(.{}),
    slice_count: u16 = 0,
    sealed: bool = false,

    pub fn apply(self: *Configuration, input: Input) !void {
        if (self.sealed) return error.ImmutableDeploymentConfiguration;
        if (input == .begin) {
            if (self.header != null) return error.ImmutableDeploymentConfiguration;
            try validateHeader(input.begin);
            self.header = input.begin;
            return;
        }
        const header = self.header orelse return error.DeploymentConfigurationRequired;
        switch (input) {
            .begin => unreachable,
            .domain => |value| try append(Domain, &self.domains, &self.domain_count, header.domain_count, value),
            .account => |value| try append(Account, &self.accounts, &self.account_count, header.account_count, value),
            .asset_limit => |value| try append(AssetLimit, &self.asset_limits, &self.asset_count, header.asset_count, value),
            .account_limit => |value| try append(AccountLimit, &self.account_limits, &self.account_limit_count, header.account_limit_count, value),
            .ownership => |value| try append(Ownership, &self.ownerships, &self.ownership_count, header.ownership_count, value),
            .slice => |value| try append(Slice, &self.slices, &self.slice_count, header.slice_count, value),
            .seal => {
                try self.validateComplete();
                if (!std.mem.eql(u8, &header.expected_digest, &self.contentDigest())) return error.DeploymentDigestMismatch;
                self.sealed = true;
            },
        }
    }

    pub fn account(self: *const Configuration, identity: u128) ?Account {
        for (self.accounts[0..self.account_count]) |entry| if (entry.identity == identity) return entry;
        return null;
    }
    pub fn bindingRecord(self: *const Configuration, domain_id: u128, stream: u64) !BindingRecord {
        if (!self.sealed) return error.IncompleteDeploymentConfiguration;
        const entry = self.domain(domain_id) orelse return error.InvalidDecisionDomain;
        if (entry.stream != stream) return error.InvalidDecisionDomain;
        const header = self.header.?;
        return .{ .domain = domain_id, .stream = stream, .portfolio = entry.portfolio, .deployment = header.identity, .epoch = header.epoch, .configuration_digest = header.expected_digest };
    }
    pub fn domain(self: *const Configuration, identity: u128) ?Domain {
        for (self.domains[0..self.domain_count]) |entry| if (entry.identity == identity) return entry;
        return null;
    }
    pub fn owner(self: *const Configuration, account_id: u128, instrument: u128) ?u128 {
        if (!self.sealed) return null;
        for (self.ownerships[0..self.ownership_count]) |entry|
            if (entry.account == account_id and entry.instrument == instrument) return entry.domain;
        return null;
    }
    pub fn sliceLimit(self: *const Configuration, account_id: u128, asset: u64, domain_id: u128) ?i128 {
        if (!self.sealed) return null;
        for (self.slices[0..self.slice_count]) |entry|
            if (entry.account == account_id and entry.asset == asset and entry.domain == domain_id) return entry.atoms;
        return null;
    }

    pub fn validateComplete(self: *const Configuration) !void {
        const header = self.header orelse return error.DeploymentConfigurationRequired;
        try validateHeader(header);
        inline for (.{ "domain_count", "account_count", "asset_count", "account_limit_count", "ownership_count", "slice_count" }) |field|
            if (@field(self, field) != @field(header, field)) return error.IncompleteDeploymentConfiguration;
        for (self.domains[0..self.domain_count], 0..) |entry, index| {
            if (entry.identity == 0 or entry.stream == 0 or entry.portfolio == 0) return error.InvalidDeploymentDomain;
            for (self.domains[0..index]) |prior|
                if (prior.identity == entry.identity or prior.stream == entry.stream or prior.portfolio == entry.portfolio) return error.DuplicateDeploymentDomain;
        }
        for (self.accounts[0..self.account_count], 0..) |entry, index| {
            if (entry.identity == 0 or entry.venue == 0) return error.InvalidDeploymentAccount;
            for (self.accounts[0..index]) |prior| if (prior.identity == entry.identity) return error.DuplicateDeploymentAccount;
        }
        for (self.asset_limits[0..self.asset_count], 0..) |entry, index| {
            if (entry.asset == 0 or entry.atoms <= 0) return error.InvalidDeploymentBudget;
            for (self.asset_limits[0..index]) |prior| if (prior.asset == entry.asset) return error.DuplicateDeploymentBudget;
            var allocated: i128 = 0;
            for (self.account_limits[0..self.account_limit_count]) |limit| {
                if (limit.asset != entry.asset) continue;
                if (limit.atoms <= 0) return error.InvalidDeploymentBudget;
                allocated = try std.math.add(i128, allocated, limit.atoms);
            }
            if (allocated > entry.atoms) return error.GlobalBudgetOversubscribed;
        }
        for (self.account_limits[0..self.account_limit_count], 0..) |entry, index| {
            if (self.account(entry.account) == null or !self.hasAsset(entry.asset) or entry.atoms <= 0) return error.InvalidDeploymentBudget;
            for (self.account_limits[0..index]) |prior|
                if (prior.account == entry.account and prior.asset == entry.asset) return error.DuplicateDeploymentBudget;
            var allocated: i128 = 0;
            for (self.slices[0..self.slice_count]) |slice| {
                if (slice.account != entry.account or slice.asset != entry.asset) continue;
                if (slice.atoms <= 0) return error.InvalidDeploymentBudget;
                allocated = try std.math.add(i128, allocated, slice.atoms);
            }
            if (allocated > entry.atoms) return error.AccountBudgetOversubscribed;
        }
        for (self.ownerships[0..self.ownership_count], 0..) |entry, index| {
            if (entry.instrument == 0 or self.account(entry.account) == null or self.domain(entry.domain) == null) return error.InvalidDeploymentOwnership;
            for (self.ownerships[0..index]) |prior|
                if (prior.account == entry.account and prior.instrument == entry.instrument) return error.ConflictingDeploymentOwnership;
        }
        for (self.slices[0..self.slice_count], 0..) |entry, index| {
            if (self.domain(entry.domain) == null or entry.atoms <= 0 or !self.hasAccountLimit(entry.account, entry.asset)) return error.InvalidDeploymentSlice;
            for (self.slices[0..index]) |prior|
                if (prior.account == entry.account and prior.asset == entry.asset and prior.domain == entry.domain) return error.DuplicateDeploymentSlice;
        }
    }

    fn hasAsset(self: *const Configuration, asset: u64) bool {
        for (self.asset_limits[0..self.asset_count]) |entry| if (entry.asset == asset) return true;
        return false;
    }
    fn hasAccountLimit(self: *const Configuration, account_id: u128, asset: u64) bool {
        for (self.account_limits[0..self.account_limit_count]) |entry|
            if (entry.account == account_id and entry.asset == asset) return true;
        return false;
    }

    /// Canonical row order is part of the immutable configured identity. The
    /// expected digest itself is excluded, preventing circular self-attestation.
    pub fn contentDigest(self: *const Configuration) Digest {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update("DeploymentAllocationV1\x00");
        if (self.header) |value| {
            var header = value;
            header.expected_digest = @splat(0);
            hashValue(&hasher, header);
        }
        inline for (.{ .{ "domains", "domain_count" }, .{ "accounts", "account_count" }, .{ "asset_limits", "asset_count" }, .{ "account_limits", "account_limit_count" }, .{ "ownerships", "ownership_count" }, .{ "slices", "slice_count" } }) |fields| {
            hashValue(&hasher, @field(self, fields[1]));
            for (@field(self, fields[0])[0..@field(self, fields[1])]) |value| hashValue(&hasher, value);
        }
        var result: Digest = undefined;
        hasher.final(&result);
        return result;
    }

    pub fn validateSnapshot(self: *const Configuration) !void {
        if (self.domain_count > max_domains or self.account_count > max_accounts or self.asset_count > max_assets or
            self.account_limit_count > max_account_limits or self.ownership_count > max_ownerships or self.slice_count > max_slices) return error.InvalidDeploymentCapacity;
        if (self.header) |header| {
            try validateHeader(header);
            inline for (.{ "domain_count", "account_count", "asset_count", "account_limit_count", "ownership_count", "slice_count" }) |field|
                if (@field(self, field) > @field(header, field)) return error.InvalidDeploymentCapacity;
            if (self.sealed) {
                try self.validateComplete();
                if (!std.mem.eql(u8, &header.expected_digest, &self.contentDigest())) return error.DeploymentDigestMismatch;
            }
        } else if (self.sealed or self.domain_count != 0 or self.account_count != 0 or self.asset_count != 0 or self.account_limit_count != 0 or self.ownership_count != 0 or self.slice_count != 0) return error.InvalidDeploymentConfiguration;
    }
};

fn append(comptime T: type, storage: []T, count: anytype, expected: usize, value: T) !void {
    if (count.* >= expected or count.* >= storage.len) return error.DeploymentCapacity;
    storage[count.*] = value;
    count.* += 1;
}
fn validateHeader(header: Header) !void {
    if (header.identity == 0 or header.epoch == 0 or std.mem.allEqual(u8, &header.expected_digest, 0)) return error.InvalidDeploymentConfiguration;
    if (header.domain_count == 0 or header.domain_count > max_domains or header.account_count == 0 or header.account_count > max_accounts or
        header.asset_count == 0 or header.asset_count > max_assets or header.account_limit_count == 0 or header.account_limit_count > max_account_limits or
        header.ownership_count == 0 or header.ownership_count > max_ownerships or header.slice_count == 0 or header.slice_count > max_slices) return error.InvalidDeploymentCapacity;
}
fn hashValue(hasher: *std.crypto.hash.sha2.Sha256, value: anytype) void {
    var bytes: [256]u8 = undefined;
    hasher.update(codec.encodeBare(&bytes, value) catch unreachable);
}
