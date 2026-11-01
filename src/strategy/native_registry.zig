//! Static native entrypoints; no runtime loading or trading authorization.
const std = @import("std");
const canonical = @import("../model/canonical_event.zig");
const core = @import("../runtime/production_contract.zig");
const contract = @import("native_definition.zig");
const manifest = @import("native_manifest.zig");

const observer = struct {
    pub const implementation = @import("native_observer.zig");
    pub const definition: contract.Definition = .{
        .definition_identity = "a21994db11534bf5b193c5aa89000001",
        .name = "native_observer",
        .entrypoint = "native_observer",
        .algorithm_path = "src/strategy/native_observer.zig",
        .algorithm_sha256 = contract.sha256(@embedFile("native_observer.zig")),
        .config_schema = .{
            .identity = "a21994db11534bf5b193c5aa89000002",
            .version = 1,
            .path = "share/ringwin/contracts/native_observer_config.json",
            .sha256 = contract.sha256(@embedFile("native_observer_config.json")),
        },
        .state_schema = .{
            .identity = "a21994db11534bf5b193c5aa89000003",
            .version = 1,
            .path = "share/ringwin/contracts/native_observer_state.json",
            .sha256 = contract.sha256(@embedFile("native_observer_state.json")),
        },
        .compatibility = .{
            .native_api = 1,
            .canonical_schema = canonical.schema_version,
            .schema_registry = core.schema_registry_identity,
            .journal_schema = core.journal_schema_version,
            .core_state_schema = core.state_schema_version,
        },
        .subscription = @intFromEnum(canonical.EventType.reference_price),
        .output = .none,
    };
};

pub const registrations = .{observer};

// Compare slice contents, including nested schema strings, rather than addresses.
fn equal(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    if (T == []const u8) return std.mem.eql(u8, a, b);
    if (@typeInfo(T) == .@"struct") {
        inline for (std.meta.fields(T)) |field| {
            if (!equal(@field(a, field.name), @field(b, field.name))) return false;
        }
        return true;
    }
    return a == b;
}

pub fn validate() !void {
    @setEvalBranchQuota(200_000);
    inline for (registrations, 0..) |registration, index| {
        inline for (registrations, 0..) |previous, previous_index| {
            if (previous_index < index and std.mem.eql(u8, registration.definition.definition_identity, previous.definition.definition_identity)) return error.DuplicateDefinition;
        }
    }
    inline for (manifest.definitions, 0..) |expected, index| {
        inline for (manifest.definitions[0..index]) |previous| {
            if (std.mem.eql(u8, expected.definition_identity, previous.definition_identity)) return error.DuplicateDefinition;
        }
    }
    if (registrations.len != manifest.definitions.len) return error.MissingRegistration;
    inline for (registrations) |registration| {
        const actual = registration.definition;
        _ = try contract.identity(actual.definition_identity);
        _ = try contract.identity(actual.config_schema.identity);
        _ = try contract.identity(actual.state_schema.identity);
        if (actual.config_schema.version == 0 or actual.state_schema.version == 0) return error.InvalidDefinition;
        var found = false;
        inline for (manifest.definitions) |expected| {
            if (std.mem.eql(u8, actual.definition_identity, expected.definition_identity)) {
                if (!equal(actual, expected)) return error.ManifestMismatch;
                found = true;
            }
        }
        if (!found) return error.ManifestMismatch;
        const Impl = registration.implementation;
        _ = @as(*const fn (Impl.Config) Impl.Error!Impl.State, &Impl.create);
        _ = @as(*const fn (Impl.Config, Impl.State) Impl.Error!void, &Impl.validate);
        _ = @as(*const fn (Impl.Config, *Impl.State, u64, canonical.ReferencePrice) Impl.Error!void, &Impl.onReferencePrice);
    }
}

comptime {
    validate() catch |err| @compileError("native strategy build rejected: " ++ @errorName(err));
}

pub fn find(identity: u128) ?contract.Definition {
    @setEvalBranchQuota(10_000);
    inline for (registrations) |registration| {
        if (identity == comptime (contract.identity(registration.definition.definition_identity) catch unreachable)) return registration.definition;
    }
    return null;
}

pub fn implementation(comptime identity: u128) type {
    inline for (registrations) |registration| {
        if (identity == (contract.identity(registration.definition.definition_identity) catch unreachable)) return registration.implementation;
    }
    @compileError("native strategy has no registered entrypoint");
}
