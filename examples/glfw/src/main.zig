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

// can override default_functions if more or less Vulkan functions are required
// pub const base_functions = dispatch.base;
// pub const instance_functions = dispatch.instance;
// pub const device_functions = dispatch.device;

fn errorCallback(error_code: i32, description: [*c]const u8) callconv(.C) void {
    std.log.err("glfw: {}: {s}\n", .{ error_code, description });
}

const window_width = 800;
const window_height = 600;

pub fn main() !void {
    if (c.glfwInit() == c.GLFW_FALSE) return error.GlfwInitFailed;
    defer c.glfwTerminate();

    _ = c.glfwSetErrorCallback(errorCallback);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const window = try Window.init(allocator, window_width, window_height, "vk-kickstart");
    defer window.deinit(allocator);

    const instance = try vkk.Instance.create(allocator, c.glfwGetInstanceProcAddress, .{
        .required_api_version = vk.API_VERSION_1_3,
    });
    defer instance.destroy();

    const surface = try window.createSurface(instance.handle);
    defer vki().destroySurfaceKHR(instance.handle, surface, instance.allocation_callbacks);

    const physical_device = try vkk.PhysicalDevice.select(allocator, &instance, surface, .{
        .transfer_queue = .dedicated,
        .required_extensions = &.{
            "VK_KHR_acceleration_structure",
            "VK_KHR_deferred_host_operations",
            "VK_KHR_ray_tracing_pipeline",
        },
        .required_features = .{
            .sampler_anisotropy = vk.TRUE,
        },
        .required_features_12 = .{
            .descriptor_indexing = vk.TRUE,
        },
        .required_features_13 = .{
            .dynamic_rendering = vk.TRUE,
            .synchronization_2 = vk.TRUE,
        },
    });

    std.log.info("selected {s}", .{physical_device.name()});

    const device = try vkk.Device.create(allocator, &physical_device, null);
    defer device.destroy();

    const queue = device.graphics_queue;
    _ = queue;

    const swapchain = try vkk.Swapchain.create(allocator, &device, surface, .{
        .desired_extent = .{ .width = window_width, .height = window_height },
    });
    defer swapchain.destroy();

    const images = try swapchain.getImages(allocator);
    defer allocator.free(images);

    const image_views = try swapchain.getImageViews(allocator, images);
    defer swapchain.destroyImageViews(allocator, image_views);

    while (!window.shouldClose()) {
        c.glfwPollEvents();
    }
}
