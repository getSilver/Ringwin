const std = @import("std");

pub const windows_demo_transport_enabled = true;

pub fn main(init: std.process.Init) !void {
    return @import("main.zig").main(init);
}
