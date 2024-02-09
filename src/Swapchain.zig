const std = @import("std");
const mem = std.mem;
const vk = @import("vulkan");
const Device = @import("Device.zig");

const disptach = @import("dispatch.zig");
const vki = disptach.vki;
const vkd = disptach.vkd;

device: vk.Device,
handle: vk.SwapchainKHR,
surface: vk.SurfaceKHR,
image_count: u32,
image_format: vk.Format,
image_usage: vk.ImageUsageFlags,
color_space: vk.ColorSpaceKHR,
extent: vk.Extent2D,
present_mode: vk.PresentModeKHR,
allocation_callbacks: ?*const vk.AllocationCallbacks,

pub const Options = struct {
    desired_extent: vk.Extent2D,
    create_flags: vk.SwapchainCreateFlagsKHR = .{},
    desired_min_image_count: ?u32 = null,
    desired_formats: []const vk.SurfaceFormatKHR = &.{
        // In order of priority
        .{ .format = .b8g8r8a8_srgb, .color_space = .srgb_nonlinear_khr },
    },
    desired_present_modes: []const vk.PresentModeKHR = &.{
        // In order of priority
        .mailbox_khr,
    },
    desired_array_layer_count: u32 = 1,
    image_usage_flags: vk.ImageUsageFlags = .{ .color_attachment_bit = true },
    pre_transform: ?vk.SurfaceTransformFlagsKHR = null,
    composite_alpha: vk.CompositeAlphaFlagsKHR = .{ .opaque_bit_khr = true },
    clipped: vk.Bool32 = vk.TRUE,
    old_swapchain: ?vk.SwapchainKHR = null,
    allocation_callbacks: ?*const vk.AllocationCallbacks = null,
};

pub fn create(
    allocator: mem.Allocator,
    device: *const Device,
    surface: vk.SurfaceKHR,
    options: Options,
) !@This() {
    std.debug.assert(surface != .null_handle);

    const surface_support = try fetchSurfaceSupportDetails(allocator, device.physical_device.handle, surface);
    defer {
        allocator.free(surface_support.formats);
        allocator.free(surface_support.present_modes);
    }

    const image_count = try selectMinImageCount(&surface_support.capabilities, options.desired_min_image_count);
    const format = pickSurfaceFormat(surface_support.formats, options.desired_formats);
    const present_mode = pickPresentMode(surface_support.present_modes, options.desired_present_modes);
    const extent = pickExtent(&surface_support.capabilities, options.desired_extent);

    const array_layer_count = if (surface_support.capabilities.max_image_array_layers < options.desired_array_layer_count)
        surface_support.capabilities.max_image_array_layers
    else
        options.desired_array_layer_count;

    if (isSharedPresentMode(present_mode)) {
        // TODO: Shared present modes check
    } else {
        if (!options.image_usage_flags.contains(surface_support.capabilities.supported_usage_flags))
            return error.UsageFlagsNotSupported;
    }

    const graphics_queue_index = device.physical_device.graphics_family_index;
    const present_queue_index = device.physical_device.present_family_index;
    const same_index = graphics_queue_index == present_queue_index;
    const queue_family_indices = [_]u32{ graphics_queue_index, present_queue_index };

    const swapchain_info = vk.SwapchainCreateInfoKHR{
        .flags = options.create_flags,
        .surface = surface,
        .min_image_count = image_count,
        .image_format = format.format,
        .image_color_space = format.color_space,
        .image_extent = extent,
        .image_array_layers = array_layer_count,
        .image_usage = options.image_usage_flags,
        .image_sharing_mode = if (same_index) .exclusive else .concurrent,
        .queue_family_index_count = if (same_index) 0 else @intCast(queue_family_indices.len),
        .p_queue_family_indices = if (same_index) null else @ptrCast(&queue_family_indices),
        .pre_transform = if (options.pre_transform) |pre_transform| pre_transform else surface_support.capabilities.current_transform,
        .composite_alpha = options.composite_alpha,
        .present_mode = present_mode,
        .clipped = options.clipped,
        .old_swapchain = if (options.old_swapchain) |old| old else .null_handle,
    };
    const swapchain = try vkd().createSwapchainKHR(device.handle, &swapchain_info, options.allocation_callbacks);
    errdefer vkd().destroySwapchainKHR(device.handle, swapchain, options.allocation_callbacks);

    return .{
        .device = device.handle,
        .handle = swapchain,
        .surface = surface,
        .image_count = image_count,
        .image_format = format.format,
        .color_space = format.color_space,
        .extent = extent,
        .image_usage = options.image_usage_flags,
        .present_mode = present_mode,
        .allocation_callbacks = options.allocation_callbacks,
    };
}

