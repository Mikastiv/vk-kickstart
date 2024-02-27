const std = @import("std");
const build_options = @import("build_options");
const vk = @import("vulkan-zig");
const dispatch = @import("dispatch.zig");
const PhysicalDevice = @import("PhysicalDevice.zig");
const Device = @This();

const log = @import("log.zig").vk_kickstart_log;

const vki = dispatch.vki;
const vkd = dispatch.vkd;

const InstanceDispatch = dispatch.InstanceDispatch;

handle: vk.Device,
physical_device: vk.PhysicalDevice,
surface: vk.SurfaceKHR,
allocation_callbacks: ?*const vk.AllocationCallbacks,
graphics_queue: vk.Queue,
present_queue: vk.Queue,
transfer_queue: ?vk.Queue,
compute_queue: ?vk.Queue,
graphics_queue_index: u32,
present_queue_index: u32,
transfer_queue_index: ?u32,
compute_queue_index: ?u32,

const Error = error{
    OutOfMemory,
    CommandLoadFailure,
};

const CreateError = Error ||
    InstanceDispatch.CreateDeviceError;

pub fn create(
    physical_device: *const PhysicalDevice,
    p_next_chain: ?*anyopaque,
    allocation_callbacks: ?*const vk.AllocationCallbacks,
) CreateError!Device {
    std.debug.assert(physical_device.handle != .null_handle);

    const fixed_buffer_size =
        PhysicalDevice.max_unique_queues * @sizeOf(vk.DeviceQueueCreateInfo) +
        PhysicalDevice.max_unique_queues * 128; // Space for hashmap data
    var fixed_buffer: [fixed_buffer_size]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fixed_buffer);

    const queue_create_infos = try createQueueInfos(&fba, physical_device);

    var extensions_buffer: [PhysicalDevice.max_enabled_extensions][*:0]u8 = undefined;
    const enabled_extensions = physical_device.getExtensions(&extensions_buffer);

    var features = vk.PhysicalDeviceFeatures2{ .features = physical_device.features };
    var features_11 = physical_device.features_11;
    var features_12 = physical_device.features_12;
    var features_13 = physical_device.features_13;

    features.p_next = &features_11;
    if (physical_device.properties.api_version >= vk.API_VERSION_1_3) {
        features_11.p_next = &features_12;
        features_12.p_next = &features_13;
        features_13.p_next = p_next_chain;
    } else if (physical_device.properties.api_version >= vk.API_VERSION_1_2) {
        features_11.p_next = &features_12;
        features_12.p_next = p_next_chain;
    } else {
        features_11.p_next = p_next_chain;
    }

    const device_info = vk.DeviceCreateInfo{
        .queue_create_info_count = @intCast(queue_create_infos.len),
        .p_queue_create_infos = queue_create_infos.ptr,
        .enabled_extension_count = @intCast(enabled_extensions.len),
        .pp_enabled_extension_names = enabled_extensions.ptr,
        .p_next = &features,
    };

    const handle = try vki().createDevice(physical_device.handle, &device_info, allocation_callbacks);
    try dispatch.initDeviceDispatch(handle);
    errdefer vkd().destroyDevice(handle, allocation_callbacks);

    if (build_options.verbose) {
        log.debug("----- device creation -----", .{});
        log.debug("queue count: {d}", .{queue_create_infos.len});
        log.debug("graphics queue family index: {d}", .{physical_device.graphics_queue_index});
        log.debug("present queue family index: {d}", .{physical_device.present_queue_index});
        if (physical_device.transfer_queue_index) |family| {
            log.debug("transfer queue family index: {d}", .{family});
        }
        if (physical_device.compute_queue_index) |family| {
            log.debug("compute queue family index: {d}", .{family});
        }

        log.debug("enabled extensions:", .{});
        for (enabled_extensions) |ext| {
            log.debug("- {s}", .{ext});
        }

        log.debug("enabled features:", .{});
        printEnabledFeatures(vk.PhysicalDeviceFeatures, features.features);
        log.debug("enabled features (vulkan 1.1):", .{});
        printEnabledFeatures(vk.PhysicalDeviceVulkan11Features, features_11);
        if (physical_device.properties.api_version >= vk.API_VERSION_1_2) {
            log.debug("enabled features (vulkan 1.2):", .{});
            printEnabledFeatures(vk.PhysicalDeviceVulkan12Features, features_12);
        }
        if (physical_device.properties.api_version >= vk.API_VERSION_1_3) {
            log.debug("enabled features (vulkan 1.3):", .{});
            printEnabledFeatures(vk.PhysicalDeviceVulkan13Features, features_13);
        }
    }

    const graphics_queue = vkd().getDeviceQueue(handle, physical_device.graphics_queue_index, 0);
    const present_queue = vkd().getDeviceQueue(handle, physical_device.present_queue_index, 0);
    const transfer_queue = if (physical_device.transfer_queue_index) |family| vkd().getDeviceQueue(handle, family, 0) else null;
    const compute_queue = if (physical_device.compute_queue_index) |family| vkd().getDeviceQueue(handle, family, 0) else null;

    return .{
        .handle = handle,
        .physical_device = physical_device.handle,
        .surface = physical_device.surface,
        .allocation_callbacks = allocation_callbacks,
        .graphics_queue = graphics_queue,
        .present_queue = present_queue,
        .transfer_queue = transfer_queue,
        .compute_queue = compute_queue,
        .graphics_queue_index = physical_device.graphics_queue_index,
        .present_queue_index = physical_device.present_queue_index,
        .transfer_queue_index = physical_device.transfer_queue_index,
        .compute_queue_index = physical_device.compute_queue_index,
    };
}

pub fn destroy(self: *const Device) void {
    vkd().destroyDevice(self.handle, self.allocation_callbacks);
}

fn printEnabledFeatures(comptime T: type, features: T) void {
    const info = @typeInfo(T);
    if (info != .Struct) @compileError("must be a struct");
    inline for (info.Struct.fields) |field| {
        if (field.type == vk.Bool32 and @field(features, field.name) != 0) {
            log.debug(" - {s}", .{field.name});
        }
    }
}

fn createQueueInfos(
    fba: *std.heap.FixedBufferAllocator,
    physical_device: *const PhysicalDevice,
) ![]vk.DeviceQueueCreateInfo {
    const allocator = fba.allocator();
    var unique_queue_families = std.AutoHashMap(u32, void).init(allocator);

    try unique_queue_families.put(physical_device.graphics_queue_index, {});
    try unique_queue_families.put(physical_device.present_queue_index, {});
    if (physical_device.transfer_queue_index) |idx| {
        try unique_queue_families.put(idx, {});
    }
    if (physical_device.compute_queue_index) |idx| {
        try unique_queue_families.put(idx, {});
    }

    var queue_create_infos = try std.ArrayList(vk.DeviceQueueCreateInfo).initCapacity(
        allocator,
        PhysicalDevice.max_unique_queues,
    );

    const queue_priorities = [_]f32{1};

    var it = unique_queue_families.iterator();
    while (it.next()) |queue_family| {
        const queue_create_info = vk.DeviceQueueCreateInfo{
            .queue_family_index = queue_family.key_ptr.*,
            .queue_count = @intCast(queue_priorities.len),
            .p_queue_priorities = &queue_priorities,
        };
        try queue_create_infos.append(queue_create_info);
    }

    return queue_create_infos.items;
}
