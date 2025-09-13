# zig compile_commands.json

A simple zig module to generate compile_commands.json from a slice of build
targets. Useful if you are using zig as a build system for C/C++.

Intended for Zig v0.15.1 (Older versions available but not maintained, check
commit history)

## Example Usage

To get the package in your project, `cd` into its root directory and run:

```bash
zig fetch --save-exact=compile_commands "https://github.com/the-argus/zig-compile-commands/archive/a5389749b867eaa595acccc5cb4dd63f4cc0c07a.tar.gz"
```

This will add an entry in your `build.zig.zon` with the hash of the commit in
that link (the 0.15.1 version).

The next step is to use it into your `build.zig` by use `@import` on the
dependency (zig compile commands is not a normal zig dependency, it is intended
to be used as a build-time zig library):

```zig
// import the dependency
const zcc = @import("compile_commands");

pub fn build(b: *std.Build) !void {
    // make a list of targets that have include files and c source files
    var targets = std.ArrayListUnmanaged(*std.Build.Step.Compile){};

    // create your executable
    const exe = b.addExecutable(.{
        .name = "my-project",
        .optimize = optimize,
        .target = target,
    });
    // keep track of it, so later we can pass it to compile_commands
    targets.append(b.allocator, exe) catch @panic("OOM");
    // maybe some other targets, too?
    targets.append(b.allocator, exe_2) catch @panic("OOM");
    // if this is an output, append it. but if exe or exe_2 links it, then it
    // will get pulled in automatically
    targets.append(b.allocator, lib) catch @panic("OOM");

    // add a step called "cdb" (Compile commands DataBase) for making
    // compile_commands.json. could be named anything. cdb is just quick to type
    _ = zcc.createStep(b, "cdb", targets.toOwnedSlice(b.allocator) catch @panic("OOM"));
}
```

And you're all done. Just run `zig build cdb` to generate the `compile_commands.json`
file according to your current build graph.
