const vk = @import("vulkan");
const build_options = @import("build_options");

const api: []const vk.ApiInfo = &.{
    vk.features.version_1_0,
    vk.features.version_1_1,
    vk.extensions.khr_surface,
    vk.extensions.khr_swapchain,
    if (build_options.enable_validation) vk.extensions.ext_debug_utils else {},
};

pub const BaseDispatch = vk.BaseWrapper(api);
pub const InstanceDispatch = vk.InstanceWrapper(api);
pub const DeviceDispatch = vk.DeviceWrapper(api);

pub var vkb_table: ?BaseDispatch = null;
pub var vki_table: ?InstanceDispatch = null;
pub var vkd_table: ?DeviceDispatch = null;

pub fn vkb() *const BaseDispatch {
    return &vkb_table.?;
}

pub fn vki() *const InstanceDispatch {
    return &vki_table.?;
}

pub fn vkd() *const DeviceDispatch {
    return &vkd_table.?;
}
