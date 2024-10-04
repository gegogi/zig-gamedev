const std = @import("std");

const demo_name = "zxbrush";
const content_dir = demo_name ++ "_content/";

pub fn build(b: *std.Build, options: anytype) *std.Build.Step.Compile {
    const cwd_path = b.pathJoin(&.{ "samples", demo_name });
    const src_path = b.pathJoin(&.{ cwd_path, "src" });
    const exe = b.addExecutable(.{
        .name = demo_name,
        .root_source_file = b.path(b.pathJoin(&.{ src_path, demo_name ++ ".zig" })),
        .target = options.target,
        .optimize = options.optimize,
    });

    if (options.target.result.os.tag == .windows) {
        exe.subsystem = .Windows;
    }

    @import("system_sdk").addLibraryPathsTo(exe);

    const zglfw = b.dependency("zglfw", .{
        .target = options.target,
    });
    exe.root_module.addImport("zglfw", zglfw.module("root"));
    exe.linkLibrary(zglfw.artifact("glfw"));

    @import("zgpu").addLibraryPathsTo(exe);
    const zgpu = b.dependency("zgpu", .{
        .target = options.target,
    });
    exe.root_module.addImport("zgpu", zgpu.module("root"));
    exe.linkLibrary(zgpu.artifact("zdawn"));

    const zgui = b.dependency("zgui", .{
        .target = options.target,
        .backend = .glfw_wgpu,
    });
    exe.root_module.addImport("zgui", zgui.module("root"));
    exe.linkLibrary(zgui.artifact("imgui"));

    const exe_options = b.addOptions();
    exe.root_module.addOptions("build_options", exe_options);
    exe_options.addOption([]const u8, "content_dir", content_dir);

    const content_path = b.pathJoin(&.{ cwd_path, content_dir });
    const install_content_step = b.addInstallDirectory(.{
        .source_dir = b.path(content_path),
        .install_dir = .{ .custom = "" },
        .install_subdir = b.pathJoin(&.{ "bin", content_dir }),
    });
    exe.step.dependOn(&install_content_step.step);

    const zmath = b.dependency("zmath", .{
        .target = options.target,
    });
    exe.root_module.addImport("zmath", zmath.module("root"));

    const zstbi = b.dependency("zstbi", .{
        .target = options.target,
    });
    exe.root_module.addImport("zstbi", zstbi.module("root"));
    exe.linkLibrary(zstbi.artifact("zstbi"));

    // SDL2_image
    const zsdl = b.dependency("zsdl", .{});
    exe.root_module.addImport("zsdl2", zsdl.module("zsdl2"));
    exe.root_module.addImport("zsdl2_image", zsdl.module("zsdl2_image"));

    @import("zsdl").link_SDL2(exe);
    @import("zsdl").link_SDL2_image(exe);
    //const sdl2_libs_path = b.dependency("sdl2-prebuilt", .{}).path("").getPath(b);

    @import("zsdl").prebuilt.addLibraryPathsTo(exe);
    //@import("zsdl").addRPathsTo(sdl2_libs_path, exe);

    if (@import("zsdl").prebuilt.install_SDL2(b, options.target.result, .bin)) |install_sdl2_step| {
        exe.step.dependOn(install_sdl2_step);
    }
    if (@import("zsdl").prebuilt.install_SDL2_image(b, options.target.result, .bin)) |install_sdl2_image_step| {
        exe.step.dependOn(install_sdl2_image_step);
    }

    return exe;
}
