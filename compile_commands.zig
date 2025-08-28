const std = @import("std");

// here's the static memory!!!!
var compile_steps: ?[]*std.Build.Step.Compile = null;

const CSourceFiles = std.Build.Module.CSourceFiles;

/// A list of files (by absolute path) to compile with the given flags
const AbsoluteCSourceFiles = struct {
    files: []const []const u8,
    flags: []const []const u8,
};

const CompileCommandEntry = struct {
    arguments: []const []const u8,
    directory: []const u8,
    file: []const u8,
    output: []const u8,
};

pub fn createStep(b: *std.Build, name: []const u8, targets: []*std.Build.Step.Compile) *std.Build.Step {
    const step = b.allocator.create(std.Build.Step) catch @panic("Allocation failure, probably OOM");

    compile_steps = targets;

    step.* = std.Build.Step.init(.{
        .id = .custom,
        .name = "cc_file",
        .makeFn = makeCdb,
        .owner = b,
    });

    const cdb_step = b.step(name, "Create compile_commands.json");
    cdb_step.dependOn(step);

    return step;
}

fn extractIncludeDirsFromCompileStepInner(b: *std.Build, step: *std.Build.Step.Compile, lazy_path_output: *std.ArrayList(std.Build.LazyPath)) void {
    for (step.root_module.include_dirs.items) |include_dir| {
        switch (include_dir) {
            .other_step => |other_step| {
                // if we are including another step, that step probably installs
                // some headers. look through all of those and get their dirs.
                for (other_step.installed_headers.items) |header_step| {
                    // NOTE: this may be either a path to a file or a path to a directory of files to include.
                    // if the directory has exclude patterns set, we will ignore those.
                    // TODO: switch this to include the output directory instead of the source directory, so
                    // that include / exclude patterns are respected
                    lazy_path_output.append(b.allocator, header_step.getSource()) catch @panic("OOM");
                }
                // recurse- this step may have included child dependencies
                var local_lazy_path_output = std.ArrayList(std.Build.LazyPath){};
                defer local_lazy_path_output.deinit(b.allocator);
                extractIncludeDirsFromCompileStepInner(b, other_step, &local_lazy_path_output);
                lazy_path_output.appendSlice(b.allocator, local_lazy_path_output.items) catch @panic("OOM");
            },
            .path => |path| lazy_path_output.append(b.allocator, path) catch @panic("OOM"),
            .path_system => |path| lazy_path_output.append(b.allocator, path) catch @panic("OOM"),
            // TODO: support this
            .config_header_step => {},
            // TODO: test these...
            .framework_path => |path| {
                std.log.warn("Found framework include path- compile commands generation for this is untested.", .{});
                lazy_path_output.append(b.allocator, path) catch @panic("OOM");
            },
            .framework_path_system => |path| {
                std.log.warn("Found system framework include path- compile commands generation for this is untested.", .{});
                lazy_path_output.append(b.allocator, path) catch @panic("OOM");
            },
            .path_after => |path| {
                std.log.warn("Found path_after- compile commands generation for this is untested.", .{});
                lazy_path_output.append(b.allocator, path) catch @panic("OOM");
            },
            // TODO: support this
            .embed_path => {},
        }
    }
}

/// A compilation step has an "include_dirs" array list, which contains paths as
/// well as other compile steps. This loops until all the include directories
/// necessary for good intellisense on the files compile by this step are found.
pub fn extractIncludeDirsFromCompileStep(b: *std.Build, step: *std.Build.Step.Compile) []const []const u8 {
    var dirs = std.ArrayList(std.Build.LazyPath){};
    defer dirs.deinit(b.allocator);

    // populates dirs
    extractIncludeDirsFromCompileStepInner(b, step, &dirs);

    var dirs_as_strings = std.ArrayList([]const u8){};
    defer dirs_as_strings.deinit(b.allocator);

    // resolve lazy paths all at once
    for (dirs.items) |lazy_path| {
        dirs_as_strings.append(b.allocator, lazy_path.getPath(b)) catch @panic("OOM");
    }

    return dirs_as_strings.toOwnedSlice(b.allocator) catch @panic("OOM");
}

