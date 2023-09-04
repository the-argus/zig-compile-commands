const std = @import("std");

pub const createStep = @import("compile_commands.zig").createStep;

pub fn build(b: *std.Build) void {
    _ = b;
    @panic("zig-compile-commands is not meant to be built.");
}
