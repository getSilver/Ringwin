//! Offline public auth -> TransportOwner -> C request seam.
const std = @import("std");
const auth = @import("../../adapters/okx/okx_rest_auth.zig");
const curl = @import("../../adapters/okx/okx_curl_transport.zig");
extern fn ringwin_test_reset(c_int, c_int) void;
extern fn ringwin_test_cleaned() c_int;

test "protected credentials survive borrowed transport rebuild and synthetic request failures" {
    var credentials = try auth.Credentials.init("key", "secret", "pass");
    defer credentials.deinit();
    try std.testing.expectError(error.InvalidSourceSession, curl.TransportOwner.init(&credentials, null, 0));
    // Each owner borrows the same mapping. It is not consumed or freed on error/rebuild.
    for ([_]c_int{ 0, 4, -1 }) |failure| {
        var owner = try curl.TransportOwner.init(&credentials, null, 1);
        defer owner.deinit();
        try owner.prepare("2020-12-08T09:08:57.715Z", .{ .receive_time_utc_ns = 1, .monotonic_time_ns = 1, .wall_time_utc_ns = 1 });
        ringwin_test_reset(if (failure > 0) failure else 0, if (failure < 0) 55 else 0);
        const result = owner.transport().submit("/api/v5/trade/order", "{\"x\":1}");
        try std.testing.expectEqual(@as(@TypeOf(result.outcome), if (failure == 0) .response else if (failure > 0) .proven_before_send else .write_or_response_uncertain), result.outcome);
        try std.testing.expectEqual(@as(c_int, 1), ringwin_test_cleaned());
        try std.testing.expect(credentials.protection().locked);
    }
}

extern fn ringwin_test_http_status(c_long) void;

test "read-only account guard rejects non2xx code0 without changing delivery outcome" {
    var credentials = try auth.Credentials.init("key", "secret", "pass");
    defer credentials.deinit();
    var owner = try curl.TransportOwner.init(&credentials, null, 1);
    defer owner.deinit();
    try owner.prepare("2020-12-08T09:08:57.715Z", .{ .receive_time_utc_ns = 1, .monotonic_time_ns = 1, .wall_time_utc_ns = 1 });
    for ([_]c_long{ 199, 300, 401, 429, 500 }) |status| {
        ringwin_test_reset(0, 0);
        ringwin_test_http_status(status);
        try std.testing.expectError(error.DemoGuardHTTPStatusRejected, owner.requestReadOnlyChecked("/api/v5/account/config"));
        try std.testing.expectEqual(status, owner.last_http_status);
        const delivery = owner.request(.get, "/api/v5/account/config", "");
        try std.testing.expectEqual(@as(@TypeOf(delivery.outcome), .response), delivery.outcome);
    }
    for ([_]c_long{ 200, 299 }) |status| {
        ringwin_test_reset(0, 0);
        ringwin_test_http_status(status);
        try std.testing.expectEqualStrings("{\"code\":\"0\",\"data\":[]}", try owner.requestReadOnlyChecked("/api/v5/account/config"));
    }
    const invalid = owner.request(.get, "invalid-relative-path", "");
    try std.testing.expectEqual(@as(@TypeOf(invalid.outcome), .proven_before_send), invalid.outcome);
    try std.testing.expectEqual(@as(c_long, 0), owner.last_http_status);
}
