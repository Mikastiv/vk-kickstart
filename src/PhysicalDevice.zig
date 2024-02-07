const std = @import("std");
const vk = @import("vulkan");
const dispatch = @import("dispatch.zig");
const Instance = @import("Instance.zig");
const mem = std.mem;

const vki = dispatch.vki;

// TODO: properties 11,12,13
handle: vk.PhysicalDevice,
surface: vk.SurfaceKHR,
properties: vk.PhysicalDeviceProperties,
memory_properties: vk.PhysicalDeviceMemoryProperties,
features: vk.PhysicalDeviceFeatures,
features_11: vk.PhysicalDeviceVulkan11Features,
features_12: vk.PhysicalDeviceVulkan12Features,
features_13: vk.PhysicalDeviceVulkan13Features,
extensions: std.ArrayList([*:0]const u8),
graphics_family: u32,
present_family: u32,
transfer_family: ?u32,
compute_family: ?u32,

pub const QueuePreference = enum {
    none,
    dedicated,
    separate,
};

pub const Config = struct {
    name: ?[*:0]const u8 = null,
    required_api_version: u32 = vk.API_VERSION_1_0,
    preferred_type: vk.PhysicalDeviceType = .discrete_gpu,
    transfer_queue: QueuePreference = .none,
    compute_queue: QueuePreference = .none,
    required_mem_size: vk.DeviceSize = 0,
    required_features: vk.PhysicalDeviceFeatures = .{},
    required_features_11: vk.PhysicalDeviceVulkan11Features = .{},
    required_features_12: vk.PhysicalDeviceVulkan12Features = .{},
    required_features_13: vk.PhysicalDeviceVulkan13Features = .{},
    required_extensions: []const [*:0]const u8 = &.{},
};

pub fn init(
    allocator: mem.Allocator,
    instance: *const Instance,
    surface: vk.SurfaceKHR,
    config: Config,
) !@This() {
    const physical_device_handles = try getPhysicalDevices(allocator, instance.handle);
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
        const physical_device = try fetchPhysicalDeviceInfo(allocator, handle, surface, instance.api_version);
        try physical_device_infos.append(physical_device);
    }

    for (physical_device_infos.items) |*info| {
        info.suitable = try isDeviceSuitable(info, surface, config);
    }

    const selected = physical_device_infos.items[0];
    if (!selected.suitable) return error.NoSuitableDeviceFound;

    var extensions = std.ArrayList([*:0]const u8).init(allocator);
    errdefer {
        for (extensions.items) |ext| {
            const span = std.mem.span(ext);
            allocator.free(span);
        }
        extensions.deinit();
    }

    for (config.required_extensions) |ext| {
        try appendExtension(&extensions, ext);
    }

    if (selected.portability_ext_available) {
        try appendExtension(&extensions, vk.extension_info.khr_portability_subset.name);
    }

    try appendExtension(&extensions, vk.extension_info.khr_swapchain.name);

    return .{
        .handle = selected.handle,
        .surface = surface,
        .features = config.required_features,
        .features_11 = config.required_features_11,
        .features_12 = config.required_features_12,
        .features_13 = config.required_features_13,
        .properties = selected.properties,
        .memory_properties = selected.memory_properties,
        .extensions = extensions,
        .graphics_family = selected.graphics_family.?,
        .present_family = selected.present_family.?,
        .transfer_family = switch (config.transfer_queue) {
            .none => null,
            .dedicated => selected.dedicated_transfer_family,
            .separate => selected.separate_transfer_family,
        },
        .compute_family = switch (config.compute_queue) {
            .none => null,
            .dedicated => selected.dedicated_compute_family,
            .separate => selected.separate_compute_family,
        },
    };
}

pub fn deinit(self: *@This()) void {
    for (self.extensions.items) |ext| {
        const span = std.mem.span(ext);
        self.extensions.allocator.free(span);
    }
    self.extensions.deinit();
}

pub fn name(self: *const @This()) []const u8 {
    const str: [*:0]const u8 = @ptrCast(&self.properties.device_name);
    return mem.span(str);
}

