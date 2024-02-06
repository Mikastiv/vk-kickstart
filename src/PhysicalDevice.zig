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
    required_version: u32 = vk.API_VERSION_1_0,
    preferred_type: vk.PhysicalDeviceType = .discrete_gpu,
    require_present: bool = true,
    dedicated_transfer_queue: bool = false,
    dedicated_compute_queue: bool = false,
    required_mem_size: vk.DeviceSize = 0,
    extensions: []const [*:0]const u8 = &.{},
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
        const physical_device = try fetchPhysicalDeviceInfo(allocator, handle);
        try physical_device_infos.append(physical_device);
    }

    for (physical_device_infos.items) |*info| {
        info.suitability = try isDeviceSuitable(info, surface, options);
    }

    const selected = physical_device_infos.items[0];
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

const PhysicalDeviceSuitability = enum(u8) {
    not_suitable,
    partially,
    suitable,
};

const PhysicalDeviceInfo = struct {
    handle: vk.PhysicalDevice,
    features: vk.PhysicalDeviceFeatures,
    properties: vk.PhysicalDeviceProperties,
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    available_extensions: []vk.ExtensionProperties,
    queue_families: []vk.QueueFamilyProperties,
    portability_ext_available: bool,
    suitability: PhysicalDeviceSuitability = .suitable,
};

fn getPresentQueue(physical_device: *const PhysicalDeviceInfo, surface: ?vk.SurfaceKHR) !?u32 {
    if (surface == null) return null;

    for (physical_device.queue_families, 0..) |family, i| {
        if (family.queue_count == 0) continue;

        const index: u32 = @intCast(i);

        if (try vki().getPhysicalDeviceSurfaceSupportKHR(physical_device.handle, index, surface.?) == vk.TRUE) {
            return index;
        }
    }
    return null;
}

fn getDedicatedQueue(
    families: []vk.QueueFamilyProperties,
    wanted_flags: vk.QueueFlags,
    unwanted_flags: vk.QueueFlags,
) ?u32 {
    for (families, 0..) |family, i| {
        if (family.queue_count == 0) continue;

        const index: u32 = @intCast(i);

        const has_wanted = family.queue_flags.contains(wanted_flags);
        const no_unwanted = family.queue_flags.intersect(unwanted_flags).toInt() == vk.QueueFlags.toInt(.{});
        if (!family.queue_flags.graphics_bit and has_wanted and no_unwanted) {
            return index;
        }
    }
    return null;
}

fn comparePhysicalDevices(options: Options, a: PhysicalDeviceInfo, b: PhysicalDeviceInfo) bool {
    if (a.suitability != b.suitability) {
        if (a.suitability == .suitable) return true;
        if (b.suitability == .suitable) return false;
        if (a.suitability == .partially) return true;
        return false;
    }

    const a_is_prefered_type = a.properties.device_type == options.preferred_type;
    const b_is_prefered_type = b.properties.device_type == options.preferred_type;
    if (a_is_prefered_type != b_is_prefered_type) {
        return a_is_prefered_type;
    }

    if (a.properties.api_version != b.properties.api_version) {
        return a.properties.api_version > b.properties.api_version;
    }
}

fn isDeviceSuitable(
    physical_device: *const PhysicalDeviceInfo,
    surface: ?vk.SurfaceKHR,
    options: Options,
) !PhysicalDeviceSuitability {
    if (options.name) |n| {
        const device_name: [*:0]const u8 = @ptrCast(&physical_device.properties.device_name);
        if (mem.orderZ(u8, n, device_name) != .eq) return .not_suitable;
    }

    if (options.required_version < physical_device.properties.api_version) return .not_suitable;

    const dedicated_transfer = getDedicatedQueue(
        physical_device.queue_families,
        .{ .transfer_bit = true },
        .{ .compute_bit = true },
    );
    const dedicated_compute = getDedicatedQueue(
        physical_device.queue_families,
        .{ .compute_bit = true },
        .{ .transfer_bit = true },
    );
    const present_queue = try getPresentQueue(physical_device, surface);

    if (options.dedicated_transfer_queue and dedicated_transfer == null) return .not_suitable;
    if (options.dedicated_compute_queue and dedicated_compute == null) return .not_suitable;
    if (options.require_present and present_queue == null) return .not_suitable;

    for (options.extensions) |ext| {
        if (!isExtensionAvailable(physical_device.available_extensions, ext)) {
            return .not_suitable;
        }
    }
    if (options.require_present) {
        if (!isExtensionAvailable(physical_device.available_extensions, vk.extension_info.khr_swapchain.name)) {
            return .not_suitable;
        }
    }

    var suitable = PhysicalDeviceSuitability.suitable;
    if (options.preferred_type != physical_device.properties.device_type) suitable = .partially;

    return suitable;
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

fn fetchPhysicalDeviceInfo(allocator: mem.Allocator, handle: vk.PhysicalDevice) !PhysicalDeviceInfo {
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

    return .{
        .handle = handle,
        .features = features,
        .properties = properties,
        .memory_properties = memory_properties,
        .available_extensions = extensions,
        .queue_families = queue_families,
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
