const builtin = @import("builtin");
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
const useSdl = false;
// stbi supported set
const stbi_img_exts: [10][]const u8 = .{ ".jpg", ".jpeg", ".png", ".tga", ".bmp", ".psd", ".gif", ".hdr", ".pic", ".pnm" };
// sdl supported set
const sdl_img_exts: [12][]const u8 = .{ ".bmp", ".gif", ".jpg", ".jpeg", ".lbm", ".pcx", ".png", ".pnm", ".qoi", ".tga", ".xcf", ".xpm" };
const img_exts: []const []const u8 = if (useSdl) &sdl_img_exts else &stbi_img_exts;

const Allocator = std.mem.Allocator;
const PathStr = file_dlg.PathStr;
const DirList = file_dlg.DirList;
const PathStrList = std.ArrayList(*PathStr);

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
    object_to_world_edge: zm.Mat,
    world_to_clip: zm.Mat,
};

const ImageFit = enum(i32) {
    original = 0,
    osScale,
    width,
    height,
    autoAspect,
    resizeWin,
    count,
};

const ImageObj = struct {
    w: u32 = 0,
    h: u32 = 0,
    tex: zgpu.TextureHandle = undefined,
    texv: zgpu.TextureViewHandle = undefined,

    fn initWithStiImage(gctx: *zgpu.GraphicsContext, image: zstbi.Image) !ImageObj {
        const img_w = image.width;
        const img_h = image.height;
        const img_num_components = image.num_components;
        const img_bytes_per_component = image.bytes_per_component;
        const img_is_hdr = image.is_hdr;
        const img_bytes_per_row = image.bytes_per_row;
        const img_data = image.data;
        return try ImageObj.initData(gctx, img_w, img_h, img_num_components, img_bytes_per_component, img_is_hdr, img_bytes_per_row, img_data);
    }

    fn initWithSdlImage(gctx: *zgpu.GraphicsContext, image: *sdl.Surface) !ImageObj {
        const img_w: u32 = @intCast(image.w);
        const img_h: u32 = @intCast(image.h);

        std.debug.assert(image.format != null);
        const img_fmt = image.format.?.*;
        const img_num_components: u32 = switch (img_fmt) {
            .argb8888, .rgba8888, .abgr8888, .bgra8888 => 4,
            .xrgb8888, .rgbx8888, .xbgr8888, .bgrx8888 => 3,
            else => 3,
        };
        const img_is_hdr = false;
        const img_bytes_per_component: u32 = switch (img_fmt) {
            .argb8888, .rgba8888, .abgr8888, .bgra8888, .xrgb8888, .rgbx8888, .xbgr8888, .bgrx8888 => 1,
            else => 1,
        };
        const img_bytes_per_row = img_bytes_per_component * img_num_components * img_w;
        const img_data_len = img_h * img_bytes_per_row;
        const img_data = @as([*]u8, @ptrCast(image.pixels))[0..img_data_len];

        return try ImageObj.initData(gctx, img_w, img_h, img_num_components, img_bytes_per_component, img_is_hdr, img_bytes_per_row, img_data);
    }

    fn initData(gctx: *zgpu.GraphicsContext, w: u32, h: u32, num_components: u32, bytes_per_component: u32, is_hdr: bool, bytes_per_row: u32, data: []const u8) !ImageObj {
        var self: ImageObj = .{};
        self.w = w;
        self.h = h;

        const tex_format = zgpu.imageInfoToTextureFormat(num_components, bytes_per_component, is_hdr);
        if (tex_format == .undef) return error.FormatNotSupported;

        self.tex = gctx.createTexture(.{
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .size = .{
                .width = w,
                .height = h,
                .depth_or_array_layers = 1,
            },
            .format = tex_format,
            .mip_level_count = 1,
        });
        self.texv = gctx.createTextureView(self.tex, .{});
        gctx.queue.writeTexture(
            .{ .texture = gctx.lookupResource(self.tex).? },
            .{
                .bytes_per_row = bytes_per_row,
                .rows_per_image = h,
            },
            .{ .width = w, .height = h },
            u8,
            data,
        );
        return self;
    }

    fn deinit(self: *ImageObj, gctx: *zgpu.GraphicsContext) void {
        gctx.releaseResource(self.texv);
        gctx.destroyResource(self.tex);
        self.w = 0;
        self.h = 0;
    }
};

