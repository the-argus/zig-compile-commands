const std = @import("std");

const cc = @import("compile_commands.zig");
pub const createStep = cc.createStep;
pub const options = cc.options;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = try @import("tests/integration/build.zig").transitiveBuild(b, "integration", target, optimize);
    _ = try @import("tests/config_header/build.zig").transitiveBuild(b, "config_header", target, optimize);
}
