/// This file exists simply to replicate the way triples are generated both in
/// zig 0.15.x and 0.16.x. The llvmTriple function could be made public in zig
/// upstream to help this, but seeing as we support old versions anyways, this
/// file must continue to exist.
const std = @import("std");
const is_0_16_or_newer = @import("file_compat.zig").is_0_16_or_newer;

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
