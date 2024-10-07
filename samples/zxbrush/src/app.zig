const std = @import("std");
const Allocator = std.mem.Allocator;
const file_dlg = @import("file_dlg.zig");
const MsgStr = file_dlg.MsgStr;
const PathStr = file_dlg.PathStr;
const DirList = file_dlg.DirList;
const FileDialog = file_dlg.FileDialog;
const PathStrList = file_dlg.PathStrList;
const loadPathStrList = file_dlg.loadPathStrList;
const savePathStrList = file_dlg.savePathStrList;
const loadPathStrMap = file_dlg.loadPathStrMap;
const savePathStrMap = file_dlg.savePathStrMap;
const zm = @import("zmath");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zgui = @import("zgui");
const image = @import("image.zig");
const img_exts = image.img_exts;
const ImageObj = image.ImageObj;
const wgsl = @import("zxbrush_wgsl.zig");
const content_dir = @import("build_options").content_dir;

const depth_tex_format = wgpu.TextureFormat.depth16_unorm;

const toolbox_len: f32 = 700;
const toolbox_thickness: f32 = 56;
const image_button_size: u32 = 32;

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
    object_to_world_sel: zm.Mat,
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

const ToolboxPos = enum(i32) {
    auto = 0,
    left,
    top,
    right,
    bottom,
    count,
};

const ToolFunc = enum(i32) {
    select = 0,
    draw_line,
    draw_circle,
    count,
};

fn beginEnumCombo(
    label: [:0]const u8,
    comptime T: type,
    cur_sel: T,
) struct { opened: bool, sel: ?T } {
    var sel: ?T = null;
    const cur_sel_str = @tagName(cur_sel);
    if (zgui.beginCombo(label, .{ .preview_value = cur_sel_str })) {
        for (0..@intCast(@intFromEnum(T.count))) |i| {
            const enum_val: T = @enumFromInt(i);
            if (zgui.selectable(@tagName(@as(T, enum_val)), .{})) {
                sel = enum_val;
                break;
            }
        }
        return .{ .opened = true, .sel = sel };
    } else {
        return .{ .opened = false, .sel = null };
    }
}

const AppConfig = struct {
    reset_view_scale_on_clear: bool = false,
    img_fit: ImageFit = .original,
    toolbox_pos: ToolboxPos = .auto,

    const Self = @This();

    fn load(self: *Self, allocator: Allocator, fpath: []const u8) !void {
        var dict = std.StringHashMap(*PathStr).init(allocator);
        defer {
            var iter = dict.iterator();
            while (iter.next()) |kv| {
                allocator.free(kv.key_ptr.*);
                allocator.destroy(kv.value_ptr.*);
            }
            dict.deinit();
        }
        try loadPathStrMap(allocator, &dict, fpath);
        if (dict.get("reset_view_scale_on_clear")) |v| {
            self.reset_view_scale_on_clear = (std.fmt.parseInt(u32, v.str, 10) catch 0 != 0);
        }
        if (dict.get("img_fit")) |v| {
            self.img_fit = @enumFromInt(std.fmt.parseInt(u32, v.str, 10) catch 0);
        }
    }

    fn save(self: *Self, allocator: Allocator, fpath: []const u8) !void {
        var dict = std.StringHashMap(*PathStr).init(allocator);
        defer {
            var iter = dict.iterator();
            while (iter.next()) |kv| {
                allocator.free(kv.key_ptr.*);
                allocator.destroy(kv.value_ptr.*);
            }
            dict.deinit();
        }
        var buf: [1024]u8 = undefined;
        {
            const k = "reset_view_scale_on_clear";
            const r = try dict.getOrPut(k);
            const s = try std.fmt.bufPrintZ(&buf, "{d}", .{@intFromBool(self.reset_view_scale_on_clear)});
            if (!r.found_existing) {
                r.key_ptr.* = try allocator.dupe(u8, k);
                r.value_ptr.* = try allocator.create(PathStr);
            }
            r.value_ptr.*.set(s);
        }
        {
            const k = "img_fit";
            const r = try dict.getOrPut(k);
            const s = try std.fmt.bufPrintZ(&buf, "{d}", .{@intFromEnum(self.img_fit)});
            if (!r.found_existing) {
                r.key_ptr.* = try allocator.dupe(u8, k);
                r.value_ptr.* = try allocator.create(PathStr);
            }
            r.value_ptr.*.set(s);
        }
        try savePathStrMap(&dict, fpath);
    }
};

