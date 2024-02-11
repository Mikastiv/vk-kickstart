const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan-zig");
const build_options = @import("build_options");
const dispatch = @import("dispatch.zig");
const mem = std.mem;

const log = @import("log.zig").vk_kickstart_log;
const vk_log = @import("log.zig").vulkan_log;

const vkb = dispatch.vkb;
const vki = dispatch.vki;

const validation_layers: []const [*:0]const u8 = &.{"VK_LAYER_KHRONOS_validation"};

handle: vk.Instance,
allocation_callbacks: ?*const vk.AllocationCallbacks,
debug_messenger: DebugMessenger,
api_version: u32,

pub const DebugMessenger = if (build_options.enable_validation) vk.DebugUtilsMessengerEXT else void;
pub const DebugCallback = if (build_options.enable_validation) vk.PfnDebugUtilsMessengerCallbackEXT else void;
pub const DebugMessageSeverity = if (build_options.enable_validation) vk.DebugUtilsMessageSeverityFlagsEXT else void;
pub const DebugMessageType = if (build_options.enable_validation) vk.DebugUtilsMessageTypeFlagsEXT else void;

const default_debug_callback = if (build_options.enable_validation) defaultDebugMessageCallback else {};
const default_message_severity = if (build_options.enable_validation) .{
    .warning_bit_ext = true,
    .error_bit_ext = true,
} else {};
const default_message_type = if (build_options.enable_validation) .{
    .general_bit_ext = true,
    .validation_bit_ext = true,
    .performance_bit_ext = true,
} else {};

pub const CreateOptions = struct {
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
    /// Debug user data pointer
    debug_user_data: ?*anyopaque = null,
};

pub fn create(allocator: mem.Allocator, loader: anytype, options: CreateOptions) !@This() {
    try dispatch.initBaseDispatch(loader);

    const api_version = try getAppropriateApiVersion(options.required_api_version);
    std.debug.assert(api_version >= vk.API_VERSION_1_1);

    const app_info = vk.ApplicationInfo{
        .p_application_name = options.app_name,
        .application_version = options.app_version,
        .p_engine_name = options.engine_name,
        .engine_version = options.engine_version,
        .api_version = api_version,
    };

    const available_extensions = try getAvailableExtensions(allocator);
    defer allocator.free(available_extensions);

    const available_layers = try getAvailableLayers(allocator);
    defer allocator.free(available_layers);

    var required_extensions = try getRequiredExtensions(allocator, options.required_extensions, available_extensions);
    defer required_extensions.deinit();

    const portability_enumeration_support = isExtensionAvailable(
        available_extensions,
        vk.extension_info.khr_portability_enumeration.name,
    );
    if (portability_enumeration_support) {
        try required_extensions.append(vk.extension_info.khr_portability_enumeration.name);
    }

    var required_layers = try getRequiredLayers(allocator, options.required_layers, available_layers);
    defer required_layers.deinit();

    const next = if (build_options.enable_validation) &vk.DebugUtilsMessengerCreateInfoEXT{
        .message_severity = options.debug_message_severity,
        .message_type = options.debug_message_type,
        .pfn_user_callback = options.debug_callback,
        .p_user_data = options.debug_user_data,
    } else null;

    const instance_info = vk.InstanceCreateInfo{
        .flags = if (portability_enumeration_support) .{ .enumerate_portability_bit_khr = true } else .{},
        .p_application_info = &app_info,
        .enabled_extension_count = @as(u32, @intCast(required_extensions.items.len)),
        .pp_enabled_extension_names = required_extensions.items.ptr,
        .enabled_layer_count = @as(u32, @intCast(required_layers.items.len)),
        .pp_enabled_layer_names = required_layers.items.ptr,
        .p_next = next,
    };

    if (build_options.verbose) {
        log.debug("----- instance creation -----", .{});

        log.debug("api version: {d}.{d}.{d}", .{
            vk.apiVersionMajor(api_version),
            vk.apiVersionMinor(api_version),
            vk.apiVersionPatch(api_version),
        });

        log.debug("validation layers: {s}", .{if (build_options.enable_validation) "enabled" else "disabled"});

        log.debug("available extensions:", .{});
        for (available_extensions) |ext| {
            const ext_name: [*:0]const u8 = @ptrCast(&ext.extension_name);
            log.debug("- {s}", .{ext_name});
        }

        log.debug("available layers:", .{});
        for (available_layers) |layer| {
            const layer_name: [*:0]const u8 = @ptrCast(&layer.layer_name);
            log.debug("- {s}", .{layer_name});
        }

        log.debug("enabled extensions:", .{});
        for (required_extensions.items) |ext| {
            log.debug("- {s}", .{ext});
        }

        log.debug("enabled layers:", .{});
        for (required_layers.items) |layer| {
            log.debug("- {s}", .{layer});
        }
    }

    const instance = try vkb().createInstance(&instance_info, options.allocation_callbacks);
    try dispatch.initInstanceDispatch(instance);
    errdefer vki().destroyInstance(instance, options.allocation_callbacks);

    const debug_messenger = try createDebugMessenger(instance, options);
    errdefer destroyDebugMessenger(instance, debug_messenger, options.allocation_callbacks);

    return .{
        .handle = instance,
        .allocation_callbacks = options.allocation_callbacks,
        .debug_messenger = debug_messenger,
        .api_version = api_version,
    };
}

