const std = @import("std");
const builtin = @import("builtin");

pub const is_0_16_or_newer = builtin.zig_version.major > 0 or
    (builtin.zig_version.major == 0 and builtin.zig_version.minor >= 16);

pub const File = if (is_0_16_or_newer) std.Io.File else std.fs.File;
pub const Dir = if (is_0_16_or_newer) std.Io.Dir else std.fs.Dir;
pub const Writer = if (is_0_16_or_newer) std.Io.File.Writer else std.fs.File.Writer;

pub fn getBuilderIo(b: *std.Build) ?std.Io {
    if (is_0_16_or_newer) {
        return b.graph.io;
    } else {
        return getIo();
    }
}

pub fn getIo() ?std.Io {
    if (is_0_16_or_newer) {
        var threaded: std.Io.Threaded = .init_single_threaded;
        return threaded.io();
    }
    return null;
}

pub fn getCwd(b: *std.Build) ![]const u8 {
    if (is_0_16_or_newer) {
        return b.build_root.path orelse error.FailedToGetPath;
    } else {
        const cwd = std.fs.cwd();
        return cwd.realpathAlloc(b.allocator, ".");
    }
}

pub fn asDirectory(io: ?std.Io, p: []const u8) !Dir {
    if (is_0_16_or_newer) {
        const iop = io orelse return error.NoIoAvailable;
        return Dir.openDirAbsolute(iop, p, .{});
    } else {
        return std.fs.openDirAbsolute(p, .{});
    }
}

pub fn createFile(io: ?std.Io, dir: Dir, filename: []const u8) !File {
    if (is_0_16_or_newer) {
        const iop = io orelse return error.NoIoAvailable;
        return dir.createFile(iop, filename, .{});
    } else {
        return dir.createFile(filename, .{});
    }
}
