const std = @import("std");

pub fn link(compile_step: *std.Build.Step.Compile, deps: struct {
    zgui: *std.Build.Module,
}) void {
    const b = compile_step.step.owner;
    const target = compile_step.root_module.resolved_target.?;
    const optimize = compile_step.root_module.optimize.?;

    //const zmesh = b.dependency("zmesh", .{});

    //lib.addIncludePath(zmesh.path("libs/cgltf"));
    //lib.addCSourceFile(.{
    //    .file = zmesh.path("libs/cgltf/cgltf.c"),
    //    .flags = &.{"-std=c99"},
    //});

    //lib.addIncludePath(b.path("samples/common/libs"));
    //lib.addIncludePath(zmesh.path("libs/cgltf"));

    const module = b.createModule(.{
        .root_source_file = b.path("samples/util/src/util.zig"),
        .imports = &.{
            .{ .name = "zgui", .module = deps.zgui },
        },
    });
    //module.addIncludePath(b.path("samples/common/libs/imgui"));
    //module.addIncludePath(zmesh.path("libs/cgltf"));

    compile_step.root_module.addImport("util", module);

    //compile_step.linkLibrary(lib);
}