pub const App = struct {
    allocator: Allocator,
    window: *zglfw.Window,
    gctx: *zgpu.GraphicsContext,
    os_scale_factor: f32 = 1.0,

    // config
    config: AppConfig = undefined,

    // state
    img_ext_set: ?*file_dlg.ExtSet = undefined,
    cur_dir_ls: DirList = undefined,
    open_file_history: PathStrList = undefined,

    // UI
    sel_but_img_obj: ImageObj = undefined,
    line_but_img_obj: ImageObj = undefined,

    file_dlg_obj: *FileDialog = undefined,
    is_file_dlg_open: bool = false,

    resize_dlg_obj: *ResizeDialog = undefined,
    is_resize_dlg_open: bool = false,

    cursor_pos_win: zm.Vec = zm.splat(zm.Vec, 0),
    cursor_pos_img: zm.Vec = zm.splat(zm.Vec, 0),
    sel_rect: SelectRect = undefined,
    sel_tool_func: ToolFunc = .select,
    is_panning: bool = false,
    zoom_scale: f32 = 1.0,
    pan_offset: zm.Vec = zm.splat(zm.Vec, 0),

    ///////////////////////////////////////////
    // static env
    vertex_buf: zgpu.BufferHandle = undefined,
    index_buf: zgpu.BufferHandle = undefined,
    depth_tex: zgpu.TextureHandle = undefined,
    depth_texv: zgpu.TextureViewHandle = undefined,
    near_samp: zgpu.SamplerHandle = undefined,
    lin_samp: zgpu.SamplerHandle = undefined,
    // binding group layout
    img_rend_bgl: zgpu.BindGroupLayoutHandle = undefined,
    edge_rend_bgl: zgpu.BindGroupLayoutHandle = undefined,
    sel_rend_bgl: zgpu.BindGroupLayoutHandle = undefined,
    // render pipeline
    img_rend_pipe: zgpu.RenderPipelineHandle = undefined,
    edge_rend_pipe: zgpu.RenderPipelineHandle = undefined,
    sel_rend_pipe: zgpu.RenderPipelineHandle = undefined,

    ///////////////////////////////////////////
    // dynamic env by image
    img_obj: ImageObj = undefined,
    img_fit_scale: f32 = 1.0,
    img_path: PathStr = undefined,
    // binding group
    img_rend_bg: ?zgpu.BindGroupHandle = null,
    edge_rend_bg: ?zgpu.BindGroupHandle = null,
    sel_rend_bg: ?zgpu.BindGroupHandle = null,

    const Self = @This();
    var selfApp: ?*Self = null;

    pub fn getDataFilePath(path: *PathStr, filename: []const u8) []const u8 {
        const exe_dir = std.fs.selfExeDirPath(path.buf[0..]) catch ".";
        path.setLen(exe_dir.len);
        path.replaceChar('\\', '/');
        path.concat("/");
        path.concat(filename);
        return path.str;
    }

    pub fn selfOpenImageFile(_fpath: [:0]const u8, is_saving: bool) !void {
        try selfApp.?.openImageFile(_fpath, is_saving);
    }

    pub fn create(
        allocator: Allocator,
        window: *zglfw.Window,
        gctx: *zgpu.GraphicsContext,
    ) !*Self {
        var self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .window = window,
            .gctx = gctx,
        };
        if (App.selfApp == null) {
            App.selfApp = self;
        }

        self.file_dlg_obj = try FileDialog.create(
            allocator,
            "File Dialog",
            img_exts,
            false,
            selfOpenImageFile,
        );
        self.is_file_dlg_open = false;

        self.resize_dlg_obj = try ResizeDialog.create(allocator);
        self.is_resize_dlg_open = false;

        var sel_but_img_path: PathStr = undefined;
        _ = getDataFilePath(&sel_but_img_path, content_dir ++ "ui_sel_but.png");
        var line_but_img_path: PathStr = undefined;
        _ = getDataFilePath(&line_but_img_path, content_dir ++ "ui_sel_but.png");

        self.sel_but_img_obj = try ImageObj.load(self.gctx, sel_but_img_path.str_z);
        self.line_but_img_obj = try ImageObj.load(self.gctx, line_but_img_path.str_z);

        // buffer
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
        // sampler
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
        // bind group layout
        self.img_rend_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .vertex = true, .fragment = true }, .uniform, true, 0),
            zgpu.textureEntry(1, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.samplerEntry(2, .{ .fragment = true }, .filtering),
        });
        self.edge_rend_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .vertex = true, .fragment = true }, .uniform, true, 0),
        });
        self.sel_rend_bgl = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .vertex = true, .fragment = true }, .uniform, true, 0),
            zgpu.textureEntry(1, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.samplerEntry(2, .{ .fragment = true }, .filtering),
        });
        // render pipeline
        createRenderPipe(
            allocator,
            gctx,
            &.{self.img_rend_bgl},
            wgsl.img_vs,
            wgsl.img_fs,
            zgpu.GraphicsContext.swapchain_format,
            false,
            null,
            wgpu.DepthStencilState{
                .format = depth_tex_format,
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
            null,
            wgpu.DepthStencilState{
                .format = depth_tex_format,
                .depth_write_enabled = true,
                .depth_compare = .less_equal,
            },
            &self.edge_rend_pipe,
        );
        createRenderPipe(
            allocator,
            gctx,
            &.{self.sel_rend_bgl},
            wgsl.sel_vs,
            wgsl.sel_fs,
            zgpu.GraphicsContext.swapchain_format,
            false,
            wgpu.BlendState{
                .color = .{
                    .operation = .add,
                    .src_factor = .one_minus_dst,
                    .dst_factor = .zero,
                },
                .alpha = .{},
            },
            wgpu.DepthStencilState{
                .format = depth_tex_format,
                .depth_write_enabled = true,
                .depth_compare = .less_equal,
            },
            &self.sel_rend_pipe,
        );

        self.cur_dir_ls = DirList.init(allocator);
        self.open_file_history = PathStrList.init(allocator);

        self.img_path.set("");
        const img_obj = try ImageObj.initEmptyRGBA(gctx, allocator, 256, 256);
        self.setImageObj(img_obj);
        // 초기화 이후 config 적용 시점에 호출될 것이다.
        //self.updateViewScale(false, true);

        self.loadFileHistory() catch {};

        return self;
    }

    pub fn destroy(self: *Self) void {
        self.clearImage();

        for (self.open_file_history.items) |path| {
            self.allocator.destroy(path);
        }
        self.open_file_history.deinit();

        self.cur_dir_ls.deinit();

        self.gctx.releaseResource(self.sel_rend_pipe);
        self.gctx.releaseResource(self.edge_rend_pipe);
        self.gctx.releaseResource(self.img_rend_pipe);

        self.gctx.releaseResource(self.sel_rend_bgl);
        self.gctx.releaseResource(self.edge_rend_bgl);
        self.gctx.releaseResource(self.img_rend_bgl);

        self.gctx.releaseResource(self.lin_samp);
        self.gctx.releaseResource(self.near_samp);
        self.gctx.releaseResource(self.depth_texv);
        self.gctx.destroyResource(self.depth_tex);

        self.file_dlg_obj.destroy();
        self.resize_dlg_obj.destroy();

        self.allocator.destroy(self);
    }

    pub fn onResizeFrameBuffer(self: *Self) void {
        // resize depth buffer
        self.gctx.releaseResource(self.depth_texv);
        self.gctx.destroyResource(self.depth_tex);
        const depth = createDepthTexture(self.gctx);
        self.depth_tex = depth.tex;
        self.depth_texv = depth.texv;
        //const win_size = app.window.getSize();
        //const fb_size = app.window.getFramebufferSize();
        // hdpi mode 에서는 win_size < fb_size 이다.
        // fb_size 는 실제 LCD 상의 픽셀 수를 의미한다.
        //std.debug.print("win_size=({d},{d}), fb_size=({d},{d})\n", .{ win_size[0], win_size[1], fb_size[0], fb_size[1] });
        self.updateViewScale(false, false);
    }

    pub fn loadConfig(self: *Self) !void {
        var path: PathStr = undefined;
        _ = getDataFilePath(&path, content_dir ++ "config.txt");
        try self.config.load(self.allocator, path.str);

        self.updateViewScale(true, true);
    }

    pub fn saveConfig(self: *Self) !void {
        var path: PathStr = undefined;
        _ = getDataFilePath(&path, content_dir ++ "config.txt");
        try self.config.save(self.allocator, path.str);
    }

    pub fn loadFileHistory(self: *Self) !void {
        var hist_fpath: PathStr = undefined;
        _ = getDataFilePath(&hist_fpath, content_dir ++ "history.txt");
        try loadPathStrList(self.allocator, &self.open_file_history, hist_fpath.str);
    }

    pub fn saveFileHistory(self: *Self) !void {
        var hist_fpath: PathStr = undefined;
        _ = getDataFilePath(&hist_fpath, content_dir ++ "history.txt");
        try savePathStrList(&self.open_file_history, hist_fpath.str);
    }

    pub fn clearImage(self: *Self) void {
        if (self.sel_rend_bg != null) {
            self.gctx.releaseResource(self.sel_rend_bg.?);
            self.sel_rend_bg = null;
        }
        if (self.edge_rend_bg != null) {
            self.gctx.releaseResource(self.edge_rend_bg.?);
            self.edge_rend_bg = null;
        }
        if (self.img_rend_bg != null) {
            self.gctx.releaseResource(self.img_rend_bg.?);
            self.img_rend_bg = null;
        }

        self.img_obj.deinit(self.gctx);
        self.img_path.set("");
        if (self.config.reset_view_scale_on_clear) {
            self.img_fit_scale = 1.0;
        }
    }

    fn setImageObj(self: *Self, img_obj: ImageObj) void {
        self.img_obj = img_obj;

        self.img_rend_bg = self.gctx.createBindGroup(self.img_rend_bgl, &.{
            .{ .binding = 0, .buffer_handle = self.gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(MeshUniforms) },
            .{ .binding = 1, .texture_view_handle = self.img_obj.texv },
            .{ .binding = 2, .sampler_handle = self.near_samp },
        });
        self.edge_rend_bg = self.gctx.createBindGroup(self.edge_rend_bgl, &.{
            .{ .binding = 0, .buffer_handle = self.gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(MeshUniforms) },
        });
        self.sel_rend_bg = self.gctx.createBindGroup(self.sel_rend_bgl, &.{
            .{ .binding = 0, .buffer_handle = self.gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(MeshUniforms) },
            .{ .binding = 1, .texture_view_handle = self.img_obj.texv },
            .{ .binding = 2, .sampler_handle = self.near_samp },
        });
    }

    fn updateViewScale(self: *Self, can_resize_win: bool, reset_ui_xform: bool) void {
        // adjust image scale or window size
        var fb_w = self.gctx.swapchain_descriptor.width;
        var fb_h = self.gctx.swapchain_descriptor.height;
        const img_w = self.img_obj.w;
        const img_h = self.img_obj.h;

        var img_fit = self.config.img_fit;
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
            self.img_fit_scale = 1.0;
        } else if (img_fit == .osScale) {
            self.img_fit_scale = self.os_scale_factor;
        } else if (img_fit == .width) {
            self.img_fit_scale = @as(f32, @floatFromInt(fb_w)) / @as(f32, @floatFromInt(img_w));
        } else if (img_fit == .height) {
            self.img_fit_scale = @as(f32, @floatFromInt(fb_h)) / @as(f32, @floatFromInt(img_h));
        } else if (img_fit == .resizeWin) {
            if (can_resize_win) {
                const win_w = @as(i32, @intFromFloat(@as(f32, @floatFromInt(img_w)) * self.os_scale_factor));
                const win_h = @as(i32, @intFromFloat(@as(f32, @floatFromInt(img_h)) * self.os_scale_factor));
                self.window.setSize(win_w, win_h);
                fb_w = @intFromFloat(@as(f32, @floatFromInt(win_w)) * self.os_scale_factor);
                fb_h = @intFromFloat(@as(f32, @floatFromInt(win_h)) * self.os_scale_factor);
                self.img_fit_scale = @as(f32, @floatFromInt(fb_w)) / @as(f32, @floatFromInt(img_w));
            }
        }

        if (reset_ui_xform) {
            self.zoom_scale = 1.0;
            self.pan_offset = zm.splat(zm.Vec, 0.0);
        }
    }

    pub fn openImageFile(self: *Self, _fpath: [:0]const u8, is_saving: bool) !void {
        var fpath: PathStr = undefined;
        fpath.set(_fpath);
        fpath.replaceChar('\\', '/');

        std.debug.print("opening file: {s}\n", .{fpath.str});

        var img_obj: ImageObj = undefined;
        if (is_saving) {
            // TODO : implement save
        } else {
            errdefer |err| {
                std.debug.print("failed to open app image: {s}, reason: {s}\n", .{ fpath.str, @errorName(err) });
                self.removeFileHistory(fpath.str);
            }
            img_obj = try ImageObj.load(self.gctx, _fpath);
        }

        self.clearImage(); // 로딩에 성공할 경우만 클리어
        self.setImageObj(img_obj);
        try self.onOpenImageFile(fpath.str);
    }

    fn openNeighborImageFile(self: *Self, offset: i32) !void {
        std.debug.assert(offset != 0);
        if (self.img_path.str.len == 0) {
            return;
        }

        const img_dpath = std.fs.path.dirname(self.img_path.str) orelse "";
        const img_fname = std.fs.path.basename(self.img_path.str);
        var next_fpath: ?PathStr = null;
        const names = self.cur_dir_ls.name_list.items;
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
                        next_fpath.?.concat(self.cur_dir_ls.name_list.items[@intCast(i + 1)].str);
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
                        next_fpath.?.concat(self.cur_dir_ls.name_list.items[@intCast(i - 1)].str);
                        break;
                    }
                }
            }
        }
        if (next_fpath != null) {
            try self.openImageFile(next_fpath.?.str_z, false);
        }
    }

    fn onOpenImageFile(self: *Self, fpath: []const u8) !void {
        self.img_path.set(fpath);

        const dpath = std.fs.path.dirname(fpath) orelse "";
        if (dpath.len == 0) return;

        if (!self.cur_dir_ls.is_populated or !std.mem.eql(u8, self.cur_dir_ls.dpath.str, dpath)) {
            var dir = try std.fs.openDirAbsolute(dpath, .{});
            defer dir.close();
            try dir.setAsCwd();
            std.debug.print("chdir: {s}\n", .{dpath});
            self.cur_dir_ls.reset();
            try self.cur_dir_ls.populate(dpath, false, self.file_dlg_obj.ext_set);
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

        try self.saveFileHistory();

        self.updateViewScale(true, true);
    }

    fn removeFileHistory(self: *Self, fpath: []const u8) void {
        var i: usize = 1;
        var hist = &self.open_file_history;
        while (i < hist.items.len) {
            const fpath_in_hist = hist.items[i].str;
            if (std.mem.eql(u8, fpath, fpath_in_hist)) {
                const removed_fpath = hist.orderedRemove(i);
                self.allocator.destroy(removed_fpath);
                continue;
            }
            i += 1;
        }
    }

    fn updateUI_menuBar(self: *Self, menubar_h: *f32) void {
        const img_w = self.img_obj.w;
        const img_h = self.img_obj.h;

        if (zgui.beginMainMenuBar()) {
            if (zgui.beginMenu("File", true)) {
                if (zgui.menuItem("New", .{})) {
                    self.is_resize_dlg_open = true;
                }
                if (zgui.menuItem("Load", .{})) {
                    self.is_file_dlg_open = true;
                    self.file_dlg_obj.is_saving = false;
                }
                if (zgui.menuItem("Load and Add", .{})) {
                    self.is_file_dlg_open = true;
                    self.file_dlg_obj.is_saving = false;
                }
                if (zgui.menuItem("Save As", .{})) {
                    self.is_file_dlg_open = true;
                    self.file_dlg_obj.is_saving = true;
                }
                zgui.separator();
                for (self.open_file_history.items) |path| {
                    if (zgui.menuItem(path.str_z, .{})) {
                        self.openImageFile(path.str_z, false) catch {};
                    }
                }
                zgui.endMenu();
            }
            if (zgui.beginMenu("Select", true)) {
                if (zgui.menuItem("Select All", .{})) {
                    //
                }
                zgui.endMenu();
            }
            if (zgui.beginMenu("Edit", true)) {
                if (zgui.menuItem("Clear", .{})) {
                    self.clearImage();
                    const img_obj = ImageObj.initEmptyRGBA(
                        self.gctx,
                        self.allocator,
                        img_w,
                        img_h,
                    ) catch unreachable;
                    self.setImageObj(img_obj);
                    self.updateViewScale(true, true);
                }
                if (zgui.menuItem("Copy Selected", .{})) {
                    //
                }
                if (zgui.menuItem("Paste from Clipboard", .{})) {
                    // TODO : paste
                }
                if (zgui.menuItem("Resize", .{})) {
                    self.is_resize_dlg_open = true;
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
                if (zgui.checkbox("Reset View Scale on Clear", .{ .v = &self.config.reset_view_scale_on_clear })) {
                    willCloseMenu = true;
                }
                {
                    const c = beginEnumCombo("Image Fit", ImageFit, self.config.img_fit);
                    if (c.opened) {
                        zgui.endCombo();
                        if (c.sel != null) {
                            self.config.img_fit = c.sel.?;
                            self.updateViewScale(true, true);
                            willCloseMenu = true;
                        }
                    }
                }
                {
                    const c = beginEnumCombo("Toolbox Pos", ToolboxPos, self.config.toolbox_pos);
                    if (c.opened) {
                        zgui.endCombo();
                        if (c.sel != null) {
                            self.config.toolbox_pos = c.sel.?;
                            willCloseMenu = true;
                        }
                    }
                }
                // combo를 선택했을 때 상위 메뉴까지 한번에 닫는 코드
                //if (willCloseMenu) {
                //    zgui.closeCurrentPopup();
                //}
                zgui.endMenu();
            }
            menubar_h.* = zgui.getWindowSize()[1];
            zgui.endMainMenuBar();
        }
    }

    fn updateUI_statusBar(self: *Self) void {
        const vp = zgui.getMainViewport();
        const vp_pos = vp.getPos();
        const vp_size = vp.getSize();
        const frame_h = zgui.getFrameHeight();

        // status bar
        zgui.setNextWindowPos(.{
            .x = vp_pos[0],
            .y = vp_pos[1] + vp_size[1] - frame_h,
        });
        zgui.setNextWindowSize(.{
            .w = vp_size[0],
            .h = frame_h,
        });
        const flags = zgui.WindowFlags{
            //.no_title_bar = true,
            .no_resize = true,
            .no_move = true,
            .no_scrollbar = true,
            .no_scroll_with_mouse = true,
            .no_focus_on_appearing = true,
            //.no_background = true,
            .no_mouse_inputs = true,
            .no_saved_settings = true,
            .no_collapse = true,
            .no_bring_to_front_on_focus = true,
            .no_nav_inputs = true,
            .no_nav_focus = true,
            //.menu_bar = true,
        };
        var status_msg: MsgStr = undefined;
        const fname = std.fs.path.basenamePosix(self.img_path.str);
        const s = std.fmt.bufPrintZ(
            status_msg.buf[0..],
            "fname={s}, size=({d},{d}), pos=({d:.2},{d:.2}), ipos=({d:.2},{d:.2})",
            .{
                fname,
                self.img_obj.w,
                self.img_obj.h,
                self.cursor_pos_win[0],
                self.cursor_pos_win[1],
                self.cursor_pos_img[0],
                self.cursor_pos_img[1],
            },
        ) catch unreachable;
        status_msg.setLen(s.len);
        if (zgui.begin(status_msg.str_z, .{ .flags = flags })) {
            //zgui.text("{s}", .{"test"});
        }
        zgui.end();
    }

    fn updateUI_toolBox(self: *Self, menubar_h: f32) void {
        const vp = zgui.getMainViewport();
        const vp_pos = vp.getPos();
        const vp_size = vp.getSize();
        const frame_h = zgui.getFrameHeight();

        const toolbox_flags = zgui.WindowFlags{
            .no_collapse = true,
            .no_title_bar = true,
            .no_docking = true,
            .no_resize = true,
        };
        var toolbox_pos: ToolboxPos = self.config.toolbox_pos;
        if (toolbox_pos == .auto) {
            const fb_w = @as(f32, @floatFromInt(self.gctx.swapchain_descriptor.width));
            const fb_h = @as(f32, @floatFromInt(self.gctx.swapchain_descriptor.height));
            const img_w = @as(f32, @floatFromInt(self.img_obj.w));
            const img_h = @as(f32, @floatFromInt(self.img_obj.h));
            const fb_aspect_ratio = fb_w / fb_h;
            const img_aspect_ratio = img_w / img_h;
            toolbox_pos = if (fb_aspect_ratio >= img_aspect_ratio) .left else .top;
        }
        switch (toolbox_pos) {
            .left => {
                zgui.setNextWindowPos(.{
                    .x = vp_pos[0],
                    .y = vp_pos[1] + menubar_h,
                });
                zgui.setNextWindowSize(.{
                    .w = toolbox_thickness,
                    .h = @min(toolbox_len, vp_size[1] - menubar_h - frame_h),
                });
            },
            .top => {
                zgui.setNextWindowPos(.{
                    .x = vp_pos[0],
                    .y = vp_pos[1] + menubar_h,
                });
                zgui.setNextWindowSize(.{
                    .w = @min(toolbox_len, vp_size[0]),
                    .h = toolbox_thickness,
                });
            },
            .right => {
                zgui.setNextWindowPos(.{
                    .x = vp_pos[0] + vp_size[0] - toolbox_thickness,
                    .y = vp_pos[1] + menubar_h,
                });
                zgui.setNextWindowSize(.{
                    .w = toolbox_thickness,
                    .h = @min(toolbox_len, vp_size[1] - menubar_h - frame_h),
                });
            },
            .bottom => {
                zgui.setNextWindowPos(.{
                    .x = vp_pos[0],
                    .y = vp_pos[1] + vp_size[1] - frame_h - toolbox_thickness,
                });
                zgui.setNextWindowSize(.{
                    .w = @min(toolbox_len, vp_size[0]),
                    .h = toolbox_thickness,
                });
            },
            else => {},
        }
        if (zgui.begin("Toolbox", .{ .flags = toolbox_flags })) {
            const ToolButton = struct {
                label: [:0]const u8,
                icon_texv: zgpu.TextureViewHandle,
                func_id: ToolFunc,
            };
            const tool_buttons = [_]ToolButton{
                .{ .label = "Select", .icon_texv = self.sel_but_img_obj.texv, .func_id = .select },
                .{ .label = "Line", .icon_texv = self.line_but_img_obj.texv, .func_id = .draw_line },
                .{ .label = "Circle", .icon_texv = self.line_but_img_obj.texv, .func_id = .draw_circle },
            };
            for (tool_buttons, 0..) |b, i| {
                const t = self.gctx.lookupResource(b.icon_texv).?;
                const use_sel_col = (b.func_id == self.sel_tool_func);
                if (use_sel_col) {
                    zgui.pushStyleColor4f(.{ .idx = zgui.StyleCol.button, .c = .{ 0.8, 0, 0, 1 } });
                    zgui.pushStyleColor4f(.{ .idx = zgui.StyleCol.button_active, .c = .{ 1, 0, 0, 1 } });
                    zgui.pushStyleColor4f(.{ .idx = zgui.StyleCol.button_hovered, .c = .{ 1, 0, 0, 1 } });
                }
                if (zgui.imageButton(b.label, t, .{ .w = image_button_size, .h = image_button_size })) {
                    self.sel_tool_func = b.func_id;
                }
                if (use_sel_col) {
                    zgui.popStyleColor(.{});
                    zgui.popStyleColor(.{});
                    zgui.popStyleColor(.{});
                }
                if (toolbox_pos == .top or toolbox_pos == .bottom) {
                    if (i < tool_buttons.len - 1) {
                        zgui.sameLine(.{});
                    }
                }
            }
        }
        zgui.end();
    }

    pub fn updateUI(self: *Self) void {
        var menubar_h: f32 = 0;

        self.updateUI_menuBar(&menubar_h);
        self.updateUI_statusBar();
        self.updateUI_toolBox(menubar_h);

        if (self.is_file_dlg_open) {
            var need_confirm: bool = false;
            self.is_file_dlg_open = self.file_dlg_obj.ui(&need_confirm);
            //_ = need_confirm;
        }

        if (self.is_resize_dlg_open) {
            self.is_resize_dlg_open = self.resize_dlg_obj.ui();
        }
    }

    pub fn renderMainPass(self: *Self, swapchain_texv: wgpu.TextureView, encoder: wgpu.CommandEncoder) void {
        const gctx = self.gctx;
        const fb_w = gctx.swapchain_descriptor.width;
        const fb_h = gctx.swapchain_descriptor.height;
        const _fb_w: f32 = @floatFromInt(fb_w);
        const _fb_h: f32 = @floatFromInt(fb_h);

        const view_img_w: f32 = @as(f32, @floatFromInt(self.img_obj.w)) * self.img_fit_scale * self.zoom_scale;
        const view_img_h: f32 = @as(f32, @floatFromInt(self.img_obj.h)) * self.img_fit_scale * self.zoom_scale;
        const img_scale = zm.scaling(view_img_w, view_img_h, 1.0);
        const edge_scale = zm.scaling(view_img_w + 2.0, view_img_h + 2.0, 1.0);
        const img_translate = zm.translationV(self.pan_offset);
        const img_mat = zm.mul(img_scale, img_translate);
        const edge_mat = zm.mul(edge_scale, img_translate);

        const sel_size = self.sel_rect.max_pos - self.sel_rect.min_pos;
        const sel_scale = zm.scalingV(sel_size);
        const sel_ctr = (self.sel_rect.min_pos + self.sel_rect.max_pos) * zm.splat(zm.Vec, 0.5) + self.pan_offset;
        const sel_translate = zm.translationV(sel_ctr);
        const sel_mat = zm.mul(sel_scale, sel_translate);

        const cam_world_to_clip = zm.orthographicLh(
            _fb_w,
            _fb_h,
            -1.0,
            1.0,
        );

        // Main pass
        pass: {
            // TODO : move to outside
            const vb_info = gctx.lookupResourceInfo(self.vertex_buf) orelse break :pass;
            const ib_info = gctx.lookupResourceInfo(self.index_buf) orelse break :pass;
            const edge_rend_pipe = gctx.lookupResource(self.edge_rend_pipe) orelse break :pass;
            const img_rend_pipe = gctx.lookupResource(self.img_rend_pipe) orelse break :pass;
            const sel_rend_pipe = gctx.lookupResource(self.sel_rend_pipe) orelse break :pass;
            const depth_texv = gctx.lookupResource(self.depth_texv) orelse break :pass;
            // image specific objects
            const edge_rend_bg = gctx.lookupResource(self.edge_rend_bg.?) orelse break :pass;
            const img_rend_bg = gctx.lookupResource(self.img_rend_bg.?) orelse break :pass;
            const sel_rend_bg = gctx.lookupResource(self.sel_rend_bg.?) orelse break :pass;

            const pass = zgpu.beginRenderPassSimple(
                encoder,
                .clear,
                swapchain_texv,
                null,
                depth_texv,
                1.0,
            );
            defer zgpu.endReleasePass(pass);

            const mem = gctx.uniformsAllocate(MeshUniforms, 1);
            mem.slice[0] = .{
                .object_to_world = zm.transpose(img_mat),
                .object_to_world_edge = zm.transpose(edge_mat),
                .object_to_world_sel = zm.transpose(sel_mat),
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

            if (self.sel_rect.is_active) {
                pass.setPipeline(sel_rend_pipe);
                pass.setBindGroup(0, sel_rend_bg, &.{mem.offset});
                pass.drawIndexed(6, 1, 0, 0, 0);
            }
        }
    }

    pub fn onKey(
        self: *Self,
        key: zglfw.Key,
        scancode: i32,
        action: zglfw.Action,
        mods: zglfw.Mods,
    ) void {
        _ = scancode;

        if (zgui.io.getWantCaptureKeyboard()) return;

        var handled: bool = false;
        var openImageOffset: i32 = 0;
        if (key == .left or key == .comma) {
            if (action == .press or action == .repeat) {
                openImageOffset = if (mods.shift) -5 else -1;
            }
        } else if (key == .right or key == .period) {
            if (action == .press or action == .repeat) {
                openImageOffset = if (mods.shift) 5 else 1;
            }
        }
        if (openImageOffset != 0) {
            self.openNeighborImageFile(openImageOffset) catch {};
            handled = true;
        }
    }

    pub fn onScroll(
        self: *Self,
        xoffset: f64,
        yoffset: f64,
    ) void {
        _ = xoffset;

        if (zgui.io.getWantCaptureMouse()) return;

        var handled: bool = false;
        const rbutton_state = self.window.getMouseButton(.right);
        const lshift_state = self.window.getKey(.left_shift);
        //const rshift_state = window.getKey(.right_shift);
        if (rbutton_state == .press or rbutton_state == .repeat or lshift_state == .press or lshift_state == .repeat) {
            if (self.img_path.str.len != 0) {
                self.zoom_scale += @as(f32, @floatCast(yoffset)) * 0.1;
                self.sel_rect.changeViewScale(self.img_fit_scale * self.zoom_scale);
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
                self.openNeighborImageFile(openImageOffset) catch {};
                handled = true;
            }
        }
    }

    pub fn onMouseButton(
        self: *Self,
        button: zglfw.MouseButton,
        action: zglfw.Action,
        mods: zglfw.Mods,
    ) void {
        _ = mods;

        if (zgui.io.getWantCaptureMouse()) return;

        const fb_w = self.gctx.swapchain_descriptor.width;
        const fb_h = self.gctx.swapchain_descriptor.height;
        const _p = self.window.getCursorPos();
        const pos = zm.loadArr2(.{ @floatCast(_p[0]), @floatCast(_p[1]) });
        const cpos = getCenteredPos(pos, fb_w, fb_h, false) - self.pan_offset;

        if (button == .left) {
            if (action == .press) {
                self.sel_rect.start(cpos, self.img_fit_scale * self.zoom_scale);
            } else if (action == .release) {
                self.sel_rect.updateEnd(cpos);
                self.sel_rect.is_dragging = false;
            }
        } else if (button == .right) {
            if (action == .press) {
                self.is_panning = true;
            } else if (action == .release) {
                self.sel_rect.is_active = false;
                self.sel_rect.is_dragging = false;
                self.is_panning = false;
            }
        }
    }

    pub fn onCursorPos(
        self: *Self,
        _px: f64,
        _py: f64,
    ) void {
        //if (zgui.io.getWantCaptureMouse()) return;

        const fb_w = self.gctx.swapchain_descriptor.width;
        const fb_h = self.gctx.swapchain_descriptor.height;
        const pos = zm.loadArr2(.{ @floatCast(_px), @floatCast(_py) });
        const old_cpos = getCenteredPos(self.cursor_pos_win, fb_w, fb_h, false) - self.pan_offset;
        const cpos = getCenteredPos(pos, fb_w, fb_h, false) - self.pan_offset;

        if (self.sel_rect.is_dragging) {
            self.sel_rect.updateEnd(cpos);
        } else if (self.is_panning) {
            const cpos_diff = cpos - old_cpos;
            self.pan_offset += cpos_diff;
        }

        self.cursor_pos_win = pos;

        const cpos_img = cpos * zm.splat(zm.Vec, 1.0 / (self.img_fit_scale * self.zoom_scale));
        self.cursor_pos_img = zm.ceil(getCenteredPos(cpos_img, self.img_obj.w, self.img_obj.h, true));
    }

    pub fn onDrop(
        self: *Self,
        path_count: i32,
        paths: [*][*:0]const u8,
    ) void {
        //if (zgui.io.getWantCaptureMouse()) return;

        if (path_count == 1) {
            self.openImageFile(std.mem.sliceTo(paths[0], 0), false) catch {};
        } else {
            var i: i32 = 0;
            while (i < path_count) : (i += 1) {
                //
            }
        }
    }
};

const ResizeDialog = struct {
    allocator: Allocator,
    unit_type: i32 = 0,
    extend_canvas_only: bool = false,

    buf_w: [256:0]u8 = [_:0]u8{0} ** 256,
    val_w: i32 = 0,
    buf_h: [256:0]u8 = [_:0]u8{0} ** 256,
    val_h: i32 = 0,

    const Self = @This();

    pub fn create(allocator: Allocator) !*ResizeDialog {
        var dlg = try allocator.create(Self);
        dlg.* = Self{
            .allocator = allocator,
        };
        dlg.unit_type = 0;
        dlg.extend_canvas_only = false;
        return dlg;
    }

    pub fn destroy(self: *Self) void {
        self.allocator.destroy(self);
    }

    pub fn ui(self: *Self) bool {
        var ui_opened: bool = true;
        var is_active: bool = true;
        _ = zgui.begin("Resize Image", .{
            .popen = &ui_opened,
            .flags = zgui.WindowFlags{ .no_collapse = true },
        });
        if (ui_opened) {
            const img_obj = App.selfApp.?.img_obj;
            zgui.text("Unit (Flip on Negative):", .{});
            zgui.sameLine(.{});
            if (zgui.radioButton("Percent", .{ .active = (self.unit_type == 0) })) {
                self.unit_type = 0;
            }
            zgui.sameLine(.{});
            if (zgui.radioButton("Pixel", .{ .active = (self.unit_type == 1) })) {
                self.unit_type = 1;
            }
            if (self.unit_type == 0) { // percent
                _ = std.fmt.bufPrintZ(&self.buf_w, "{d}", .{100}) catch unreachable;
                _ = std.fmt.bufPrintZ(&self.buf_h, "{d}", .{100}) catch unreachable;
            } else { // pixel
                _ = std.fmt.bufPrintZ(&self.buf_w, "{d}", .{img_obj.w}) catch unreachable;
                _ = std.fmt.bufPrintZ(&self.buf_h, "{d}", .{img_obj.h}) catch unreachable;
            }
            if (zgui.inputText(
                "Width",
                .{
                    .buf = self.buf_w[0..],
                    .flags = .{ .chars_decimal = true },
                },
            )) {
                self.val_w = std.fmt.parseInt(i32, &self.buf_w, 10) catch 0;
            }
            if (zgui.inputText(
                "Height",
                .{
                    .buf = self.buf_h[0..],
                    .flags = .{ .chars_decimal = true },
                },
            )) {
                self.val_h = std.fmt.parseInt(i32, &self.buf_h, 10) catch 0;
            }
            _ = zgui.checkbox("Extend Canvas Only", .{ .v = &self.extend_canvas_only });
            if (zgui.button("OK", .{})) {
                // calc new image size
                var new_img_w: i32 = @intCast(img_obj.w);
                var new_img_h: i32 = @intCast(img_obj.h);
                if (self.unit_type == 0) {
                    new_img_w = @intFromFloat(@as(f32, @floatFromInt(new_img_w)) * @as(f32, @floatFromInt(self.val_w)) * 0.01);
                    new_img_h = @intFromFloat(@as(f32, @floatFromInt(new_img_h)) * @as(f32, @floatFromInt(self.val_h)) * 0.01);
                } else {
                    new_img_w = self.val_w;
                    new_img_h = self.val_h;
                }
                // apply by resize method
                if (self.extend_canvas_only) {
                    //
                } else {
                    //
                }
                is_active = false;
            }
            zgui.sameLine(.{});
            if (zgui.button("Cancel", .{})) {
                is_active = false;
            }
        } else {
            is_active = false;
        }
        zgui.end();
        return is_active;
    }
};

fn snapValue(v: zm.Vec, pixel_size: f32) zm.Vec {
    const snapped = zm.floor(v * zm.splat(zm.Vec, 1 / pixel_size));
    return snapped * zm.splat(zm.Vec, pixel_size);
}

const SelectRect = struct {
    is_active: bool = false,
    is_dragging: bool = false,
    beg_pos: zm.Vec,
    end_pos: zm.Vec,
    min_pos: zm.Vec,
    max_pos: zm.Vec,
    view_scale: f32,

    const Self = @This();

    pub fn start(self: *Self, p: zm.Vec, view_scale: f32) void {
        self.is_active = true;
        self.is_dragging = true;
        self.beg_pos = p;
        self.view_scale = view_scale;
        self.updateEnd(p);
    }

    pub fn updateEnd(self: *Self, p: zm.Vec) void {
        self.end_pos = p;
        self.update();
    }

    pub fn update(self: *Self) void {
        self.min_pos = zm.minFast(self.beg_pos, self.end_pos);
        self.max_pos = zm.maxFast(self.beg_pos, self.end_pos);
        // snap to image pixel boundary
        self.min_pos = snapValue(self.min_pos, self.view_scale);
        self.max_pos = snapValue(self.max_pos, self.view_scale);
    }

    pub fn changeViewScale(self: *Self, new_view_scale: f32) void {
        self.beg_pos *= zm.splat(zm.Vec, new_view_scale / self.view_scale);
        self.end_pos *= zm.splat(zm.Vec, new_view_scale / self.view_scale);
        self.view_scale = new_view_scale;
        self.update();
    }
};

fn createRenderPipe(
    allocator: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,
    bgls: []const zgpu.BindGroupLayoutHandle,
    wgsl_vs: [:0]const u8,
    wgsl_fs: [:0]const u8,
    format: wgpu.TextureFormat,
    only_position_attrib: bool,
    blend_state: ?wgpu.BlendState,
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

    const color_targets = [_]wgpu.ColorTargetState{
        .{
            .format = format,
            .blend = if (blend_state) |bs| &bs else null,
        },
    };

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
        .format = depth_tex_format,
        .mip_level_count = 1,
        .sample_count = 1,
    });
    const texv = gctx.createTextureView(tex, .{});
    return .{ .tex = tex, .texv = texv };
}

inline fn getCenteredPos(pos: zm.Vec, space_w: u32, space_h: u32, reverse: bool) zm.Vec {
    const w: f32 = @floatFromInt(space_w);
    const h: f32 = @floatFromInt(space_h);
    const half_w = w * 0.5;
    const half_h = h * 0.5;
    if (reverse) {
        return zm.loadArr2(.{
            pos[0] + half_w,
            -pos[1] + half_h,
        });
    } else {
        return zm.loadArr2(.{
            pos[0] - half_w,
            -pos[1] + half_h,
        });
    }
}
