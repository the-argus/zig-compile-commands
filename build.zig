const std = @import("std");

const cc = @import("compile_commands.zig");
pub const createStep = cc.createStep;

/// This function is the same as createStep, except it also makes the building
/// of the compile_commands.json depend on the building of all the targets.
/// This guarantees that all paths exist before compile_commands.json tries to
/// resolve them (which should never be necessary, in theory, so you probably
/// don't need to use this. And if you do this manually after calling
/// createStep, you have much more flexibility). Also, the tests for
/// zig-compile-commands all want to test both compile_commands.json generation
/// *and* target compilation, so they all use this.
pub fn createStepAndDependOnTargets(b: *std.Build, options: cc.CompileCommandOptions) *std.Build.Step {
    const step = createStep(b, options);
    for (options.targets) |target| {
        step.dependOn(&target.step);
    }
    return step;
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_steps = &[_]*std.Build.Step{
        try @import("tests/integration/build.zig").transitiveBuild(b, "integration", target, optimize),
        try @import("tests/config_header/build.zig").transitiveBuild(b, "config_header", target, optimize),
        try @import("tests/musl_static/build.zig").transitiveBuild(b, "musl_static", target, optimize),
        try @import("tests/musl_static_cpp/build.zig").transitiveBuild(b, "musl_static_cpp", target, optimize),
        try @import("tests/sdl/build.zig").transitiveBuild(b, "sdl", target, optimize),
        try @import("tests/raylib/build.zig").transitiveBuild(b, "raylib", target, optimize),
    };

    const all_tests_step = b.step(
        "tests",
        "Compile all test libraries and executables and generate their compile_commands.json files",
    );

    for (test_steps) |step|
        all_tests_step.dependOn(step);
}
