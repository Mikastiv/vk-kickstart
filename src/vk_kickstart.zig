const std = @import("std");
const testing = std.testing;

pub const dispatch = @import("dispatch.zig");

test "basic" {
    try testing.expect(true);
}
