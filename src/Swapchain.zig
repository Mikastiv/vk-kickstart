const std = @import("std");
const build_options = @import("build_options");
const vk = @import("vulkan-zig");
const Device = @import("Device.zig");
const dispatch = @import("dispatch.zig");

const log = @import("log.zig").vk_kickstart_log;

const vki = dispatch.vki;
const vkd = dispatch.vkd;

const InstanceDispatch = dispatch.InstanceDispatch;
const DeviceDispatch = dispatch.DeviceDispatch;

handle: vk.SwapchainKHR,
device: vk.Device,
surface: vk.SurfaceKHR,
image_count: u32,
image_format: vk.Format,
image_usage: vk.ImageUsageFlags,
color_space: vk.ColorSpaceKHR,
extent: vk.Extent2D,
present_mode: vk.PresentModeKHR,
allocation_callbacks: ?*const vk.AllocationCallbacks,

pub const CreateOptions = struct {
    /// Desired size (in pixels) of the swapchain image(s).
    /// These values will be clamped within the capabilities of the device
    desired_extent: vk.Extent2D,
    /// Swapchain create flags
    create_flags: vk.SwapchainCreateFlagsKHR = .{},
    /// Desired minimum number of presentable images that the application needs.
    /// If left on default, will try to use the minimum of the device + 1.
    /// This value will be clamped between the device's minimum and maximum (if there is a max).
    desired_min_image_count: ?u32 = null,
    /// Array of desired image formats, in order of priority.
    /// Will fallback to the first found if none match
    desired_formats: []const vk.SurfaceFormatKHR = &.{
        .{ .format = .b8g8r8a8_srgb, .color_space = .srgb_nonlinear_khr },
    },
    /// Array of desired present modes, in order of priority.
    /// Will fallback to fifo_khr is none match
    desired_present_modes: []const vk.PresentModeKHR = &.{
        .mailbox_khr,
    },
    /// Desired number of views in a multiview/stereo surface.
    /// Will be clamped down if higher than device's max
    desired_array_layer_count: u32 = 1,
    /// Intended usage of the (acquired) swapchain images
    image_usage_flags: vk.ImageUsageFlags = .{ .color_attachment_bit = true },
    /// Value describing the transform, relative to the presentation engine’s natural orientation, applied to the image content prior to presentation
    pre_transform: ?vk.SurfaceTransformFlagsKHR = null,
    /// Value indicating the alpha compositing mode to use when this surface is composited together with other surfaces on certain window systems
    composite_alpha: vk.CompositeAlphaFlagsKHR = .{ .opaque_bit_khr = true },
    /// Discard rendering operation that are not visible
    clipped: vk.Bool32 = vk.TRUE,
    /// Existing non-retired swapchain currently associated with surface
    old_swapchain: ?vk.SwapchainKHR = null,
    /// pNext chain
    p_next_chain: ?*anyopaque = null,
    /// Vulkan allocation callbacks
    allocation_callbacks: ?*const vk.AllocationCallbacks = null,
};

const Error = error{
    OutOfMemory,
    UsageFlagsNotSupported,
    GetPhysicalDeviceFormatsFailed,
    GetPhysicalDevicePresentModesFailed,
};

pub const CreateError = Error ||
    InstanceDispatch.GetPhysicalDeviceSurfaceCapabilitiesKHRError ||
    InstanceDispatch.GetPhysicalDeviceSurfaceFormatsKHRError ||
    InstanceDispatch.GetPhysicalDeviceSurfacePresentModesKHRError ||
    DeviceDispatch.CreateSwapchainKHRError;