pub fn destroy(self: *const @This()) void {
    destroyDebugMessenger(self.handle, self.debug_messenger, self.allocation_callbacks);
    vki().destroyInstance(self.handle, self.allocation_callbacks);
}

fn defaultDebugMessageCallback(
    severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    _: vk.DebugUtilsMessageTypeFlagsEXT,
    p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    _: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    if (p_callback_data) |data| {
        const format = "{?s}";

        if (severity.error_bit_ext) {
            vk_log.err(format, .{data.p_message});
        } else if (severity.warning_bit_ext) {
            vk_log.warn(format, .{data.p_message});
        } else if (severity.info_bit_ext) {
            vk_log.info(format, .{data.p_message});
        } else {
            vk_log.debug(format, .{data.p_message});
        }
    }
    return vk.FALSE;
}

fn createDebugMessenger(instance: vk.Instance, options: CreateOptions) !DebugMessenger {
    if (!build_options.enable_validation) return;

    const debug_info = vk.DebugUtilsMessengerCreateInfoEXT{
        .message_severity = options.debug_message_severity,
        .message_type = options.debug_message_type,
        .pfn_user_callback = options.debug_callback,
        .p_user_data = options.debug_user_data,
    };

    return vki().createDebugUtilsMessengerEXT(instance, &debug_info, options.allocation_callbacks);
}

fn destroyDebugMessenger(
    instance: vk.Instance,
    debug_messenger: DebugMessenger,
    allocation_callbacks: ?*const vk.AllocationCallbacks,
) void {
    if (!build_options.enable_validation) return;

    vki().destroyDebugUtilsMessengerEXT(instance, debug_messenger, allocation_callbacks);
}

fn isExtensionAvailable(
    available_extensions: []const vk.ExtensionProperties,
    extension: [*:0]const u8,
) bool {
    for (available_extensions) |ext| {
        const name: [*:0]const u8 = @ptrCast(&ext.extension_name);
        if (mem.orderZ(u8, name, extension) == .eq) {
            return true;
        }
    }
    return false;
}

fn addExtension(
    extensions: *std.ArrayList([*:0]const u8),
    available_extensions: []const vk.ExtensionProperties,
    new_extension: [*:0]const u8,
) !bool {
    if (isExtensionAvailable(available_extensions, new_extension)) {
        try extensions.append(new_extension);
        return true;
    }
    return false;
}

