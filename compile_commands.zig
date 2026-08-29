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
    // output the compile_commands.json to a file other than
    // $PWD/compile_commands.json. Mainly used by tests. Will cause an error
    // the file path does not exist.
    // NOTE: if you choose this then be aware that the CompileCommandsStep
    // will depend on the generation of this path.
    custom_output_directory: ?std.Build.LazyPath = null,
    // Output a file that is called something other than "compile_commands.json"
    custom_output_filename: ?[]const u8 = null,
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
        if (self.options.custom_output_directory) |output_lazy_path| {
            // our step should depend on the generation of this path
            output_lazy_path.addStepDependencies(&self.step);
        }
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
            std.debug.panic("Error getting leaf dependencies of compile step: {}", .{err});
        };
        for (lazy_paths.items) |lazy_path| {
            lazy_path.addStepDependencies(&step.step);
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

    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();

    var output_file = block: {
        const output_filename: []const u8 = cc_step.options.custom_output_filename orelse "compile_commands.json";

        const dir = dir_block: {
            if (cc_step.options.custom_output_directory) |custom_output_directory| {
                const cache_path = try custom_output_directory.getPath4(b, &cc_step.step);
                const stat = try cache_path.statFile(io, "");
                if (stat.kind != .directory) {
                    std.log.err(
                        \\Refusing to output compile_commands.json to anything other
                        \\than a regular directory. Requested output dir was {s}, of type {}
                    , .{ try cache_path.toString(b.allocator), stat.kind });
                    return error.RequestedCompileCommandsOutputWasNotRegularDirectory;
                }

                break :dir_block try cache_path.openDir(io, "", .{});
            } else if (b.build_root.path) |build_root_path| {
                break :dir_block try std.Io.Dir.openDirAbsolute(io, build_root_path, .{});
            } else {
                const cwd_string = try std.process.currentPathAlloc(io, b.allocator);
                std.log.warn(
                    \\No build root path specified by the build system for
                    \\ compile_commands.json output, falling back to process CWD {s}
                , .{cwd_string});
                // std.Io.Dir.cwd() would be better but we want to print it as a string before this
                break :dir_block try std.Io.Dir.openDirAbsolute(io, cwd_string, .{});
            }
        };
        defer dir.close(io);
        break :block try dir.createFile(io, output_filename, .{});
    };
    defer output_file.close(io);

    try writeCompileCommands(io, &output_file, compile_commands.items);
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
