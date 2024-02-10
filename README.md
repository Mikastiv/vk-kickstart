# `vk-kickstart`

A Zig library to help with Vulkan initialization inspired by [vk-bootstrap](https://github.com/charles-lunarg/vk-bootstrap)

The minimum required version is Vulkan 1.1

This library helps with:
- Instance creation
- Setting up debug environment (validation layers and debug messenger)
- Physical device selection based on a set of criteria
- Enabling physical device extensions
- Device creation
- Swapchain creation

## Setting up

Add [`vulkan-zig`](https://github.com/Snektron/vulkan-zig) as a dependency to your build.zig.zon:
```
zig fetch --save=vulkan_zig "https://github.com/Snektron/vulkan-zig/archive/<COMMIT_HASH>.tar.gz"
```
You should use the same version as vk-kickstart for the commit hash. See [build.zig.zon](build.zig.zon)

Then add vk-kickstart:
```
zig fetch --save https://github.com/Mikastiv/vk-kickstart/archive/<COMMIT_HASH>.tar.gz
```

Then update your build file with the following:
```zig
// Provide the path to the Vulkan registry
const xml_path: []const u8 = b.pathFromRoot("vk.xml");

// Add the vulkan-zig module
const vkzig_dep = b.dependency("vulkan_zig", .{
    .registry = xml_path,
});
exe.root_module.addImport("vulkan", vkzig_dep.module("vulkan-zig"));

// Add vk-kickstart
const kickstart_dep = b.dependency("vk_kickstart", .{
    .registry = xml_path,
    // Optional
    .enable_validation = true, // By default this is true when compiling in .Debug mode
    .verbose = true, // False by default
});
exe.root_module.addImport("vk-kickstart", kickstart_dep.module("vk-kickstart"));
```

There are two more build options that are optional:
```zig
const kickstart_dep = b.dependency("vk_kickstart", .{
    // Enables debug layers and debug messenger
    .enable_validation = true, // By default this is true when compiling in .Debug mode
    // Enables debug output
    .verbose = true, // False by default
});
```

You can then import `vk-kickstart` as a module and vulkan-zig
```zig
const vkk = @import("vk-kickstart");
const vk = @import("vulkan-zig");
```

See [build.zig](examples/glfw/build.zig) for an example

## How to use

For a code example, see [main.zig](examples/glfw/src/main.zig)

### Instance creation

Using the `Instance.Config` struct's fields, you can you can choose how you want the instance to be configured like the required api version.

Note: VK_KHR_surface and the platform specific surface extension are automatically enabled. Only works for Windows, MacOS and Linux (xcb, xlib or wayland) for now

```zig
const vk = @import("vulkan-zig");

pub const Config = struct {
    /// Application name
    app_name: [*:0]const u8 = "",
    /// Application version
    app_version: u32 = 0,
    /// Engine name
    engine_name: [*:0]const u8 = "",
    /// Engine version
    engine_version: u32 = 0,
    /// Required Vulkan version (minimum 1.1)
    required_api_version: u32 = vk.API_VERSION_1_1,
    /// Array of required extensions to enable
    /// Note: VK_KHR_surface and the platform specific surface extension are automatically enabled
    required_extensions: []const [*:0]const u8 = &.{},
    /// Array of required layers to enable
    required_layers: []const [*:0]const u8 = &.{},
    /// Vulkan allocation callbacks
    allocation_callbacks: ?*const vk.AllocationCallbacks = null,
    /// Custom debug callback function (or use default)
    debug_callback: DebugCallback = default_debug_callback,
    /// Debug message severity filter
    debug_message_severity: DebugMessageSeverity = default_message_severity,
    /// Debug message type filter
    debug_message_type: DebugMessageType = default_message_type,
};
```

Pass these configs to `Instance.create()` to create an instance

### Physical device selection

You can set criterias to select an appropriate physical device for your application using `PhysicalDevice.Options`

Note: VK_KHR_subset (if available) and VK_KHR_swapchain are automatically enabled, no need to add them to the list

```zig
const vk = @import("vulkan-zig");

pub const Options = struct {
    /// Name of the device to select
    name: ?[*:0]const u8 = null,
    /// Required Vulkan version (minimum 1.1)
    required_api_version: u32 = vk.API_VERSION_1_1,
    /// Prefered physical device type
    preferred_type: vk.PhysicalDeviceType = .discrete_gpu,
    /// Transfer queue preference
    transfer_queue: QueuePreference = .none,
    /// Compute queue preference
    compute_queue: QueuePreference = .none,
    /// Required local memory size
    required_mem_size: vk.DeviceSize = 0,
    /// Required physical device features
    required_features: vk.PhysicalDeviceFeatures = .{},
    /// Required physical device feature version 1.1
    required_features_11: vk.PhysicalDeviceVulkan11Features = .{},
    /// Required physical device feature version 1.2
    required_features_12: ?vk.PhysicalDeviceVulkan12Features = null,
    /// Required physical device feature version 1.3
    required_features_13: ?vk.PhysicalDeviceVulkan13Features = null,
    /// Array of required physical device extensions to enable
    /// Note: VK_KHR_swapchain and VK_KHR_subset (if available) are automatically enabled
    required_extensions: []const [*:0]const u8 = &.{},
};
```

Pass these options and a vk.SurfaceKHR to `PhysicalDevice.select()` to select a device

### Device creation

For this, you only need to call `Device.create()` with the previously selected physical device

### Swapchain creation

Finally to create a swapchain, use `Swapchain.Config`

```zig
const vk = @import("vulkan-zig");

pub const Config = struct {
    /// Desired size (in pixels) of the swapchain image(s)
    /// These values will be clamped within the capabilities of the device
    desired_extent: vk.Extent2D,
    /// Swapchain create flags
    create_flags: vk.SwapchainCreateFlagsKHR = .{},
    /// Desired minimum number of presentable images that the application needs
    /// If left on default, will try to use the minimum of the device + 1
    /// This value will be clamped between the device's minimum and maximum (if there is a max)
    desired_min_image_count: ?u32 = null,
    /// Array of desired image formats, in order of priority
    /// Will fallback to the first found if none match
    desired_formats: []const vk.SurfaceFormatKHR = &.{
        .{ .format = .b8g8r8a8_srgb, .color_space = .srgb_nonlinear_khr },
    },
    /// Array of desired present modes, in order of priority
    /// Will fallback to fifo_khr is none match
    desired_present_modes: []const vk.PresentModeKHR = &.{
        .mailbox_khr,
    },
    /// Desired number of views in a multiview/stereo surface
    /// Will be clamped down if higher than device's max
    desired_array_layer_count: u32 = 1,
    /// Intended usage of the (acquired) swapchain images
    image_usage_flags: vk.ImageUsageFlags = .{ .color_attachment_bit = true },
    /// Value describing the transform, relative to the presentation engine’s natural orientation, applied to the image content prior to presentation
    pre_transform: ?vk.SurfaceTransformFlagsKHR = null,
    /// Value indicating the alpha compositing mode to use when this surface is composited together with other surfaces on certain window systems
    composite_alpha: vk.CompositeAlphaFlagsKHR = .{ .opaque_bit_khr = true },
    /// Discard rendering operation that are not visible
    clipped: vk.Bool32 = vk.TRUE,
    /// Existing non-retired swapchain currently associated with surface
    old_swapchain: ?vk.SwapchainKHR = null,
    /// Vulkan allocation callbacks
    allocation_callbacks: ?*const vk.AllocationCallbacks = null,
};
```

Pass these configs and a the logical device to `Swapchain.create()` to create the swapchain

### Vulkan dispatchers

`vk-kickstart` uses [`vulkan-zig`](https://github.com/Snektron/vulkan-zig) and you can access vulkan functions using it's dispatcher api with the functions `vkb()`, `vki()` and `vkd()`

```zig
const vkk = @import("vk-kickstart");
const vkb = vkk.vkb; // Base dispatch
const vki = vkk.vki; // Instance dispatch
const vkd = vkk.vkd; // Device dispatch
```

Not all functions are loaded by default. If you need other functions you will need to overwrite them in the root module like you would do for std.log.

In your `main.zig`:
```zig
pub const base_functions = dispatch.base;
pub const instance_functions = dispatch.instance;
pub const device_functions = dispatch.device;
```

See [dispatch.zig](examples/glfw/src/dispatch.zig) for their definition

You can then use in your code any loaded vulkan functions:
```zig
vkd().createRenderPass();
vkd().cmdDrawIndexed();
vkd().allocateCommandBuffers();
```

## Todo list
- Headless mode
- Render triangle in glfw example
