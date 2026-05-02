const std = @import("std");
const builtin = @import("builtin");

var compile_steps: ?[]*std.Build.Step.Compile = null;
var cc_options: CompileCommandOptions = .{};

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

const CompileCommandOptions = struct {
    // Alternative command driver path (eg: /usr/local/bin/clang++)
    // It will use `clang` if not specified this.
    driver: ?[]const u8 = null,
};

const is_0_16_or_newer = builtin.zig_version.major > 0 or
    (builtin.zig_version.major == 0 and builtin.zig_version.minor >= 16);

const File = if (is_0_16_or_newer) std.Io.File else std.fs.File;
const Dir = if (is_0_16_or_newer) std.Io.Dir else std.fs.Dir;
const Writer = if (is_0_16_or_newer) std.Io.File.Writer else std.fs.File.Writer;

fn getIo() ?std.Io {
    if (is_0_16_or_newer) {
        var threaded: std.Io.Threaded = .init_single_threaded;
        return threaded.io();
    }
    return null;
}

fn getCwd(b: *std.Build) ![]const u8 {
    if (is_0_16_or_newer) {
        return b.build_root.path orelse error.FailedToGetPath;
    } else {
        const cwd = std.fs.cwd();
        return cwd.realpathAlloc(b.allocator, ".");
    }
}

fn asDirectory(io: ?std.Io, p: []const u8) !Dir {
    if (is_0_16_or_newer) {
        const iop = io orelse return error.NoIoAvailable;
        return Dir.openDirAbsolute(iop, p, .{});
    } else {
        return std.fs.openDirAbsolute(p, .{});
    }
}

fn createFile(io: ?std.Io, dir: Dir, filename: []const u8) !File {
    if (is_0_16_or_newer) {
        const iop = io orelse return error.NoIoAvailable;
        return dir.createFile(iop, filename, .{});
    } else {
        return dir.createFile(filename, .{});
    }
}

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

    // make the generation of compile_commands.json depend on the generation of
    // all header files for libraries linked to the target, so that it can know
    // the absolute path to the generated directory
    for (targets) |target| {
        for (target.root_module.link_objects.items) |link_object| {
            switch (link_object) {
                .other_step => |other_step| {
                    step.dependOn(other_step.getEmittedIncludeTree().generated.file.step);
                },
                else => {},
            }
        }

        // paranoia: propagate all dependencies from targets to the step, but
        // not the building of the targets themselves. this is just here to
        // hopefully catch the possibility that there are some config headers
        // or something that need to be generated
        for (target.step.dependencies.items) |dependency| {
            step.dependOn(dependency);
        }
    }

    return step;
}

