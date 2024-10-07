const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zgui = @import("zgui");
const zm = @import("zmath");
const file_dlg = @import("file_dlg.zig");
const PathStr = file_dlg.PathStr;
const zstbi = @import("zstbi");
const App = @import("app.zig").App;

const content_dir = @import("build_options").content_dir;
const window_title = "ZXBrush";

// global vars
var g_allocator: Allocator = undefined;
var app: *App = undefined;
var cmd_args: std.ArrayList(PathStr) = undefined;

// this is callback used by cocoa framework
export fn appOpenFile(fpath: [*c]const u8, index: c_int, count: c_int) callconv(.C) c_int {
    const ret: c_int = 1;
    if (index == 0) {
        cmd_args.clearAndFree();
        _ = cmd_args.addManyAsSlice(@intCast(count)) catch {};
    }
    cmd_args.items[@intCast(index)].set(std.mem.sliceTo(fpath, 0));
    return ret;
}

var prevOnKey: ?zglfw.Window.KeyFn = null;
var prevOnScroll: ?zglfw.Window.ScrollFn = null;
var prevOnMouseButton: ?zglfw.Window.MouseButtonFn = null;
var prevOnCursorPos: ?zglfw.Window.CursorPosFn = null;
var prevOnDrop: ?zglfw.Window.DropFn = null;

fn onKey(
    window: *zglfw.Window,
    key: zglfw.Key,
    scancode: i32,
    action: zglfw.Action,
    mods: zglfw.Mods,
) callconv(.C) void {
    if (prevOnKey != null) {
        prevOnKey.?(window, key, scancode, action, mods);
    }

    app.onKey(key, scancode, action, mods);
}

fn onScroll(
    window: *zglfw.Window,
    xoffset: f64,
    yoffset: f64,
) callconv(.C) void {
    if (prevOnScroll != null) {
        prevOnScroll.?(window, xoffset, yoffset);
    }

    app.onScroll(xoffset, yoffset);
}

fn onMouseButton(
    window: *zglfw.Window,
    button: zglfw.MouseButton,
    action: zglfw.Action,
    mods: zglfw.Mods,
) callconv(.C) void {
    if (prevOnMouseButton != null) {
        prevOnMouseButton.?(window, button, action, mods);
    }

    app.onMouseButton(button, action, mods);
}

fn onCursorPos(
    window: *zglfw.Window,
    xpos: f64,
    ypos: f64,
) callconv(.C) void {
    if (prevOnCursorPos != null) {
        prevOnCursorPos.?(window, xpos, ypos);
    }

    app.onCursorPos(xpos, ypos);
}

fn onDrop(
    window: *zglfw.Window,
    path_count: i32,
    paths: [*][*:0]const u8,
) callconv(.C) void {
    if (prevOnDrop != null) {
        prevOnDrop.?(window, path_count, paths);
    }

    app.onDrop(path_count, paths);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    g_allocator = gpa.allocator();

    cmd_args = std.ArrayList(PathStr).init(g_allocator);
    if (builtin.os.tag == .macos) {
        // do nothing because it will be handled by [NSApplication application:openFile:]
    } else {
        const args = try std.process.argsAlloc(g_allocator);
        defer std.process.argsFree(g_allocator, args);
        cmd_args.clearAndFree();
        _ = try cmd_args.addManyAsSlice(args.len - 1);
        for (0.., args) |i, arg| {
            if (i == 0) continue;
            cmd_args.items[i - 1].set(arg);
            cmd_args.items[i - 1].replaceChar('\\', '/');
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
    _ = App.getDataFilePath(&ui_cfg_path, content_dir ++ "imgui.ini");
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

    app.loadConfig() catch {};

    zgui.getStyle().scaleAllSizes(scale_factor);

    // command line args를 처리한다.
    // mac의 경우 Finder의 Open With는 process exec args로 처리되지 않고
    // cocoa framework의 약속된 함수를 통해서 처리되는 것에 유의한다.
    if (cmd_args.items.len > 0) {
        if (cmd_args.items.len == 1) {
            app.openImageFile(cmd_args.items[0].str_z, false) catch {};
        } else {
            // open multiple as a grid shape
        }
    }

    prevOnKey = window.setKeyCallback(onKey);
    prevOnScroll = window.setScrollCallback(onScroll);
    prevOnMouseButton = window.setMouseButtonCallback(onMouseButton);
    prevOnCursorPos = window.setCursorPosCallback(onCursorPos);
    prevOnDrop = window.setDropCallback(onDrop);

    while (!window.shouldClose()) {
        zglfw.pollEvents();

        const fb_w = gctx.swapchain_descriptor.width;
        const fb_h = gctx.swapchain_descriptor.height;

        zgui.backend.newFrame(fb_w, fb_h);

        zgui.setNextWindowPos(.{ .x = 20.0, .y = 20.0, .cond = .first_use_ever });
        zgui.setNextWindowSize(.{ .w = -1.0, .h = -1.0, .cond = .first_use_ever });

        app.updateUI();

        const swapchain_texv = gctx.swapchain.getCurrentTextureView();
        defer swapchain_texv.release();

        const commands = commands: {
            const encoder = gctx.device.createCommandEncoder(null);
            defer encoder.release();

            // Main pass (if image is loaded)
            if (app.img_rend_bg != null) {
                app.renderMainPass(swapchain_texv, encoder);
            }

            // GUI pass
            {
                const pass = zgpu.beginRenderPassSimple(
                    encoder,
                    .load,
                    swapchain_texv,
                    null,
                    null,
                    null,
                );
                defer zgpu.endReleasePass(pass);
                zgui.backend.draw(pass);
            }

            break :commands encoder.finish(null);
        };
        defer commands.release();

        gctx.submit(&.{commands});

        if (gctx.present() == .swap_chain_resized) {
            app.onResizeFrameBuffer();
        }
    }

    try app.saveConfig();
}
