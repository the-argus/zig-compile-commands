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
            const triple = llvmTriple(&rt.result, allocator) catch |err| switch (err) {
                error.LlvmUnsupportedArch => @panic("Clangd does not support the target architecture"),
                else => @panic("OOM"),
            };
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

/// Return an LLVM-formatted target triple
/// More info: https://clang.llvm.org/docs/CrossCompilation.html#target-triple
pub fn llvmTriple(target: *const std.Target, allocator: std.mem.Allocator) ![]const u8 {
    if (is_0_16_or_newer) {
        // copied from src/codegen/llvm.zig in the 0.16 release
        var llvm_triple = std.array_list.Managed(u8).init(allocator);
        defer llvm_triple.deinit();

        const llvm_arch = switch (target.cpu.arch) {
            .arm => "arm",
            .armeb => "armeb",
            .aarch64 => if (target.abi == .ilp32) "aarch64_32" else "aarch64",
            .aarch64_be => "aarch64_be",
            .arc => "arc",
            .avr => "avr",
            .bpfel => "bpfel",
            .bpfeb => "bpfeb",
            .csky => "csky",
            .hexagon => "hexagon",
            .loongarch32 => "loongarch32",
            .loongarch64 => "loongarch64",
            .m68k => "m68k",
            // MIPS sub-architectures are a bit irregular, so we handle them manually here.
            .mips => if (target.cpu.has(.mips, .mips32r6)) "mipsisa32r6" else "mips",
            .mipsel => if (target.cpu.has(.mips, .mips32r6)) "mipsisa32r6el" else "mipsel",
            .mips64 => if (target.cpu.has(.mips, .mips64r6)) "mipsisa64r6" else "mips64",
            .mips64el => if (target.cpu.has(.mips, .mips64r6)) "mipsisa64r6el" else "mips64el",
            .msp430 => "msp430",
            .powerpc => "powerpc",
            .powerpcle => "powerpcle",
            .powerpc64 => "powerpc64",
            .powerpc64le => "powerpc64le",
            .amdgcn => "amdgcn",
            .riscv32 => "riscv32",
            .riscv32be => "riscv32be",
            .riscv64 => "riscv64",
            .riscv64be => "riscv64be",
            .sparc => "sparc",
            .sparc64 => "sparc64",
            .s390x => "s390x",
            .thumb => "thumb",
            .thumbeb => "thumbeb",
            .x86 => "i386",
            .x86_64 => "x86_64",
            .xcore => "xcore",
            .xtensa => "xtensa",
            .nvptx => "nvptx",
            .nvptx64 => "nvptx64",
            .spirv32 => switch (target.os.tag) {
                .vulkan, .opengl => "spirv",
                else => "spirv32",
            },
            .spirv64 => "spirv64",
            .lanai => "lanai",
            .wasm32 => "wasm32",
            .wasm64 => "wasm64",
            .ve => "ve",

            .alpha,
            .arceb,
            .hppa,
            .hppa64,
            .kalimba,
            .kvx,
            .microblaze,
            .microblazeel,
            .or1k,
            .propeller,
            .sh,
            .sheb,
            .x86_16,
            .xtensaeb,
            => return error.LlvmUnsupportedArch,
        };

        try llvm_triple.appendSlice(llvm_arch);

        const llvm_sub_arch: ?[]const u8 = switch (target.cpu.arch) {
            .arm, .armeb, .thumb, .thumbeb => subArchName(target, .arm, .{
                .{ .v4t, "v4t" },
                .{ .v5t, "v5t" },
                .{ .v5te, "v5te" },
                .{ .v5tej, "v5tej" },
                .{ .v6, "v6" },
                .{ .v6k, "v6k" },
                .{ .v6kz, "v6kz" },
                .{ .v6m, "v6m" },
                .{ .v6t2, "v6t2" },
                .{ .v7a, "v7a" },
                .{ .v7em, "v7em" },
                .{ .v7m, "v7m" },
                .{ .v7r, "v7r" },
                .{ .v7ve, "v7ve" },
                .{ .v8a, "v8a" },
                .{ .v8_1a, "v8.1a" },
                .{ .v8_2a, "v8.2a" },
                .{ .v8_3a, "v8.3a" },
                .{ .v8_4a, "v8.4a" },
                .{ .v8_5a, "v8.5a" },
                .{ .v8_6a, "v8.6a" },
                .{ .v8_7a, "v8.7a" },
                .{ .v8_8a, "v8.8a" },
                .{ .v8_9a, "v8.9a" },
                .{ .v8m, "v8m.base" },
                .{ .v8m_main, "v8m.main" },
                .{ .v8_1m_main, "v8.1m.main" },
                .{ .v8r, "v8r" },
                .{ .v9a, "v9a" },
                .{ .v9_1a, "v9.1a" },
                .{ .v9_2a, "v9.2a" },
                .{ .v9_3a, "v9.3a" },
                .{ .v9_4a, "v9.4a" },
                .{ .v9_5a, "v9.5a" },
                .{ .v9_6a, "v9.6a" },
            }),
            .powerpc => subArchName(target, .powerpc, .{
                .{ .spe, "spe" },
            }),
            .spirv32, .spirv64 => subArchName(target, .spirv, .{
                .{ .v1_6, "1.6" },
                .{ .v1_5, "1.5" },
                .{ .v1_4, "1.4" },
                .{ .v1_3, "1.3" },
                .{ .v1_2, "1.2" },
                .{ .v1_1, "1.1" },
            }),
            else => null,
        };

        if (llvm_sub_arch) |sub| try llvm_triple.appendSlice(sub);
        try llvm_triple.append('-');

        try llvm_triple.appendSlice(switch (target.os.tag) {
            .driverkit,
            .ios,
            .maccatalyst,
            .macos,
            .tvos,
            .visionos,
            .watchos,
            => "apple",
            .ps4,
            .ps5,
            => "scei",
            .amdhsa,
            .amdpal,
            => "amd",
            .cuda,
            .nvcl,
            => "nvidia",
            .mesa3d,
            => "mesa",
            else => "unknown",
        });
        try llvm_triple.append('-');

        const llvm_os = switch (target.os.tag) {
            .dragonfly => "dragonfly",
            .freebsd => "freebsd",
            .fuchsia => "fuchsia",
            .linux => "linux",
            .netbsd => "netbsd",
            .openbsd => "openbsd",
            .illumos => "solaris",
            .windows, .uefi => "windows",
            .haiku => "haiku",
            .rtems => "rtems",
            .cuda => "cuda",
            .nvcl => "nvcl",
            .amdhsa => "amdhsa",
            .ps3 => "lv2",
            .ps4 => "ps4",
            .ps5 => "ps5",
            .mesa3d => "mesa3d",
            .amdpal => "amdpal",
            .hermit => "hermit",
            .hurd => "hurd",
            .wasi => "wasi",
            .emscripten => "emscripten",
            .macos => "macosx",
            .ios, .maccatalyst => "ios",
            .tvos => "tvos",
            .watchos => "watchos",
            .driverkit => "driverkit",
            .visionos => "xros",
            .serenity => "serenity",
            .vulkan => "vulkan",
            .managarm => "managarm",

            .@"3ds",
            .contiki,
            .freestanding,
            .opencl, // https://llvm.org/docs/SPIRVUsage.html#target-triples
            .opengl,
            .other,
            .plan9,
            .psp,
            .vita,
            => "unknown",
        };
        try llvm_triple.appendSlice(llvm_os);

        switch (target.os.versionRange()) {
            .none,
            .windows,
            => {},
            .semver => |ver| try llvm_triple.print("{d}.{d}.{d}", .{
                ver.min.major,
                ver.min.minor,
                ver.min.patch,
            }),
            inline .linux, .hurd => |ver| try llvm_triple.print("{d}.{d}.{d}", .{
                ver.range.min.major,
                ver.range.min.minor,
                ver.range.min.patch,
            }),
        }
        try llvm_triple.append('-');

        const llvm_abi = switch (target.abi) {
            .none => if (target.os.tag == .maccatalyst) "macabi" else "unknown",
            .gnu => "gnu",
            .gnuabin32 => "gnuabin32",
            .gnuabi64 => "gnuabi64",
            .gnueabi => "gnueabi",
            .gnueabihf => "gnueabihf",
            .gnuf32 => "gnuf32",
            .gnusf => "gnusf",
            .gnux32 => "gnux32",
            .ilp32 => "unknown",
            .eabi => "eabi",
            .eabihf => "eabihf",
            .android => "android",
            .androideabi => "androideabi",
            .musl => switch (target.os.tag) {
                // For WASI/Emscripten, "musl" refers to the libc, not really the ABI.
                // "unknown" provides better compatibility with LLVM-based tooling for these targets.
                .wasi, .emscripten => "unknown",
                else => "musl",
            },
            .muslabin32 => "muslabin32",
            .muslabi64 => "muslabi64",
            .musleabi => "musleabi",
            .musleabihf => "musleabihf",
            .muslf32 => "muslf32",
            .muslsf => "muslsf",
            .muslx32 => "muslx32",
            .msvc => "msvc",
            .itanium => "itanium",
            .simulator => "simulator",
            .ohos, .ohoseabi => "ohos",
        };
        try llvm_triple.appendSlice(llvm_abi);

        switch (target.os.versionRange()) {
            .none,
            .semver,
            .windows,
            => {},
            inline .hurd, .linux => |ver| if (target.abi.isGnu()) {
                try llvm_triple.print("{d}.{d}.{d}", .{
                    ver.glibc.major,
                    ver.glibc.minor,
                    ver.glibc.patch,
                });
            } else if (@TypeOf(ver) == std.Target.Os.LinuxVersionRange and target.abi.isAndroid()) {
                try llvm_triple.print("{d}", .{ver.android});
            },
        }

        return llvm_triple.toOwnedSlice();
    } else {
        // copied from src/codegen/llvm.zig in the 0.15.1 release
        var llvm_triple = std.array_list.Managed(u8).init(allocator);
        defer llvm_triple.deinit();

        const llvm_arch = switch (target.cpu.arch) {
            .arm => "arm",
            .armeb => "armeb",
            .aarch64 => if (target.abi == .ilp32) "aarch64_32" else "aarch64",
            .aarch64_be => "aarch64_be",
            .arc => "arc",
            .avr => "avr",
            .bpfel => "bpfel",
            .bpfeb => "bpfeb",
            .csky => "csky",
            .hexagon => "hexagon",
            .loongarch32 => "loongarch32",
            .loongarch64 => "loongarch64",
            .m68k => "m68k",
            // MIPS sub-architectures are a bit irregular, so we handle them manually here.
            .mips => if (target.cpu.has(.mips, .mips32r6)) "mipsisa32r6" else "mips",
            .mipsel => if (target.cpu.has(.mips, .mips32r6)) "mipsisa32r6el" else "mipsel",
            .mips64 => if (target.cpu.has(.mips, .mips64r6)) "mipsisa64r6" else "mips64",
            .mips64el => if (target.cpu.has(.mips, .mips64r6)) "mipsisa64r6el" else "mips64el",
            .msp430 => "msp430",
            .powerpc => "powerpc",
            .powerpcle => "powerpcle",
            .powerpc64 => "powerpc64",
            .powerpc64le => "powerpc64le",
            .amdgcn => "amdgcn",
            .riscv32 => "riscv32",
            .riscv64 => "riscv64",
            .sparc => "sparc",
            .sparc64 => "sparc64",
            .s390x => "s390x",
            .thumb => "thumb",
            .thumbeb => "thumbeb",
            .x86 => "i386",
            .x86_64 => "x86_64",
            .xcore => "xcore",
            .xtensa => "xtensa",
            .nvptx => "nvptx",
            .nvptx64 => "nvptx64",
            .spirv32 => switch (target.os.tag) {
                .vulkan, .opengl => "spirv",
                else => "spirv32",
            },
            .spirv64 => "spirv64",
            .lanai => "lanai",
            .wasm32 => "wasm32",
            .wasm64 => "wasm64",
            .ve => "ve",

            .kalimba,
            .or1k,
            .propeller,
            => error.LlvmUnsupportedArch,
        };

        try llvm_triple.appendSlice(llvm_arch);

        const llvm_sub_arch: ?[]const u8 = switch (target.cpu.arch) {
            .arm, .armeb, .thumb, .thumbeb => subArchName(target, .arm, .{
                .{ .v4t, "v4t" },
                .{ .v5t, "v5t" },
                .{ .v5te, "v5te" },
                .{ .v5tej, "v5tej" },
                .{ .v6, "v6" },
                .{ .v6k, "v6k" },
                .{ .v6kz, "v6kz" },
                .{ .v6m, "v6m" },
                .{ .v6t2, "v6t2" },
                .{ .v7a, "v7a" },
                .{ .v7em, "v7em" },
                .{ .v7m, "v7m" },
                .{ .v7r, "v7r" },
                .{ .v7ve, "v7ve" },
                .{ .v8a, "v8a" },
                .{ .v8_1a, "v8.1a" },
                .{ .v8_2a, "v8.2a" },
                .{ .v8_3a, "v8.3a" },
                .{ .v8_4a, "v8.4a" },
                .{ .v8_5a, "v8.5a" },
                .{ .v8_6a, "v8.6a" },
                .{ .v8_7a, "v8.7a" },
                .{ .v8_8a, "v8.8a" },
                .{ .v8_9a, "v8.9a" },
                .{ .v8m, "v8m.base" },
                .{ .v8m_main, "v8m.main" },
                .{ .v8_1m_main, "v8.1m.main" },
                .{ .v8r, "v8r" },
                .{ .v9a, "v9a" },
                .{ .v9_1a, "v9.1a" },
                .{ .v9_2a, "v9.2a" },
                .{ .v9_3a, "v9.3a" },
                .{ .v9_4a, "v9.4a" },
                .{ .v9_5a, "v9.5a" },
                .{ .v9_6a, "v9.6a" },
            }),
            .powerpc => subArchName(target, .powerpc, .{
                .{ .spe, "spe" },
            }),
            .spirv32, .spirv64 => subArchName(target, .spirv, .{
                .{ .v1_5, "1.5" },
                .{ .v1_4, "1.4" },
                .{ .v1_3, "1.3" },
                .{ .v1_2, "1.2" },
                .{ .v1_1, "1.1" },
            }),
            else => null,
        };

        if (llvm_sub_arch) |sub| try llvm_triple.appendSlice(sub);
        try llvm_triple.append('-');

        try llvm_triple.appendSlice(switch (target.os.tag) {
            .aix,
            .zos,
            => "ibm",
            .driverkit,
            .ios,
            .macos,
            .tvos,
            .visionos,
            .watchos,
            => "apple",
            .ps4,
            .ps5,
            => "scei",
            .amdhsa,
            .amdpal,
            => "amd",
            .cuda,
            .nvcl,
            => "nvidia",
            .mesa3d,
            => "mesa",
            else => "unknown",
        });
        try llvm_triple.append('-');

        const llvm_os = switch (target.os.tag) {
            .freestanding => "unknown",
            .dragonfly => "dragonfly",
            .freebsd => "freebsd",
            .fuchsia => "fuchsia",
            .linux => "linux",
            .ps3 => "lv2",
            .netbsd => "netbsd",
            .openbsd => "openbsd",
            .solaris, .illumos => "solaris",
            .windows, .uefi => "windows",
            .zos => "zos",
            .haiku => "haiku",
            .rtems => "rtems",
            .aix => "aix",
            .cuda => "cuda",
            .nvcl => "nvcl",
            .amdhsa => "amdhsa",
            .opencl => "unknown", // https://llvm.org/docs/SPIRVUsage.html#target-triples
            .ps4 => "ps4",
            .ps5 => "ps5",
            .mesa3d => "mesa3d",
            .amdpal => "amdpal",
            .hermit => "hermit",
            .hurd => "hurd",
            .wasi => "wasi",
            .emscripten => "emscripten",
            .macos => "macosx",
            .ios => "ios",
            .tvos => "tvos",
            .watchos => "watchos",
            .driverkit => "driverkit",
            .visionos => "xros",
            .serenity => "serenity",
            .vulkan => "vulkan",

            .opengl,
            .plan9,
            .contiki,
            .other,
            => "unknown",
        };
        try llvm_triple.appendSlice(llvm_os);

        switch (target.os.versionRange()) {
            .none,
            .windows,
            => {},
            .semver => |ver| try llvm_triple.print("{d}.{d}.{d}", .{
                ver.min.major,
                ver.min.minor,
                ver.min.patch,
            }),
            inline .linux, .hurd => |ver| try llvm_triple.print("{d}.{d}.{d}", .{
                ver.range.min.major,
                ver.range.min.minor,
                ver.range.min.patch,
            }),
        }
        try llvm_triple.append('-');

        const llvm_abi = switch (target.abi) {
            .none, .ilp32 => "unknown",
            .gnu => "gnu",
            .gnuabin32 => "gnuabin32",
            .gnuabi64 => "gnuabi64",
            .gnueabi => "gnueabi",
            .gnueabihf => "gnueabihf",
            .gnuf32 => "gnuf32",
            .gnusf => "gnusf",
            .gnux32 => "gnux32",
            .code16 => "code16",
            .eabi => "eabi",
            .eabihf => "eabihf",
            .android => "android",
            .androideabi => "androideabi",
            .musl => switch (target.os.tag) {
                // For WASI/Emscripten, "musl" refers to the libc, not really the ABI.
                // "unknown" provides better compatibility with LLVM-based tooling for these targets.
                .wasi, .emscripten => "unknown",
                else => "musl",
            },
            .muslabin32 => "muslabin32",
            .muslabi64 => "muslabi64",
            .musleabi => "musleabi",
            .musleabihf => "musleabihf",
            .muslf32 => "muslf32",
            .muslsf => "muslsf",
            .muslx32 => "muslx32",
            .msvc => "msvc",
            .itanium => "itanium",
            .cygnus => "cygnus",
            .simulator => "simulator",
            .macabi => "macabi",
            .ohos, .ohoseabi => "ohos",
        };
        try llvm_triple.appendSlice(llvm_abi);

        switch (target.os.versionRange()) {
            .none,
            .semver,
            .windows,
            => {},
            inline .hurd, .linux => |ver| if (target.abi.isGnu()) {
                try llvm_triple.print("{d}.{d}.{d}", .{
                    ver.glibc.major,
                    ver.glibc.minor,
                    ver.glibc.patch,
                });
            } else if (@TypeOf(ver) == std.Target.Os.LinuxVersionRange and target.abi.isAndroid()) {
                try llvm_triple.print("{d}", .{ver.android});
            },
        }

        return llvm_triple.toOwnedSlice();
    }
}

fn subArchName(target: *const std.Target, comptime family: std.Target.Cpu.Arch.Family, mappings: anytype) ?[]const u8 {
    inline for (mappings) |mapping| {
        if (target.cpu.has(family, mapping[0])) return mapping[1];
    }

    return null;
}
