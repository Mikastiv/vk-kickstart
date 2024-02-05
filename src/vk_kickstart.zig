const std = @import("std");
const testing = std.testing;

const dispatch = @import("dispatch.zig");
pub const vkb = dispatch.vkb;
pub const vki = dispatch.vki;
pub const vkd = dispatch.vkd;
pub const Instance = @import("Instance.zig");

test "basic" {
    try testing.expect(true);
}
