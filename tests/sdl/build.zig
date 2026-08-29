const std = @import("std");
const zcc = @import("../../build.zig");

pub fn transitiveBuild(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step {
    const loc = "tests/sdl/";

    var targets: std.ArrayList(*std.Build.Step.Compile) = .empty;

    const exe = b.addExecutable(.{
        .name = "sdl_exe",
        .linkage = .static,
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

    if (b.lazyDependency("SDL", .{ .target = target, .optimize = optimize })) |sdl| {
        exe.root_module.linkLibrary(sdl.artifact("SDL3"));
    }

    try targets.append(b.allocator, exe);

    return zcc.createStepAndDependOnTargets(b, .{
        .name = b.fmt("test_{s}_cdb", .{name}),
        .targets = targets.items,
        .custom_output_directory = b.path(loc),
    });
}