fn getRequiredExtensions(
    allocator: mem.Allocator,
    config_extensions: []const [*:0]const u8,
    available_extensions: []const vk.ExtensionProperties,
) !std.ArrayList([*:0]const u8) {
    var extensions = std.ArrayList([*:0]const u8).init(allocator);
    errdefer extensions.deinit();

    for (config_extensions) |ext| {
        if (!try addExtension(&extensions, available_extensions, ext)) {
            return error.RequestedExtensionNotAvailable;
        }
    }

    if (!try addExtension(&extensions, available_extensions, vk.extension_info.khr_surface.name)) {
        return error.SurfaceExtensionNotAvailable;
    }

    const windowing_extensions: []const [*:0]const u8 = switch (builtin.os.tag) {
        .windows => &.{vk.extension_info.khr_win_32_surface.name},
        .macos => &.{vk.extension_info.ext_metal_surface.name},
        .linux => &.{
            vk.extension_info.khr_xlib_surface,
            vk.extension_info.khr_xcb_surface,
            vk.extension_info.khr_wayland_surface,
        },
        else => @compileError("unsupported platform"),
    };

    var added_one = false;
    for (windowing_extensions) |ext| {
        added_one = try addExtension(&extensions, available_extensions, ext) or added_one;
    }

    if (!added_one) return error.WindowingExtensionNotAvailable;

    if (build_options.enable_validation) {
        if (!try addExtension(&extensions, available_extensions, vk.extension_info.ext_debug_utils.name)) {
            return error.DebugMessengerExtensionNotAvailable;
        }
    }

    return extensions;
}

fn isLayerAvailable(
    available_layers: []const vk.LayerProperties,
    layer: [*:0]const u8,
) bool {
    for (available_layers) |l| {
        const name: [*:0]const u8 = @ptrCast(&l.layer_name);
        if (mem.orderZ(u8, name, layer) == .eq) {
            return true;
        }
    }
    return false;
}

fn addLayer(
    layers: *std.ArrayList([*:0]const u8),
    available_layers: []const vk.LayerProperties,
    new_layer: [*:0]const u8,
) !bool {
    if (isLayerAvailable(available_layers, new_layer)) {
        try layers.append(new_layer);
        return true;
    }
    return false;
}

fn getRequiredLayers(
    allocator: mem.Allocator,
    config_layers: []const [*:0]const u8,
    available_layers: []const vk.LayerProperties,
) !std.ArrayList([*:0]const u8) {
    var layers = std.ArrayList([*:0]const u8).init(allocator);
    errdefer layers.deinit();

    for (config_layers) |layer| {
        if (!try addLayer(&layers, available_layers, layer)) {
            return error.RequestedLayerNotAvailable;
        }
    }

    if (build_options.enable_validation) {
        for (validation_layers) |layer| {
            if (!try addLayer(&layers, available_layers, layer)) {
                return error.ValidationLayersNotAvailable;
            }
        }
    }

    return layers;
}

fn getAvailableExtensions(allocator: mem.Allocator) ![]vk.ExtensionProperties {
    var extension_count: u32 = 0;
    var result = try vkb().enumerateInstanceExtensionProperties(null, &extension_count, null);
    if (result != .success) return error.EnumerateExtensionsFailed;

    const extension_properties = try allocator.alloc(vk.ExtensionProperties, extension_count);
    errdefer allocator.free(extension_properties);

    while (true) {
        result = try vkb().enumerateInstanceExtensionProperties(null, &extension_count, extension_properties.ptr);
        if (result == .success) break;
    }

    return extension_properties;
}

fn getAvailableLayers(allocator: mem.Allocator) ![]vk.LayerProperties {
    var layer_count: u32 = 0;
    var result = try vkb().enumerateInstanceLayerProperties(&layer_count, null);
    if (result != .success) return error.EnumerateLayersFailed;

    const layer_properties = try allocator.alloc(vk.LayerProperties, layer_count);
    errdefer allocator.free(layer_properties);

    while (true) {
        result = try vkb().enumerateInstanceLayerProperties(&layer_count, layer_properties.ptr);
        if (result == .success) break;
    }

    return layer_properties;
}

fn getAppropriateApiVersion(required_version: u32) !u32 {
    const instance_version = try vkb().enumerateInstanceVersion();

    if (instance_version < required_version)
        return error.RequiredVersionNotAvailable;
    return instance_version;
}
