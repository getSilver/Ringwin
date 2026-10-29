//! Reviewed build inventory, independent of actual static registrations.
const Definition = @import("native_definition.zig").Definition;

pub const definitions = [_]Definition{.{
    .definition_identity = "a21994db11534bf5b193c5aa89000001",
    .name = "native_observer",
    .entrypoint = "native_observer",
    .algorithm_path = "src/strategy/native_observer.zig",
    .algorithm_sha256 = "e457372e519b84dcadaf4680a6a5aaf659bdfdfecb073ed9751e676ddda27c3c",
    .config_schema = .{
        .identity = "a21994db11534bf5b193c5aa89000002",
        .version = 1,
        .path = "share/ringwin/contracts/native_observer_config.json",
        .sha256 = "6cc78d28697631286be8a0d9726e5d7506f40cb734e79da39b183190003ac207",
    },
    .state_schema = .{
        .identity = "a21994db11534bf5b193c5aa89000003",
        .version = 1,
        .path = "share/ringwin/contracts/native_observer_state.json",
        .sha256 = "4902395836bd3917c1944b0c80be1b4a61e33cff2fe1b5e5aefbaef3fe6ed23d",
    },
    .compatibility = .{
        .native_api = 1,
        .canonical_schema = 18,
        .schema_registry = 48,
        .journal_schema = 50,
        .core_state_schema = 54,
    },
    .subscription = 19,
    .output = .none,
}};