const App = struct {
    allocator: Allocator,
    window: *zglfw.Window,
    gctx: *zgpu.GraphicsContext,
    os_scale_factor: f32 = 1.0,

    // settings
    reset_view_scale_on_clear: bool = false,
    img_fit: ImageFit = .original,

    // state
    img_ext_set: ?*file_dlg.ExtSet = undefined,
    cur_dir_ls: DirList = undefined,
    config: std.StringHashMap(*PathStr) = undefined,
    open_file_history: PathStrList = undefined,

    // env
    vertex_buf: zgpu.BufferHandle = undefined,
    index_buf: zgpu.BufferHandle = undefined,
    depth_tex: zgpu.TextureHandle = undefined,
    depth_texv: zgpu.TextureViewHandle = undefined,
    img_rend_bgl: zgpu.BindGroupLayoutHandle = undefined,
    edge_rend_bgl: zgpu.BindGroupLayoutHandle = undefined,
    near_samp: zgpu.SamplerHandle = undefined,
    lin_samp: zgpu.SamplerHandle = undefined,
    img_rend_pipe: zgpu.RenderPipelineHandle = undefined,
    edge_rend_pipe: zgpu.RenderPipelineHandle = undefined,

    img_obj: ?ImageObj = null,

    img_rend_bg: ?zgpu.BindGroupHandle = null,
    edge_rend_bg: ?zgpu.BindGroupHandle = null,
    img_view_scale: f32 = 1.0,
    img_path: PathStr = undefined,

    const Self = @This();

    pub fn create(allocator: Allocator, window: *zglfw.Window, gctx: *zgpu.GraphicsContext) !*Self {
        var self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .window = window,
            .gctx = gctx,
        };
        self.img_rend_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .vertex = true, .fragment = true }, .uniform, true, 0),
            zgpu.textureEntry(1, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.samplerEntry(2, .{ .fragment = true }, .filtering),
        });
        self.edge_rend_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .vertex = true, .fragment = true }, .uniform, true, 0),
        });

        self.near_samp = gctx.createSampler(.{
            .mag_filter = .nearest,
            .min_filter = .nearest,
            .mipmap_filter = .nearest,
            .max_anisotropy = 1,
        });
        self.lin_samp = gctx.createSampler(.{
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .linear,
            .max_anisotropy = 1,
        });

        const indices: [6]u32 = .{ 0, 1, 2, 0, 2, 3 };
        const positions: [4][3]f32 = .{ .{ -0.5, -0.5, 0.0 }, .{ 0.5, -0.5, 0.0 }, .{ 0.5, 0.5, 0.0 }, .{ -0.5, 0.5, 0.0 } };
        const texcoords: [4][2]f32 = .{ .{ 0.0, 1.0 }, .{ 1.0, 1.0 }, .{ 1.0, 0.0 }, .{ 0.0, 0.0 } };
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
            &.{self.img_rend_bgl},
            wgsl.img_vs,
            wgsl.img_fs,
            zgpu.GraphicsContext.swapchain_format,
            false,
            wgpu.DepthStencilState{
                .format = .depth32_float,
                .depth_write_enabled = true,
                .depth_compare = .less_equal,
            },
            &self.img_rend_pipe,
        );
        createRenderPipe(
            allocator,
            gctx,
            &.{self.edge_rend_bgl},
            wgsl.edge_vs,
            wgsl.edge_fs,
            zgpu.GraphicsContext.swapchain_format,
            false,
            wgpu.DepthStencilState{
                .format = .depth32_float,
                .depth_write_enabled = true,
                .depth_compare = .less_equal,
            },
            &self.edge_rend_pipe,
        );

        self.img_ext_set = file_dlg.createExtSet(allocator, img_exts) catch null;
        self.cur_dir_ls = DirList.init(allocator);
        self.config = std.StringHashMap(*PathStr).init(allocator);
        self.open_file_history = PathStrList.init(allocator);
        self.img_path.set("");

        return self;
    }

    pub fn destroy(self: *Self) void {
        self.clearImage();

        for (self.open_file_history.items) |path| {
            self.allocator.destroy(path);
        }
        self.open_file_history.deinit();

        var cfg_iter = self.config.iterator();
        while (cfg_iter.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            self.allocator.destroy(kv.value_ptr.*);
        }
        self.config.deinit();

        self.cur_dir_ls.deinit();

        if (self.img_ext_set != null) {
            self.img_ext_set.?.clearAndFree();
            self.allocator.destroy(self.img_ext_set.?);
        }

        self.gctx.releaseResource(self.edge_rend_pipe);
        self.gctx.releaseResource(self.img_rend_pipe);
        self.gctx.releaseResource(self.edge_rend_bgl);
        self.gctx.releaseResource(self.img_rend_bgl);
        self.gctx.releaseResource(self.lin_samp);
        self.gctx.releaseResource(self.near_samp);
        self.gctx.releaseResource(self.depth_texv);
        self.gctx.destroyResource(self.depth_tex);
        self.allocator.destroy(self);
    }

    pub fn clearImage(self: *Self) void {
        if (self.edge_rend_bg != null) {
            self.gctx.releaseResource(self.edge_rend_bg.?);
            self.edge_rend_bg = null;
        }
        if (self.img_rend_bg != null) {
            self.gctx.releaseResource(self.img_rend_bg.?);
            self.img_rend_bg = null;
        }
        if (self.img_obj != null) {
            self.img_obj.?.deinit(self.gctx);
            self.img_obj = null;
        }
        self.img_path.set("");
        if (self.reset_view_scale_on_clear) {
            self.img_view_scale = 1.0;
        }
    }

    fn setImageObj(self: *Self, img_obj: ImageObj) !void {
        self.img_obj = img_obj;

        self.img_rend_bg = self.gctx.createBindGroup(self.img_rend_bgl, &.{
            .{ .binding = 0, .buffer_handle = self.gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(MeshUniforms) },
            .{ .binding = 1, .texture_view_handle = self.img_obj.?.texv },
            .{ .binding = 2, .sampler_handle = self.near_samp },
        });
        self.edge_rend_bg = self.gctx.createBindGroup(self.edge_rend_bgl, &.{
            .{ .binding = 0, .buffer_handle = self.gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(MeshUniforms) },
        });
    }

    fn updateViewScale(self: *Self, canResizeWin: bool) void {
        // adjust image scale or window size
        var fb_w = self.gctx.swapchain_descriptor.width;
        var fb_h = self.gctx.swapchain_descriptor.height;
        const img_w = self.img_obj.?.w;
        const img_h = self.img_obj.?.h;

        var img_fit = self.img_fit;
        if (img_fit == .autoAspect) {
            const img_ratio = @as(f32, @floatFromInt(img_w)) / @as(f32, @floatFromInt(img_h));
            const fb_ratio = @as(f32, @floatFromInt(fb_w)) / @as(f32, @floatFromInt(fb_h));
            if (img_ratio >= fb_ratio) {
                img_fit = .width;
            } else {
                img_fit = .height;
            }
        }

        if (img_fit == .original) {
            self.img_view_scale = 1.0;
        } else if (img_fit == .osScale) {
            self.img_view_scale = self.os_scale_factor;
        } else if (img_fit == .width) {
            self.img_view_scale = @as(f32, @floatFromInt(fb_w)) / @as(f32, @floatFromInt(img_w));
        } else if (img_fit == .height) {
            self.img_view_scale = @as(f32, @floatFromInt(fb_h)) / @as(f32, @floatFromInt(img_h));
        } else if (img_fit == .resizeWin) {
            if (canResizeWin) {
                const win_w = @as(i32, @intFromFloat(@as(f32, @floatFromInt(img_w)) * self.os_scale_factor));
                const win_h = @as(i32, @intFromFloat(@as(f32, @floatFromInt(img_h)) * self.os_scale_factor));
                app.window.setSize(win_w, win_h);
                fb_w = @intFromFloat(@as(f32, @floatFromInt(win_w)) * self.os_scale_factor);
                fb_h = @intFromFloat(@as(f32, @floatFromInt(win_h)) * self.os_scale_factor);
                self.img_view_scale = @as(f32, @floatFromInt(fb_w)) / @as(f32, @floatFromInt(img_w));
            }
        }
    }

    fn onOpenAppImage(self: *Self, fpath: []const u8) !void {
        self.img_path.set(fpath);
        const dpath = std.fs.path.dirname(fpath) orelse "";
        if (dpath.len == 0) return;

        if (!self.cur_dir_ls.is_populated or !std.mem.eql(u8, self.cur_dir_ls.dpath.str, dpath)) {
            var dir = try std.fs.openDirAbsolute(dpath, .{});
            defer dir.close();
            try dir.setAsCwd();
            std.debug.print("chdir: {s}", .{dpath});
            self.cur_dir_ls.reset();
            try self.cur_dir_ls.populate(dpath, false, self.img_ext_set);
        }

        // manage history
        const fpath_str = try self.allocator.create(PathStr);
        fpath_str.set(fpath);
        try self.open_file_history.insert(0, fpath_str);

        // remove dups
        var i: usize = 1;
        var hist = &self.open_file_history;
        while (i < hist.items.len) {
            const fpath_in_hist = hist.items[i].str;
            if (i >= 5 or std.mem.eql(u8, fpath, fpath_in_hist)) {
                const removed_fpath = hist.orderedRemove(i);
                self.allocator.destroy(removed_fpath);
                continue;
            }
            i += 1;
        }

        var hist_fpath_str: PathStr = undefined;
        const hist_fpath = getAppFilePath(&hist_fpath_str, "zxbrush_content/history.txt");
        try savePathStrList(hist, hist_fpath);

        self.updateViewScale(true);
    }

    fn updateConfigMap(self: *Self) !void {
        var buf: [1024]u8 = undefined;

        if (self.config.getEntry("reset_view_scale_on_clear")) |kv| {
            const s = try std.fmt.bufPrintZ(&buf, "{d}", .{@intFromBool(self.reset_view_scale_on_clear)});
            kv.value_ptr.*.set(s);
        }
        if (self.config.getEntry("img_fit")) |kv| {
            const s = try std.fmt.bufPrintZ(&buf, "{d}", .{@intFromEnum(self.img_fit)});
            kv.value_ptr.*.set(s);
        }
    }

    fn applyConfigMap(self: *Self) void {
        if (self.config.get("reset_view_scale_on_clear")) |v| {
            self.reset_view_scale_on_clear = (std.fmt.parseInt(u32, v.str, 10) catch 0 != 0);
        }
        if (self.config.get("img_fit")) |v| {
            self.img_fit = @enumFromInt(std.fmt.parseInt(u32, v.str, 10) catch 0);
        }
    }
};

