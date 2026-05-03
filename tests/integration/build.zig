const std = @import("std");
/// This test has to be built from the root so it can do this, you can't do zig build in this directory
const zcc = @import("../../build.zig");

pub fn transitiveBuild(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step {
    const loc = "tests/integration/";
    var targets: std.ArrayList(*std.Build.Step.Compile) = .empty;

    const exe = b.addExecutable(.{
        .name = "two",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path(loc ++ "main.c"),
        .flags = &.{ "-Wall", "-Werror", "-DFOO" },
    });

    const add_lib = b.addLibrary(.{
        .name = "add",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    add_lib.installHeader(b.path(loc ++ "add.h"), "add.h");
    add_lib.root_module.addCSourceFile(.{
        .file = b.path(loc ++ "add.c"),
        .flags = &.{ "-Werror", "-DBAR" },
    });

    exe.root_module.linkLibrary(add_lib);

    // in theory, just the root exe should need to be included and the library
    // will be pulled in transitively
    try targets.append(b.allocator, exe);

    return zcc.createStep(b, b.fmt("test_{s}_cdb", .{name}), try targets.toOwnedSlice(b.allocator));
}
