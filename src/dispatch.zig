const std = @import("std");
const vk = @import("vulkan-zig");
const build_options = @import("build_options");
const root = @import("root");

const dispatch_override = if (@hasDecl(root, "vulkan_dispatch")) root.vulkan_dispatch else struct {};

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

pub const BaseDispatch = vk.BaseWrapper(base_functions);
pub const InstanceDispatch = vk.InstanceWrapper(instance_functions);
pub const DeviceDispatch = vk.DeviceWrapper(device_functions);

const base_functions = if (@hasDecl(dispatch_override, "base"))
    dispatch_override.base
else
    vk.BaseCommandFlags{
        .createInstance = true,
        .getInstanceProcAddr = true,
        .enumerateInstanceVersion = true,
        .enumerateInstanceLayerProperties = true,
        .enumerateInstanceExtensionProperties = true,
    };

const instance_functions = if (@hasDecl(dispatch_override, "instance"))
    dispatch_override.instance
else
    vk.InstanceCommandFlags{
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
        .getPhysicalDeviceSurfaceSupportKHR = true,
        .getPhysicalDeviceSurfaceCapabilitiesKHR = true,
        .getPhysicalDeviceSurfaceFormatsKHR = true,
        .getPhysicalDeviceSurfacePresentModesKHR = true,
        .getPhysicalDeviceImageFormatProperties = true,
        .createDebugUtilsMessengerEXT = if (build_options.enable_validation) true else false,
        .destroyDebugUtilsMessengerEXT = if (build_options.enable_validation) true else false,
        .destroySurfaceKHR = true,
        .getPhysicalDeviceFeatures2 = true,
    };

const device_functions = if (@hasDecl(dispatch_override, "device"))
    dispatch_override.device
else
    vk.DeviceCommandFlags{
        .destroyDevice = true,
        .getDeviceQueue = true,
        .createSwapchainKHR = true,
        .destroySwapchainKHR = true,
        .getSwapchainImagesKHR = true,
        .createImageView = true,
        .destroyImageView = true,
        .createRenderPass = true,
        .destroyRenderPass = true,
        .createFramebuffer = true,
        .destroyFramebuffer = true,
        .createSemaphore = true,
        .destroySemaphore = true,
        .createFence = true,
        .destroyFence = true,
        .createShaderModule = true,
        .destroyShaderModule = true,
        .createPipelineLayout = true,
        .destroyPipelineLayout = true,
        .createGraphicsPipelines = true,
        .destroyPipeline = true,
        .createCommandPool = true,
        .destroyCommandPool = true,
        .allocateCommandBuffers = true,
        .freeCommandBuffers = true,
        .beginCommandBuffer = true,
        .waitForFences = true,
        .deviceWaitIdle = true,
        .resetFences = true,
        .acquireNextImageKHR = true,
        .queueSubmit = true,
        .queuePresentKHR = true,
        .endCommandBuffer = true,
        .cmdBeginRenderPass = true,
        .cmdSetViewport = true,
        .cmdSetScissor = true,
        .cmdBindPipeline = true,
        .cmdDraw = true,
        .cmdEndRenderPass = true,
    };