fn getAppFilePath(path: *PathStr, filename: []const u8) []const u8 {
    const exe_dir = std.fs.selfExeDirPath(path.buf[0..]) catch ".";
    path.setLen(exe_dir.len);
    path.replaceChar('\\', '/');
    path.concat("/");
    path.concat(filename);
    return path.str;
}

fn loadPathStrList(allocator: Allocator, str_list: *PathStrList, fpath: []const u8) !void {
    var file_obj = try std.fs.openFileAbsolute(fpath, .{ .mode = .read_only });
    defer file_obj.close();
    var buf_reader = std.io.bufferedReader(file_obj.reader());
    var reader = buf_reader.reader();

    var line_buf: [1024]u8 = undefined;
    while (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
        const line_str = try allocator.create(PathStr);
        line_str.set(line);
        try str_list.append(line_str);
    }
}

fn savePathStrList(str_list: *PathStrList, fpath: []const u8) !void {
    var file_obj = try std.fs.createFileAbsolute(fpath, .{});
    defer file_obj.close();
    var buf_writer = std.io.bufferedWriter(file_obj.writer());
    var writer = buf_writer.writer();

    for (str_list.items) |path_str| {
        _ = try writer.write(path_str.str);
        _ = try writer.write("\n");
    }
    try buf_writer.flush();
}

