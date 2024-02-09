# `vk-kickstart`

A Zig library to help with Vulkan initialization inspired by [vk-bootstrap](https://github.com/charles-lunarg/vk-bootstrap)

The minimum required version is Vulkan 1.1

This library helps with:
- Instance creation
- Setting up debug environment (validation layers and debug messenger)
- Physical device selection based on a set of criteria
- Enabling physical device extensions
- Device creation

### Setting up

Add vk-kickstart as a dependency to your build.zig.zon:
```
zig fetch --save https://github.com/Mikastiv/vk-kickstart/archive/<COMMIT_HASH>.tar.gz
```

Then update your build file with the following:
```zig
const kickstart_dep = b.dependency("vk_kickstart", .{});
exe.root_module.addImport("vk-kickstart", kickstart_dep.module("vk-kickstart"));
// vk-kickstart uses vulkan-zig under the hood and provides it as module
exe.root_module.addImport("vulkan", kickstart_dep.module("vulkan-zig"));
```

You can then import vk-kickstart as a module
```zig
const vkk = @import("vk-kickstart");

// Vulkan dispatchers
const vkb = vkk.vkb; // Base dispatch
const vki = vkk.vki; // Instance dispatch
const vkd = vkk.vkd; // Device dispatch
```

See `examples/*` for examples

### Todo list
- Swapchain creation
- Headless mode
- Render triangle in glfw example
