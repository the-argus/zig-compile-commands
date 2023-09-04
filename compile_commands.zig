const std = @import("std");

// here's the static memory!!!!
var compile_steps: ?[]*std.Build.CompileStep = null;

const CSourceFiles = std.Build.CompileStep.CSourceFiles;

const CompileCommandEntry = struct {
    arguments: []const []const u8,
    directory: []const u8,
    file: []const u8,
    output: []const u8,
};

pub fn createStep(b: *std.Build, name: []const u8, targets: []*std.Build.CompileStep) void {
    var step = b.allocator.create(std.Build.Step) catch @panic("Allocation failure, probably OOM");

    compile_steps = targets;

    step.* = std.Build.Step.init(.{
        .id = .custom,
        .name = "cc_file",
        .makeFn = makeCdb,
        .owner = b,
    });

    const cdb_step = b.step(name, "Create compile_commands.json");
    cdb_step.dependOn(step);
}

/// Find all the header installation directories for a step.
/// returns an owned arraylist
fn extractHeaderDirsFromStep(allocator: std.mem.Allocator, step: *std.Build.CompileStep) std.ArrayList([]const u8) {
    var dirs = std.ArrayList([]const u8).init(allocator);
    for (step.installed_headers.items) |header_step| {
        if (header_step.id == .install_file) {
            const install_file = header_step.cast(std.Build.InstallFileStep) orelse @panic("Programmer error generating compile_commands.json");
            // path to specific file being installed
            const file = install_file.dest_builder.getInstallPath(
                install_file.dir,
                install_file.dest_rel_path,
            );
            // just add the directory of that file. often creates duplicates
            dirs.append(if (std.fs.path.dirname(file)) |dirname| dirname else {
                std.log.warn("Unable to get directory name for installed header file {s} ", .{file});
                continue;
            }) catch @panic("OOM");
        }
    }
    return dirs;
}

// NOTE: some of the CSourceFiles pointed at by the elements of the returned
// array are allocated with the allocator, some are not.
fn getCSources(b: *std.Build, steps: []const *std.Build.CompileStep) []*CSourceFiles {
    var allocator = b.allocator;
    var res = std.ArrayList(*CSourceFiles).init(allocator);

    // move the compile steps into a mutable dynamic array, so we can add
    // any child steps
    var compile_steps_list = std.ArrayList(*std.Build.CompileStep).init(b.allocator);
    compile_steps_list.appendSlice(steps);

    var index: u32 = 0;

    // list may be appended to during the loop, so use a while
    while (index < compile_steps_list.?.items.len) {
        const step = compile_steps_list.?.items[index];

        var shared_flags = std.ArrayList([]const u8).init(allocator);
        defer shared_flags.deinit();

        // catch all the system libraries being linked, make flags out of them
        for (step.link_objects.items) |link_object| {
            switch (link_object) {
                .system_lib => |lib| shared_flags.append(linkFlag(allocator, lib.name)) catch @panic("OOM"),
                else => {},
            }
        }

        if (step.is_linking_libc) {
            shared_flags.append(linkFlag(allocator, "c")) catch @panic("OOM");
        }
        if (step.is_linking_libcpp) {
            shared_flags.append(linkFlag(allocator, "c++")) catch @panic("OOM");
        }

        // do the same for include directories
        for (step.include_dirs.items) |include_dir| {
            switch (include_dir) {
                .other_step => |other_step| {
                    const arraylist_header_dirs = extractHeaderDirsFromStep(allocator, other_step);
                    for (arraylist_header_dirs.items) |header_dir| {
                        shared_flags.append(includeFlag(allocator, header_dir)) catch @panic("OOM");
                    }
                },
                .path => |path| shared_flags.append(includeFlag(allocator, path.getPath(b))) catch @panic("OOM"),
                .path_system => |path| shared_flags.append(includeFlag(allocator, path.getPath(b))) catch @panic("OOM"),
                // TODO: support this
                .config_header_step => {},
            }
        }

        for (step.link_objects.items) |link_object| {
            switch (link_object) {
                .static_path => {
                    continue;
                },
                .other_step => {
                    compile_steps.?.append(link_object.other_step) catch @panic("OOM");
                },
                .system_lib => {
                    continue;
                },
                .assembly_file => {
                    continue;
                },
                .c_source_file => {
                    // convert C source file into c source fileS
                    const path = link_object.c_source_file.file.getPath(b);
                    var files_mem = allocator.alloc([]const u8, 1) catch @panic("Allocation failure, probably OOM");
                    files_mem[0] = path;

                    var source_file = allocator.create(CSourceFiles) catch @panic("Allocation failure, probably OOM");

                    var flags = std.ArrayList([]const u8).init(allocator);
                    flags.appendSlice(link_object.c_source_file.flags) catch @panic("OOM");
                    flags.appendSlice(shared_flags.items) catch @panic("OOM");

                    source_file.* = CSourceFiles{
                        .files = files_mem,
                        .flags = flags.toOwnedSlice() catch @panic("OOM"),
                    };

                    res.append(source_file) catch @panic("OOM");
                },
                .c_source_files => {
                    var source_files = link_object.c_source_files;
                    var flags = std.ArrayList([]const u8).init(allocator);
                    flags.appendSlice(source_files.flags) catch @panic("OOM");
                    flags.appendSlice(shared_flags.items) catch @panic("OOM");
                    source_files.flags = flags.toOwnedSlice() catch @panic("OOM");

                    res.append(source_files) catch @panic("OOM");
                },
            }
        }
        index += 1;
    }

    return res.toOwnedSlice() catch @panic("OOM");
}

