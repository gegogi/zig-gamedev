const std = @import("std");
const math = std.math;
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zgui = @import("zgui");
const zm = @import("zmath");
const sdl = @import("zsdl2");
const sdl_image = @import("zsdl2_image");
const zstbi = @import("zstbi");
const file_dlg = @import("file_dlg.zig");
const wgsl = @import("zxbrush_wgsl.zig");

const content_dir = @import("build_options").content_dir;
const window_title = "ZXBrush";

const Vertex = extern struct {
    position: [3]f32,
    texcoord: [2]f32,
};

//const Mesh = struct {
//    index_offset: u32,
//    vertex_offset: i32,
//    num_indices: u32,
//    num_vertices: u32,
//};

const MeshUniforms = struct {
    object_to_world: zm.Mat,
    world_to_clip: zm.Mat,
};

const App = struct {
    gctx: *zgpu.GraphicsContext,

    vertex_buf: zgpu.BufferHandle = undefined,
    index_buf: zgpu.BufferHandle = undefined,
    depth_tex: zgpu.TextureHandle = undefined,
    depth_texv: zgpu.TextureViewHandle = undefined,
    main_bgl: zgpu.BindGroupLayoutHandle = undefined,
    main_samp: zgpu.SamplerHandle = undefined,
    main_pipe: zgpu.RenderPipelineHandle = undefined,

    img_w: u32 = 0,
    img_h: u32 = 0,
    img_tex: ?zgpu.TextureHandle = null,
    img_texv: ?zgpu.TextureViewHandle = null,
    img_rend_bg: ?zgpu.BindGroupHandle = undefined,

    const Self = @This();

    pub fn init(gctx: *zgpu.GraphicsContext, allocator: std.mem.Allocator) App {
        var self = App{
            .gctx = gctx,
        };
        self.main_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .vertex = true, .fragment = true }, .uniform, true, 0),
            zgpu.textureEntry(1, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.samplerEntry(2, .{ .fragment = true }, .filtering),
        });
        self.main_samp = gctx.createSampler(.{
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .linear,
            .max_anisotropy = 1,
        });

        const indices: [6]u32 = .{ 0, 1, 2, 0, 2, 3 };
        const positions: [4][3]f32 = .{ .{ -0.5, -0.5, 0.0 }, .{ 0.5, -0.5, 0.0 }, .{ 0.5, 0.5, 0.0 }, .{ -0.5, 0.5, 0.0 } };
        const texcoords: [4][2]f32 = .{ .{ 0.0, 1.0 }, .{ 1.0, 1.0 }, .{ 1.0, 0.0 }, .{ 0.0, 0.0 } };

        // VB
        self.vertex_buf = gctx.createBuffer(.{
            .usage = .{ .copy_dst = true, .vertex = true },
            .size = positions.len * @sizeOf(Vertex),
        });
        var vertex_data: [positions.len]Vertex = undefined;
        for (positions, 0..) |_, i| {
            vertex_data[i].position = positions[i];
            vertex_data[i].texcoord = texcoords[i];
        }
        gctx.queue.writeBuffer(gctx.lookupResource(self.vertex_buf).?, 0, Vertex, &vertex_data);
        // IB
        self.index_buf = gctx.createBuffer(.{
            .usage = .{ .copy_dst = true, .index = true },
            .size = indices.len * @sizeOf(u32),
        });
        gctx.queue.writeBuffer(gctx.lookupResource(self.index_buf).?, 0, u32, &indices);

        const depth = createDepthTexture(gctx);
        self.depth_tex = depth.tex;
        self.depth_texv = depth.texv;
        createRenderPipe(
            allocator,
            gctx,
            &.{self.main_bgl},
            wgsl.img_vs,
            wgsl.img_fs,
            zgpu.GraphicsContext.swapchain_format,
            false,
            wgpu.DepthStencilState{
                .format = .depth32_float,
                .depth_write_enabled = true,
                .depth_compare = .less_equal,
            },
            &self.main_pipe,
        );
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.clearImage();
        self.gctx.releaseResource(self.main_pipe);
        self.gctx.releaseResource(self.main_bgl);
        self.gctx.releaseResource(self.depth_texv);
        self.gctx.destroyResource(self.depth_tex);
    }

    pub fn clearImage(self: *Self) void {
        if (self.img_rend_bg != null) {
            self.gctx.releaseResource(self.img_rend_bg.?);
            self.img_rend_bg = null;
        }
        if (self.img_texv != null) {
            self.gctx.releaseResource(self.img_texv.?);
            self.img_texv = null;
        }
        if (self.img_tex != null) {
            self.gctx.destroyResource(self.img_tex.?);
            self.img_tex = null;
        }
        self.img_w = 0;
        self.img_h = 0;
    }

    pub fn setStiImage(self: *Self, image: zstbi.Image) void {
        const img_w = image.width;
        const img_h = image.height;
        const img_num_components = image.num_components;
        const img_bytes_per_component = image.bytes_per_component;
        const img_is_hdr = image.is_hdr;
        const img_bytes_per_row = image.bytes_per_row;
        const img_data = image.data;

        self.setImageData(img_w, img_h, img_num_components, img_bytes_per_component, img_is_hdr, img_bytes_per_row, img_data);
    }

    pub fn setSdlImage(self: *Self, image: *sdl.Surface) void {
        const img_w: u32 = @intCast(image.w);
        const img_h: u32 = @intCast(image.h);

        std.debug.assert(image.format != null);
        const img_fmt = image.format.?.*;
        const img_num_components: u32 = switch (img_fmt) {
            .argb8888 => 4,
            else => 3,
        };
        const img_is_hdr = false;
        const img_bytes_per_component: u32 = switch (img_fmt) {
            .argb8888 => 1,
            else => 1,
        };
        const img_bytes_per_row = img_bytes_per_component * img_num_components * img_h;
        const img_data_len = img_h * img_bytes_per_row;
        const img_data = @as([*]u8, @ptrCast(image.pixels))[0..img_data_len];

        self.setImageData(img_w, img_h, img_num_components, img_bytes_per_component, img_is_hdr, img_bytes_per_row, img_data);
    }

    fn setImageData(self: *Self, w: u32, h: u32, num_componenets: u32, bytes_per_component: u32, is_hdr: bool, bytes_per_row: u32, data: []const u8) void {
        self.img_w = w;
        self.img_h = h;

        self.img_tex = self.gctx.createTexture(.{
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .size = .{
                .width = w,
                .height = h,
                .depth_or_array_layers = 1,
            },
            .format = zgpu.imageInfoToTextureFormat(
                num_componenets,
                bytes_per_component,
                is_hdr,
            ),
            .mip_level_count = 1,
        });
        self.img_texv = self.gctx.createTextureView(self.img_tex.?, .{});
        self.gctx.queue.writeTexture(
            .{ .texture = self.gctx.lookupResource(self.img_tex.?).? },
            .{
                .bytes_per_row = bytes_per_row,
                .rows_per_image = h,
            },
            .{ .width = w, .height = h },
            u8,
            data,
        );

        self.img_rend_bg = self.gctx.createBindGroup(self.main_bgl, &.{
            .{ .binding = 0, .buffer_handle = self.gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(MeshUniforms) },
            .{ .binding = 1, .texture_view_handle = self.img_texv },
            .{ .binding = 2, .sampler_handle = self.main_samp },
        });
    }
};

