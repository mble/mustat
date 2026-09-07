const std = @import("std");
const mustat = @import("mustat");

const Io = std.Io;
const kibibyte = 1024;
const input_buffer_bytes = 64 * kibibyte;
const output_buffer_bytes = 16 * kibibyte;
const version = "0.1.0";
const confidence_default = 95.0;

const TestOutput = enum {
    enabled,
    disabled,
};

const Options = struct {
    column: usize = 1,
    confidence: f64 = confidence_default,
    delimiters: []const u8 = " \t",
    quiet: bool = false,
    test_output: TestOutput = .enabled,
    files: []const []const u8 = &.{},
};

const CliError = error{
    InvalidColumn,
    InvalidConfidence,
    MissingOptionValue,
    OutOfMemory,
    UnknownOption,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [output_buffer_bytes]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file.interface;
    defer stdout.flush() catch {};

    const options = parseArgs(arena, arguments[1..], stdout) catch |err| {
        try usage(stdout);
        return err;
    } orelse return;

    const paths: []const []const u8 = if (options.files.len == 0) &.{"-"} else options.files;
    var baseline: ?mustat.Stats = null;
    var baseline_name: []const u8 = undefined;
    for (paths) |path| {
        const is_stdin = std.mem.eql(u8, path, "-");
        const file = if (is_stdin)
            Io.File.stdin()
        else
            try Io.Dir.cwd().openFile(init.io, path, .{});
        defer {
            if (is_stdin == false) {
                file.close(init.io);
            }
        }

        var input_buffer: [input_buffer_bytes]u8 = undefined;
        var input_file: Io.File.Reader = .initStreaming(file, init.io, &input_buffer);

        const name = if (is_stdin) "<stdin>" else path;

        const stats = try report(init.gpa, stdout, name, &input_file.interface, &options);
        if (baseline) |reference| {
            if (options.test_output == .enabled) {
                try printTest(stdout, name, &stats, baseline_name, &reference, options.confidence);
            }
            continue;
        }

        baseline = stats;
        baseline_name = name;
    }
}

fn parseArgs(
    allocator: std.mem.Allocator,
    arguments: []const []const u8,
    stdout: *Io.Writer,
) (CliError || Io.Writer.Error)!?Options {
    var options: Options = .{};
    var files: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;

    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, "--")) {
            try files.appendSlice(allocator, arguments[index + 1 ..]);
            break;
        }
        if (std.mem.eql(u8, argument, "-h") or std.mem.eql(u8, argument, "--help")) {
            try usage(stdout);
            return null;
        }
        if (std.mem.eql(u8, argument, "--version")) {
            try stdout.print("mustat {s}\n", .{version});
            return null;
        }
        if (std.mem.eql(u8, argument, "-q") or std.mem.eql(u8, argument, "--quiet")) {
            options.quiet = true;
            continue;
        }
        if (std.mem.eql(u8, argument, "-A")) {
            continue;
        }
        if (std.mem.eql(u8, argument, "-n")) {
            options.test_output = .disabled;
            continue;
        }
        if (std.mem.eql(u8, argument, "-C") or std.mem.eql(u8, argument, "--column")) {
            options.column = try parseColumn(try nextArgument(arguments, &index));
            continue;
        }
        if (std.mem.eql(u8, argument, "-d") or std.mem.eql(u8, argument, "--delimiters")) {
            options.delimiters = try nextArgument(arguments, &index);
            continue;
        }
        if (std.mem.eql(u8, argument, "-c") or std.mem.eql(u8, argument, "--confidence")) {
            options.confidence = try parseConfidence(try nextArgument(arguments, &index));
            continue;
        }
        if (argument.len > 1 and argument[0] == '-') {
            return error.UnknownOption;
        }

        try files.append(allocator, argument);
    }

    options.files = try files.toOwnedSlice(allocator);
    return options;
}

fn nextArgument(arguments: []const []const u8, index: *usize) CliError![]const u8 {
    index.* += 1;
    if (index.* == arguments.len) {
        return error.MissingOptionValue;
    }

    return arguments[index.*];
}

fn parseColumn(argument: []const u8) CliError!usize {
    const column = std.fmt.parseInt(usize, argument, 10) catch {
        return error.InvalidColumn;
    };
    if (column == 0) {
        return error.InvalidColumn;
    }

    return column;
}

fn parseConfidence(argument: []const u8) CliError!f64 {
    const confidence = std.fmt.parseFloat(f64, argument) catch {
        return error.InvalidConfidence;
    };
    if (std.math.isFinite(confidence) == false) {
        return error.InvalidConfidence;
    }
    if (confidence <= 0.0) {
        return error.InvalidConfidence;
    }
    if (confidence >= 100.0) {
        return error.InvalidConfidence;
    }

    return confidence;
}

