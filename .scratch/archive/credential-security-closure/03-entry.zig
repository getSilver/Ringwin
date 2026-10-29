const std = @import("std");
const builtin = @import("builtin");
const store = @import("credential_store");
pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag == .windows) return store.runWindowsAcceptance(init);
    return store.runLinuxAcceptance(init);
}
