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
pub const vulkan_dispatch = struct {
    // pub const base = dispatch.base;
    // pub const instance = dispatch.instance;
    pub const device = dispatch.device;
};

const max_frames_in_flight = 2;

const SyncObjects = struct {
    image_available_semaphores: [max_frames_in_flight]vk.Semaphore,
    render_finished_semaphores: [max_frames_in_flight]vk.Semaphore,
    in_flight_fences: [max_frames_in_flight]vk.Fence,
};

const FrameSyncObjects = struct {
    image_available_semaphore: vk.Semaphore,
    render_finished_semaphore: vk.Semaphore,
    in_flight_fence: vk.Fence,
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
        .required_api_version = vk.API_VERSION_1_2,
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
    });

    std.log.info("selected {s}", .{physical_device.name()});

    const device = try vkk.Device.create(allocator, &physical_device, null);
    defer device.destroy();

    var swapchain = try vkk.Swapchain.create(allocator, &device, surface, .{
        .desired_extent = .{ .width = window_width, .height = window_height },
    });
    defer swapchain.destroy();

    var images = try swapchain.getImages(allocator);
    defer allocator.free(images);

    var image_views = try swapchain.getImageViews(allocator, images);
    defer swapchain.destroyAndFreeImageViews(allocator, image_views);

    const render_pass = try createRenderPass(device.handle, swapchain.image_format);
    defer vkd().destroyRenderPass(device.handle, render_pass, null);

    var framebuffers = try createFramebuffers(allocator, device.handle, swapchain.extent, swapchain.image_count, image_views, render_pass);
    defer destroyFramebuffers(allocator, device.handle, framebuffers);

    const sync = try createSyncObjects(device.handle);
    defer destroySyncObjects(device.handle, sync);

    const vertex_shader = try createShaderModule(device.handle, &Shaders.shader_vert);
    defer vkd().destroyShaderModule(device.handle, vertex_shader, null);
    const fragment_shader = try createShaderModule(device.handle, &Shaders.shader_frag);
    defer vkd().destroyShaderModule(device.handle, fragment_shader, null);

    const pipeline_layout_info = vk.PipelineLayoutCreateInfo{};
    const pipeline_layout = try vkd().createPipelineLayout(device.handle, &pipeline_layout_info, null);
    defer vkd().destroyPipelineLayout(device.handle, pipeline_layout, null);

    const pipeline = try createGraphicsPipeline(device.handle, render_pass, vertex_shader, fragment_shader, pipeline_layout);
    defer vkd().destroyPipeline(device.handle, pipeline, null);

    const command_pool = try createCommandPool(device.handle, device.physical_device.graphics_family_index);
    defer vkd().destroyCommandPool(device.handle, command_pool, null);

    const command_buffers = try createCommandBuffers(allocator, device.handle, command_pool, max_frames_in_flight);
    defer allocator.free(command_buffers);

    var current_frame: u32 = 0;
    var should_recreate_swapchain = false;
    while (!window.shouldClose()) {
        c.glfwPollEvents();

        if (should_recreate_swapchain) {
            swapchain = try recreateSwapchain(
                allocator,
                &device,
                window,
                &swapchain,
                &images,
                &image_views,
                render_pass,
                &framebuffers,
            );
            should_recreate_swapchain = false;
        }

        if (window.framebuffer_resized) {
            should_recreate_swapchain = true;
            window.framebuffer_resized = false;
            continue;
        }

        const result = try vkd().waitForFences(device.handle, 1, @ptrCast(&sync.in_flight_fences[current_frame]), vk.TRUE, std.math.maxInt(u64));
        std.debug.assert(result == .success);

        const next_image_result = vkd().acquireNextImageKHR(
            device.handle,
            swapchain.handle,
            std.math.maxInt(u64),
            sync.image_available_semaphores[current_frame],
            .null_handle,
        ) catch |err| {
            if (err == error.OutOfDateKHR) {
                should_recreate_swapchain = true;
                continue;
            }
            return err;
        };
        std.debug.assert(next_image_result.result == .success);

        const image_index = next_image_result.image_index;
        try recordCommandBuffer(command_buffers[current_frame], pipeline, render_pass, framebuffers[image_index], swapchain.extent);

        const frame_sync_objects = FrameSyncObjects{
            .image_available_semaphore = sync.image_available_semaphores[current_frame],
            .render_finished_semaphore = sync.render_finished_semaphores[current_frame],
            .in_flight_fence = sync.in_flight_fences[current_frame],
        };
        if (!try drawFrame(&device, command_buffers[current_frame], frame_sync_objects, swapchain.handle, image_index)) {
            should_recreate_swapchain = true;
            continue;
        }

        current_frame = (current_frame + 1) % max_frames_in_flight;
    }

    try vkd().deviceWaitIdle(device.handle);
}

