const std = @import("std");
const builtin = @import("builtin");
const fcompat = @import("file_compat.zig");
const get_flags = @import("get_flags.zig");

var static_options: CompileCommandOptions = .{};

const CSourceFiles = std.Build.Module.CSourceFiles;
const LazyPath = std.Build.LazyPath;
const TargetsSlice = []*std.Build.Step.Compile;

const CompileCommandsStep = struct {
    step: std.Build.Step,
    compile_steps: TargetsSlice,
    options: CompileCommandOptions = .{},

    fn create(b: *std.Build, targets: TargetsSlice, cc_options: CompileCommandOptions) *CompileCommandsStep {
        const self = b.allocator.create(@This()) catch @panic("Allocation failure, probably OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "cc_file",
                .makeFn = makeCdb,
                .owner = b,
            }),
            .compile_steps = targets,
            .options = cc_options,
        };
        return self;
    }
};

pub const CompileCommandEntry = struct {
    arguments: []const []const u8,
    directory: []const u8,
    file: []const u8,
    output: []const u8,
};

const CompileCommandOptions = struct {
    // Alternative command driver path (eg: /usr/local/bin/clang++)
    // It will use `clang` if not specified this.
    driver: ?[]const u8 = null,
};

pub fn createStep(b: *std.Build, name: []const u8, targets: TargetsSlice) *std.Build.Step {
    const step = CompileCommandsStep.create(b, targets, static_options);

    const cdb_step = b.step(name, "Create compile_commands.json");
    cdb_step.dependOn(&step.step);

    // do a dummy run through generating compile commands and gather the needed LazyPaths
    var lazy_paths: std.ArrayList(LazyPath) = .empty;
    for (targets) |target| {
        lazy_paths.clearRetainingCapacity();
        get_flags.compileStepPathDependencies(target, &lazy_paths) catch |err| {
            std.log.err("Error getting leaf dependencies of compile step: {}", .{err});
            @panic("Failed to get leaf dependencies of compile step");
        };
        for (lazy_paths.items) |lazy_path| {
            if (lazy_path == .generated) {
                step.step.dependOn(lazy_path.generated.file.step);
            }
        }
    }

    return &step.step;
}

fn makeCdb(step: *std.Build.Step, make_options: std.Build.Step.MakeOptions) anyerror!void {
    _ = make_options;

    const cc_step: *CompileCommandsStep = @fieldParentPtr("step", step);
    const b = step.owner;
    var compile_commands: std.ArrayList(CompileCommandEntry) = .empty;
    for (cc_step.compile_steps) |cstep| {
        try get_flags.compileStepToCompileCommandEntries(cstep, cc_step.options.driver, &compile_commands);
    }

    const cwd_string = try fcompat.getCwd(b);
    const io = fcompat.getIo();
    const cwd = try fcompat.asDirectory(io, cwd_string);
    var file = try fcompat.createFile(io, cwd, "compile_commands.json");
    try writeCompileCommands(io, &file, compile_commands.items);
    if (fcompat.is_0_16_or_newer) {
        const iop = io orelse return error.NoIoAvailable;
        file.close(iop);
    } else {
        file.close();
    }
}

fn writeCompileCommands(
    io: ?std.Io,
    file: *fcompat.File,
    compile_commands: []CompileCommandEntry,
) !void {
    var buf: [std.json.default_buffer_size]u8 = undefined;
    var writer: fcompat.Writer = undefined;

    if (fcompat.is_0_16_or_newer) {
        const iop = io orelse return error.NoIoAvailable;
        writer = file.*.writer(iop, &buf);
    } else {
        writer = file.*.writer(&buf);
    }

    var stringify = std.json.Stringify{
        .writer = &writer.interface,
        .options = .{
            .whitespace = .indent_tab,
            .emit_null_optional_fields = false,
        },
    };

    try stringify.write(compile_commands);
    try writer.interface.flush();
}

fn linkFlag(ally: std.mem.Allocator, lib: []const u8) []const u8 {
    return std.fmt.allocPrint(ally, "-l{s}", .{lib}) catch @panic("OOM");
}

/// Returns a pointer to the options used for compile_commands.json generation.
///
/// The returned options are intended to be mutated in order to customize
/// how the compilation commands are generated.
pub fn options() *CompileCommandOptions {
    return &static_options;
}