fn loadPathStrMap(allocator: Allocator, str_map: *std.StringHashMap(*PathStr), fpath: []const u8) !void {
    var file_obj = try std.fs.openFileAbsolute(fpath, .{ .mode = .read_only });
    defer file_obj.close();
    var buf_reader = std.io.bufferedReader(file_obj.reader());
    var reader = buf_reader.reader();

    var line_buf: [1024]u8 = undefined;
    while (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
        const key = std.mem.sliceTo(line, '=');
        const value = line[key.len + 1 ..];
        const key_str = try allocator.dupe(u8, key);
        const value_str = try allocator.create(PathStr);
        value_str.set(value);
        try str_map.put(key_str, value_str);
    }

    // var cfg_iter = str_map.iterator();
    // while (cfg_iter.next()) |kv| {
    //     std.debug.print("k={s}, v={s}\n", .{ kv.key_ptr.*, kv.value_ptr.*.str });
    // }
}

fn savePathStrMap(str_map: *std.StringHashMap(*PathStr), fpath: []const u8) !void {
    var file_obj = try std.fs.createFileAbsolute(fpath, .{});
    defer file_obj.close();
    var buf_writer = std.io.bufferedWriter(file_obj.writer());
    var writer = buf_writer.writer();

    var cfg_iter = str_map.iterator();
    while (cfg_iter.next()) |kv| {
        _ = try writer.write(kv.key_ptr.*);
        _ = try writer.write("=");
        _ = try writer.write(kv.value_ptr.*.str);
        _ = try writer.write("\n");
    }
    try buf_writer.flush();
}