fn makeCdb(step: *std.Build.Step, prog_node: *std.Progress.Node) anyerror!void {
    if (compile_steps == null) {
        @panic("No compile steps registered. Programmer error in createStep");
    }
    _ = prog_node;
    var allocator = step.owner.allocator;

    var compile_commands = std.ArrayList(CompileCommandEntry).init(allocator);
    defer compile_commands.deinit();

    // initialize file and struct containing its future contents
    const cwd: std.fs.Dir = std.fs.cwd();
    var file = try cwd.createFile("compile_commands.json", .{});
    defer file.close();

    const cwd_string = try dirToString(cwd, allocator);
    const c_sources = getCSources(step.owner, compile_steps);

    // fill compile command entries, one for each file
    for (c_sources) |c_source_file_set| {
        const flags = c_source_file_set.flags;
        for (c_source_file_set.files) |c_file| {
            const file_str = std.fs.path.join(allocator, &[_][]const u8{ cwd_string, c_file }) catch @panic("OOM");
            const output_str = std.fmt.allocPrint(allocator, "{s}.o", .{file_str}) catch @panic("OOM");

            var arguments = std.ArrayList([]const u8).init(allocator);
            // pretend this is clang compiling
            arguments.append("clang") catch @panic("OOM");
            arguments.append(c_file) catch @panic("OOM");
            arguments.appendSlice(&.{ "-o", std.fmt.allocPrint(allocator, "{s}.o", .{c_file}) catch @panic("OOM") }) catch @panic("OOM");
            arguments.appendSlice(flags) catch @panic("OOM");

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
                .arguments = arguments.toOwnedSlice() catch @panic("OOM"),
                .output = output_str,
                .file = file_str,
                .directory = cwd_string,
            };
            compile_commands.append(entry) catch @panic("OOM");
        }
    }

    try writeCompileCommands(&file, compile_commands.items);
}

fn writeCompileCommands(file: *std.fs.File, compile_commands: []CompileCommandEntry) !void {
    const options = std.json.StringifyOptions{
        .whitespace = .indent_tab,
        .emit_null_optional_fields = false,
    };

    try std.json.stringify(compile_commands, options, file.*.writer());
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
