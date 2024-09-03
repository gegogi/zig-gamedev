const std = @import("std");

const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zgui = @import("zgui");
const zmath = @import("zmath");
//const sdl = @import("zsdl2");
//const sdl_image = @import("zsdl2_image");
const zstbi = @import("zstbi");
const file_dlg = @import("file_dlg.zig");

const content_dir = @import("build_options").content_dir;
const window_title = "ZXBrush";

const App = struct {
    gctx: *zgpu.GraphicsContext,
    image_w: u32,
    image_h: u32,
    texture: ?zgpu.TextureHandle,
    texture_view: ?zgpu.TextureViewHandle,

    const Self = @This();

    pub fn init(gctx: *zgpu.GraphicsContext) App {
        return App{
            .gctx = gctx,
            .image_w = 0,
            .image_h = 0,
            .texture = null,
            .texture_view = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.reset();
    }

    pub fn reset(self: *Self) void {
        if (self.texture_view != null) {
            //self.gctx.destroyResource(self.texture_view.?);
            self.texture_view = null;
        }
        if (self.texture != null) {
            self.gctx.destroyResource(self.texture.?);
            self.texture = null;
        }
        self.image_w = 0;
        self.image_h = 0;
    }

    pub fn setImage(self: *Self, image: zstbi.Image) void {
        self.image_w = image.width;
        self.image_h = image.height;

        self.texture = self.gctx.createTexture(.{
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .size = .{
                .width = image.width,
                .height = image.height,
                .depth_or_array_layers = 1,
            },
            .format = zgpu.imageInfoToTextureFormat(
                image.num_components,
                image.bytes_per_component,
                image.is_hdr,
            ),
            .mip_level_count = 1,
        });

        self.texture_view = app.gctx.createTextureView(self.texture.?, .{});

        self.gctx.queue.writeTexture(
            .{ .texture = self.gctx.lookupResource(self.texture.?).? },
            .{
                .bytes_per_row = image.bytes_per_row,
                .rows_per_image = image.height,
            },
            .{ .width = image.width, .height = image.height },
            u8,
            image.data,
        );
    }
};

var app: App = undefined;
var file_dlg_obj: ?*file_dlg.FileDialog = null;
var file_dlg_open: bool = false;

fn open_img(fpath: [:0]const u8) !void {
    std.debug.print("opening file: {s}", .{fpath});

    //const surface = sdl_image.load(@ptrCast(fpath)) catch unreachable;
    //_ = surface;
    var image = try zstbi.Image.loadFromFile(@ptrCast(fpath), 4);
    defer image.deinit();

    app.reset();
    app.setImage(image);
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    try zglfw.init();
    defer zglfw.terminate();

    zstbi.init(gpa);
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
        gpa,
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
    defer gctx.destroy(gpa);

    app = App.init(gctx);

    const scale_factor = scale_factor: {
        const scale = window.getContentScale();
        break :scale_factor @max(scale[0], scale[1]);
    };

    zgui.init(gpa);
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
        file_dlg_obj = try file_dlg.FileDialog.create(gpa, "File Dialog", &.{ ".png", ".jpg" }, false, open_img);
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

        if (app.texture_view != null) {
            const tex_id = gctx.lookupResource(app.texture_view.?).?;
            zgui.image(tex_id, .{ .w = @floatFromInt(app.image_w), .h = @floatFromInt(app.image_h) });
        }

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

        const swapchain_texv = gctx.swapchain.getCurrentTextureView();
        defer swapchain_texv.release();

        const commands = commands: {
            const encoder = gctx.device.createCommandEncoder(null);
            defer encoder.release();

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
        _ = gctx.present();
    }

    if (file_dlg_obj != null) {
        file_dlg_obj.?.destroy();
    }
}
