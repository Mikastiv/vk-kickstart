const vk = @import("vulkan");

const apis: []const vk.ApiInfo = &.{
    vk.features.version_1_0,
    vk.features.version_1_1,
    vk.extensions.khr_surface,
    vk.extensions.khr_swapchain,
    .{
        .instance_commands = .{
            .destroySurfaceKHR = true,
        },
        .device_commands = .{
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
        },
    },
};

pub const InstanceDispatch = vk.InstanceWrapper(apis);
pub const DeviceDispatch = vk.DeviceWrapper(apis);
pub const Instance = vk.InstanceProxy(apis);
pub const Device = vk.DeviceProxy(apis);
pub const Queue = vk.QueueProxy(apis);
pub const CommandBuffer = vk.CommandBufferProxy(apis);

var vki_table: ?InstanceDispatch = null;
var vkd_table: ?DeviceDispatch = null;

pub fn initInstance(instance: vk.Instance, loader: anytype) !Instance {
    vki_table = try InstanceDispatch.load(instance, loader);
    return Instance.init(instance, &vki_table.?);
}

pub fn initDevice(device: vk.Device) !Device {
    vkd_table = try DeviceDispatch.load(device, vki_table.?.dispatch.vkGetDeviceProcAddr);
    return Device.init(device, &vkd_table.?);
}

pub fn initQueue(queue: vk.Queue) Queue {
    return Queue.init(queue, &vkd_table.?);
}

pub fn initCommandBuffer(cmd: vk.CommandBuffer) CommandBuffer {
    return CommandBuffer.init(cmd, &vkd_table.?);
}
