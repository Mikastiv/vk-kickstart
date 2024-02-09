const std = @import("std");
const mem = std.mem;
const vk = @import("vulkan");
const dispatch = @import("dispatch.zig");
const PhysicalDevice = @import("PhysicalDevice.zig");

const vki = dispatch.vki;
const vkd = dispatch.vkd;

handle: vk.Device,
physical_device: PhysicalDevice,
allocation_callbacks: ?*const vk.AllocationCallbacks,
graphics_queue: vk.Queue,
present_queue: vk.Queue,
transfer_queue: ?vk.Queue,
compute_queue: ?vk.Queue,

pub fn create(
    allocator: mem.Allocator,
    physical_device: *const PhysicalDevice,
    allocation_callbacks: ?*const vk.AllocationCallbacks,
) !@This() {
    const queue_create_infos = try createQueueInfos(allocator, physical_device);
    defer allocator.free(queue_create_infos);

    const physical_device_exts = try physical_device.extensions(allocator);
    defer allocator.free(physical_device_exts);
    var enabled_extensions = std.ArrayList([*:0]const u8).init(allocator);
    defer enabled_extensions.deinit();

    try enabled_extensions.appendSlice(physical_device_exts);
    try enabled_extensions.append(vk.extension_info.khr_swapchain.name);

    var features = vk.PhysicalDeviceFeatures2{ .features = physical_device.features };
    var features_11 = physical_device.features_11;
    var features_12 = physical_device.features_12;
    var features_13 = physical_device.features_13;

    features.p_next = &features_11;
    if (physical_device.instance_version >= vk.API_VERSION_1_2)
        features_11.p_next = &features_12;
    if (physical_device.instance_version >= vk.API_VERSION_1_3)
        features_12.p_next = &features_13;

    const device_info = vk.DeviceCreateInfo{
        .queue_create_info_count = @intCast(queue_create_infos.len),
        .p_queue_create_infos = queue_create_infos.ptr,
        .enabled_extension_count = @intCast(enabled_extensions.items.len),
        .pp_enabled_extension_names = enabled_extensions.items.ptr,
        .p_next = &features,
    };

    const handle = try vki().createDevice(physical_device.handle, &device_info, allocation_callbacks);
    try dispatch.initDeviceDispatch(handle);
    errdefer vkd().destroyDevice(handle, allocation_callbacks);

    const graphics_queue = vkd().getDeviceQueue(handle, physical_device.graphics_family_index, 0);
    const present_queue = vkd().getDeviceQueue(handle, physical_device.present_family_index, 0);
    const transfer_queue = if (physical_device.transfer_family_index) |family| vkd().getDeviceQueue(handle, family, 0) else null;
    const compute_queue = if (physical_device.compute_family_index) |family| vkd().getDeviceQueue(handle, family, 0) else null;

    return .{
        .handle = handle,
        .physical_device = physical_device.*,
        .allocation_callbacks = allocation_callbacks,
        .graphics_queue = graphics_queue,
        .present_queue = present_queue,
        .transfer_queue = transfer_queue,
        .compute_queue = compute_queue,
    };
}

pub fn destroy(self: *const @This()) void {
    vkd().destroyDevice(self.handle, self.allocation_callbacks);
}

fn createQueueInfos(allocator: mem.Allocator, physical_device: *const PhysicalDevice) ![]vk.DeviceQueueCreateInfo {
    var unique_queue_families = std.AutoHashMap(u32, void).init(allocator);
    defer unique_queue_families.deinit();

    try unique_queue_families.put(physical_device.graphics_family_index, {});
    try unique_queue_families.put(physical_device.present_family_index, {});
    if (physical_device.transfer_family_index) |idx| {
        try unique_queue_families.put(idx, {});
    }
    if (physical_device.compute_family_index) |idx| {
        try unique_queue_families.put(idx, {});
    }

    var queue_create_infos = std.ArrayList(vk.DeviceQueueCreateInfo).init(allocator);
    errdefer queue_create_infos.deinit();

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

    return queue_create_infos.toOwnedSlice();
}