pub fn clone(self: *const @This()) !@This() {
    const exts_copy = try self.extensions.clone();
    for (exts_copy.items) |*ext| {
        const span = std.mem.span(ext.*);
        ext.* = try self.extensions.allocator.dupeZ(u8, span);
    }

    var copy = self.*;
    copy.extensions = exts_copy;

    return copy;
}

const PhysicalDeviceInfo = struct {
    handle: vk.PhysicalDevice,
    features: vk.PhysicalDeviceFeatures,
    features_11: vk.PhysicalDeviceVulkan11Features,
    features_12: vk.PhysicalDeviceVulkan12Features,
    features_13: vk.PhysicalDeviceVulkan13Features,
    properties: vk.PhysicalDeviceProperties,
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    available_extensions: []vk.ExtensionProperties,
    queue_families: []vk.QueueFamilyProperties,
    graphics_family: ?u32,
    present_family: ?u32,
    dedicated_transfer_family: ?u32,
    dedicated_compute_family: ?u32,
    separate_transfer_family: ?u32,
    separate_compute_family: ?u32,
    portability_ext_available: bool,
    suitable: bool = true,
};

fn appendExtension(extensions: *std.ArrayList([*:0]const u8), new: [*:0]const u8) !void {
    const span = std.mem.span(new);
    const copy = try extensions.allocator.dupeZ(u8, span);
    try extensions.append(copy);
}

