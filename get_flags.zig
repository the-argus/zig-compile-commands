/// This file just contains ports of functions from std.Build.Step.Compile and
/// std.Build.Module which determine what compilation flags should be used. But
/// in these versions, linker flags and zig-specific flags are removed, so only
/// the clangd-relevant flags appear in the compile_commands.json
/// (also, most of the relevant functions are private in std, so they have to
/// be replicated here anyways)
const std = @import("std");
const fcompat = @import("file_compat.zig");
const LazyPath = std.Build.LazyPath;
const CompileCommandEntry = @import("compile_commands.zig").CompileCommandEntry;

const InProgressCompileCommandsEntry = struct {
    directory: []const u8,
    file_specific_flags: std.ArrayList([]const u8) = .empty,
};
const CompileCommandsBuilder = struct {
    files: std.StringHashMapUnmanaged(InProgressCompileCommandsEntry) = .{},

    pub fn init() @This() {
        return .{};
    }

    pub fn resolvePathAndAdd(self: *@This(), b: *std.Build, source: *std.Build.Module.CSourceFile) !void {
        // the file for this is a LazyPath
        const absolute_path = try source.file.getPath3(b, null).joinString(b.allocator, "");
        const gop_result = try self.files.getOrPut(b.allocator, absolute_path);
        if (!gop_result.found_existing) {
            gop_result.value_ptr.* = .{ .directory = std.fs.path.dirname(absolute_path) orelse "/" };
        } else {
            @panic("multiple files with the same absolute path?");
        }
        try gop_result.value_ptr.file_specific_flags.appendSlice(b.allocator, source.flags);
    }
    pub fn resolvePathAndAddMany(self: *@This(), b: *std.Build, sources: *std.Build.Module.CSourceFiles) !void {
        // the files in CSourceFiles are subpaths from root
        for (sources.files) |subpath| {
            const root = sources.root.getPath3(b, null);
            const absolute_path = try root.joinString(b.allocator, subpath);
            const gop_result = try self.files.getOrPut(b.allocator, absolute_path);
            if (!gop_result.found_existing) {
                gop_result.value_ptr.* = .{ .directory = std.fs.path.dirname(absolute_path) orelse "/" };
            } else {
                @panic("multiple files with the same absolute path?");
            }
            try gop_result.value_ptr.file_specific_flags.appendSlice(b.allocator, sources.flags);
            gop_result.value_ptr.directory = try root.joinString(b.allocator, "");
        }
    }

    /// Fills up some CompileCommandEntrys with pointers to shared_flags. relies
    /// on builder allocator being leaky, and not using this builder after this
    /// function is called, as the entries have pointers to keys of this
    /// object's hash map
    pub fn finish(
        self: *@This(),
        b: *std.Build,
        shared_flags: []const []const u8,
        driver: ?[]const u8,
        output: *std.ArrayList(CompileCommandEntry),
    ) !void {
        const cwd_string = try fcompat.getCwd(b);
        const global_cache_root = b.graph.global_cache_root.path orelse b.cache_root.path orelse cwd_string;

        try output.ensureUnusedCapacity(b.allocator, self.files.size);
        var iterator = self.files.iterator();
        while (iterator.next()) |hm_entry| {
            const output_str = b.fmt("{s}.o", .{b.pathJoin(&.{ global_cache_root, std.fs.path.basename(hm_entry.key_ptr.*) })});

            // for each source file, create a new set of flags which is the shared flags + file specific flags
            var allflags: std.ArrayList([]const u8) = .empty; // leak this
            const initial_flags = &.{ driver orelse "clang", hm_entry.key_ptr.*, "-o", output_str };
            try allflags.ensureTotalCapacity(b.allocator, initial_flags.len + shared_flags.len + hm_entry.value_ptr.file_specific_flags.items.len);

            allflags.appendSliceAssumeCapacity(initial_flags);
            allflags.appendSliceAssumeCapacity(shared_flags);
            allflags.appendSliceAssumeCapacity(hm_entry.value_ptr.file_specific_flags.items);

            output.appendAssumeCapacity(CompileCommandEntry{
                .file = hm_entry.key_ptr.*,
                .directory = hm_entry.value_ptr.directory,
                .output = output_str,
                .arguments = allflags.items,
            });
        }
    }
};

