const std = @import("std");
const vk = @import("vulkan");
const dispatch = @import("dispatch.zig");
const mem = std.mem;

const vki = dispatch.vki;

handle: vk.PhysicalDevice,
features: vk.PhysicalDeviceFeatures,
properties: vk.PhysicalDeviceProperties,
memory_properties: vk.PhysicalDeviceMemoryProperties,

pub const Options = struct {
    name: ?[*:0]const u8 = null,
    required_api_version: u32 = vk.API_VERSION_1_0,
    preferred_type: vk.PhysicalDeviceType = .discrete_gpu,
    require_present: bool = true,
    dedicated_transfer_queue: bool = false,
    dedicated_compute_queue: bool = false,
    separate_transfer_queue: bool = false,
    separate_compute_queue: bool = false,
    required_mem_size: vk.DeviceSize = 0,
    required_features: vk.PhysicalDeviceFeatures = .{},
    required_extensions: []const [*:0]const u8 = &.{},
};

pub fn init(
    allocator: mem.Allocator,
    instance: vk.Instance,
    surface: ?vk.SurfaceKHR,
    options: Options,
) !@This() {
    if (options.require_present and surface == null) {
        return error.NoSurfaceProvided;
    }

    const physical_device_handles = try getPhysicalDevices(allocator, instance);
    defer allocator.free(physical_device_handles);

    var physical_device_infos = try std.ArrayList(PhysicalDeviceInfo).initCapacity(allocator, physical_device_handles.len);
    defer {
        for (physical_device_infos.items) |info| {
            allocator.free(info.available_extensions);
            allocator.free(info.queue_families);
        }
        physical_device_infos.deinit();
    }
    for (physical_device_handles) |handle| {
        const physical_device = try fetchPhysicalDeviceInfo(allocator, handle, surface);
        try physical_device_infos.append(physical_device);
    }

    for (physical_device_infos.items) |*info| {
        info.suitable = try isDeviceSuitable(info, surface, options);
    }

    const selected = physical_device_infos.items[0];
    if (!selected.suitable) return error.NoSuitableDeviceFound;

    return .{
        .handle = selected.handle,
        .features = selected.features,
        .properties = selected.properties,
        .memory_properties = selected.memory_properties,
    };
}

pub fn deinit(self: @This()) void {
    _ = self;
}

pub fn name(self: *const @This()) []const u8 {
    const str: [*:0]const u8 = @ptrCast(&self.properties.device_name);
    return mem.span(str);
}

const PhysicalDeviceInfo = struct {
    handle: vk.PhysicalDevice,
    features: vk.PhysicalDeviceFeatures,
    properties: vk.PhysicalDeviceProperties,
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    available_extensions: []vk.ExtensionProperties,
    queue_families: []vk.QueueFamilyProperties,
    graphics_queue_idx: ?u32,
    present_queue_idx: ?u32,
    dedicated_transfer_queue_idx: ?u32,
    dedicated_compute_queue_idx: ?u32,
    separate_transfer_queue_idx: ?u32,
    separate_compute_queue_idx: ?u32,
    portability_ext_available: bool,
    suitable: bool = true,
};

fn getPresentQueue(
    handle: vk.PhysicalDevice,
    families: []vk.QueueFamilyProperties,
    surface: ?vk.SurfaceKHR,
) !?u32 {
    if (surface == null) return null;

    for (families, 0..) |family, i| {
        if (family.queue_count == 0) continue;

        const idx: u32 = @intCast(i);

        if (try vki().getPhysicalDeviceSurfaceSupportKHR(handle, idx, surface.?) == vk.TRUE) {
            return idx;
        }
    }
    return null;
}

fn getQueueStrict(
    families: []vk.QueueFamilyProperties,
    wanted_flags: vk.QueueFlags,
    unwanted_flags: vk.QueueFlags,
) ?u32 {
    for (families, 0..) |family, i| {
        if (family.queue_count == 0) continue;

        const idx: u32 = @intCast(i);

        const has_wanted = family.queue_flags.contains(wanted_flags);
        const no_unwanted = family.queue_flags.intersect(unwanted_flags).toInt() == vk.QueueFlags.toInt(.{});
        if (has_wanted and no_unwanted) {
            return idx;
        }
    }
    return null;
}

