const std = @import("std");
const mem = std.mem;
const vk = @import("vulkan");
const dispatch = @import("dispatch.zig");
const PhysicalDevice = @import("PhysicalDevice.zig");

const vki = dispatch.vki;
const vkd = dispatch.vkd;

handle: vk.Device,
physical_device: PhysicalDevice,
surface: vk.SurfaceKHR,
allocation_callbacks: ?*const vk.AllocationCallbacks,
graphics_queue: vk.Queue,
present_queue: vk.Queue,
transfer_queue: ?vk.Queue,
compute_queue: ?vk.Queue,

pub fn init(
    allocator: mem.Allocator,
    physical_device: *const PhysicalDevice,
    allocation_callbacks: ?*const vk.AllocationCallbacks,
) !@This() {
    const queue_create_infos = try createQueueInfos(allocator, physical_device);
    defer allocator.free(queue_create_infos);

    const device_info = vk.DeviceCreateInfo{
        .queue_create_info_count = @intCast(queue_create_infos.len),
        .p_queue_create_infos = queue_create_infos.ptr,
        .p_enabled_features = &physical_device.features,
        .enabled_extension_count = @intCast(physical_device.extensions.items.len),
        .pp_enabled_extension_names = physical_device.extensions.items.ptr,
    };

    const handle = try vki().createDevice(physical_device.handle, &device_info, allocation_callbacks);
    try dispatch.initDeviceDispatch(handle);
    errdefer vkd().destroyDevice(handle, allocation_callbacks);

    const graphics_queue = vkd().getDeviceQueue(handle, physical_device.graphics_family, 0);
    const present_queue = vkd().getDeviceQueue(handle, physical_device.present_family, 0);
    const transfer_queue = if (physical_device.transfer_family) |family| vkd().getDeviceQueue(handle, family, 0) else null;
    const compute_queue = if (physical_device.compute_family) |family| vkd().getDeviceQueue(handle, family, 0) else null;

    return .{
        .handle = handle,
        .physical_device = try physical_device.clone(),
        .surface = physical_device.surface,
        .allocation_callbacks = allocation_callbacks,
        .graphics_queue = graphics_queue,
        .present_queue = present_queue,
        .transfer_queue = transfer_queue,
        .compute_queue = compute_queue,
    };
}

pub fn deinit(self: *@This()) void {
    self.physical_device.deinit();
    vkd().destroyDevice(self.handle, self.allocation_callbacks);
}

fn createQueueInfos(allocator: mem.Allocator, physical_device: *const PhysicalDevice) ![]vk.DeviceQueueCreateInfo {
    var unique_queue_families = std.AutoHashMap(u32, void).init(allocator);
    defer unique_queue_families.deinit();

    try unique_queue_families.put(physical_device.graphics_family, {});
    try unique_queue_families.put(physical_device.present_family, {});
    if (physical_device.transfer_family) |idx| {
        try unique_queue_families.put(idx, {});
    }
    if (physical_device.compute_family) |idx| {
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