const GenerateCompileCommandsParameters = struct {
    output: *std.ArrayList(CompileCommandEntry),
    driver: ?[]const u8,
};
/// configuration parameters and intermediate data
const GenerateCompileCommandsIntermediate = struct {
    params: GenerateCompileCommandsParameters,
    allocator: std.mem.Allocator,
    flags: *std.ArrayList([]const u8), // per-module not per-file
};
const GenerateLazyPathParameters = struct {
    output: *std.ArrayList(LazyPath),
};
const GenerateParameters = union(enum) {
    cc_params: GenerateCompileCommandsIntermediate,
    lazy_path_params: GenerateLazyPathParameters,
};

const GenerateOutput = struct {
    params: GenerateParameters,

    pub fn wantsFlags(self: *const @This()) bool {
        return self.params == .cc_params;
    }

    /// add CSourceFile to compile_commands.json, OR add LazyPath so we can depend on the generation of this file
    /// does not use our allocator or modify us, just reads self.params to check if we are resolving the paths or not
    pub fn addResolvedPath(self: *const @This(), b: *std.Build, builder: *CompileCommandsBuilder, source_file: *std.Build.Module.CSourceFile) !void {
        switch (self.params) {
            .cc_params => try builder.resolvePathAndAdd(b, source_file),
            .lazy_path_params => |params| try params.output.append(b.allocator, source_file.file),
        }
    }
    /// add CSourceFiles to compile_commands.json, OR add LazyPath so we can depend on the generation of these files
    /// does not use our allocator or modify us, just reads self.params to check if we are resolving the paths or not
    pub fn addResolvedPaths(self: *const @This(), b: *std.Build, builder: *CompileCommandsBuilder, source_files: *std.Build.Module.CSourceFiles) !void {
        switch (self.params) {
            .cc_params => try builder.resolvePathAndAddMany(b, source_files),
            .lazy_path_params => |params| try params.output.append(b.allocator, source_files.root),
        }
    }
    /// add include directive to compile_commands.json, OR add LazyPath so we can depend on the generation of the file/folder
    pub fn appendFlagForIncludeDir(self: *const @This(), include_dir: FlagForIncludeDir, asking_step: *std.Build.Step) !void {
        const b = asking_step.owner;
        switch (self.params) {
            .cc_params => |params| {
                switch (include_dir.flag) {
                    .prefix => |prefix| {
                        const resolved_str = try include_dir.path.getPath3(b, asking_step).toString(params.allocator);
                        return self.appendFlagSlice(&.{ prefix, resolved_str });
                    },
                    .embed_path => {
                        const resolved = include_dir.path.getPath3(b, asking_step);
                        return self.appendFlag(b.fmt("--embed-dir={f}", .{resolved}));
                    },
                }
            },
            .lazy_path_params => |params| try params.output.append(b.allocator, include_dir.path),
        }
    }

    pub fn appendFlag(self: *const @This(), flag: []const u8) !void {
        switch (self.params) {
            .cc_params => |params| try params.flags.append(params.allocator, flag),
            .lazy_path_params => {},
        }
    }

    pub fn appendFlagSlice(self: *const @This(), to_append: []const []const u8) !void {
        switch (self.params) {
            .cc_params => |params| try params.flags.appendSlice(params.allocator, to_append),
            .lazy_path_params => {},
        }
    }

    pub fn appendYesNoFlag(
        self: *const @This(),
        opt: ?bool,
        then_name: []const u8,
        else_name: []const u8,
    ) !void {
        switch (self.params) {
            .cc_params => |params| {
                const cond = opt orelse return;
                return params.flags.append(params.allocator, if (cond) then_name else else_name);
            },
            .lazy_path_params => {},
        }
    }

    fn appendFNoFlag(self: @This(), comptime name: []const u8, opt: ?bool) !void {
        switch (self.params) {
            .cc_params => |params| {
                const cond = opt orelse return;
                try params.flags.ensureUnusedCapacity(params.allocator, 1);
                if (cond) {
                    params.flags.appendAssumeCapacity("-f" ++ name);
                } else {
                    params.flags.appendAssumeCapacity("-fno-" ++ name);
                }
            },
            .lazy_path_params => {},
        }
    }
};

