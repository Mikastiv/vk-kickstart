const std = @import("std");
const c = @import("c.zig");
const vk = @import("vulkan-zig");
const vkk = @import("vk-kickstart");
const dispatch = @import("dispatch.zig");
const Window = @import("Window.zig");
const Shaders = @import("shaders");

// Vulkan dispatchers
const vkb = vkk.vkb; // Base dispatch
const vki = vkk.vki; // Instance dispatch
const vkd = vkk.vkd; // Device dispatch

// can override default_functions if more or less Vulkan functions are required
// pub const base_functions = dispatch.base;
// pub const instance_functions = dispatch.instance;
pub const device_functions = dispatch.device;

const max_frames_in_flight = 2;

const SyncObjects = struct {
    image_available_semaphores: [max_frames_in_flight]vk.Semaphore,
    render_finished_semaphores: [max_frames_in_flight]vk.Semaphore,
    in_flight_fences: [max_frames_in_flight]vk.Fence,
};

fn errorCallback(error_code: i32, description: [*c]const u8) callconv(.C) void {
    std.log.err("glfw: {}: {s}\n", .{ error_code, description });
}

const window_width = 800;
const window_height = 600;

pub fn main() !void {
    if (c.glfwInit() == c.GLFW_FALSE) return error.GlfwInitFailed;
    defer c.glfwTerminate();

    _ = c.glfwSetErrorCallback(errorCallback);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const window = try Window.init(allocator, window_width, window_height, "vk-kickstart");
    defer window.deinit(allocator);

    const instance = try vkk.Instance.create(allocator, c.glfwGetInstanceProcAddress, .{
        .required_api_version = vk.API_VERSION_1_3,
    });
    defer instance.destroy();

    const surface = try window.createSurface(instance.handle);
    defer vki().destroySurfaceKHR(instance.handle, surface, instance.allocation_callbacks);

    const physical_device = try vkk.PhysicalDevice.select(allocator, &instance, surface, .{
        .transfer_queue = .dedicated,
        .required_extensions = &.{
            "VK_KHR_acceleration_structure",
            "VK_KHR_deferred_host_operations",
            "VK_KHR_ray_tracing_pipeline",
        },
        .required_features = .{
            .sampler_anisotropy = vk.TRUE,
        },
        .required_features_12 = .{
            .descriptor_indexing = vk.TRUE,
        },
        .required_features_13 = .{
            .dynamic_rendering = vk.TRUE,
            .synchronization_2 = vk.TRUE,
        },
    });

    std.log.info("selected {s}", .{physical_device.name()});

    const device = try vkk.Device.create(allocator, &physical_device, null);
    defer device.destroy();

    const swapchain = try vkk.Swapchain.create(allocator, &device, surface, .{
        .desired_extent = .{ .width = window_width, .height = window_height },
    });
    defer swapchain.destroy();

    const images = try swapchain.getImages(allocator);
    defer allocator.free(images);

    const image_views = try swapchain.getImageViews(allocator, images);
    defer swapchain.destroyAndFreeImageViews(allocator, image_views);

    const render_pass = try createRenderPass(device.handle, swapchain.image_format);
    defer vkd().destroyRenderPass(device.handle, render_pass, null);

    const framebuffers = try createFramebuffers(
        allocator,
        device.handle,
        swapchain.extent,
        swapchain.image_count,
        image_views,
        render_pass,
    );
    defer {
        for (framebuffers) |framebuffer| {
            vkd().destroyFramebuffer(device.handle, framebuffer, null);
        }
        allocator.free(framebuffers);
    }

    const sync = try createSyncObjects(device.handle);
    defer {
        for (sync.image_available_semaphores) |semaphore| {
            vkd().destroySemaphore(device.handle, semaphore, null);
        }
        for (sync.render_finished_semaphores) |semaphore| {
            vkd().destroySemaphore(device.handle, semaphore, null);
        }
        for (sync.in_flight_fences) |fence| {
            vkd().destroyFence(device.handle, fence, null);
        }
    }

    const vertex_shader = try createShaderModule(device.handle, &Shaders.shader_vert);
    defer vkd().destroyShaderModule(device.handle, vertex_shader, null);
    const fragment_shader = try createShaderModule(device.handle, &Shaders.shader_frag);
    defer vkd().destroyShaderModule(device.handle, fragment_shader, null);

    while (!window.shouldClose()) {
        c.glfwPollEvents();
    }
}