fn drawFrame(
    device: *const vkk.Device,
    command_buffer: vk.CommandBuffer,
    sync: FrameSyncObjects,
    swapchain: vk.SwapchainKHR,
    image_index: u32,
) !bool {
    const wait_semaphores = [_]vk.Semaphore{sync.image_available_semaphore};
    const wait_stages = [_]vk.PipelineStageFlags{.{ .color_attachment_output_bit = true }};
    const signal_semaphores = [_]vk.Semaphore{sync.render_finished_semaphore};
    const command_buffers = [_]vk.CommandBuffer{command_buffer};
    const submit_info = vk.SubmitInfo{
        .wait_semaphore_count = wait_semaphores.len,
        .p_wait_semaphores = &wait_semaphores,
        .p_wait_dst_stage_mask = &wait_stages,
        .command_buffer_count = command_buffers.len,
        .p_command_buffers = &command_buffers,
        .signal_semaphore_count = signal_semaphores.len,
        .p_signal_semaphores = &signal_semaphores,
    };

    const fences = [_]vk.Fence{sync.in_flight_fence};
    try vkd().resetFences(device.handle, fences.len, &fences);

    const submits = [_]vk.SubmitInfo{submit_info};
    try vkd().queueSubmit(device.graphics_queue, submits.len, &submits, sync.in_flight_fence);

    const indices = [_]u32{image_index};
    const swapchains = [_]vk.SwapchainKHR{swapchain};
    const present_info = vk.PresentInfoKHR{
        .wait_semaphore_count = signal_semaphores.len,
        .p_wait_semaphores = &signal_semaphores,
        .swapchain_count = swapchains.len,
        .p_swapchains = &swapchains,
        .p_image_indices = &indices,
    };

    const present_result = vkd().queuePresentKHR(device.present_queue, &present_info) catch |err| {
        if (err == error.OutOfDateKHR) {
            return false;
        }
        return err;
    };

    if (present_result == .suboptimal_khr) {
        return false;
    }

    return true;
}

fn recreateSwapchain(
    allocator: std.mem.Allocator,
    device: *const vkk.Device,
    window: *Window,
    old_swapchain: *vkk.Swapchain,
    images: *[]vk.Image,
    image_views: *[]vk.ImageView,
    render_pass: vk.RenderPass,
    framebuffers: *[]vk.Framebuffer,
) !vkk.Swapchain {
    var extent = window.extent();
    while (extent.width == 0 or extent.height == 0) {
        extent = window.extent();
        c.glfwWaitEvents();
    }

    try vkd().deviceWaitIdle(device.handle);

    const swapchain = try vkk.Swapchain.create(allocator, device, old_swapchain.surface, .{
        .desired_extent = .{ .width = extent.width, .height = extent.height },
        .old_swapchain = old_swapchain.handle,
    });

    old_swapchain.destroyAndFreeImageViews(allocator, image_views.*);
    old_swapchain.destroy();

    allocator.free(images.*);
    destroyFramebuffers(allocator, device.handle, framebuffers.*);

    images.* = try swapchain.getImages(allocator);
    image_views.* = try swapchain.getImageViews(allocator, images.*);
    framebuffers.* = try createFramebuffers(
        allocator,
        device.handle,
        extent,
        swapchain.image_count,
        image_views.*,
        render_pass,
    );

    return swapchain;
}

fn destroyFramebuffers(allocator: std.mem.Allocator, device: vk.Device, framebuffers: []const vk.Framebuffer) void {
    for (framebuffers) |framebuffer| {
        vkd().destroyFramebuffer(device, framebuffer, null);
    }
    allocator.free(framebuffers);
}

fn destroySyncObjects(device: vk.Device, sync: SyncObjects) void {
    for (sync.image_available_semaphores) |semaphore| {
        vkd().destroySemaphore(device, semaphore, null);
    }
    for (sync.render_finished_semaphores) |semaphore| {
        vkd().destroySemaphore(device, semaphore, null);
    }
    for (sync.in_flight_fences) |fence| {
        vkd().destroyFence(device, fence, null);
    }
}

fn recordCommandBuffer(
    command_buffer: vk.CommandBuffer,
    pipeline: vk.Pipeline,
    render_pass: vk.RenderPass,
    framebuffer: vk.Framebuffer,
    extent: vk.Extent2D,
) !void {
    const begin_info = vk.CommandBufferBeginInfo{};
    try vkd().beginCommandBuffer(command_buffer, &begin_info);

    const clear_values = [_]vk.ClearValue{
        .{ .color = .{ .float_32 = .{ 0.1, 0.1, 0.1, 1 } } },
    };
    const render_pass_begin_info = vk.RenderPassBeginInfo{
        .render_pass = render_pass,
        .framebuffer = framebuffer,
        .render_area = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = extent,
        },
        .clear_value_count = clear_values.len,
        .p_clear_values = &clear_values,
    };

    vkd().cmdBeginRenderPass(command_buffer, &render_pass_begin_info, .@"inline");

    const viewport = vk.Viewport{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(extent.width),
        .height = @floatFromInt(extent.height),
        .min_depth = 0,
        .max_depth = 1,
    };
    vkd().cmdSetViewport(command_buffer, 0, 1, @ptrCast(&viewport));

    const scissor = vk.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = extent,
    };
    vkd().cmdSetScissor(command_buffer, 0, 1, @ptrCast(&scissor));

    vkd().cmdBindPipeline(command_buffer, .graphics, pipeline);

    vkd().cmdDraw(command_buffer, 3, 1, 0, 0);

    vkd().cmdEndRenderPass(command_buffer);
    try vkd().endCommandBuffer(command_buffer);
}