const FlagForIncludeDir = struct {
    const Flag = union(enum) {
        prefix: []const u8,
        embed_path: void,
    };

    flag: Flag,
    path: LazyPath,

    /// Modified version of std.Build.Module.IncludeDir.appendZigProcessFlags,
    /// should stay up to date with that
    fn initFromIncludeDir(include_dir: std.Build.Module.IncludeDir) FlagForIncludeDir {
        return switch (include_dir) {
            // zig fmt: off
            .path =>                    |lp|        .{ .flag = .{ .prefix = "-I" },             .path = lp },
            .path_system =>             |lp|        .{ .flag = .{ .prefix = "-isystem" },       .path = lp },
            .path_after =>              |lp|        .{ .flag = .{ .prefix = "-idirafter" },     .path = lp },
            .framework_path =>          |lp|        .{ .flag = .{ .prefix = "-F" },             .path = lp },
            .framework_path_system =>   |lp|        .{ .flag = .{ .prefix = "-iframework" },    .path = lp },
            .config_header_step =>      |ch|        .{ .flag = .{ .prefix = "-I" },             .path = ch.getOutputDir() },
            // implementation in zig std does .installed_headers_include_tree.?.getDirectory() instead of getEmittedIncludeTree()
            // if that changes this has to change, too
            .other_step =>              |comp|      .{ .flag = .{ .prefix = "-I" },             .path = comp.getEmittedIncludeTree() },
            .embed_path =>              |lazy_path| .{ .flag = .embed_path,                     .path = lazy_path },
            // zig fmt: on
        };
    }
};

/// Modified version of std.Build.Module.appendZigProcessFlags which removes
/// or modifies zig-specific flags to work with clang
fn appendFlagsForModule(
    output: *GenerateOutput,
    mod: *std.Build.Module,
    asking_step: *std.Build.Step,
) !void {
    const b = mod.owner;

    try output.appendYesNoFlag(mod.stack_protector, "-fstack-protector", "-fno-stack-protector");
    try output.appendYesNoFlag(mod.omit_frame_pointer, "-fomit-frame-pointer", "-fno-omit-frame-pointer");
    try output.appendYesNoFlag(mod.sanitize_thread, "-fsanitize=thread", "-fno-sanitize=thread");
    try output.appendYesNoFlag(mod.pic, "-fPIC", "-fno-PIC");
    try output.appendYesNoFlag(mod.no_builtin, "-fno-builtin", "-fbuiltin");

    if (mod.sanitize_c) |sc| switch (sc) {
        .off => try output.appendFlag("-fno-sanitize=undefined"),
        .trap => try output.appendFlag("-fsanitize-trap=undefined"),
        .full => try output.appendFlag("-fsanitize=undefined"),
    };

    if (mod.dwarf_format) |dwarf_format| {
        try output.appendFlag(switch (dwarf_format) {
            .@"32" => "-gdwarf32",
            .@"64" => "-gdwarf64",
        });
    }

    if (mod.optimize) |optimize| switch (optimize) {
        .Debug => try output.appendFlag("-O0"),
        .ReleaseSmall => try output.appendFlag("-Os"),
        .ReleaseFast, .ReleaseSafe => try output.appendFlag("-O3"),
    };

    if (mod.code_model != .default) {
        if (output.params == .cc_params) {
            try output.appendFlag(b.fmt("-mcmodel={s}", .{@tagName(mod.code_model)}));
        }
    }

    if (mod.resolved_target) |*target| {
        if (!target.query.isNative()) {
            try output.appendFlagSlice(&.{
                "-target", try target.query.zigTriple(b.allocator),
                "-mcpu",   try target.query.serializeCpuAlloc(b.allocator),
            });
        }
    }

    // include dirs
    for (mod.include_dirs.items) |include_dir| {
        try output.appendFlagForIncludeDir(FlagForIncludeDir.initFromIncludeDir(include_dir), asking_step);
    }

    // c macro flags
    try output.appendFlagSlice(mod.c_macros.items);
}

