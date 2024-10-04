const std = @import("std");
const Allocator = std.mem.Allocator;
const zgpu = @import("zgpu");
const sdl = @import("zsdl2");
const sdl_image = @import("zsdl2_image");
const zstbi = @import("zstbi");

// stbi supported set
const stbi_img_exts: [10][]const u8 = .{
    ".jpg",
    ".jpeg",
    ".png",
    ".tga",
    ".bmp",
    ".psd",
    ".gif",
    ".hdr",
    ".pic",
    ".pnm",
};
// sdl supported set
const sdl_img_exts: [12][]const u8 = .{
    ".bmp",
    ".gif",
    ".jpg",
    ".jpeg",
    ".lbm",
    ".pcx",
    ".png",
    ".pnm",
    ".qoi",
    ".tga",
    ".xcf",
    ".xpm",
};

const useSdl = false;
pub const img_exts: []const []const u8 = if (useSdl) &sdl_img_exts else &stbi_img_exts;

pub const ImageObj = struct {
    w: u32 = 0,
    h: u32 = 0,
    tex: zgpu.TextureHandle = undefined,
    texv: zgpu.TextureViewHandle = undefined,

    pub fn load(gctx: *zgpu.GraphicsContext, _fpath: [:0]const u8) !ImageObj {
        var img_obj: ImageObj = undefined;
        if (useSdl) {
            const image = try sdl_image.load(_fpath);
            defer image.free();
            img_obj = try ImageObj.initWithSdlImage(gctx, image);
        } else {
            var image = try zstbi.Image.loadFromFile(_fpath, 4);
            defer image.deinit();
            img_obj = try ImageObj.initWithStiImage(gctx, image);
        }
        return img_obj;
    }

    pub fn initWithStiImage(gctx: *zgpu.GraphicsContext, image: zstbi.Image) !ImageObj {
        const img_w = image.width;
        const img_h = image.height;
        const img_num_components = image.num_components;
        const img_bytes_per_component = image.bytes_per_component;
        const img_is_hdr = image.is_hdr;
        const img_bytes_per_row = image.bytes_per_row;
        const img_data = image.data;
        return try ImageObj.initData(
            gctx,
            img_w,
            img_h,
            img_num_components,
            img_bytes_per_component,
            img_is_hdr,
            img_bytes_per_row,
            img_data,
        );
    }

    pub fn initWithSdlImage(gctx: *zgpu.GraphicsContext, image: *sdl.Surface) !ImageObj {
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

        return try ImageObj.initData(
            gctx,
            img_w,
            img_h,
            img_num_components,
            img_bytes_per_component,
            img_is_hdr,
            img_bytes_per_row,
            img_data,
        );
    }

    pub fn initEmptyRGBA(
        gctx: *zgpu.GraphicsContext,
        allocator: Allocator,
        w: u32,
        h: u32,
    ) !ImageObj {
        const img_data = try allocator.alloc(u8, w * h * 4);
        @memset(img_data, 0);
        defer allocator.free(img_data);
        return try ImageObj.initData(gctx, w, h, 4, 1, false, 4 * w, img_data);
    }

    pub fn initData(
        gctx: *zgpu.GraphicsContext,
        w: u32,
        h: u32,
        num_components: u32,
        bytes_per_component: u32,
        is_hdr: bool,
        bytes_per_row: u32,
        data: []const u8,
    ) !ImageObj {
        var self: ImageObj = .{};
        self.w = w;
        self.h = h;

        const tex_format = zgpu.imageInfoToTextureFormat(
            num_components,
            bytes_per_component,
            is_hdr,
        );
        if (tex_format == .undef) {
            return error.FormatNotSupported;
        }
        if (w > 8192 or h > 8192) {
            return error.TooBig;
        }

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

    pub fn deinit(self: *ImageObj, gctx: *zgpu.GraphicsContext) void {
        gctx.releaseResource(self.texv);
        gctx.destroyResource(self.tex);
        self.w = 0;
        self.h = 0;
    }
};