fn getQueue(
    families: []vk.QueueFamilyProperties,
    wanted_flags: vk.QueueFlags,
    unwanted_flags: vk.QueueFlags,
) ?u32 {
    var index: ?u32 = null;
    for (families, 0..) |family, i| {
        if (family.queue_count == 0 or family.queue_flags.graphics_bit) continue;

        const idx: u32 = @intCast(i);

        const has_wanted = family.queue_flags.contains(wanted_flags);
        const no_unwanted = family.queue_flags.intersect(unwanted_flags).toInt() == vk.QueueFlags.toInt(.{});
        if (has_wanted) {
            if (no_unwanted) return idx;
            if (index == null) index = idx;
        }
    }
    return index;
}

fn comparePhysicalDevices(options: Options, a: PhysicalDeviceInfo, b: PhysicalDeviceInfo) bool {
    if (a.suitable != b.suitable) {
        return a.suitable;
    }

    const a_is_prefered_type = a.properties.device_type == options.preferred_type;
    const b_is_prefered_type = b.properties.device_type == options.preferred_type;
    if (a_is_prefered_type != b_is_prefered_type) {
        return a_is_prefered_type;
    }

    if (a.properties.api_version != b.properties.api_version) {
        return a.properties.api_version >= b.properties.api_version;
    }
}

fn isDeviceSuitable(
    device: *const PhysicalDeviceInfo,
    surface: ?vk.SurfaceKHR,
    options: Options,
) !bool {
    if (options.name) |n| {
        const device_name: [*:0]const u8 = @ptrCast(&device.properties.device_name);
        if (mem.orderZ(u8, n, device_name) != .eq) return false;
    }

    if (device.properties.api_version < options.required_api_version) return false;

    if (options.dedicated_transfer_queue and device.dedicated_transfer_queue_idx == null) return false;
    if (options.dedicated_compute_queue and device.dedicated_compute_queue_idx == null) return false;
    if (options.separate_transfer_queue and device.separate_transfer_queue_idx == null) return false;
    if (options.separate_compute_queue and device.separate_compute_queue_idx == null) return false;

    if (!supportsRequiredFeatures(device.features, options.required_features)) return false;

    for (options.required_extensions) |ext| {
        if (!isExtensionAvailable(device.available_extensions, ext)) {
            return false;
        }
    }

    if (options.require_present) {
        if (device.present_queue_idx == null) return false;
        if (!isExtensionAvailable(device.available_extensions, vk.extension_info.khr_swapchain.name)) {
            return false;
        }
        if (!try isCompatibleWithSurface(device.handle, surface.?)) {
            return false;
        }
    }

    const heap_count = device.memory_properties.memory_heap_count;
    for (device.memory_properties.memory_heaps[0..heap_count]) |heap| {
        if (heap.flags.device_local_bit and heap.size >= options.required_mem_size) {
            break;
        }
    } else {
        return false;
    }

    return true;
}