/// If a file is given to zig by absolute path, this function does nothing.
/// Otherwise, it makes the relative path to the source file absolute by
/// appending it to the builder passed in to this function.
fn makeCSourcePathsAbsolute(b: *std.Build, c_sources: CSourceFiles) AbsoluteCSourceFiles {
    var cpaths = std.ArrayList([]const u8){};
    defer cpaths.deinit(b.allocator);

    for (c_sources.files) |file| {
        if (std.fs.path.isAbsolute(file)) {
            cpaths.append(b.allocator, file) catch @panic("OOM");
        } else {
            cpaths.append(b.allocator, c_sources.root.path(b, file).getPath(b)) catch @panic("OOM");
        }
    }

    return AbsoluteCSourceFiles{
        .files = cpaths.toOwnedSlice(b.allocator) catch @panic("OOM"),
        .flags = c_sources.flags,
    };
}

// NOTE: some of the CSourceFiles pointed at by the elements of the returned
// array are allocated with the allocator, some are not.
fn getCSources(b: *std.Build, steps: []const *std.Build.Step.Compile) []*AbsoluteCSourceFiles {
    var allocator = b.allocator;
    var res = std.ArrayList(*AbsoluteCSourceFiles){};

    // move the compile steps into a mutable dynamic array, so we can add
    // any child steps
    var compile_steps_list = std.ArrayList(*std.Build.Step.Compile){};
    compile_steps_list.appendSlice(allocator, steps) catch @panic("OOM");

    var index: u32 = 0;

    // list may be appended to during the loop, so use a while
    while (index < compile_steps_list.items.len) {
        const step = compile_steps_list.items[index];

        var shared_flags = std.ArrayList([]const u8){};
        defer shared_flags.deinit(allocator);

        // catch all the system libraries being linked, make flags out of them
        for (step.root_module.link_objects.items) |link_object| {
            switch (link_object) {
                .system_lib => |lib| shared_flags.append(allocator, linkFlag(allocator, lib.name)) catch @panic("OOM"),
                else => {},
            }
        }

        if (step.is_linking_libc) {
            shared_flags.append(allocator, linkFlag(allocator, "c")) catch @panic("OOM");
        }
        if (step.is_linking_libcpp) {
            shared_flags.append(allocator, linkFlag(allocator, "c++")) catch @panic("OOM");
        }

        // make flags out of all include directories
        for (extractIncludeDirsFromCompileStep(b, step)) |include_dir| {
            shared_flags.append(allocator, includeFlag(allocator, include_dir)) catch @panic("OOM");
        }

        for (step.root_module.link_objects.items) |link_object| {
            switch (link_object) {
                .static_path => {
                    continue;
                },
                .other_step => {
                    compile_steps_list.append(allocator, link_object.other_step) catch @panic("OOM");
                },
                .system_lib => {
                    continue;
                },
                .assembly_file => {
                    continue;
                },
                .win32_resource_file => {
                    continue;
                },
                .c_source_file => {
                    // convert C source file into absolute C source files
                    const path = link_object.c_source_file.file.getPath(b);
                    var files_mem = allocator.alloc([]const u8, 1) catch @panic("Allocation failure, probably OOM");
                    files_mem[0] = path;

                    const abs_source_file = allocator.create(AbsoluteCSourceFiles) catch @panic("Allocation failure, probably OOM");

                    var flags = std.ArrayList([]const u8){};
                    flags.appendSlice(allocator, link_object.c_source_file.flags) catch @panic("OOM");
                    flags.appendSlice(allocator, shared_flags.items) catch @panic("OOM");

                    abs_source_file.* = makeCSourcePathsAbsolute(step.step.owner, CSourceFiles{
                        .root = .{ .src_path = .{
                            .owner = step.step.owner,
                            .sub_path = "",
                        } },
                        .files = files_mem,
                        .flags = flags.toOwnedSlice(allocator) catch @panic("OOM"),
                        .language = .c,
                    });

                    res.append(b.allocator, abs_source_file) catch @panic("OOM");
                },
                .c_source_files => {
                    var source_files = link_object.c_source_files;
                    var flags = std.ArrayList([]const u8){};
                    flags.appendSlice(allocator, source_files.flags) catch @panic("OOM");
                    flags.appendSlice(allocator, shared_flags.items) catch @panic("OOM");
                    source_files.flags = flags.toOwnedSlice(allocator) catch @panic("OOM");

                    const absolute_source_files = allocator.create(AbsoluteCSourceFiles) catch @panic("OOM");
                    absolute_source_files.* = makeCSourcePathsAbsolute(step.step.owner, source_files.*);

                    res.append(b.allocator, absolute_source_files) catch @panic("OOM");
                },
            }
        }
        index += 1;
    }

    return res.toOwnedSlice(b.allocator) catch @panic("OOM");
}