var app: App = undefined;
var file_dlg_obj: ?*file_dlg.FileDialog = null;
var file_dlg_open: bool = false;

fn open_img(fpath: [:0]const u8) !void {
    std.debug.print("opening file: {s}\n", .{fpath});

    app.clearImage();

    const useSdl = true;
    if (useSdl) {
        const image = sdl_image.load(@ptrCast(fpath)) catch unreachable;
        defer image.free();
        app.setSdlImage(image);
    } else {
        var image = try zstbi.Image.loadFromFile(@ptrCast(fpath), 4);
        defer image.deinit();
        app.setStiImage(image);
    }
}

fn createRenderPipe(
    allocator: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,
    bgls: []const zgpu.BindGroupLayoutHandle,
    wgsl_vs: [:0]const u8,
    wgsl_fs: [:0]const u8,
    format: wgpu.TextureFormat,
    only_position_attrib: bool,
    depth_state: ?wgpu.DepthStencilState,
    out_pipe: *zgpu.RenderPipelineHandle,
) void {
    _ = allocator;

    const pl = gctx.createPipelineLayout(bgls);
    defer gctx.releaseResource(pl);

    const vs_mod = zgpu.createWgslShaderModule(gctx.device, wgsl_vs, null);
    defer vs_mod.release();

    const fs_mod = zgpu.createWgslShaderModule(gctx.device, wgsl_fs, null);
    defer fs_mod.release();

    const color_targets = [_]wgpu.ColorTargetState{.{
        .format = format,
    }};

    const vertex_attributes = [_]wgpu.VertexAttribute{
        .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
        .{ .format = .float32x2, .offset = @offsetOf(Vertex, "texcoord"), .shader_location = 1 },
    };
    const vertex_buffers = [_]wgpu.VertexBufferLayout{.{
        .array_stride = @sizeOf(Vertex),
        .attribute_count = if (only_position_attrib) 1 else vertex_attributes.len,
        .attributes = &vertex_attributes,
    }};

    // Create a render pipeline.
    const pipe_desc = wgpu.RenderPipelineDescriptor{
        .vertex = wgpu.VertexState{
            .module = vs_mod,
            .entry_point = "main",
            .buffer_count = vertex_buffers.len,
            .buffers = &vertex_buffers,
        },
        .fragment = &wgpu.FragmentState{
            .module = fs_mod,
            .entry_point = "main",
            .target_count = color_targets.len,
            .targets = &color_targets,
        },
        .depth_stencil = if (depth_state) |ds| &ds else null,
    };

    out_pipe.* = gctx.createRenderPipeline(pl, pipe_desc);
}

