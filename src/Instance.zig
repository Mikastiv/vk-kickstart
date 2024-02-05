const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const build_options = @import("build_options");
const dispatch = @import("dispatch.zig");

const vkb = dispatch.vkb();
const vki = dispatch.vki();

const mem = std.mem;

const validation_layers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
const debug_extensions = [_][*:0]const u8{vk.extension_info.ext_debug_utils.name};

handle: vk.Instance,
allocation_callbacks: ?*vk.AllocationCallbacks,

pub const Options = struct {
    app_name: [*:0]const u8 = "",
    app_version: u32 = 0,
    engine_name: [*:0]const u8 = "",
    engine_version: u32 = 0,
    api_version: u32 = vk.API_VERSION_1_0,
    headless: bool = false,
    extensions: []const [*:0]const u8 = &.{},
    layers: []const [*:0]const u8 = &.{},
    debug_callback: vk.PfnDebugUtilsMessengerCallbackEXT = defaultDebugMessageCallback,
    debug_message_severity: vk.DebugUtilsMessageSeverityFlagsEXT = .{
        .warning_bit_ext = true,
        .error_bit_ext = true,
    },
    debug_message_type: vk.DebugUtilsMessageTypeFlagsEXT = .{
        .general_bit_ext = true,
        .validation_bit_ext = true,
        .performance_bit_ext = true,
    },
};

pub fn init(allocator: mem.Allocator, loader: anytype, options: Options) !@This() {
    try dispatch.initBaseDispatch(loader);

    const app_info = vk.ApplicationInfo{
        .p_application_name = options.app_name,
        .application_version = options.app_version,
        .p_engine_name = options.engine_name,
        .engine_version = options.engine_version,
        .api_version = options.api_version,
    };

    // TODO: better extension checking
    var extensions = try getRequiredExtensions(allocator, options);
    defer extensions.deinit();

    // TODO: better layer checking
    var layers = try getRequiredLayers(allocator, options);
    defer layers.deinit();

    const next = if (build_options.enable_validation) &vk.DebugUtilsMessengerCreateInfoEXT{
        .message_severity = options.debug_message_severity,
        .message_type = options.debug_message_type,
        .pfn_user_callback = options.debug_callback,
    } else null;

    const instance_info = vk.InstanceCreateInfo{
        .p_application_info = &app_info,
        .enabled_extension_count = @as(u32, @intCast(extensions.items.len)),
        .pp_enabled_extension_names = extensions.items.ptr,
        .enabled_layer_count = @as(u32, @intCast(layers.items.len)),
        .pp_enabled_layer_names = layers.items.ptr,
        .p_next = next,
    };

    const instance = try vkb.createInstance(&instance_info, null);
    try dispatch.initInstanceDispatch(instance, loader);

    return .{ .handle = instance, .allocation_callbacks = null };
}

pub fn deinit(self: @This()) void {
    vki.destroyInstance(self.handle, self.allocation_callbacks);
}

fn defaultDebugMessageCallback(
    severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    _: vk.DebugUtilsMessageTypeFlagsEXT,
    p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    _: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    if (p_callback_data) |data| {
        const format = "{s}\n";

        if (severity.error_bit_ext) {
            std.log.err(format, .{data.p_message});
        } else if (severity.warning_bit_ext) {
            std.log.warn(format, .{data.p_message});
        } else if (severity.info_bit_ext) {
            std.log.info(format, .{data.p_message});
        } else {
            std.log.debug(format, .{data.p_message});
        }
    }
    return vk.FALSE;
}

fn logWarning(result: vk.Result, src: std.builtin.SourceLocation) void {
    std.log.warn("vulkan call returned {s}, ({s}:{d})", .{ @tagName(result), src.file, src.line });
}

fn getRequiredExtensions(allocator: mem.Allocator, options: Options) !std.ArrayList([*:0]const u8) {
    var extensions = std.ArrayList([*:0]const u8).init(allocator);
    errdefer extensions.deinit();

    try extensions.appendSlice(options.extensions);

    if (build_options.enable_validation) {
        try extensions.appendSlice(&debug_extensions);
    }

    return extensions;
}

fn getRequiredLayers(allocator: mem.Allocator, options: Options) !std.ArrayList([*:0]const u8) {
    var layers = std.ArrayList([*:0]const u8).init(allocator);
    errdefer layers.deinit();

    try layers.appendSlice(options.layers);

    if (build_options.enable_validation) {
        try layers.appendSlice(&validation_layers);
    }

    return layers;
}

fn validationLayerSupported(allocator: mem.Allocator) !bool {
    var layer_count: u32 = undefined;
    var result = try vkb.enumerateInstanceLayerProperties(&layer_count, null);
    if (result != .success) {
        logWarning(result, @src());
    }

    const layer_properties = try allocator.alloc(vk.LayerProperties, layer_count);
    defer allocator.free(layer_properties);

    result = try vkb.enumerateInstanceLayerProperties(&layer_count, layer_properties.ptr);
    if (result != .success) {
        logWarning(result, @src());
    }

    for (validation_layers) |layer_name| {
        var layer_found = false;

        for (layer_properties) |layer| {
            const name: [*:0]const u8 = @ptrCast(&layer.layer_name);
            if (mem.orderZ(u8, name, layer_name) == .eq) {
                layer_found = true;
                break;
            }
        }

        if (!layer_found) return false;
    }

    return true;
}
