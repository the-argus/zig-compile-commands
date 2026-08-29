const std = @import("std");
const builtin = @import("builtin");
const fcompat = @import("file_compat.zig");
const get_flags = @import("get_flags.zig");

const CSourceFiles = std.Build.Module.CSourceFiles;
const LazyPath = std.Build.LazyPath;
const TargetsSlice = []*std.Build.Step.Compile;

pub const CompileCommandOptions = struct {
    name: []const u8,
    targets: []*std.Build.Step.Compile,
    // Alternative command driver path (eg: /usr/local/bin/clang++)
    // It will use `clang` if not specified this.
    driver: ?[]const u8 = null,
    // Include many flags specifying all the features of the specific
    // target cpu. makes compile_commands.json a much much larger file, but may
    // fix some incorrect LSP stuff indicating, for example, whether simd
    // extensions are available
    include_cpu_features: bool = false,
};

const CompileCommandsStep = struct {
    step: std.Build.Step,
    compile_steps: TargetsSlice,
    options: CompileCommandOptions,

    fn create(b: *std.Build, options: CompileCommandOptions) *CompileCommandsStep {
        const self = b.allocator.create(@This()) catch @panic("Allocation failure, probably OOM");
        var owned_options = options;
        owned_options.targets = b.allocator.dupe(*std.Build.Step.Compile, options.targets) catch @panic("Allocation failure, probably OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "cc_file",
                .makeFn = makeCdb,
                .owner = b,
            }),
            .compile_steps = owned_options.targets,
            .options = owned_options,
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

pub fn createStep(b: *std.Build, options: CompileCommandOptions) *std.Build.Step {
    const step = CompileCommandsStep.create(b, options);

    const cdb_step = b.step(options.name, "Create compile_commands.json");
    cdb_step.dependOn(&step.step);

    // do a dummy run through generating compile commands and gather the needed LazyPaths
    var lazy_paths: std.ArrayList(LazyPath) = .empty;
    var idx: usize = 0;
    var csteps: std.ArrayList(*std.Build.Step.Compile) = .empty;
    csteps.appendSlice(b.allocator, options.targets) catch @panic("OOM");
    while (idx < csteps.items.len) {
        defer idx += 1;
        lazy_paths.clearRetainingCapacity();
        get_flags.compileStepPathDependencies(csteps.items[idx], &lazy_paths, &csteps) catch |err| {
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
    var idx: usize = 0;
    var csteps: std.ArrayList(*std.Build.Step.Compile) = .empty;
    try csteps.appendSlice(b.allocator, cc_step.compile_steps);
    while (idx < csteps.items.len) {
        defer idx += 1;
        try get_flags.compileStepToCompileCommandEntries(csteps.items[idx], cc_step.options, &compile_commands, &csteps);
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
