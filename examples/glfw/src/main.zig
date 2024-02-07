const std = @import("std");
const c = @import("c.zig");
const vk = @import("vulkan");
const vkk = @import("vk-kickstart");
const dispatch = @import("dispatch.zig");
const Window = @import("Window.zig");

const vki = vkk.vki;

// can override default_functions
// pub const instance_functions = dispatch.instance;
// pub const device_functions = dispatch.device;

fn errorCallback(error_code: i32, description: [*c]const u8) callconv(.C) void {
    std.log.err("glfw: {}: {s}\n", .{ error_code, description });
}

pub fn main() !void {
    if (c.glfwInit() == c.GLFW_FALSE) return error.GlfwInitFailed;
    defer c.glfwTerminate();

    _ = c.glfwSetErrorCallback(errorCallback);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const window = try Window.init(allocator, 800, 600, "VkKickstart");
    defer window.deinit(allocator);

    const instance = try vkk.Instance.init(allocator, c.glfwGetInstanceProcAddress, .{});
    defer instance.deinit();

    const surface = try window.createSurface(instance.handle);
    defer vki().destroySurfaceKHR(instance.handle, surface, instance.allocation_callbacks);

    var physical_device = try vkk.PhysicalDevice.init(allocator, &instance, surface, .{
        .transfer_queue = .dedicated,
        .compute_queue = .separate,
        .required_features = .{
            .wide_lines = vk.TRUE,
        },
        .required_features_13 = .{
            .private_data = vk.TRUE,
        },
    });
    defer physical_device.deinit();

    std.log.info("selected {s}", .{physical_device.name()});

    var device = try vkk.Device.init(allocator, &physical_device, null);
    defer device.deinit();
}