pub fn destroy(self: *const @This()) void {
    vkd().destroySwapchainKHR(self.device, self.handle, self.allocation_callbacks);
}

fn isSharedPresentMode(present_mode: vk.PresentModeKHR) bool {
    return present_mode == .immediate_khr or
        present_mode == .mailbox_khr or
        present_mode == .fifo_khr or
        present_mode == .fifo_relaxed_khr;
}

fn pickSurfaceFormat(
    available_formats: []const vk.SurfaceFormatKHR,
    desired_formats: []const vk.SurfaceFormatKHR,
) vk.SurfaceFormatKHR {
    for (desired_formats) |desired| {
        for (available_formats) |available| {
            if (available.format == desired.format and available.color_space == desired.color_space)
                return available;
        }
    }
    return available_formats[0];
}

fn pickPresentMode(
    available_modes: []const vk.PresentModeKHR,
    desired_modes: []const vk.PresentModeKHR,
) vk.PresentModeKHR {
    for (desired_modes) |desired| {
        for (available_modes) |available| {
            if (available == desired)
                return available;
        }
    }
    return .fifo_khr; // This mode is guaranteed to be present
}

fn pickExtent(
    surface_capabilities: *const vk.SurfaceCapabilitiesKHR,
    desired_extent: vk.Extent2D,
) vk.Extent2D {
    if (surface_capabilities.current_extent.width != std.math.maxInt(u32)) {
        return surface_capabilities.current_extent;
    }

    var actual_extent = desired_extent;

    actual_extent.width = std.math.clamp(
        actual_extent.width,
        surface_capabilities.min_image_extent.width,
        surface_capabilities.max_image_extent.width,
    );

    actual_extent.height = std.math.clamp(
        actual_extent.height,
        surface_capabilities.min_image_extent.height,
        surface_capabilities.max_image_extent.height,
    );

    return actual_extent;
}

fn selectMinImageCount(capabilities: *const vk.SurfaceCapabilitiesKHR, desired_min_image_count: ?u32) !u32 {
    const has_max_count = capabilities.max_image_count > 0;
    var image_count = capabilities.min_image_count;
    if (desired_min_image_count) |desired| {
        if (desired < capabilities.min_image_count)
            image_count = capabilities.min_image_count
        else if (has_max_count and desired > capabilities.max_image_count)
            image_count = capabilities.max_image_count
        else
            image_count = desired;
    } else if (has_max_count) {
        image_count = @min(capabilities.min_image_count + 1, capabilities.max_image_count);
    } else {
        image_count = capabilities.min_image_count + 1;
    }

    return image_count;
}

const SurfaceSupportDetails = struct {
    capabilities: vk.SurfaceCapabilitiesKHR,
    formats: []const vk.SurfaceFormatKHR,
    present_modes: []const vk.PresentModeKHR,
};

fn fetchSurfaceSupportDetails(
    allocator: mem.Allocator,
    physical_device: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
) !SurfaceSupportDetails {
    const capabilities = try vki().getPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface);

    var format_count: u32 = 0;
    var result = try vki().getPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, null);
    if (result != .success) return error.EnumeratePhysicalDeviceFormatsFailed;

    const formats = try allocator.alloc(vk.SurfaceFormatKHR, format_count);
    errdefer allocator.free(formats);

    while (true) {
        result = try vki().getPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, formats.ptr);
        if (result == .success) break;
    }

    var present_mode_count: u32 = 0;
    result = try vki().getPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &present_mode_count, null);
    if (result != .success) return error.EnumeratePhysicalDevicePresentModesFailed;

    const present_modes = try allocator.alloc(vk.PresentModeKHR, present_mode_count);
    errdefer allocator.free(present_modes);

    while (true) {
        result = try vki().getPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &present_mode_count, present_modes.ptr);
        if (result == .success) break;
    }

    return .{
        .capabilities = capabilities,
        .formats = formats,
        .present_modes = present_modes,
    };
}