/// Appends the transitive/public flags of a system library which is linked to some artifact `step`
/// A subset of std.Build.Step.Compile.getZigArgs
fn appendFlagsForSystemLib(
    step: *std.Build.Step.Compile,
    output: *GenerateOutput,
    system_lib: std.Build.Module.SystemLib,
    seen_system_libs: *std.StringHashMapUnmanaged([]const []const u8),
) !void {
    const b = step.step.owner;
    const system_lib_gop = try seen_system_libs.getOrPut(b.allocator, system_lib.name);
    if (system_lib_gop.found_existing) {
        try output.appendFlagSlice(system_lib_gop.value_ptr.*);
        return;
    } else {
        system_lib_gop.value_ptr.* = &.{};
    }

    const prefix: []const u8 = prefix: {
        if (system_lib.needed) break :prefix "-needed-l";
        if (system_lib.weak) break :prefix "-weak-l";
        break :prefix "-l";
    };
    switch (system_lib.use_pkg_config) {
        .no => if (output.wantsFlags()) try output.appendFlag(b.fmt("{s}{s}", .{ prefix, system_lib.name })),
        .yes, .force => {
            if (std.Build.Step.Compile.runPkgConfig(&step.step, system_lib.name)) |result| {
                try output.appendFlagSlice(result.cflags);
                try output.appendFlagSlice(result.libs);
                try seen_system_libs.put(b.allocator, system_lib.name, result.cflags);
            } else |err| switch (err) {
                error.PkgConfigInvalidOutput,
                error.PkgConfigCrashed,
                error.PkgConfigFailed,
                error.PkgConfigNotInstalled,
                error.PackageNotFound,
                => switch (system_lib.use_pkg_config) {
                    .yes => {
                        // pkg-config failed, so fall back to linking the library
                        // by name directly.
                        if (output.wantsFlags()) try output.appendFlag(b.fmt("{s}{s}", .{
                            prefix,
                            system_lib.name,
                        }));
                    },
                    .force => {
                        std.debug.panic("pkg-config failed for library {s}, unable to build compile_commands.json", .{system_lib.name});
                    },
                    .no => unreachable,
                },

                else => |e| return e,
            }
        },
    }
}

/// Get all the LazyPaths that must be resolved before
/// compileStepToCompileCommandEntries can be safely called.
pub fn compileStepPathDependencies(step: *std.Build.Step.Compile, output: *std.ArrayList(LazyPath)) !void {
    var intermediate_output = GenerateOutput{ .params = .{ .lazy_path_params = .{ .output = output } } };
    return generateCompileCommandEntriesOrGatherDependencies(step, &intermediate_output);
}

pub fn compileStepToCompileCommandEntries(
    step: *std.Build.Step.Compile,
    driver: ?[]const u8,
    output: *std.ArrayList(CompileCommandEntry),
) !void {
    var flags: std.ArrayList([]const u8) = .empty;
    var intermediate_output = GenerateOutput{ .params = .{ .cc_params = .{
        .params = .{
            .output = output,
            .driver = driver,
        },
        .allocator = step.step.owner.allocator,
        .flags = &flags,
    } } };
    return generateCompileCommandEntriesOrGatherDependencies(step, &intermediate_output);
}