fn report(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    name: []const u8,
    reader: *Io.Reader,
    options: *const Options,
) !mustat.Stats {
    const values = mustat.parseReader(allocator, reader, .{
        .column = options.column,
        .delimiters = options.delimiters,
    }) catch |err| {
        std.log.err("{s}: {s}", .{ name, @errorName(err) });
        return err;
    };
    defer allocator.free(values);

    const stats = mustat.calculate(values);

    if (options.quiet == false) {
        try writer.print("{s}\n", .{name});
        try writer.writeAll("       N           Min            Q1        Median            Q3");
        try writer.writeAll("           Max           IQR          Mean        Stddev");
        try writer.writeAll("        StdErr          CV%           P90           P95");
        try writer.writeAll("           P99\n");
    }

    try writer.print("{d:>8} {e:>13.6} {e:>13.6} {e:>13.6} {e:>13.6} {e:>13.6}", .{
        stats.count,
        stats.min,
        stats.q1,
        stats.median,
        stats.q3,
        stats.max,
    });
    try writer.print(" {e:>13.6} {e:>13.6}", .{ stats.iqr, stats.mean });
    try printOptional(writer, stats.stddev);
    try printOptional(writer, stats.stderr);
    try printOptional(writer, stats.cv_percent);
    try writer.print(" {e:>13.6} {e:>13.6} {e:>13.6}\n", .{
        stats.p90,
        stats.p95,
        stats.p99,
    });

    return stats;
}

fn printTest(
    writer: *Io.Writer,
    name: []const u8,
    stats: *const mustat.Stats,
    baseline_name: []const u8,
    baseline: *const mustat.Stats,
    confidence: f64,
) Io.Writer.Error!void {
    const result = mustat.welch(stats, baseline) orelse {
        try writer.print("Welch t-test {s} vs {s}: unavailable\n", .{ name, baseline_name });
        return;
    };
    const alpha = 1.0 - confidence / 100.0;
    const conclusion = if (result.p_value < alpha) "difference" else "no difference";

    try writer.print("Welch t-test {s} vs {s}:\n", .{ name, baseline_name });
    try writer.print("  delta={e:.6}", .{result.difference});
    if (result.relative_percent) |relative| {
        try writer.print(" ({e:.6}%)", .{relative});
    }
    try writer.print(", t={e:.6}, df={e:.6}, p={e:.6}\n", .{
        result.statistic,
        result.freedom,
        result.p_value,
    });
    try writer.print("  {s} at {d:.1}% confidence\n", .{ conclusion, confidence });
}

fn printOptional(writer: *Io.Writer, value: ?f64) Io.Writer.Error!void {
    if (value) |number| {
        try writer.print(" {e:>13.6}", .{number});
        return;
    }

    try writer.print(" {s:>13}", .{"n/a"});
}

fn usage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.writeAll(
        \\Usage: mustat [-Ahnq] [-C column] [-c confidence] [-d delimiters] [file ...]
        \\
        \\  -C, --column N       Read one-based column N (default: 1)
        \\  -c, --confidence N   Set comparison confidence (default: 95)
        \\  -d, --delimiters S   Split on any byte in S (default: space and tab)
        \\  -q, --quiet          Omit headers and dataset names
        \\  -A                   Accepted ministat compatibility flag
        \\  -n                   Suppress comparisons
        \\  -h, --help           Show help
        \\      --version        Show version
        \\
        \\Use '-' or no file to read standard input. Lines may contain '#' comments.
        \\
    );
}

test "small measurements remain visible" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const options: Options = .{ .quiet = true };
    var input: Io.Reader = .fixed("0.000000001\n");
    _ = try report(
        std.testing.allocator,
        &output.writer,
        "test",
        &input,
        &options,
    );

    try std.testing.expect(std.mem.indexOf(u8, output.written(), "1.000000e-9") != null);
}

test "reject invalid confidence" {
    try std.testing.expectError(error.InvalidConfidence, parseConfidence("nan"));
    try std.testing.expectError(error.InvalidConfidence, parseConfidence("0"));
    try std.testing.expectError(error.InvalidConfidence, parseConfidence("100"));
}

test "print Welch comparison" {
    var baseline_values = [_]f64{ 1, 2, 3, 4, 5 };
    var candidate_values = [_]f64{ 2, 3, 4, 5, 6 };
    const baseline = mustat.calculate(&baseline_values);
    const candidate = mustat.calculate(&candidate_values);

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try printTest(&output.writer, "new", &candidate, "old", &baseline, 95.0);
    const heading = std.mem.indexOf(u8, output.written(), "Welch t-test new vs old");
    try std.testing.expect(heading != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "p=") != null);
}
