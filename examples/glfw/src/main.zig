const std = @import("std");
const c = @import("c.zig");
const vk = @import("vulkan");
const vkk = @import("vk-kickstart");
const dispatch = @import("dispatch.zig");
const Window = @import("Window.zig");

// Vulkan dispatchers
const vkb = vkk.vkb; // Base dispatch
const vki = vkk.vki; // Instance dispatch
const vkd = vkk.vkd; // Device dispatch

// can override default_functions if more Vulkan functions are required
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

    const window = try Window.init(allocator, 800, 600, "vk-kickstart");
    defer window.deinit(allocator);

    const instance = try vkk.Instance.init(allocator, c.glfwGetInstanceProcAddress, .{
        .required_api_version = vk.API_VERSION_1_3,
    });
    defer instance.deinit();

    const surface = try window.createSurface(instance.handle);
    defer vki().destroySurfaceKHR(instance.handle, surface, instance.allocation_callbacks);

    var physical_device = try vkk.PhysicalDevice.init(allocator, &instance, surface, .{
        .transfer_queue = .dedicated,
        .required_features = .{
            .sampler_anisotropy = vk.TRUE,
        },
        .required_features_13 = .{
            .dynamic_rendering = vk.TRUE,
            .synchronization_2 = vk.TRUE,
        },
    });
    defer physical_device.deinit();

    std.log.info("selected {s}", .{physical_device.name()});

    var device = try vkk.Device.init(allocator, &physical_device, null);
    defer device.deinit();

    const queue = device.graphics_queue;
    _ = queue;

    while (!window.shouldClose()) {
        c.glfwPollEvents();
    }
}
