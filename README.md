# zig compile_commands.json

A simple zig module to generate compile_commands.json from a slice of build
targets. Useful if you are using zig as a build system for C/C++.

Supports zig v0.16.0
Older versions are available in the commit history, but not maintained.

## Example Usage

To get the package in your project, `cd` into its root directory and run:

```bash
zig fetch --save-exact=compile_commands "https://github.com/the-argus/zig-compile-commands/archive/690eef9b8926dcf1f70b00b0f9c15d99ec2901bb.tar.gz"
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
    b.installArtifact(exe);

    // keep track of it, so later we can pass it to compile_commands
    try targets.append(b.allocator, exe);
    // maybe some other targets, too?
    const exe_2 = b.addExecutable(...);
    b.installArtifact(exe_2);
    try targets.append(b.allocator, exe_2);

    // If you have a lib which is a standalone output of the build, like exe and
    // exe_2 are, append it to the list of targets. But if exe or exe_2 links
    // lib, then it will be visited by the compile_commands.json generator
    // automatically
    const lib = b.addLibrary(...);
    try targets.append(b.allocator, lib);

    // Always call createStep last, because it will analyze the build graph at
    // the moment it is called. The "cdb" string is the name the step will be
    // registered under.
    //
    // This function returns the step. One thing you might use this for is to
    // make it a dependency of the main install step of the std.Build, so that
    // `zig build` also generates the compile_commands.json.
    _ = zcc.createStep(b, .{
        .name = "cdb",
        .targets = targets.toOwnedSlice(b.allocator) catch @panic("OOM"),
    });
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
