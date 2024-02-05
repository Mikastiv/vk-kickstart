const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vkzig_dep = b.dependency("vulkan_zig", .{
        .registry = @as([]const u8, b.pathFromRoot("vk.xml")),
    });
    const vkzig_bindings = vkzig_dep.module("vulkan-zig");

    _ = b.addModule("vk_kickstart", .{
        .root_source_file = .{ .path = "src/vk_kickstart.zig" },
        .imports = &.{
            .{ .name = "vulkan", .module = vkzig_bindings },
        },
    });

    const lib_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/root.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