fn createShaderModule(device: vk.Device, bytecode: []align(4) const u8) !vk.ShaderModule {
    const create_info = vk.ShaderModuleCreateInfo{
        .code_size = bytecode.len,
        .p_code = std.mem.bytesAsSlice(u32, bytecode).ptr,
    };

    return vkd().createShaderModule(device, &create_info, null);
}

fn createSyncObjects(device: vk.Device) !SyncObjects {
    var image_available_semaphores = [_]vk.Semaphore{.null_handle} ** max_frames_in_flight;
    var render_finished_semaphores = [_]vk.Semaphore{.null_handle} ** max_frames_in_flight;
    var in_flight_fences = [_]vk.Fence{.null_handle} ** max_frames_in_flight;
    errdefer {
        for (image_available_semaphores) |semaphore| {
            if (semaphore == .null_handle) continue;
            vkd().destroySemaphore(device, semaphore, null);
        }
        for (render_finished_semaphores) |semaphore| {
            if (semaphore == .null_handle) continue;
            vkd().destroySemaphore(device, semaphore, null);
        }
        for (in_flight_fences) |fence| {
            if (fence == .null_handle) continue;
            vkd().destroyFence(device, fence, null);
        }
    }

    const semaphore_info = vk.SemaphoreCreateInfo{};
    const fence_info = vk.FenceCreateInfo{ .flags = .{ .signaled_bit = true } };
    for (0..max_frames_in_flight) |i| {
        image_available_semaphores[i] = try vkd().createSemaphore(device, &semaphore_info, null);
        render_finished_semaphores[i] = try vkd().createSemaphore(device, &semaphore_info, null);
        in_flight_fences[i] = try vkd().createFence(device, &fence_info, null);
    }

    return .{
        .image_available_semaphores = image_available_semaphores,
        .render_finished_semaphores = render_finished_semaphores,
        .in_flight_fences = in_flight_fences,
    };
}

fn createFramebuffers(
    allocator: std.mem.Allocator,
    device: vk.Device,
    extent: vk.Extent2D,
    image_count: u32,
    image_views: []vk.ImageView,
    render_pass: vk.RenderPass,
) ![]vk.Framebuffer {
    var framebuffers = try std.ArrayList(vk.Framebuffer).initCapacity(allocator, image_count);
    errdefer {
        for (framebuffers.items) |framebuffer| {
            vkd().destroyFramebuffer(device, framebuffer, null);
        }
        framebuffers.deinit();
    }

    for (0..image_count) |i| {
        const attachments = [_]vk.ImageView{image_views[i]};
        const framebuffer_info = vk.FramebufferCreateInfo{
            .render_pass = render_pass,
            .attachment_count = attachments.len,
            .p_attachments = &attachments,
            .width = extent.width,
            .height = extent.height,
            .layers = 1,
        };

        const framebuffer = try vkd().createFramebuffer(device, &framebuffer_info, null);
        try framebuffers.append(framebuffer);
    }

    return framebuffers.toOwnedSlice();
}

fn createRenderPass(device: vk.Device, image_format: vk.Format) !vk.RenderPass {
    const color_attachment = vk.AttachmentDescription{
        .format = image_format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .present_src_khr,
    };

    const color_attachment_refs = [_]vk.AttachmentReference{.{
        .attachment = 0,
        .layout = .color_attachment_optimal,
    }};

    const subpasses = [_]vk.SubpassDescription{.{
        .pipeline_bind_point = .graphics,
        .color_attachment_count = color_attachment_refs.len,
        .p_color_attachments = &color_attachment_refs,
    }};

    const dependencies = [_]vk.SubpassDependency{.{
        .src_subpass = vk.SUBPASS_EXTERNAL,
        .dst_subpass = 0,
        .src_stage_mask = .{ .color_attachment_output_bit = true, .early_fragment_tests_bit = true },
        .src_access_mask = .{},
        .dst_stage_mask = .{ .color_attachment_output_bit = true, .early_fragment_tests_bit = true },
        .dst_access_mask = .{ .color_attachment_write_bit = true },
    }};

    const attachments = [_]vk.AttachmentDescription{color_attachment};
    const renderpass_info = vk.RenderPassCreateInfo{
        .attachment_count = attachments.len,
        .p_attachments = &attachments,
        .subpass_count = subpasses.len,
        .p_subpasses = &subpasses,
        .dependency_count = dependencies.len,
        .p_dependencies = &dependencies,
    };

    return vkd().createRenderPass(device, &renderpass_info, null);
}
