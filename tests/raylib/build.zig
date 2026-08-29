const std = @import("std");
const zcc = @import("../../build.zig");

pub fn transitiveBuild(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step {
    const loc = "tests/raylib/";

    var targets: std.ArrayList(*std.Build.Step.Compile) = .empty;

    const exe = b.addExecutable(.{
        .name = "raylib_exe",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path(loc ++ "main.c"),
        .flags = &.{ "-Wall", "-Werror" },
    });

    if (b.lazyDependency("raylib", .{ .target = target, .optimize = optimize, .linkage = .dynamic })) |raylib| {
        exe.root_module.linkLibrary(raylib.artifact("raylib"));
    }

    try targets.append(b.allocator, exe);

    return zcc.createStepAndDependOnTargets(b, .{
        .name = b.fmt("test_{s}_cdb", .{name}),
        .targets = targets.items,
        .custom_output_directory = b.path(loc),
    });
}