fn supportsRequiredFeatures(available: vk.PhysicalDeviceFeatures, required: vk.PhysicalDeviceFeatures) bool {
    if (required.alpha_to_one == vk.TRUE and available.alpha_to_one == vk.FALSE) return false;
    if (required.depth_bias_clamp == vk.TRUE and available.depth_bias_clamp == vk.FALSE) return false;
    if (required.depth_bounds == vk.TRUE and available.depth_bounds == vk.FALSE) return false;
    if (required.depth_clamp == vk.TRUE and available.depth_clamp == vk.FALSE) return false;
    if (required.draw_indirect_first_instance == vk.TRUE and available.draw_indirect_first_instance == vk.FALSE) return false;
    if (required.dual_src_blend == vk.TRUE and available.dual_src_blend == vk.FALSE) return false;
    if (required.fill_mode_non_solid == vk.TRUE and available.fill_mode_non_solid == vk.FALSE) return false;
    if (required.fragment_stores_and_atomics == vk.TRUE and available.fragment_stores_and_atomics == vk.FALSE) return false;
    if (required.full_draw_index_uint_32 == vk.TRUE and available.full_draw_index_uint_32 == vk.FALSE) return false;
    if (required.geometry_shader == vk.TRUE and available.geometry_shader == vk.FALSE) return false;
    if (required.image_cube_array == vk.TRUE and available.image_cube_array == vk.FALSE) return false;
    if (required.independent_blend == vk.TRUE and available.independent_blend == vk.FALSE) return false;
    if (required.inherited_queries == vk.TRUE and available.inherited_queries == vk.FALSE) return false;
    if (required.large_points == vk.TRUE and available.large_points == vk.FALSE) return false;
    if (required.logic_op == vk.TRUE and available.logic_op == vk.FALSE) return false;
    if (required.multi_draw_indirect == vk.TRUE and available.multi_draw_indirect == vk.FALSE) return false;
    if (required.multi_viewport == vk.TRUE and available.multi_viewport == vk.FALSE) return false;
    if (required.occlusion_query_precise == vk.TRUE and available.occlusion_query_precise == vk.FALSE) return false;
    if (required.pipeline_statistics_query == vk.TRUE and available.pipeline_statistics_query == vk.FALSE) return false;
    if (required.robust_buffer_access == vk.TRUE and available.robust_buffer_access == vk.FALSE) return false;
    if (required.sample_rate_shading == vk.TRUE and available.sample_rate_shading == vk.FALSE) return false;
    if (required.sampler_anisotropy == vk.TRUE and available.sampler_anisotropy == vk.FALSE) return false;
    if (required.shader_clip_distance == vk.TRUE and available.shader_clip_distance == vk.FALSE) return false;
    if (required.shader_cull_distance == vk.TRUE and available.shader_cull_distance == vk.FALSE) return false;
    if (required.shader_float_64 == vk.TRUE and available.shader_float_64 == vk.FALSE) return false;
    if (required.shader_image_gather_extended == vk.TRUE and available.shader_image_gather_extended == vk.FALSE) return false;
    if (required.shader_int_16 == vk.TRUE and available.shader_int_16 == vk.FALSE) return false;
    if (required.shader_int_64 == vk.TRUE and available.shader_int_64 == vk.FALSE) return false;
    if (required.shader_resource_min_lod == vk.TRUE and available.shader_resource_min_lod == vk.FALSE) return false;
    if (required.shader_resource_residency == vk.TRUE and available.shader_resource_residency == vk.FALSE) return false;
    if (required.shader_tessellation_and_geometry_point_size == vk.TRUE and available.shader_tessellation_and_geometry_point_size == vk.FALSE) return false;
    if (required.shader_sampled_image_array_dynamic_indexing == vk.TRUE and available.shader_sampled_image_array_dynamic_indexing == vk.FALSE) return false;
    if (required.shader_storage_buffer_array_dynamic_indexing == vk.TRUE and available.shader_storage_buffer_array_dynamic_indexing == vk.FALSE) return false;
    if (required.shader_storage_image_array_dynamic_indexing == vk.TRUE and available.shader_storage_image_array_dynamic_indexing == vk.FALSE) return false;
    if (required.shader_storage_image_extended_formats == vk.TRUE and available.shader_storage_image_extended_formats == vk.FALSE) return false;
    if (required.shader_storage_image_multisample == vk.TRUE and available.shader_storage_image_multisample == vk.FALSE) return false;
    if (required.shader_storage_image_read_without_format == vk.TRUE and available.shader_storage_image_read_without_format == vk.FALSE) return false;
    if (required.shader_storage_image_write_without_format == vk.TRUE and available.shader_storage_image_write_without_format == vk.FALSE) return false;
    if (required.shader_uniform_buffer_array_dynamic_indexing == vk.TRUE and available.shader_uniform_buffer_array_dynamic_indexing == vk.FALSE) return false;
    if (required.sparse_binding == vk.TRUE and available.sparse_binding == vk.FALSE) return false;
    if (required.sparse_residency_2_samples == vk.TRUE and available.sparse_residency_2_samples == vk.FALSE) return false;
    if (required.sparse_residency_4_samples == vk.TRUE and available.sparse_residency_4_samples == vk.FALSE) return false;
    if (required.sparse_residency_8_samples == vk.TRUE and available.sparse_residency_8_samples == vk.FALSE) return false;
    if (required.sparse_residency_16_samples == vk.TRUE and available.sparse_residency_16_samples == vk.FALSE) return false;
    if (required.sparse_residency_aliased == vk.TRUE and available.sparse_residency_aliased == vk.FALSE) return false;
    if (required.sparse_residency_buffer == vk.TRUE and available.sparse_residency_buffer == vk.FALSE) return false;
    if (required.sparse_residency_image_2d == vk.TRUE and available.sparse_residency_image_2d == vk.FALSE) return false;
    if (required.sparse_residency_image_3d == vk.TRUE and available.sparse_residency_image_3d == vk.FALSE) return false;
    if (required.tessellation_shader == vk.TRUE and available.tessellation_shader == vk.FALSE) return false;
    if (required.texture_compression_astc_ldr == vk.TRUE and available.texture_compression_astc_ldr == vk.FALSE) return false;
    if (required.texture_compression_bc == vk.TRUE and available.texture_compression_bc == vk.FALSE) return false;
    if (required.texture_compression_etc2 == vk.TRUE and available.texture_compression_etc2 == vk.FALSE) return false;
    if (required.variable_multisample_rate == vk.TRUE and available.variable_multisample_rate == vk.FALSE) return false;
    if (required.vertex_pipeline_stores_and_atomics == vk.TRUE and available.vertex_pipeline_stores_and_atomics == vk.FALSE) return false;
    if (required.wide_lines == vk.TRUE and available.wide_lines == vk.FALSE) return false;
    return true;
}

