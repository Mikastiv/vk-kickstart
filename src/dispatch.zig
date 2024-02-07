const std = @import("std");
const vk = @import("vulkan");
const build_options = @import("build_options");
const root = @import("root");

const instance_functions = if (@hasDecl(root, "instance_functions")) root.instance_functions else default_instance_functions;
const device_functions = if (@hasDecl(root, "device_functions")) root.device_functions else default_device_functions;

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

pub fn initInstanceDispatch(inst: vk.Instance) !void {
    if (!instance_init) {
        instance = try InstanceDispatch.load(inst, base.dispatch.vkGetInstanceProcAddr);
        instance_init = true;
    }
}

pub fn initDeviceDispatch(dev: vk.Device) !void {
    if (!device_init) {
        device = try DeviceDispatch.load(dev, instance.dispatch.vkGetDeviceProcAddr);
        device_init = true;
    }
}

pub fn vkb() BaseDispatch {
    std.debug.assert(base_init);
    return base;
}

pub fn vki() InstanceDispatch {
    std.debug.assert(instance_init);
    return instance;
}

pub fn vkd() DeviceDispatch {
    std.debug.assert(device_init);
    return device;
}

pub const BaseDispatch = vk.BaseWrapper(default_base_functions);
pub const InstanceDispatch = vk.InstanceWrapper(instance_functions);
pub const DeviceDispatch = vk.DeviceWrapper(device_functions);

const default_base_functions = vk.BaseCommandFlags{
    .createInstance = true,
    .getInstanceProcAddr = true,
    .enumerateInstanceVersion = true,
    .enumerateInstanceLayerProperties = true,
    .enumerateInstanceExtensionProperties = true,
};

const default_instance_functions = vk.InstanceCommandFlags{
    .destroyInstance = true,
    .createDevice = true,
    .enumeratePhysicalDevices = true,
    .enumerateDeviceLayerProperties = true,
    .enumerateDeviceExtensionProperties = true,
    .getDeviceProcAddr = true,
    .getPhysicalDeviceProperties = true,
    .getPhysicalDeviceQueueFamilyProperties = true,
    .getPhysicalDeviceMemoryProperties = true,
    .getPhysicalDeviceFeatures = true,
    .getPhysicalDeviceFormatProperties = true,
    .getPhysicalDeviceImageFormatProperties = true,
    .getPhysicalDeviceSurfaceSupportKHR = true,
    .getPhysicalDeviceSurfaceFormatsKHR = true,
    .getPhysicalDeviceSurfacePresentModesKHR = true,
    .createDebugUtilsMessengerEXT = true,
    .destroyDebugUtilsMessengerEXT = true,
    .destroySurfaceKHR = true,
};

const default_device_functions = vk.DeviceCommandFlags{
    .destroyDevice = true,
};