/// A subset of std.Build.Step.Compile.getZigArgs
/// Two possible code paths: one to generate CompileCommandEntrys, one to
/// just output the dependent LazyPaths
fn generateCompileCommandEntriesOrGatherDependencies(
    step: *std.Build.Step.Compile,
    output: *GenerateOutput,
) !void {
    const b = step.step.owner;

    // these are additional per-file flags, stored by absolute path to source file
    var file_flags = CompileCommandsBuilder.init();
    if (b.reference_trace) |some| {
        if (output.wantsFlags()) {
            try output.appendFlag(b.fmt("-freference-trace={d}", .{some}));
        }
    }

    // not adding -lc -lc++ here
    {
        // stores flags per system lib
        var seen_system_libs: std.StringHashMapUnmanaged([]const []const u8) = .empty;
        // store -framework FrameworkName flags, which I think clangd might care about?
        var frameworks: std.StringArrayHashMapUnmanaged(std.Build.Module.LinkFrameworkOptions) = .empty;

        for (step.getCompileDependencies(false)) |dep_compile| {
            // when compiling a C/C++ project, usually there is just one module
            // per compile step, but for completeness's sake this loop is here
            for (dep_compile.root_module.getGraph().modules) |mod| {
                // in getZigArgs, this is to optimize linking and avoid the linker getting transient dependencies.
                // Here, this also makes sense, since compile steps do not have public flags they can forward to
                // us. So if something is just linked against then we don't worry about it.
                if (output.wantsFlags()) {
                    for (mod.frameworks.keys(), mod.frameworks.values()) |name, info| {
                        try frameworks.put(b.allocator, name, info);
                    }
                }

                // Inherit dependencies on system libraries and static libraries.
                for (mod.link_objects.items) |link_object| {
                    switch (link_object) {
                        // linking a static library offers nothing to compile_commands.json
                        .static_path => {},
                        // clangd doesnt care about linking against a test or object file or library or adding to rpath
                        // NOTE: if compile steps get a concept of public flags, then this will change and other_step
                        // maye forward something, and we will need to do getCompileDependencies(true) or something to
                        // gather the public flags of linked objects
                        .other_step, .win32_resource_file => {},
                        // assembly files have no associated flags
                        .assembly_file => {},

                        .c_source_file => |c_source_file| try output.addResolvedPath(b, &file_flags, c_source_file),
                        .c_source_files => |c_source_files| try output.addResolvedPaths(b, &file_flags, c_source_files),
                        .system_lib => |system_lib| try appendFlagsForSystemLib(step, output, system_lib, &seen_system_libs),
                    }
                }

                // NOTE: originally in getZigArgs there was some logic here that checks if this is a uniquely named cli module.
                // but I wasn't sure I understood why it was there, so I am just removing code and being liberal with the
                // amount of flags appended -Ian
                try appendFlagsForModule(output, mod, &step.step);
            }
        }

        for (frameworks.keys(), frameworks.values()) |name, info| {
            if (info.needed) {
                try output.appendFlag("-needed_framework");
            } else if (info.weak) {
                try output.appendFlag("-weak_framework");
            } else {
                try output.appendFlag("-framework");
            }
            try output.appendFlag(name);
        }
    }

    if (step.link_function_sections) {
        try output.appendFlag("-ffunction-sections");
    }
    if (step.link_data_sections) {
        try output.appendFlag("-fdata-sections");
    }
    if (step.force_load_objc) {
        try output.appendFlag("-ObjC");
    }
    if (step.wasi_exec_model) |model| {
        try output.appendFlag(b.fmt("-mexec-model={s}", .{@tagName(model)}));
    }

    if (b.sysroot) |sysroot| {
        try output.appendFlagSlice(&[_][]const u8{ "--sysroot", sysroot });
    }

    // NOTE: the actual zig std code checks if the directories exist before doing this
    for (b.search_prefixes.items) |search_prefix| {
        try output.appendFlagSlice(&.{ "-I", b.pathJoin(&.{ search_prefix, "include" }) });
    }

    try output.appendFNoFlag("PIE", step.pie);

    if (step.lto) |lto| {
        try output.appendFlag(switch (lto) {
            .full => "-flto=full",
            .thin => "-flto=thin",
            .none => "-fno-lto",
        });
    }

    switch (output.params) {
        .cc_params => |params| return file_flags.finish(b, params.flags.items, params.params.driver, params.params.output),
        .lazy_path_params => {},
    }
}