fn isCompatibleWithSurface(handle: vk.PhysicalDevice, surface: vk.SurfaceKHR) !bool {
    var format_count: u32 = 0;
    var result = try vki().getPhysicalDeviceSurfaceFormatsKHR(handle, surface, &format_count, null);
    if (result != .success) return false;

    var present_mode_count: u32 = 0;
    result = try vki().getPhysicalDeviceSurfacePresentModesKHR(handle, surface, &present_mode_count, null);
    if (result != .success) return false;

    return format_count > 0 and present_mode_count > 0;
}

fn isExtensionAvailable(
    available_extensions: []const vk.ExtensionProperties,
    extension: [*:0]const u8,
) bool {
    for (available_extensions) |ext| {
        const n: [*:0]const u8 = @ptrCast(&ext.extension_name);
        if (mem.orderZ(u8, n, extension) == .eq) {
            return true;
        }
    }
    return false;
}

fn fetchPhysicalDeviceInfo(
    allocator: mem.Allocator,
    handle: vk.PhysicalDevice,
    surface: ?vk.SurfaceKHR,
) !PhysicalDeviceInfo {
    const features = vki().getPhysicalDeviceFeatures(handle);
    const properties = vki().getPhysicalDeviceProperties(handle);
    const memory_properties = vki().getPhysicalDeviceMemoryProperties(handle);

    var extension_count: u32 = 0;
    var result = try vki().enumerateDeviceExtensionProperties(handle, null, &extension_count, null);
    if (result != .success) return error.EnumerateDeviceExtensionsFailed;

    const extensions = try allocator.alloc(vk.ExtensionProperties, extension_count);
    errdefer allocator.free(extensions);

    while (true) {
        result = try vki().enumerateDeviceExtensionProperties(handle, null, &extension_count, extensions.ptr);
        if (result == .success) break;
    }

    var family_count: u32 = 0;
    vki().getPhysicalDeviceQueueFamilyProperties(handle, &family_count, null);

    const queue_families = try allocator.alloc(vk.QueueFamilyProperties, family_count);
    errdefer allocator.free(queue_families);

    vki().getPhysicalDeviceQueueFamilyProperties(handle, &family_count, queue_families.ptr);

    const graphics_queue = getQueue(queue_families, .{ .graphics_bit = true }, .{});
    const dedicated_transfer = getQueueStrict(
        queue_families,
        .{ .transfer_bit = true },
        .{ .graphics_bit = true, .compute_bit = true },
    );
    const dedicated_compute = getQueueStrict(
        queue_families,
        .{ .compute_bit = true },
        .{ .graphics_bit = true, .transfer_bit = true },
    );
    const separate_transfer = getQueue(
        queue_families,
        .{ .transfer_bit = true },
        .{ .compute_bit = true },
    );
    const separate_compute = getQueue(
        queue_families,
        .{ .compute_bit = true },
        .{ .transfer_bit = true },
    );
    const present_queue = try getPresentQueue(handle, queue_families, surface);

    return .{
        .handle = handle,
        .features = features,
        .properties = properties,
        .memory_properties = memory_properties,
        .available_extensions = extensions,
        .queue_families = queue_families,
        .graphics_queue_idx = graphics_queue,
        .present_queue_idx = present_queue,
        .dedicated_transfer_queue_idx = dedicated_transfer,
        .dedicated_compute_queue_idx = dedicated_compute,
        .separate_transfer_queue_idx = separate_transfer,
        .separate_compute_queue_idx = separate_compute,
        .portability_ext_available = isExtensionAvailable(extensions, vk.extension_info.khr_portability_subset.name),
    };
}

fn getPhysicalDevices(allocator: mem.Allocator, instance: vk.Instance) ![]vk.PhysicalDevice {
    var device_count: u32 = 0;
    var result = try vki().enumeratePhysicalDevices(instance, &device_count, null);
    if (result != .success) return error.EnumeratePhysicalDevicesFailed;

    const physical_devices = try allocator.alloc(vk.PhysicalDevice, device_count);
    errdefer allocator.free(physical_devices);

    while (true) {
        result = try vki().enumeratePhysicalDevices(instance, &device_count, physical_devices.ptr);
        if (result == .success) break;
    }

    return physical_devices;
}
