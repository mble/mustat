const std = @import("std");

const manifest_bytes_max = 64 * 1024;

const Manifest = struct {
    version: []const u8,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug information") orelse false;
    const static_link = b.option(bool, "static", "Link the executable statically") orelse false;
    const linkage: ?std.builtin.LinkMode = if (static_link) .static else null;

    // Keep the statistics module internal; mustat's supported interface is its CLI.
    const module = b.createModule(.{
        .root_source_file = b.path("src/mustat.zig"),
        .target = target,
        .optimize = optimize,
    });
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", manifest_version(b));

    const executable = b.addExecutable(.{
        .name = "mustat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{
                .{ .name = "build_options", .module = build_options.createModule() },
                .{ .name = "mustat", .module = module },
            },
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

fn manifest_version(b: *std.Build) []const u8 {
    const source = b.build_root.handle.readFileAllocOptions(
        b.graph.io,
        "build.zig.zon",
        b.allocator,
        .limited(manifest_bytes_max),
        .of(u8),
        0,
    ) catch @panic("cannot read build.zig.zon");
    const manifest = std.zon.parse.fromSliceAlloc(
        Manifest,
        b.allocator,
        source,
        null,
        .{ .ignore_unknown_fields = true },
    ) catch @panic("cannot parse build.zig.zon");
    _ = std.SemanticVersion.parse(manifest.version) catch {
        @panic("build.zig.zon version is not semantic");
    };

    return manifest.version;
}