fn getPresentQueue(
    handle: vk.PhysicalDevice,
    families: []vk.QueueFamilyProperties,
    surface: vk.SurfaceKHR,
) !?u32 {
    for (families, 0..) |family, i| {
        if (family.queue_count == 0) continue;

        const idx: u32 = @intCast(i);

        if (try vki().getPhysicalDeviceSurfaceSupportKHR(handle, idx, surface) == vk.TRUE) {
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

fn getQueueNoGraphics(
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

fn comparePhysicalDevices(config: Config, a: PhysicalDeviceInfo, b: PhysicalDeviceInfo) bool {
    if (a.suitable != b.suitable) {
        return a.suitable;
    }

    const a_is_prefered_type = a.properties.device_type == config.preferred_type;
    const b_is_prefered_type = b.properties.device_type == config.preferred_type;
    if (a_is_prefered_type != b_is_prefered_type) {
        return a_is_prefered_type;
    }

    if (a.properties.api_version != b.properties.api_version) {
        return a.properties.api_version >= b.properties.api_version;
    }

    // TODO: more checks
}

fn isDeviceSuitable(
    device: *const PhysicalDeviceInfo,
    surface: vk.SurfaceKHR,
    config: Config,
) !bool {
    if (config.name) |n| {
        const device_name: [*:0]const u8 = @ptrCast(&device.properties.device_name);
        if (mem.orderZ(u8, n, device_name) != .eq) return false;
    }

    if (device.properties.api_version < config.required_api_version) return false;

    if (config.transfer_queue == .dedicated and device.dedicated_transfer_family == null) return false;
    if (config.transfer_queue == .separate and device.separate_transfer_family == null) return false;
    if (config.compute_queue == .dedicated and device.dedicated_compute_family == null) return false;
    if (config.compute_queue == .separate and device.separate_compute_family == null) return false;

    if (!supportsRequiredFeatures(device.features, config.required_features)) return false;
    if (!supportsRequiredFeatures11(device.features_11, config.required_features_11)) return false;
    if (!supportsRequiredFeatures12(device.features_12, config.required_features_12)) return false;
    if (!supportsRequiredFeatures13(device.features_13, config.required_features_13)) return false;

    for (config.required_extensions) |ext| {
        if (!isExtensionAvailable(device.available_extensions, ext)) {
            return false;
        }
    }

    if (device.graphics_family == null or device.present_family == null) return false;
    if (!isExtensionAvailable(device.available_extensions, vk.extension_info.khr_swapchain.name)) {
        return false;
    }
    if (!try isCompatibleWithSurface(device.handle, surface)) {
        return false;
    }

    const heap_count = device.memory_properties.memory_heap_count;
    for (device.memory_properties.memory_heaps[0..heap_count]) |heap| {
        if (heap.flags.device_local_bit and heap.size >= config.required_mem_size) {
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

fn supportsRequiredFeatures11(available: vk.PhysicalDeviceVulkan11Features, required: vk.PhysicalDeviceVulkan11Features) bool {
    if (required.storage_buffer_16_bit_access == vk.TRUE and available.storage_buffer_16_bit_access == vk.FALSE) return false;
    if (required.uniform_and_storage_buffer_16_bit_access == vk.TRUE and available.uniform_and_storage_buffer_16_bit_access == vk.FALSE) return false;
    if (required.storage_push_constant_16 == vk.TRUE and available.storage_push_constant_16 == vk.FALSE) return false;
    if (required.storage_input_output_16 == vk.TRUE and available.storage_input_output_16 == vk.FALSE) return false;
    if (required.multiview == vk.TRUE and available.multiview == vk.FALSE) return false;
    if (required.multiview_geometry_shader == vk.TRUE and available.multiview_geometry_shader == vk.FALSE) return false;
    if (required.multiview_tessellation_shader == vk.TRUE and available.multiview_tessellation_shader == vk.FALSE) return false;
    if (required.variable_pointers_storage_buffer == vk.TRUE and available.variable_pointers_storage_buffer == vk.FALSE) return false;
    if (required.variable_pointers == vk.TRUE and available.variable_pointers == vk.FALSE) return false;
    if (required.protected_memory == vk.TRUE and available.protected_memory == vk.FALSE) return false;
    if (required.sampler_ycbcr_conversion == vk.TRUE and available.sampler_ycbcr_conversion == vk.FALSE) return false;
    if (required.shader_draw_parameters == vk.TRUE and available.shader_draw_parameters == vk.FALSE) return false;
    return true;
}

fn supportsRequiredFeatures12(available: vk.PhysicalDeviceVulkan12Features, required: vk.PhysicalDeviceVulkan12Features) bool {
    if (required.sampler_mirror_clamp_to_edge == vk.TRUE and available.sampler_mirror_clamp_to_edge == vk.FALSE) return false;
    if (required.draw_indirect_count == vk.TRUE and available.draw_indirect_count == vk.FALSE) return false;
    if (required.storage_buffer_8_bit_access == vk.TRUE and available.storage_buffer_8_bit_access == vk.FALSE) return false;
    if (required.uniform_and_storage_buffer_8_bit_access == vk.TRUE and available.uniform_and_storage_buffer_8_bit_access == vk.FALSE) return false;
    if (required.storage_push_constant_8 == vk.TRUE and available.storage_push_constant_8 == vk.FALSE) return false;
    if (required.shader_buffer_int_64_atomics == vk.TRUE and available.shader_buffer_int_64_atomics == vk.FALSE) return false;
    if (required.shader_shared_int_64_atomics == vk.TRUE and available.shader_shared_int_64_atomics == vk.FALSE) return false;
    if (required.shader_float_16 == vk.TRUE and available.shader_float_16 == vk.FALSE) return false;
    if (required.shader_int_8 == vk.TRUE and available.shader_int_8 == vk.FALSE) return false;
    if (required.descriptor_indexing == vk.TRUE and available.descriptor_indexing == vk.FALSE) return false;
    if (required.shader_input_attachment_array_dynamic_indexing == vk.TRUE and available.shader_input_attachment_array_dynamic_indexing == vk.FALSE) return false;
    if (required.shader_uniform_texel_buffer_array_dynamic_indexing == vk.TRUE and available.shader_uniform_texel_buffer_array_dynamic_indexing == vk.FALSE) return false;
    if (required.shader_storage_texel_buffer_array_dynamic_indexing == vk.TRUE and available.shader_storage_texel_buffer_array_dynamic_indexing == vk.FALSE) return false;
    if (required.shader_uniform_buffer_array_non_uniform_indexing == vk.TRUE and available.shader_uniform_buffer_array_non_uniform_indexing == vk.FALSE) return false;
    if (required.shader_sampled_image_array_non_uniform_indexing == vk.TRUE and available.shader_sampled_image_array_non_uniform_indexing == vk.FALSE) return false;
    if (required.shader_storage_buffer_array_non_uniform_indexing == vk.TRUE and available.shader_storage_buffer_array_non_uniform_indexing == vk.FALSE) return false;
    if (required.shader_storage_image_array_non_uniform_indexing == vk.TRUE and available.shader_storage_image_array_non_uniform_indexing == vk.FALSE) return false;
    if (required.shader_input_attachment_array_non_uniform_indexing == vk.TRUE and available.shader_input_attachment_array_non_uniform_indexing == vk.FALSE) return false;
    if (required.shader_uniform_texel_buffer_array_non_uniform_indexing == vk.TRUE and available.shader_uniform_texel_buffer_array_non_uniform_indexing == vk.FALSE) return false;
    if (required.shader_storage_texel_buffer_array_non_uniform_indexing == vk.TRUE and available.shader_storage_texel_buffer_array_non_uniform_indexing == vk.FALSE) return false;
    if (required.descriptor_binding_uniform_buffer_update_after_bind == vk.TRUE and available.descriptor_binding_uniform_buffer_update_after_bind == vk.FALSE) return false;
    if (required.descriptor_binding_sampled_image_update_after_bind == vk.TRUE and available.descriptor_binding_sampled_image_update_after_bind == vk.FALSE) return false;
    if (required.descriptor_binding_storage_image_update_after_bind == vk.TRUE and available.descriptor_binding_storage_image_update_after_bind == vk.FALSE) return false;
    if (required.descriptor_binding_storage_buffer_update_after_bind == vk.TRUE and available.descriptor_binding_storage_buffer_update_after_bind == vk.FALSE) return false;
    if (required.descriptor_binding_uniform_texel_buffer_update_after_bind == vk.TRUE and available.descriptor_binding_uniform_texel_buffer_update_after_bind == vk.FALSE) return false;
    if (required.descriptor_binding_storage_texel_buffer_update_after_bind == vk.TRUE and available.descriptor_binding_storage_texel_buffer_update_after_bind == vk.FALSE) return false;
    if (required.descriptor_binding_update_unused_while_pending == vk.TRUE and available.descriptor_binding_update_unused_while_pending == vk.FALSE) return false;
    if (required.descriptor_binding_partially_bound == vk.TRUE and available.descriptor_binding_partially_bound == vk.FALSE) return false;
    if (required.descriptor_binding_variable_descriptor_count == vk.TRUE and available.descriptor_binding_variable_descriptor_count == vk.FALSE) return false;
    if (required.runtime_descriptor_array == vk.TRUE and available.runtime_descriptor_array == vk.FALSE) return false;
    if (required.sampler_filter_minmax == vk.TRUE and available.sampler_filter_minmax == vk.FALSE) return false;
    if (required.scalar_block_layout == vk.TRUE and available.scalar_block_layout == vk.FALSE) return false;
    if (required.imageless_framebuffer == vk.TRUE and available.imageless_framebuffer == vk.FALSE) return false;
    if (required.uniform_buffer_standard_layout == vk.TRUE and available.uniform_buffer_standard_layout == vk.FALSE) return false;
    if (required.shader_subgroup_extended_types == vk.TRUE and available.shader_subgroup_extended_types == vk.FALSE) return false;
    if (required.separate_depth_stencil_layouts == vk.TRUE and available.separate_depth_stencil_layouts == vk.FALSE) return false;
    if (required.host_query_reset == vk.TRUE and available.host_query_reset == vk.FALSE) return false;
    if (required.timeline_semaphore == vk.TRUE and available.timeline_semaphore == vk.FALSE) return false;
    if (required.buffer_device_address == vk.TRUE and available.buffer_device_address == vk.FALSE) return false;
    if (required.buffer_device_address_capture_replay == vk.TRUE and available.buffer_device_address_capture_replay == vk.FALSE) return false;
    if (required.buffer_device_address_multi_device == vk.TRUE and available.buffer_device_address_multi_device == vk.FALSE) return false;
    if (required.vulkan_memory_model == vk.TRUE and available.vulkan_memory_model == vk.FALSE) return false;
    if (required.vulkan_memory_model_device_scope == vk.TRUE and available.vulkan_memory_model_device_scope == vk.FALSE) return false;
    if (required.vulkan_memory_model_availability_visibility_chains == vk.TRUE and available.vulkan_memory_model_availability_visibility_chains == vk.FALSE) return false;
    if (required.shader_output_viewport_index == vk.TRUE and available.shader_output_viewport_index == vk.FALSE) return false;
    if (required.shader_output_layer == vk.TRUE and available.shader_output_layer == vk.FALSE) return false;
    if (required.subgroup_broadcast_dynamic_id == vk.TRUE and available.subgroup_broadcast_dynamic_id == vk.FALSE) return false;
    return true;
}

fn supportsRequiredFeatures13(available: vk.PhysicalDeviceVulkan13Features, required: vk.PhysicalDeviceVulkan13Features) bool {
    if (required.robust_image_access == vk.TRUE and available.robust_image_access == vk.FALSE) return false;
    if (required.inline_uniform_block == vk.TRUE and available.inline_uniform_block == vk.FALSE) return false;
    if (required.descriptor_binding_inline_uniform_block_update_after_bind == vk.TRUE and available.descriptor_binding_inline_uniform_block_update_after_bind == vk.FALSE) return false;
    if (required.pipeline_creation_cache_control == vk.TRUE and available.pipeline_creation_cache_control == vk.FALSE) return false;
    if (required.private_data == vk.TRUE and available.private_data == vk.FALSE) return false;
    if (required.shader_demote_to_helper_invocation == vk.TRUE and available.shader_demote_to_helper_invocation == vk.FALSE) return false;
    if (required.shader_terminate_invocation == vk.TRUE and available.shader_terminate_invocation == vk.FALSE) return false;
    if (required.subgroup_size_control == vk.TRUE and available.subgroup_size_control == vk.FALSE) return false;
    if (required.compute_full_subgroups == vk.TRUE and available.compute_full_subgroups == vk.FALSE) return false;
    if (required.synchronization_2 == vk.TRUE and available.synchronization_2 == vk.FALSE) return false;
    if (required.texture_compression_astc_hdr == vk.TRUE and available.texture_compression_astc_hdr == vk.FALSE) return false;
    if (required.shader_zero_initialize_workgroup_memory == vk.TRUE and available.shader_zero_initialize_workgroup_memory == vk.FALSE) return false;
    if (required.dynamic_rendering == vk.TRUE and available.dynamic_rendering == vk.FALSE) return false;
    if (required.shader_integer_dot_product == vk.TRUE and available.shader_integer_dot_product == vk.FALSE) return false;
    if (required.maintenance_4 == vk.TRUE and available.maintenance_4 == vk.FALSE) return false;
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
    surface: vk.SurfaceKHR,
    instance_version: u32,
) !PhysicalDeviceInfo {
    const properties = vki().getPhysicalDeviceProperties(handle);
    const memory_properties = vki().getPhysicalDeviceMemoryProperties(handle);

    var features = vk.PhysicalDeviceFeatures{};
    var features_11 = vk.PhysicalDeviceVulkan11Features{};
    var features_12 = vk.PhysicalDeviceVulkan12Features{};
    var features_13 = vk.PhysicalDeviceVulkan13Features{};

    if (instance_version >= vk.API_VERSION_1_2)
        features_11.p_next = &features_12;
    if (instance_version >= vk.API_VERSION_1_3)
        features_12.p_next = &features_13;

    var features2 = vk.PhysicalDeviceFeatures2{ .features = .{} };
    features2.p_next = &features_11;

    vki().getPhysicalDeviceFeatures2(handle, &features2);
    features = features2.features;

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

    const graphics_family = getQueueStrict(queue_families, .{ .graphics_bit = true }, .{});
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
    const separate_transfer = getQueueNoGraphics(
        queue_families,
        .{ .transfer_bit = true },
        .{ .compute_bit = true },
    );
    const separate_compute = getQueueNoGraphics(
        queue_families,
        .{ .compute_bit = true },
        .{ .transfer_bit = true },
    );
    const present_family = try getPresentQueue(handle, queue_families, surface);

    return .{
        .handle = handle,
        .features = features,
        .features_11 = features_11,
        .features_12 = features_12,
        .features_13 = features_13,
        .properties = properties,
        .memory_properties = memory_properties,
        .available_extensions = extensions,
        .queue_families = queue_families,
        .graphics_family = graphics_family,
        .present_family = present_family,
        .dedicated_transfer_family = dedicated_transfer,
        .dedicated_compute_family = dedicated_compute,
        .separate_transfer_family = separate_transfer,
        .separate_compute_family = separate_compute,
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