fn extractIncludeDirsFromCompileStepInner(b: *std.Build, step: *std.Build.Step.Compile, lazy_path_output: *std.ArrayList(std.Build.LazyPath)) void {
    for (step.root_module.include_dirs.items) |include_dir| {
        switch (include_dir) {
            .other_step => |other_step| {
                lazy_path_output.append(b.allocator, other_step.getEmittedIncludeTree()) catch @panic("OOM");
                // recurse- this step may have included child dependencies
                var local_lazy_path_output: std.ArrayList(std.Build.LazyPath) = .empty;
                defer local_lazy_path_output.deinit(b.allocator);
                extractIncludeDirsFromCompileStepInner(b, other_step, &local_lazy_path_output);
                lazy_path_output.appendSlice(b.allocator, local_lazy_path_output.items) catch @panic("OOM");
            },
            .path => |path| {
                lazy_path_output.append(b.allocator, path) catch @panic("OOM");
            },
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
/// necessary for good intellisense on the files compiled by this step are found.
pub fn extractIncludeDirsFromCompileStep(b: *std.Build, step: *std.Build.Step.Compile) []const []const u8 {
    var dirs: std.ArrayList(std.Build.LazyPath) = .empty;
    defer dirs.deinit(b.allocator);

    // populates dirs
    extractIncludeDirsFromCompileStepInner(b, step, &dirs);

    var dirs_as_strings: std.ArrayList([]const u8) = .empty;
    defer dirs_as_strings.deinit(b.allocator);

    // resolve lazy paths all at once
    for (dirs.items) |lazy_path| {
        const valid_path = switch (lazy_path) {
            .generated => |gen| gen.file.path != null,
            else => true,
        };

        if (valid_path) {
            const p = lazy_path.getPath3(b, &step.step);
            dirs_as_strings.append(b.allocator, b.pathResolve(&.{
                p.root_dir.path orelse ".",
                p.sub_path,
            })) catch @panic("OOM");
        }
    }

    return dirs_as_strings.toOwnedSlice(b.allocator) catch @panic("OOM");
}

/// If a file is given to zig by absolute path, this function does nothing.
/// Otherwise, it makes the relative path to the source file absolute by
/// appending it to the builder passed in to this function.
fn makeCSourcePathsAbsolute(b: *std.Build, c_sources: CSourceFiles) AbsoluteCSourceFiles {
    var cpaths: std.ArrayList([]const u8) = .empty;
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
    var res: std.ArrayList(*AbsoluteCSourceFiles) = .empty;

    // move the compile steps into a mutable dynamic array, so we can add
    // any child steps
    var compile_steps_list: std.ArrayList(*std.Build.Step.Compile) = .empty;
    compile_steps_list.appendSlice(allocator, steps) catch @panic("OOM");

    var index: u32 = 0;

    // list may be appended to during the loop, so use a while
    while (index < compile_steps_list.items.len) {
        const step = compile_steps_list.items[index];

        var shared_flags: std.ArrayList([]const u8) = .empty;
        defer shared_flags.deinit(allocator);

        // Add a --target flag when compiling for other architectures
        if (step.root_module.resolved_target) |rt| {
            const triple = rt.result.zigTriple(allocator) catch @panic("OOM");
            const target_flag = std.fmt.allocPrint(
                allocator,
                "--target={s}",
                .{triple},
            ) catch @panic("OOM");
            shared_flags.append(allocator, target_flag) catch @panic("OOM");
        }

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

        // create flags out of all macro definitions
        for (step.root_module.c_macros.items) |macro| {
            shared_flags.append(allocator, macro) catch @panic("OOM");
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

                    var flags: std.ArrayList([]const u8) = .empty;
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
                    var flags: std.ArrayList([]const u8) = .empty;
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
    const cwd_string = try getCwd(b);

    const global_cache_root = b.graph.global_cache_root.path orelse b.cache_root.path orelse cwd_string;

    var compile_commands: std.ArrayList(CompileCommandEntry) = .empty;
    defer compile_commands.deinit(allocator);
    const io = getIo();
    const cwd = try asDirectory(io, cwd_string);
    var file = try createFile(io, cwd, "compile_commands.json");

    const c_sources = getCSources(step.owner, compile_steps.?);

    // fill compile command entries, one for each file
    for (c_sources) |absolute_c_source_files| {
        const flags = absolute_c_source_files.flags;
        for (absolute_c_source_files.files) |c_file| {
            // NOTE: this is not accurate- not actually generating the hashed subdirectory names
            const output_str = b.fmt("{s}.o", .{b.pathJoin(&.{ global_cache_root, std.fs.path.basename(c_file) })});

            var arguments: std.ArrayList([]const u8) = .empty;
            // pretend this is clang compiling
            arguments.appendSlice(allocator, &.{ cc_options.driver orelse "clang", c_file, "-o", output_str }) catch @panic("OOM");
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
    try writeCompileCommands(io, &file, compile_commands.items);
    if (is_0_16_or_newer) {
        const iop = io orelse return error.NoIoAvailable;
        file.close(iop);
    } else {
        file.close();
    }
}

fn writeCompileCommands(
    io: ?std.Io,
    file: *File,
    compile_commands: []CompileCommandEntry,
) !void {
    var buf: [std.json.default_buffer_size]u8 = undefined;
    var writer: Writer = undefined;

    if (is_0_16_or_newer) {
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

fn includeFlag(ally: std.mem.Allocator, path: []const u8) []const u8 {
    return std.fmt.allocPrint(ally, "-I{s}", .{path}) catch @panic("OOM");
}

/// Returns a pointer to the options used for compile_commands.json generation.
///
/// The returned options are intended to be mutated in order to customize
/// how the compilation commands are generated.
pub fn options() *CompileCommandOptions {
    return &cc_options;
}
