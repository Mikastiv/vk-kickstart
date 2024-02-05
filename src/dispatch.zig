const vk = @import("vulkan");
const build_options = @import("build_options");
const root = @import("root");

const instance_functions: vk.InstanceCommandFlags = if (@hasDecl(root, "instance_functions")) root.instance_functions else @compileError("missing instance_functions in root");
const device_functions: vk.DeviceCommandFlags = if (@hasDecl(root, "device_functions")) root.device_functions else @compileError("missing device_functions in root");

var base_init: bool = false;
var base: BaseDispatch = undefined;

var instance_init: bool = false;
var instance: InstanceDispatch = undefined;

var device_init: bool = false;
var device: DeviceDispatch = undefined;

pub fn initBaseDispatch(loader: anytype) !void {
    if (!base_init) {
        base = try BaseDispatch.load(loader);
        base_init = true;
    }
}

pub fn initInstanceDispatch(inst: vk.Instance, loader: anytype) !void {
    if (!instance_init) {
        instance = try InstanceDispatch.load(inst, loader);
        instance_init = true;
    }
}

pub fn initDeviceDispatch(dev: vk.Device) !void {
    if (!device_init) {
        device = try DeviceDispatch.load(dev, instance.dispatch.vkGetDeviceProcAddr);
        device_init = true;
    }
}

pub fn vkb() *const BaseDispatch {
    return &base;
}

pub fn vki() *const InstanceDispatch {
    return &instance;
}

pub fn vkd() *const DeviceDispatch {
    return &device;
}

pub const BaseDispatch = vk.BaseWrapper(.{
    .createInstance = true,
    .getInstanceProcAddr = true,
    .enumerateInstanceVersion = true,
    .enumerateInstanceLayerProperties = true,
    .enumerateInstanceExtensionProperties = true,
});
pub const InstanceDispatch = vk.InstanceWrapper(instance_functions);
pub const DeviceDispatch = vk.DeviceWrapper(device_functions);
