# zig compile_commands.json

A simple zig module to generate compile_commands.json from a slice of build targets.

Intended for Zig v0.11.0

Relies on static variables to store the targets, so that the make step can
access them.

## Example Usage

First, `build.zig.zon`:

```zig
.{
    .name = "your-project",
    .version = "0.0.1",

    .dependencies = .{
        .zig_compile_commands = .{
            .url = "https://github.com/the-argus/zig-compile-commands/archive/SOME_REVISION_HERE.tar.gz",
            .hash = "blahblahblah",
        },
    }
}
```

Then, bring that into your `build.zig`:

```zig
// import the dependency
const zcc = @import("zig_compile_commands");

pub fn build(b: *std.Build) !void {
    // make a list of targets that have include files and c source files
    var targets = std.ArrayList(*std.Build.CompileStep).init(b.allocator);

    // create your executable
    const exe = b.addExecutable(.{
        .name = app_name,
        .optimize = mode,
        .target = target,
    });
    // keep track of it, so later we can pass it to compile_commands
    targets.append(exe) catch @panic("OOM");
    // maybe some other targets, too?
    targets.append(exe_2) catch @panic("OOM");
    targets.append(lib) catch @panic("OOM");
    
    // once we're done making target, put them into the static memory of the zcc
    // module
    zcc.registerCompileSteps(try targets.toOwnedSlice());

    // add a step called "cdb" (Compile commands DataBase) for making
    // compile_commands.json. could be named anything. cdb is just quick to type
    zcc.createStep(b, "cdb");
}
```

And you're all done. Just run `zig build cdb` to generate the `compile_commands.json`
file according to your current build graph.
