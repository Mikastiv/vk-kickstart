const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "kickstart_glfw_example",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const kickstart_dep = b.dependency("vk_kickstart", .{
        // can overwrite the default settings for validation layers and debug callback
        // .enable_validation = false, // default: true for .Debug else false
        .verbose = true, // enable debug output
    });
    exe.root_module.addImport("vk-kickstart", kickstart_dep.module("vk-kickstart"));
    exe.root_module.addImport("vulkan", kickstart_dep.module("vulkan-zig"));

    const glfw = b.dependency("glfw", .{
        .target = target,
        .optimize = .ReleaseFast,
    });
    exe.linkLibrary(glfw.artifact("glfw"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}