pub fn create(
    allocator: std.mem.Allocator,
    device: *const Device,
    surface: vk.SurfaceKHR,
    options: CreateOptions,
) CreateError!@This() {
    std.debug.assert(surface != .null_handle);

    const surface_support = try getSurfaceSupportDetails(allocator, device.physical_device, surface);
    defer {
        allocator.free(surface_support.formats);
        allocator.free(surface_support.present_modes);
    }

    const image_count = selectMinImageCount(&surface_support.capabilities, options.desired_min_image_count);
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

    const graphics_queue_index = device.graphics_family_index;
    const present_queue_index = device.present_family_index;
    const same_index = graphics_queue_index == present_queue_index;
    const queue_family_indices = [_]u32{ graphics_queue_index, present_queue_index };

    const swapchain_info = vk.SwapchainCreateInfoKHR{
        .p_next = options.p_next_chain,
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

    if (build_options.verbose) {
        log.debug("----- swapchain creation -----", .{});
        log.debug("image count: {d}", .{image_count});
        log.debug("image format: {s}", .{@tagName(format.format)});
        log.debug("color space: {s}", .{@tagName(format.color_space)});
        log.debug("present mode: {s}", .{@tagName(present_mode)});
        log.debug("extent: {d}x{d}", .{ extent.width, extent.height });
    }

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

pub const GetImagesError = error{ OutOfMemory, GetSwapchainImagesFailed } ||
    DeviceDispatch.GetSwapchainImagesKHRError;

/// Returns an array of the swapchain's images
///
/// Caller owns the memory
pub fn getImages(self: *const @This(), allocator: std.mem.Allocator) GetImagesError![]vk.Image {
    var image_count: u32 = 0;
    var result = try vkd().getSwapchainImagesKHR(self.device, self.handle, &image_count, null);
    if (result != .success) return error.GetSwapchainImagesFailed;

    const images = try allocator.alloc(vk.Image, image_count);
    errdefer allocator.free(images);

    while (true) {
        result = try vkd().getSwapchainImagesKHR(self.device, self.handle, &image_count, images.ptr);
        if (result == .success) break;
    }

    return images;
}

pub const GetImageViewsError = error{OutOfMemory} || DeviceDispatch.CreateImageViewError;

/// Returns an array of image views to the images
///
/// Caller owns the memory
pub fn getImageViews(
    self: *const @This(),
    allocator: std.mem.Allocator,
    images: []const vk.Image,
) GetImageViewsError![]vk.ImageView {
    var image_views = try std.ArrayList(vk.ImageView).initCapacity(allocator, images.len);
    errdefer {
        for (image_views.items) |view| {
            vkd().destroyImageView(self.device, view, self.allocation_callbacks);
        }
        image_views.deinit();
    }

    for (images) |image| {
        const image_view_info = vk.ImageViewCreateInfo{
            .image = image,
            .view_type = .@"2d",
            .format = self.image_format,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };

        const view = try vkd().createImageView(self.device, &image_view_info, self.allocation_callbacks);
        try image_views.append(view);
    }

    return image_views.toOwnedSlice();
}

/// Destroys and frees the image views
pub fn destroyImageViews(
    self: *const @This(),
    allocator: std.mem.Allocator,
    image_views: []const vk.ImageView,
) void {
    for (image_views) |view| {
        vkd().destroyImageView(self.device, view, self.allocation_callbacks);
    }
    allocator.free(image_views);
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

fn selectMinImageCount(capabilities: *const vk.SurfaceCapabilitiesKHR, desired_min_image_count: ?u32) u32 {
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

fn getSurfaceSupportDetails(
    allocator: std.mem.Allocator,
    physical_device: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
) !SurfaceSupportDetails {
    const capabilities = try vki().getPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface);

    var format_count: u32 = 0;
    var result = try vki().getPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, null);
    if (result != .success) return error.GetPhysicalDeviceFormatsFailed;

    const formats = try allocator.alloc(vk.SurfaceFormatKHR, format_count);
    errdefer allocator.free(formats);

    while (true) {
        result = try vki().getPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, formats.ptr);
        if (result == .success) break;
    }

    var present_mode_count: u32 = 0;
    result = try vki().getPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &present_mode_count, null);
    if (result != .success) return error.GetPhysicalDevicePresentModesFailed;

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