fn makeCdb(step: *std.Build.Step, make_options: std.Build.Step.MakeOptions) anyerror!void {
    if (compile_steps == null) {
        @panic("No compile steps registered. Programmer error in createStep");
    }
    _ = make_options;
    const allocator = step.owner.allocator;
    const b = step.owner;
    // NOTE: these are not sane defaults really, but atm I don't care about accurately providing the
    // location of the built .o object file to clangd
    const global_cache_root = b.graph.global_cache_root.path orelse b.cache_root.path orelse (try std.fs.cwd().realpathAlloc(allocator, "."));

    var compile_commands = std.ArrayList(CompileCommandEntry){};
    defer compile_commands.deinit(allocator);

    // initialize file and struct containing its future contents
    const cwd: std.fs.Dir = std.fs.cwd();
    var file = try cwd.createFile("compile_commands.json", .{});
    defer file.close();

    const cwd_string = try dirToString(cwd, allocator);
    const c_sources = getCSources(step.owner, compile_steps.?);

    // fill compile command entries, one for each file
    for (c_sources) |absolute_c_source_files| {
        const flags = absolute_c_source_files.flags;
        for (absolute_c_source_files.files) |c_file| {
            // NOTE: this is not accurate- not actually generating the hashed subdirectory names
            const output_str = b.fmt("{s}.o", .{b.pathJoin(&.{ global_cache_root, std.fs.path.basename(c_file) })});

            var arguments = std.ArrayList([]const u8){};
            // pretend this is clang compiling
            arguments.appendSlice(allocator, &.{ "clang", c_file, "-o", output_str }) catch @panic("OOM");
            arguments.appendSlice(allocator, flags) catch @panic("OOM");

            // add host native include dirs and libs
            // (doesn't really help unless your include dirs change after generating this)
            // {
            //     var native_paths = try std.zig.system.NativePaths.detect(allocator, step.owner.host);
            //     defer native_paths.deinit();
            //     // native_paths also has lib_dirs. probably not relevant to clangd and compile_commands.json
            //     for (native_paths.include_dirs.items) |include_dir| {
            //         try arguments.append(try common.includeFlag(allocator, include_dir));
            //     }
            // }

            const entry = CompileCommandEntry{
                .arguments = arguments.toOwnedSlice(allocator) catch @panic("OOM"),
                .output = output_str,
                .file = c_file,
                .directory = cwd_string,
            };
            compile_commands.append(allocator, entry) catch @panic("OOM");
        }
    }

    try writeCompileCommands(&file, compile_commands.items);
}

fn writeCompileCommands(file: *std.fs.File, compile_commands: []CompileCommandEntry) !void {
    var buf: [std.json.default_buffer_size]u8 = undefined;
    var writer = file.*.writer(&buf);
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

fn dirToString(dir: std.fs.Dir, allocator: std.mem.Allocator) ![]const u8 {
    var real_dir = try dir.openDir(".", .{});
    defer real_dir.close();
    return std.fs.realpathAlloc(allocator, ".") catch |err| {
        std.debug.print("error encountered in converting directory to string.\n", .{});
        return err;
    };
}

fn linkFlag(ally: std.mem.Allocator, lib: []const u8) []const u8 {
    return std.fmt.allocPrint(ally, "-l{s}", .{lib}) catch @panic("OOM");
}

fn includeFlag(ally: std.mem.Allocator, path: []const u8) []const u8 {
    return std.fmt.allocPrint(ally, "-I{s}", .{path}) catch @panic("OOM");
}
