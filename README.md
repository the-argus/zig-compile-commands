# zig compile_commands.json

A simple zig module to generate compile_commands.json from a slice of build
targets. Useful if you are using zig as a build system for C/C++.

Supports zig v0.15.1 and v0.16.0
Older versions are available in the commit history, but not maintained.

## Example Usage

To get the package in your project, `cd` into its root directory and run:

```bash
zig fetch --save-exact=compile_commands "https://github.com/the-argus/zig-compile-commands/archive/9400cd1963ea6bb58fe47ba7d9700075b808cdd2.tar.gz"
```

This will add an entry in your `build.zig.zon` with the hash of the commit in
that link (the 0.15.1/0.16.0 version).

The next step is to use it into your `build.zig` by use `@import` on the
dependency (zig compile commands is not a normal zig dependency, it is intended
to be used as a build-time zig library):

```zig
// import the dependency
const zcc = @import("compile_commands");

pub fn build(b: *std.Build) !void {
    // make a list of targets that have include files and c source files
    var targets: std.ArrayList(*std.Build.Step.Compile) = .empty;

    // create your executable
    const exe = b.addExecutable(.{
        .name = "my-project",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    // keep track of it, so later we can pass it to compile_commands
    try targets.append(b.allocator, exe);
    // maybe some other targets, too?
    try targets.append(b.allocator, exe_2);
    // if this is an output, append it. but if exe or exe_2 links it, then it
    // will get pulled in automatically, anyways
    try targets.append(b.allocator, lib);

    // Always call createStep last, because it will analyze the build graph at
    // the moment it is called. The "cdb" string is the name the step will be
    // registered under.
    _ = zcc.createStep(b, "cdb", targets.toOwnedSlice(b.allocator) catch @panic("OOM"));
}
```

And you're all done. Just run `zig build cdb` to generate the `compile_commands.json`
file according to your current build graph.

## Building `compile_commands.json` panics

The Zig buildsystem creates folders at build time, to place generated files in.
The paths to these folders is usually determined by the contents of the files.
Therefore, in order for zig-compile-commands to put the right paths in the
`compile_commands.json`, the files at those paths must have already been built.
To achieve this, zig-compile-commands will traverse the build graph and depend
on the build steps that generate those files. It does this during `createStep`.
Steps added after the call to `createStep` may be missed. You may see output
like this:

```txt
getPath() was called on a GeneratedFile that wasn't built yet.
```

It should be resolved by making sure nothing is added to the build graph after
`createStep` is called. If that does not work, report an issue, and in the
meantime you can do something like this, to guarantee that everything needed for
the `compile_commands.json` is present before generation:

```zig
    const targetsSlice = targets.toOwnedSlice(b.allocator) catch @panic("OOM");
    const buildStep = zcc.createStep(b, "cdb", targetsSlice);
    // Build everything in the project before generating the compile_commands
    for (targetsSlice) |target| step.dependOn(&target.step);
```
