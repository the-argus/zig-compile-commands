const std = @import("std");
const zcc = @import("../../build.zig");

pub fn transitiveBuild(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step {
    const loc = "tests/musl_static/";

    _ = target;

    const musl_target = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .os_tag = .linux,
        .abi = .musleabihf,
    });

    var targets: std.ArrayList(*std.Build.Step.Compile) = .empty;

    const exe = b.addExecutable(.{
        .name = "musl_static_exe",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = musl_target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path(loc ++ "main.c"),
        .flags = &.{ "-Wall", "-Werror" },
    });

    try targets.append(b.allocator, exe);

    return zcc.createStep(b, .{
        .name = b.fmt("test_{s}_cdb", .{name}),
        .targets = try targets.toOwnedSlice(b.allocator),
    });
}