fn createDepthTexture(gctx: *zgpu.GraphicsContext) struct {
    tex: zgpu.TextureHandle,
    texv: zgpu.TextureViewHandle,
} {
    const tex = gctx.createTexture(.{
        .usage = .{ .render_attachment = true },
        .dimension = .tdim_2d,
        .size = .{
            .width = gctx.swapchain_descriptor.width,
            .height = gctx.swapchain_descriptor.height,
            .depth_or_array_layers = 1,
        },
        .format = .depth32_float,
        .mip_level_count = 1,
        .sample_count = 1,
    });
    const texv = gctx.createTextureView(tex, .{});
    return .{ .tex = tex, .texv = texv };
}

fn update_ui() !void {
    //if (app.img_texv != null) {
    //    const tex_id = gctx.lookupResource(app.img_texv.?).?;
    //    zgui.image(tex_id, .{ .w = @floatFromInt(app.img_w), .h = @floatFromInt(app.img_h) });
    //}

    if (zgui.beginMainMenuBar()) {
        if (zgui.beginMenu("File", true)) {
            if (zgui.menuItem("Open", .{})) {
                file_dlg_open = true;
                file_dlg_obj.?.is_saving = false;
            }
            if (zgui.menuItem("Save", .{})) {
                file_dlg_open = true;
                file_dlg_obj.?.is_saving = true;
            }
            zgui.endMenu();
        }
        if (zgui.beginMenu("Edit", true)) {
            if (zgui.menuItem("Item", .{})) {
                std.debug.print("Item selected\n", .{});
            }
            zgui.endMenu();
        }
        zgui.endMainMenuBar();
    }

    // if (zgui.begin("My window", .{})) {
    //     if (zgui.button("Press me!", .{ .w = 200.0 })) {
    //         std.debug.print("Button pressed\n", .{});
    //     }
    //     zgui.end();
    // }

    if (file_dlg_open) {
        var need_confirm: bool = false;
        std.debug.assert(file_dlg_obj != null);
        file_dlg_open = try file_dlg_obj.?.ui(&need_confirm);
        //_ = need_confirm;
    }
}

