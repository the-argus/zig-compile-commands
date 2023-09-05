const std = @import("std");

const cc = @import("compile_commands.zig");
pub const createStep = cc.createStep;
pub const extractIncludeDirsFromCompileStep = cc.extractIncludeDirsFromCompileStep;
pub const extractIncludeDirFromInstallFileStep = cc.extractIncludeDirFromInstallFileStep;

pub fn build(b: *std.Build) void {
    _ = b;
    @panic("zig-compile-commands is not meant to be built.");
}