var g_allocator: Allocator = undefined;
var app: *App = undefined;
var cmd_arg_fpath: ?PathStr = null;

var file_dlg_obj: ?*file_dlg.FileDialog = null;
var file_dlg_open: bool = false;
var sel_but_img_obj: ImageObj = undefined;
var line_but_img_obj: ImageObj = undefined;
var resize_dlg_open: bool = false;

// this is callback used by cocoa framework
export fn appOpenFile(fpath: [*c]const u8) callconv(.C) c_int {
    const ret: c_int = 1;
    cmd_arg_fpath = .{};
    cmd_arg_fpath.?.set(std.mem.sliceTo(fpath, 0));
    return ret;
}

fn openAppImage(fpath: [:0]const u8, is_saving: bool) !void {
    std.debug.print("opening file: {s}\n", .{fpath});

    app.clearImage();

    var img_obj: ImageObj = undefined;
    var failed = false;
    if (is_saving) {
        // TODO : implement save
    } else {
        if (useSdl) {
            const image = sdl_image.load(@ptrCast(fpath)) catch unreachable;
            defer image.free();
            img_obj = ImageObj.initWithSdlImage(app.gctx, image) catch blk: {
                failed = true;
                break :blk undefined;
            };
        } else {
            var image = try zstbi.Image.loadFromFile(@ptrCast(fpath), 4);
            defer image.deinit();
            img_obj = ImageObj.initWithStiImage(app.gctx, image) catch blk: {
                failed = true;
                break :blk undefined;
            };
        }
    }

    if (failed) {
        std.debug.print("failed to open app image: {s}\n", .{fpath});
    } else {
        try app.setImageObj(img_obj);
        try app.onOpenAppImage(fpath);
    }
}

