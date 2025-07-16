const std = @import("std");

pub fn link(compile_step: *std.Build.Step.Compile, deps: struct {
    zgpu: *std.Build.Module,
    zgui: *std.Build.Module,
    zsdl2: *std.Build.Module,
    zsdl2_image: *std.Build.Module,
    zstbi: *std.Build.Module,
}) void {
    const b = compile_step.step.owner;
    const target = compile_step.root_module.resolved_target.?;
    const optimize = compile_step.root_module.optimize.?;

    // C 코드가 포함될 때만 의미가 있다.
    // const lib = b.addStaticLibrary(.{
    //     .name = "util",
    //     .target = target,
    //     .optimize = optimize,
    // });

    // lib.linkLibC();
    // if (target.result.abi != .msvc)
    //     lib.linkLibCpp();
    // lib.linkSystemLibrary("imm32");

    // lib.addIncludePath(b.path("libs"));
    // lib.addCSourceFile(
    //     .{ .file = b.path("samples/common/libs/imgui/imgui.cpp"), .flags = &.{""} },
    // );
    // lib.addCSourceFile(
    //     .{ .file = b.path("samples/common/libs/imgui/imgui_widgets.cpp"), .flags = &.{""} },
    // );
    // lib.addCSourceFile(
    //     .{ .file = b.path("samples/common/libs/imgui/imgui_tables.cpp"), .flags = &.{""} },
    // );
    // lib.addCSourceFile(
    //     .{ .file = b.path("samples/common/libs/imgui/imgui_draw.cpp"), .flags = &.{""} },
    // );
    // lib.addCSourceFile(
    //     .{ .file = b.path("samples/common/libs/imgui/imgui_demo.cpp"), .flags = &.{""} },
    // );
    // lib.addCSourceFile(
    //     .{ .file = b.path("samples/common/libs/imgui/cimgui.cpp"), .flags = &.{""} },
    // );

    // const zmesh = b.dependency("zmesh", .{});

    // lib.addIncludePath(zmesh.path("libs/cgltf"));
    // lib.addCSourceFile(.{
    //     .file = zmesh.path("libs/cgltf/cgltf.c"),
    //     .flags = &.{"-std=c99"},
    // });

    // lib.addIncludePath(b.path("samples/common/libs"));
    // lib.addIncludePath(zmesh.path("libs/cgltf"));

    const module = b.createModule(.{
        .root_source_file = b.path("samples/util/src/util.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zgpu", .module = deps.zgpu },
            .{ .name = "zgui", .module = deps.zgui },
            .{ .name = "zsdl2", .module = deps.zsdl2 },
            .{ .name = "zsdl2_image", .module = deps.zsdl2_image },
            .{ .name = "zstbi", .module = deps.zstbi },
        },
    });

    compile_step.root_module.addImport("util", module);

    //compile_step.linkLibrary(lib);
}
