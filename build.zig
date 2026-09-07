const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug information") orelse false;
    const static_link = b.option(bool, "static", "Link the executable statically") orelse false;
    const linkage: ?std.builtin.LinkMode = if (static_link) .static else null;

    const module = b.addModule("mustat", .{
        .root_source_file = b.path("src/mustat.zig"),
        .target = target,
        .optimize = optimize,
    });

    const executable = b.addExecutable(.{
        .name = "mustat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{.{ .name = "mustat", .module = module }},
        }),
        .linkage = linkage,
    });
    b.installArtifact(executable);

    const run_command = b.addRunArtifact(executable);
    run_command.step.dependOn(b.getInstallStep());
    if (b.args) |arguments| {
        run_command.addArgs(arguments);
    }

    const run_step = b.step("run", "Run mustat");
    run_step.dependOn(&run_command.step);

    const benchmark = b.addExecutable(.{
        .name = "mustat-benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "mustat", .module = module }},
        }),
    });
    const benchmark_command = b.addRunArtifact(benchmark);
    const benchmark_step = b.step("benchmark", "Benchmark statistics");
    benchmark_step.dependOn(&benchmark_command.step);

    const tests = b.addTest(.{ .root_module = module });
    const test_command = b.addRunArtifact(tests);

    const executable_tests = b.addTest(.{ .root_module = executable.root_module });
    const executable_test_command = b.addRunArtifact(executable_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&test_command.step);
    test_step.dependOn(&executable_test_command.step);
}
