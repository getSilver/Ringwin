const std = @import("std");
const credential_store = @import("credential_store.zig");

test "password provenance type is not externally constructible" {
    comptime std.debug.assert(!@hasDecl(credential_store, "PasswordSource"));
    comptime std.debug.assert(!@hasDecl(credential_store, "readPassword"));
    comptime std.debug.assert(@hasDecl(credential_store.CredentialStore, "stage"));
}