fn createCommandBuffers(
    allocator: std.mem.Allocator,
    device: vk.Device,
    command_pool: vk.CommandPool,
    count: u32,
) ![]vk.CommandBuffer {
    const command_buffers = try allocator.alloc(vk.CommandBuffer, count);
    errdefer allocator.free(command_buffers);

    const command_buffer_info = vk.CommandBufferAllocateInfo{
        .command_pool = command_pool,
        .level = .primary,
        .command_buffer_count = count,
    };
    try vkd().allocateCommandBuffers(device, &command_buffer_info, command_buffers.ptr);

    return command_buffers;
}

fn createCommandPool(device: vk.Device, queue_family_index: u32) !vk.CommandPool {
    const create_info = vk.CommandPoolCreateInfo{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = queue_family_index,
    };
    return vkd().createCommandPool(device, &create_info, null);
}

fn createGraphicsPipeline(
    device: vk.Device,
    render_pass: vk.RenderPass,
    vertex_shader: vk.ShaderModule,
    fragment_shader: vk.ShaderModule,
    pipeline_layout: vk.PipelineLayout,
) !vk.Pipeline {
    const shader_stages = [2]vk.PipelineShaderStageCreateInfo{
        .{
            .stage = .{ .vertex_bit = true },
            .module = vertex_shader,
            .p_name = "main",
        },
        .{
            .stage = .{ .fragment_bit = true },
            .module = fragment_shader,
            .p_name = "main",
        },
    };

    const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
    const dynamic_state_info = vk.PipelineDynamicStateCreateInfo{
        .dynamic_state_count = dynamic_states.len,
        .p_dynamic_states = &dynamic_states,
    };

    const viewport_state_info = vk.PipelineViewportStateCreateInfo{
        .viewport_count = 1,
        .scissor_count = 1,
    };

    const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{};

    const input_assembly_info = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = .triangle_list,
        .primitive_restart_enable = vk.FALSE,
    };

    const rasterizer_info = vk.PipelineRasterizationStateCreateInfo{
        .depth_clamp_enable = vk.FALSE,
        .rasterizer_discard_enable = vk.FALSE,
        .polygon_mode = .fill,
        .line_width = 1,
        .cull_mode = .{ .back_bit = true },
        .front_face = .clockwise,
        .depth_bias_enable = vk.FALSE,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
    };

    const multisampling_info = vk.PipelineMultisampleStateCreateInfo{
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = vk.FALSE,
        .min_sample_shading = 1,
        .alpha_to_coverage_enable = vk.FALSE,
        .alpha_to_one_enable = vk.FALSE,
    };

    const color_blend_attachments = [_]vk.PipelineColorBlendAttachmentState{.{
        .blend_enable = vk.FALSE,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    }};

    const color_blend_info = vk.PipelineColorBlendStateCreateInfo{
        .logic_op_enable = vk.FALSE,
        .logic_op = .copy,
        .attachment_count = color_blend_attachments.len,
        .p_attachments = &color_blend_attachments,
        .blend_constants = .{ 0, 0, 0, 0 },
    };

    const pipeline_info = vk.GraphicsPipelineCreateInfo{
        .stage_count = shader_stages.len,
        .p_stages = &shader_stages,
        .p_vertex_input_state = &vertex_input_info,
        .p_input_assembly_state = &input_assembly_info,
        .p_viewport_state = &viewport_state_info,
        .p_rasterization_state = &rasterizer_info,
        .p_multisample_state = &multisampling_info,
        .p_color_blend_state = &color_blend_info,
        .p_dynamic_state = &dynamic_state_info,
        .layout = pipeline_layout,
        .render_pass = render_pass,
        .subpass = 0,
        .base_pipeline_index = -1,
    };

    var graphics_pipeline: vk.Pipeline = .null_handle;
    const result = try vkd().createGraphicsPipelines(
        device,
        .null_handle,
        1,
        @ptrCast(&pipeline_info),
        null,
        @ptrCast(&graphics_pipeline),
    );
    errdefer vkd().destroyPipeline(device, graphics_pipeline, null);

    if (result != .success) return error.PipelineCreationFailed;

    return graphics_pipeline;
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
