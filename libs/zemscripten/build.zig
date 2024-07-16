const builtin = @import("builtin");
const std = @import("std");

pub const emsdk_ver_major = "3";
pub const emsdk_ver_minor = "1";
pub const emsdk_ver_tiny = "52";
pub const emsdk_version = emsdk_ver_major ++ "." ++ emsdk_ver_minor ++ "." ++ emsdk_ver_tiny;

pub fn build(b: *std.Build) void {
    _ = b.addModule("root", .{ .root_source_file = b.path("src/zemscripten.zig") });
}

pub fn getEmsdkSysroot(b: *std.Build) []const u8 {
    return b.dependency("emsdk", .{}).path("upstream/emscripten/cache/sysroot").getPath(b);
}

pub fn activateEmsdkStep(b: *std.Build) *std.Build.Step {
    const emsdk_path = b.dependency("emsdk", .{}).path("").getPath(b);

    const emsdk_bin_path = switch (builtin.target.os.tag) {
        .windows => b.pathJoin(&.{ emsdk_path, "emsdk.bat" }),
        else => b.pathJoin(&.{ emsdk_path, "emsdk" }),
    };

    var emsdk_install = b.addSystemCommand(&.{ emsdk_bin_path, "install", emsdk_version });

    switch (builtin.target.os.tag) {
        .linux, .macos => {
            emsdk_install.step.dependOn(&b.addSystemCommand(&.{ "chmod", "+x", emsdk_bin_path }).step);
        },
        else => {},
    }

    var emsdk_activate = b.addSystemCommand(&.{ emsdk_bin_path, "activate", emsdk_version });
    emsdk_activate.step.dependOn(&emsdk_install.step);

    return &emsdk_activate.step;
}

pub fn emccStep(b: *std.Build, wasm: *std.Build.Step.Compile, options: struct {
    optimize: std.builtin.OptimizeMode,
    allocator: enum {
        none,
        dlmalloc,
        emmalloc,
        @"emmalloc-debug",
        @"emmalloc-memvalidate",
        @"emmalloc-verbose",
        mimalloc,
    } = .emmalloc,
    shell_file_path: ?[]const u8 = null,
    args: []const []const u8 = &.{},
}) *std.Build.Step.InstallDir {
    const emscripten_path = b.dependency("emsdk", .{}).path("upstream/emscripten").getPath(b);
    const emcc_path = switch (builtin.target.os.tag) {
        .windows => b.pathJoin(&.{ emscripten_path, "emcc.bat" }),
        else => b.pathJoin(&.{ emscripten_path, "emcc" }),
    };

    var emcc = b.addSystemCommand(&.{emcc_path});

    switch (options.optimize) {
        .Debug => emcc.addArgs(&.{
            "-Og",
            "-gsource-map",
            "-sSAFE_HEAP=1",
            "-sSTACK_OVERFLOW_CHECK=1",
            "-sASSERTIONS=1",
        }),
        .ReleaseSmall => emcc.addArg("-Oz"),
        else => emcc.addArg("-O3"),
    }

    emcc.addArg(std.fmt.allocPrint(
        b.allocator,
        "-sMALLOC={s}",
        .{@tagName(options.allocator)},
    ) catch unreachable);

    if (options.shell_file_path) |shell_file_path| {
        emcc.addArg(b.fmt("--shell-file={s}", .{shell_file_path}));
    }

    for (options.args) |arg| {
        emcc.addArg(arg);
    }

    emcc.addArtifactArg(wasm);
    {
        var it = wasm.root_module.iterateDependencies(wasm, false);
        while (it.next()) |item| {
            for (item.module.link_objects.items) |link_object| {
                switch (link_object) {
                    .other_step => |compile_step| {
                        switch (compile_step.kind) {
                            .lib => {
                                emcc.addArtifactArg(compile_step);
                            },
                            else => {},
                        }
                    },
                    else => {},
                }
            }
        }
    }

    emcc.addArg("-o");
    const out_file = emcc.addOutputFileArg(b.fmt("{s}.html", .{wasm.name}));

    const install_step = b.addInstallDirectory(.{
        .source_dir = out_file.dirname(),
        .install_dir = .prefix,
        .install_subdir = "web",
    });
    install_step.step.dependOn(&emcc.step);

    b.getInstallStep().dependOn(&install_step.step);

    switch (builtin.target.os.tag) {
        .linux, .macos => {
            emcc.step.dependOn(&b.addSystemCommand(&.{ "chmod", "+x", emcc_path }).step);
        },
        else => {},
    }

    return install_step;
}

pub fn emrunStep(b: *std.Build, html_path: []const u8) *std.Build.Step {
    const emscripten_path = b.dependency("emsdk", .{}).path("upstream/emscripten").getPath(b);
    const emrun_path = switch (builtin.target.os.tag) {
        .windows => b.pathJoin(&.{ emscripten_path, "emrun.bat" }),
        else => b.pathJoin(&.{ emscripten_path, "emrun" }),
    };

    var emrun = b.addSystemCommand(&.{emrun_path});
    emrun.addArgs(&.{html_path});

    switch (builtin.target.os.tag) {
        .linux, .macos => {
            emrun.step.dependOn(&b.addSystemCommand(&.{ "chmod", "+x", emrun_path }).step);
        },
        else => {},
    }

    return &emrun.step;
}