fn openNeighborImage(offset: i32) !void {
    std.debug.assert(offset != 0);
    if (app.img_path.str.len == 0) {
        return;
    }

    const img_dpath = std.fs.path.dirname(app.img_path.str) orelse "";
    const img_fname = std.fs.path.basename(app.img_path.str);
    var next_fpath: ?PathStr = null;
    const names = app.cur_dir_ls.name_list.items;
    const name_count: i32 = @intCast(names.len);
    var i: i32 = undefined;
    if (offset > 0) {
        i = 0;
        while (i < name_count) : (i += 1) {
            const fname = names[@intCast(i)].str;
            if (std.mem.eql(u8, img_fname, fname)) {
                if (i < name_count - 1) {
                    next_fpath = .{};
                    next_fpath.?.set(img_dpath);
                    next_fpath.?.concat("/");
                    next_fpath.?.concat(app.cur_dir_ls.name_list.items[@intCast(i + 1)].str);
                    break;
                }
            }
        }
    } else {
        i = name_count - 1;
        while (i >= 0) : (i -= 1) {
            const fname = names[@intCast(i)].str;
            if (std.mem.eql(u8, img_fname, fname)) {
                if (i > 0) {
                    next_fpath = .{};
                    next_fpath.?.set(img_dpath);
                    next_fpath.?.concat("/");
                    next_fpath.?.concat(app.cur_dir_ls.name_list.items[@intCast(i - 1)].str);
                    break;
                }
            }
        }
    }
    if (next_fpath != null) {
        try openAppImage(next_fpath.?.str_z, false);
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

fn updateGUI() !void {
    if (zgui.beginMainMenuBar()) {
        if (zgui.beginMenu("File", true)) {
            if (zgui.menuItem("Load", .{})) {
                file_dlg_open = true;
                file_dlg_obj.?.is_saving = false;
            }
            if (zgui.menuItem("Save", .{})) {
                file_dlg_open = true;
                file_dlg_obj.?.is_saving = true;
            }
            zgui.separator();
            for (app.open_file_history.items) |path| {
                if (zgui.menuItem(path.str_z, .{})) {
                    openAppImage(path.str_z, false) catch {};
                }
            }
            zgui.endMenu();
        }
        if (zgui.beginMenu("Edit", true)) {
            if (zgui.menuItem("Clear", .{})) {
                app.clearImage();
            }
            if (zgui.menuItem("Resize", .{})) {
                resize_dlg_open = true;
            }
            if (zgui.menuItem("Crop Selected", .{})) {
                // TODO : crop
            }
            if (zgui.menuItem("Make Grayscale", .{})) {
                // TODO : grayscale
            }
            zgui.endMenu();
        }
        if (zgui.beginMenu("Config", true)) {
            var willCloseMenu = false;
            if (zgui.checkbox("Reset View Scale on Clear", .{ .v = &app.reset_view_scale_on_clear })) {
                willCloseMenu = true;
            }
            const cur_img_fit_str = @tagName(app.img_fit);
            if (zgui.beginCombo("Image Fit", .{ .preview_value = cur_img_fit_str })) {
                for (0..@intCast(@intFromEnum(ImageFit.count))) |i| {
                    if (zgui.selectable(@tagName(@as(ImageFit, @enumFromInt(i))), .{})) {
                        app.img_fit = @enumFromInt(i);
                        app.updateViewScale(true);
                        willCloseMenu = true;
                        break;
                    }
                }
                zgui.endCombo();
            }
            // combo를 선택했을 때 상위 메뉴까지 한번에 닫는 코드
            //if (willCloseMenu) {
            //    zgui.closeCurrentPopup();
            //}
            zgui.endMenu();
        }
        zgui.endMainMenuBar();
    }

    if (zgui.begin("Toolbox", .{})) {
        const sel_but_tex_id = app.gctx.lookupResource(sel_but_img_obj.texv).?;
        const line_but_tex_id = app.gctx.lookupResource(line_but_img_obj.texv).?;
        if (zgui.imageButton("Select", sel_but_tex_id, .{ .w = 64, .h = 64 })) {
            // select
        }
        zgui.sameLine(.{});
        if (zgui.imageButton("Line", line_but_tex_id, .{ .w = 64, .h = 64 })) {
            // line
        }
    }
    zgui.end();

    if (file_dlg_open) {
        var need_confirm: bool = false;
        std.debug.assert(file_dlg_obj != null);
        file_dlg_open = try file_dlg_obj.?.ui(&need_confirm);
        //_ = need_confirm;
    }

    if (resize_dlg_open) {
        if (zgui.begin("Resize Image", .{})) {
            var buf_w: [256:0]u8 = [_:0]u8{0} ** 256;
            var buf_h: [256:0]u8 = [_:0]u8{0} ** 256;
            _ = try std.fmt.bufPrintZ(&buf_w, "{d}", .{app.img_obj.?.w});
            _ = try std.fmt.bufPrintZ(&buf_h, "{d}", .{app.img_obj.?.h});
            _ = zgui.inputText("Width", .{ .buf = buf_w[0..], .flags = .{
                .chars_decimal = true,
            } });
            _ = zgui.inputText("Height", .{ .buf = buf_h[0..], .flags = .{
                .chars_decimal = true,
            } });
            if (zgui.button("OK", .{})) {
                resize_dlg_open = false;
            }
            zgui.sameLine(.{});
            if (zgui.button("Cancel", .{})) {
                resize_dlg_open = false;
            }
        }
        zgui.end();
    }
}

var prevOnKey: ?zglfw.Window.KeyFn = null;
var prevOnScroll: ?zglfw.Window.ScrollFn = null;

fn onKey(window: *zglfw.Window, key: zglfw.Key, scancode: i32, action: zglfw.Action, mods: zglfw.Mods) callconv(.C) void {
    var handled: bool = false;
    var openImageOffset: i32 = 0;
    if (key == .left or key == .comma) {
        if (action == .press) {
            openImageOffset = if (mods.shift) -5 else -1;
        }
    } else if (key == .right or key == .period) {
        if (action == .press) {
            openImageOffset = if (mods.shift) 5 else 1;
        }
    }
    if (openImageOffset != 0) {
        openNeighborImage(openImageOffset) catch {};
        handled = true;
    }

    if (prevOnKey != null) {
        prevOnKey.?(window, key, scancode, action, mods);
    }
}

fn onScroll(window: *zglfw.Window, xoffset: f64, yoffset: f64) callconv(.C) void {
    var handled: bool = false;
    const rbutton_state = window.getMouseButton(.right);
    const lshift_state = window.getKey(.left_shift);
    //const rshift_state = window.getKey(.right_shift);
    if (rbutton_state == .press or rbutton_state == .repeat or lshift_state == .press or lshift_state == .repeat) {
        if (app.img_path.str.len != 0) {
            app.img_view_scale += @as(f32, @floatCast(yoffset)) * 0.1;
            handled = true;
        }
    } else if (rbutton_state == .release) {
        var openImageOffset: i32 = 0;
        if (yoffset > 0) {
            openImageOffset = -1;
        } else if (yoffset < 0) {
            openImageOffset = 1;
        }
        if (openImageOffset != 0) {
            openNeighborImage(openImageOffset) catch {};
            handled = true;
        }
    }

    if (prevOnScroll != null) {
        prevOnScroll.?(window, xoffset, yoffset);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    g_allocator = gpa.allocator();

    if (builtin.os.tag == .macos) {
        // do nothing because it will be handled by [NSApplication application:openFile:]
    } else {
        const args = try std.process.argsAlloc(g_allocator);
        defer std.process.argsFree(g_allocator, args);
        for (0.., args) |i, arg| {
            if (i == 1) {
                cmd_arg_fpath = .{};
                cmd_arg_fpath.set(arg);
                cmd_arg_fpath.replaceChar('\\', '/');
                break;
            }
        }
    }

    try zglfw.init(); // cocoa app의 경우 [NSApplication run]이 호출되면서 명령 인자가 openFile(s)에 전달된다.
    defer zglfw.terminate();

    zstbi.init(g_allocator);
    defer zstbi.deinit();

    // set cwd as exe dir
    {
        var buffer: [1024]u8 = undefined;
        const path = std.fs.selfExeDirPath(buffer[0..]) catch ".";
        std.posix.chdir(path) catch {};
    }

    zglfw.windowHintTyped(.client_api, .no_api);

    const window = try zglfw.Window.create(800, 800, window_title, null);
    defer window.destroy();
    window.setSizeLimits(200, 200, -1, -1);

    const gctx = try zgpu.GraphicsContext.create(
        g_allocator,
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
    defer gctx.destroy(g_allocator);

    app = try App.create(g_allocator, window, gctx);
    defer app.destroy();

    const scale_factor = scale_factor: {
        const scale = window.getContentScale();
        break :scale_factor @max(scale[0], scale[1]);
    };
    app.os_scale_factor = scale_factor;
    //std.debug.print("os_scale_factor={d:.2}\n", .{app.os_scale_factor});

    zgui.init(g_allocator);
    defer zgui.deinit();

    var ui_cfg_path: PathStr = undefined;
    _ = getAppFilePath(&ui_cfg_path, "zxbrush_content/imgui.ini");
    zgui.io.setIniFilename(ui_cfg_path.str_z);

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

    var cfg_fpath_str: PathStr = undefined;
    _ = getAppFilePath(&cfg_fpath_str, "zxbrush_content/config.txt");
    loadPathStrMap(g_allocator, &app.config, cfg_fpath_str.str) catch {};
    app.applyConfigMap();

    zgui.getStyle().scaleAllSizes(scale_factor);

    if (cmd_arg_fpath != null) {
        try openAppImage(cmd_arg_fpath.?.str_z, false);
    }

    var hist_fpath_str: PathStr = undefined;
    _ = getAppFilePath(&hist_fpath_str, "zxbrush_content/history.txt");
    loadPathStrList(g_allocator, &app.open_file_history, hist_fpath_str.str) catch {};

    if (file_dlg_obj == null) {
        file_dlg_obj = try file_dlg.FileDialog.create(g_allocator, "File Dialog", app.img_ext_set, false, openAppImage);
    }

    var sel_but_img_path: PathStr = undefined;
    _ = getAppFilePath(&sel_but_img_path, "zxbrush_content/ui_sel_but.png");
    var line_but_img_path: PathStr = undefined;
    _ = getAppFilePath(&line_but_img_path, "zxbrush_content/ui_sel_but.png");
    if (useSdl) {
        // sdl impl
    } else {
        var sel_but_img = try zstbi.Image.loadFromFile(sel_but_img_path.str_z, 4);
        defer sel_but_img.deinit();
        sel_but_img_obj = try ImageObj.initWithStiImage(gctx, sel_but_img);

        var line_but_img = try zstbi.Image.loadFromFile(line_but_img_path.str_z, 4);
        defer line_but_img.deinit();
        line_but_img_obj = try ImageObj.initWithStiImage(gctx, line_but_img);
    }

    prevOnKey = window.setKeyCallback(onKey);
    prevOnScroll = window.setScrollCallback(onScroll);

    while (!window.shouldClose()) {
        zglfw.pollEvents();

        const fb_w = gctx.swapchain_descriptor.width;
        const fb_h = gctx.swapchain_descriptor.height;

        zgui.backend.newFrame(fb_w, fb_h);

        zgui.setNextWindowPos(.{ .x = 20.0, .y = 20.0, .cond = .first_use_ever });
        zgui.setNextWindowSize(.{ .w = -1.0, .h = -1.0, .cond = .first_use_ever });

        try updateGUI();

        // const cam_world_to_view = zm.lookToLh(zm.loadArr3(.{ 0.0, 0.0, -1.0 }), zm.loadArr3(.{ 0.0, 0.0, 1.0 }), zm.loadArr3{.{ 0.0, 1.0, 0.0 }});
        // const cam_view_to_clip = zm.perspectiveFovLh(
        //     math.pi / @as(f32, 3.0),
        //     @as(f32, @floatFromInt(fb_w)) / @as(f32, @floatFromInt(fb_h)),
        //     0.01,
        //     200.0,
        // );
        // const cam_world_to_clip = zm.mul(cam_world_to_view, cam_view_to_clip);
        const img_w = if (app.img_obj == null) 0 else app.img_obj.?.w;
        const img_h = if (app.img_obj == null) 0 else app.img_obj.?.h;
        const view_img_w: i32 = @intFromFloat(@as(f32, @floatFromInt(img_w)) * app.img_view_scale);
        const view_img_h: i32 = @intFromFloat(@as(f32, @floatFromInt(img_h)) * app.img_view_scale);
        const object_to_world = zm.scaling(@floatFromInt(view_img_w), @floatFromInt(view_img_h), 1.0);
        const object_to_world_edge = zm.scaling(@floatFromInt(view_img_w + 2), @floatFromInt(view_img_h + 2), 1.0);
        const cam_world_to_clip = zm.orthographicLh(@floatFromInt(fb_w), @floatFromInt(fb_h), -1.0, 1.0);

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
                    const edge_rend_pipe = gctx.lookupResource(app.edge_rend_pipe) orelse break :pass;
                    const img_rend_pipe = gctx.lookupResource(app.img_rend_pipe) orelse break :pass;
                    const depth_texv = gctx.lookupResource(app.depth_texv) orelse break :pass;
                    // image specific objects
                    const edge_rend_bg = gctx.lookupResource(app.edge_rend_bg.?) orelse break :pass;
                    const img_rend_bg = gctx.lookupResource(app.img_rend_bg.?) orelse break :pass;

                    const pass = zgpu.beginRenderPassSimple(encoder, .clear, swapchain_texv, null, depth_texv, 1.0);
                    defer zgpu.endReleasePass(pass);

                    const mem = gctx.uniformsAllocate(MeshUniforms, 1);
                    mem.slice[0] = .{
                        .object_to_world = zm.transpose(object_to_world),
                        .object_to_world_edge = zm.transpose(object_to_world_edge),
                        .world_to_clip = zm.transpose(cam_world_to_clip),
                    };

                    pass.setVertexBuffer(0, vb_info.gpuobj.?, 0, vb_info.size);
                    pass.setIndexBuffer(ib_info.gpuobj.?, .uint32, 0, ib_info.size);

                    pass.setPipeline(edge_rend_pipe);
                    pass.setBindGroup(0, edge_rend_bg, &.{mem.offset});
                    pass.drawIndexed(6, 1, 0, 0, 0);

                    pass.setPipeline(img_rend_pipe);
                    pass.setBindGroup(0, img_rend_bg, &.{mem.offset});
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
            // resize depth buffer
            gctx.releaseResource(app.depth_texv);
            gctx.destroyResource(app.depth_tex);
            const depth = createDepthTexture(gctx);
            app.depth_tex = depth.tex;
            app.depth_texv = depth.texv;
            const win_size = app.window.getSize();
            const fb_size = app.window.getFramebufferSize();
            // hdpi mode 에서는 win_size < fb_size 이다.
            // fb_size 는 실제 LCD 상의 픽셀 수를 의미한다.
            std.debug.print("win_size=({d},{d}), fb_size=({d},{d})\n", .{ win_size[0], win_size[1], fb_size[0], fb_size[1] });
            app.updateViewScale(false);
        }
    }

    try app.updateConfigMap();
    try savePathStrMap(&app.config, cfg_fpath_str.str);

    if (file_dlg_obj != null) {
        file_dlg_obj.?.destroy();
    }
}
