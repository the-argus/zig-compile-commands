# zig compile_commands.json

A simple zig module to generate compile_commands.json from a slice of build targets.

Intended for Zig v0.13.0

Relies on static variables to store the targets, so that the make step can
access them.

## Example Usage

First, `build.zig.zon`:

```zig
.{
    .name = "your-project",
    .version = "0.0.1",
    .minimum_zig_version = "0.14.0",
    .dependencies = .{
        .compile_commands = .{
            .url = "https://github.com/the-argus/zig-compile-commands/archive/b73e8bdeb1266ea01b249387cabb39aad49f35d1.tar.gz",
            .hash = "1220b92b277b33762a10b4f239edddfbe9aadd53af88c678f94443b0d2312d9526fa",
        },
    },
    .paths = .{"src"},
}
```

Then, bring that into your `build.zig`:

```zig
// import the dependency
const zcc = @import("compile_commands");

pub fn build(b: *std.Build) !void {
    // make a list of targets that have include files and c source files
    var targets = std.ArrayList(*std.Build.Step.Compile).init(b.allocator);

    // create your executable
    const exe = b.addExecutable(.{
        .name = "my-project",
        .optimize = mode,
        .target = target,
    });
    // keep track of it, so later we can pass it to compile_commands
    targets.append(exe) catch @panic("OOM");
    // maybe some other targets, too?
    targets.append(exe_2) catch @panic("OOM");
    // if this is an output, append it. but if exe or exe_2 links it, then it
    // will get pulled in automatically
    targets.append(lib) catch @panic("OOM");

    // add a step called "cdb" (Compile commands DataBase) for making
    // compile_commands.json. could be named anything. cdb is just quick to type
    zcc.createStep(b, "cdb", targets.toOwnedSlice() catch @panic("OOM"));
}
```

And you're all done. Just run `zig build cdb` to generate the `compile_commands.json`
file according to your current build graph.
