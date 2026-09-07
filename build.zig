const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
            .imports = &.{.{ .name = "mustat", .module = module }},
        }),
    });
    b.installArtifact(executable);

    const run_command = b.addRunArtifact(executable);
    run_command.step.dependOn(b.getInstallStep());
    if (b.args) |arguments| {
        run_command.addArgs(arguments);
    }

    const run_step = b.step("run", "Run mustat");
    run_step.dependOn(&run_command.step);

    const tests = b.addTest(.{ .root_module = module });
    const test_command = b.addRunArtifact(tests);

    const executable_tests = b.addTest(.{ .root_module = executable.root_module });
    const executable_test_command = b.addRunArtifact(executable_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&test_command.step);
    test_step.dependOn(&executable_test_command.step);
}
