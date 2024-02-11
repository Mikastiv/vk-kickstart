const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const registry = b.option([]const u8, "registry", "Path to the Vulkan registry") orelse @panic("provide path to the Vulkan registry");
    const enable_validation = b.option(bool, "enable_validation", "Enable vulkan validation layers");
    const verbose = b.option(bool, "verbose", "Enable debug output");

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_validation", enable_validation orelse false);
    build_options.addOption(bool, "verbose", verbose orelse false);

    const vkzig_dep = b.dependency("vulkan_zig", .{
        .registry = registry,
    });

    const kickstart = b.addModule("vk-kickstart", .{
        .root_source_file = .{ .path = "src/vk_kickstart.zig" },
        .imports = &.{
            .{ .name = "vulkan-zig", .module = vkzig_dep.module("vulkan-zig") },
        },
    });
    kickstart.addOptions("build_options", build_options);

    const lib_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/root.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
