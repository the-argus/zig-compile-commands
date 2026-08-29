const std = @import("std");
const zcc = @import("../../build.zig");

pub fn transitiveBuild(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step {
    const loc = "tests/config_header/";
    var targets: std.ArrayList(*std.Build.Step.Compile) = .empty;

    const exe = b.addExecutable(.{
        .name = "config_header_exe",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path(loc ++ "main.c"),
        .flags = &.{ "-Wall", "-Werror" },
    });

    const lib = b.addLibrary(.{
        .name = "lib",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    lib.installHeader(b.path(loc ++ "lib.h"), "lib.h");
    lib.root_module.addCSourceFile(.{
        .file = b.path(loc ++ "lib.c"),
        .flags = &.{"-Werror"},
    });

    const config_header = b.addConfigHeader(.{ .style = .{ .cmake = b.path(loc ++ "lib_config.h.in") } }, .{ .LIB_USE_VULKAN = true });
    // lib uses its own config header
    lib.root_module.addConfigHeader(config_header);
    // and propagates it to be visible to dependents
    lib.installConfigHeader(config_header);

    exe.root_module.linkLibrary(lib);

    try targets.append(b.allocator, exe);

    return zcc.createStep(b, .{
        .name = b.fmt("test_{s}_cdb", .{name}),
        .targets = try targets.toOwnedSlice(b.allocator),
    });
}
