const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const default_validation = switch (optimize) {
        .Debug => true,
        else => false,
    };

    const enable_validation = b.option(bool, "enable_validation", "Enable vulkan validation layer");

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_validation", enable_validation orelse default_validation);

    const vkzig_dep = b.dependency("vulkan_zig", .{
        .registry = @as([]const u8, b.pathFromRoot("vk.xml")),
    });

    const kickstart = b.addModule("vk_kickstart", .{
        .root_source_file = .{ .path = "src/vk_kickstart.zig" },
        .imports = &.{
            .{ .name = "vulkan", .module = vkzig_dep.module("vulkan-zig") },
        },
    });
    kickstart.addOptions("build_options", build_options);
    b.modules.put(b.dupe("vulkan-zig"), vkzig_dep.module("vulkan-zig")) catch @panic("OOM");

    const lib_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/root.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