pub fn main() !void {
    var allocator_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = allocator_state.deinit();
    const allocator = allocator_state.allocator();

    try zglfw.init();
    defer zglfw.terminate();

    zstbi.init(allocator);
    defer zstbi.deinit();

    // Change current working directory to where the executable is located.
    {
        var buffer: [1024]u8 = undefined;
        const path = std.fs.selfExeDirPath(buffer[0..]) catch ".";
        std.posix.chdir(path) catch {};
    }

    zglfw.windowHintTyped(.client_api, .no_api);

    const window = try zglfw.Window.create(800, 800, window_title, null);
    defer window.destroy();
    window.setSizeLimits(400, 400, -1, -1);

    const gctx = try zgpu.GraphicsContext.create(
        allocator,
        .{
            .window = window,
            .fn_getTime = @ptrCast(&zglfw.getTime),
            .fn_getFramebufferSize = @ptrCast(&zglfw.Window.getFramebufferSize),
            .fn_getWin32Window = @ptrCast(&zglfw.getWin32Window),
            .fn_getX11Display = @ptrCast(&zglfw.getX11Display),
            .fn_getX11Window = @ptrCast(&zglfw.getX11Window),
            .fn_getWaylandDisplay = @ptrCast(&zglfw.getWaylandDisplay),
            .fn_getWaylandSurface = @ptrCast(&zglfw.getWaylandWindow),
            .fn_getCocoaWindow = @ptrCast(&zglfw.getCocoaWindow),
        },
        .{},
    );
    defer gctx.destroy(allocator);

    app = App.init(gctx, allocator);
    defer app.deinit();

    const scale_factor = scale_factor: {
        const scale = window.getContentScale();
        break :scale_factor @max(scale[0], scale[1]);
    };

    zgui.init(allocator);
    defer zgui.deinit();

    _ = zgui.io.addFontFromFile(
        content_dir ++ "Roboto-Medium.ttf",
        std.math.floor(16.0 * scale_factor),
    );

    zgui.backend.init(
        window,
        gctx.device,
        @intFromEnum(zgpu.GraphicsContext.swapchain_format),
        @intFromEnum(wgpu.TextureFormat.undef),
    );
    defer zgui.backend.deinit();

    zgui.getStyle().scaleAllSizes(scale_factor);

    if (file_dlg_obj == null) {
        file_dlg_obj = try file_dlg.FileDialog.create(allocator, "File Dialog", &.{ ".png", ".jpg" }, false, open_img);
    }

    while (!window.shouldClose() and window.getKey(.escape) != .press) {
        zglfw.pollEvents();

        zgui.backend.newFrame(
            gctx.swapchain_descriptor.width,
            gctx.swapchain_descriptor.height,
        );

        // Set the starting window position and size to custom values
        zgui.setNextWindowPos(.{ .x = 20.0, .y = 20.0, .cond = .first_use_ever });
        zgui.setNextWindowSize(.{ .w = -1.0, .h = -1.0, .cond = .first_use_ever });

        try update_ui();

        const fb_width = gctx.swapchain_descriptor.width;
        const fb_height = gctx.swapchain_descriptor.height;
        // const cam_world_to_view = zm.lookToLh(zm.loadArr3(.{ 0.0, 0.0, -1.0 }), zm.loadArr3(.{ 0.0, 0.0, 1.0 }), zm.loadArr3{.{ 0.0, 1.0, 0.0 }});
        // const cam_view_to_clip = zm.perspectiveFovLh(
        //     math.pi / @as(f32, 3.0),
        //     @as(f32, @floatFromInt(fb_width)) / @as(f32, @floatFromInt(fb_height)),
        //     0.01,
        //     200.0,
        // );
        // const cam_world_to_clip = zm.mul(cam_world_to_view, cam_view_to_clip);
        const cam_world_to_clip = zm.orthographicLh(@floatFromInt(fb_width), @floatFromInt(fb_height), -1.0, 1.0);
        const object_to_world = zm.scaling(@floatFromInt(app.img_w), @floatFromInt(app.img_h), 1.0);

        const swapchain_texv = gctx.swapchain.getCurrentTextureView();
        defer swapchain_texv.release();

        const commands = commands: {
            const encoder = gctx.device.createCommandEncoder(null);
            defer encoder.release();

            // Main pass
            if (app.img_rend_bg != null) {
                pass: {
                    // TODO : move to outside
                    const vb_info = gctx.lookupResourceInfo(app.vertex_buf) orelse break :pass;
                    const ib_info = gctx.lookupResourceInfo(app.index_buf) orelse break :pass;
                    const mesh_pipe = gctx.lookupResource(app.main_pipe) orelse break :pass;
                    const depth_texv = gctx.lookupResource(app.depth_texv) orelse break :pass;

                    const img_rend_bg = gctx.lookupResource(app.img_rend_bg.?) orelse break :pass;

                    const pass = zgpu.beginRenderPassSimple(encoder, .clear, swapchain_texv, null, depth_texv, 1.0);
                    defer zgpu.endReleasePass(pass);

                    pass.setVertexBuffer(0, vb_info.gpuobj.?, 0, vb_info.size);
                    pass.setIndexBuffer(ib_info.gpuobj.?, .uint32, 0, ib_info.size);
                    pass.setPipeline(mesh_pipe);
                    {
                        const mem = gctx.uniformsAllocate(MeshUniforms, 1);
                        mem.slice[0] = .{
                            .object_to_world = zm.transpose(object_to_world),
                            .world_to_clip = zm.transpose(cam_world_to_clip),
                        };
                        pass.setBindGroup(0, img_rend_bg, &.{mem.offset});
                    }
                    pass.drawIndexed(6, 1, 0, 0, 0);
                }
            }

            // GUI pass
            {
                const pass = zgpu.beginRenderPassSimple(encoder, .load, swapchain_texv, null, null, null);
                defer zgpu.endReleasePass(pass);
                zgui.backend.draw(pass);
            }

            break :commands encoder.finish(null);
        };
        defer commands.release();

        gctx.submit(&.{commands});

        if (gctx.present() == .swap_chain_resized) {
            // Release old depth texture.
            gctx.releaseResource(app.depth_texv);
            gctx.destroyResource(app.depth_tex);

            // Create a new depth texture to match the new window size.
            const depth = createDepthTexture(gctx);
            app.depth_tex = depth.tex;
            app.depth_texv = depth.texv;
        }
    }

    if (file_dlg_obj != null) {
        file_dlg_obj.?.destroy();
    }
}
