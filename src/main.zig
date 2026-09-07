const std = @import("std");
const mustat = @import("mustat");

const Io = std.Io;
const kibibyte = 1024;
const input_buffer_bytes = 64 * kibibyte;
const output_buffer_bytes = 16 * kibibyte;
const number_buffer_bytes = 64;
const number_width = 13;
const version = "0.1.0";
const confidence_default = 95.0;
const human_significant_digits = 8;
const human_scientific_min = 1e-4;
const human_scientific_max = 1e9;

const NumberFormat = enum {
    scientific,
    human,
};

const Summary = enum {
    standard,
    extended,
};

const Percentiles = enum {
    omitted,
    included,
};

const TestOutput = enum {
    enabled,
    disabled,
};

const Options = struct {
    column: usize = 1,
    confidence: f64 = confidence_default,
    delimiters: []const u8 = " \t",
    number_format: NumberFormat = .scientific,
    percentiles: Percentiles = .omitted,
    quiet: bool = false,
    summary: Summary = .standard,
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
                try printTest(
                    stdout,
                    name,
                    &stats,
                    baseline_name,
                    &reference,
                    options.confidence,
                    options.number_format,
                );
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
        if (std.mem.eql(u8, argument, "--help")) {
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
        if (std.mem.eql(u8, argument, "-h") or std.mem.eql(u8, argument, "--human")) {
            options.number_format = .human;
            continue;
        }
        if (std.mem.eql(u8, argument, "-p") or std.mem.eql(u8, argument, "--percentiles")) {
            options.percentiles = .included;
            continue;
        }
        if (std.mem.eql(u8, argument, "-x") or std.mem.eql(u8, argument, "--extended")) {
            options.summary = .extended;
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
        try printHeader(writer, options);
    }

    try printStats(writer, &stats, options);

    return stats;
}

fn printHeader(writer: *Io.Writer, options: *const Options) Io.Writer.Error!void {
    if (options.summary == .standard) {
        try writer.writeAll("       N           Min           Max        Median           Avg");
        try writer.writeAll("        Stddev");
    } else {
        try writer.writeAll("       N           Min            Q1        Median            Q3");
        try writer.writeAll("           Max           IQR          Mean        Stddev");
        try writer.writeAll("        StdErr          CV%");
    }
    if (options.percentiles == .included) {
        try writer.writeAll("           P90           P95           P99");
    }
    try writer.writeByte('\n');
}

fn printStats(
    writer: *Io.Writer,
    stats: *const mustat.Stats,
    options: *const Options,
) Io.Writer.Error!void {
    try writer.print("{d:>8}", .{stats.count});
    if (options.summary == .standard) {
        try printNumber(writer, stats.min, options.number_format);
        try printNumber(writer, stats.max, options.number_format);
        try printNumber(writer, stats.median, options.number_format);
        try printNumber(writer, stats.mean, options.number_format);
        try printOptional(writer, stats.stddev, options.number_format);
    } else {
        try printNumber(writer, stats.min, options.number_format);
        try printNumber(writer, stats.q1, options.number_format);
        try printNumber(writer, stats.median, options.number_format);
        try printNumber(writer, stats.q3, options.number_format);
        try printNumber(writer, stats.max, options.number_format);
        try printNumber(writer, stats.iqr, options.number_format);
        try printNumber(writer, stats.mean, options.number_format);
        try printOptional(writer, stats.stddev, options.number_format);
        try printOptional(writer, stats.stderr, options.number_format);
        try printOptional(writer, stats.cv_percent, options.number_format);
    }
    if (options.percentiles == .included) {
        try printNumber(writer, stats.p90, options.number_format);
        try printNumber(writer, stats.p95, options.number_format);
        try printNumber(writer, stats.p99, options.number_format);
    }
    try writer.writeByte('\n');
}

fn printTest(
    writer: *Io.Writer,
    name: []const u8,
    stats: *const mustat.Stats,
    baseline_name: []const u8,
    baseline: *const mustat.Stats,
    confidence: f64,
    number_format: NumberFormat,
) Io.Writer.Error!void {
    const result = mustat.welch(stats, baseline) orelse {
        try writer.print("Welch t-test {s} vs {s}: unavailable\n", .{ name, baseline_name });
        return;
    };
    const alpha = 1.0 - confidence / 100.0;
    const conclusion = if (result.p_value < alpha) "difference" else "no difference";

    try writer.print("Welch t-test {s} vs {s}:\n", .{ name, baseline_name });
    try writer.writeAll("  delta=");
    try printCompact(writer, result.difference, number_format);
    if (result.relative_percent) |relative| {
        try writer.writeAll(" (");
        try printCompact(writer, relative, number_format);
        try writer.writeAll("%)");
    }
    try writer.writeAll(", t=");
    try printCompact(writer, result.statistic, number_format);
    try writer.writeAll(", df=");
    try printCompact(writer, result.freedom, number_format);
    try writer.writeAll(", p=");
    try printCompact(writer, result.p_value, number_format);
    try writer.writeByte('\n');
    try writer.print("  {s} at {d:.1}% confidence\n", .{ conclusion, confidence });
}

fn printNumber(writer: *Io.Writer, value: f64, number_format: NumberFormat) Io.Writer.Error!void {
    if (number_format == .scientific) {
        try writer.print(" {e:>13.6}", .{value});
        return;
    }

    var buffer: [number_buffer_bytes]u8 = undefined;
    const number = humanNumber(&buffer, value);
    try writer.print(" {s:>[1]}", .{ number, number_width });
}

fn printCompact(writer: *Io.Writer, value: f64, number_format: NumberFormat) Io.Writer.Error!void {
    if (number_format == .scientific) {
        try writer.print("{e:.6}", .{value});
        return;
    }

    var buffer: [number_buffer_bytes]u8 = undefined;
    try writer.writeAll(humanNumber(&buffer, value));
}

fn humanNumber(buffer: []u8, value: f64) []const u8 {
    if (value == 0.0 or std.math.isFinite(value) == false) {
        return std.fmt.bufPrint(buffer, "{}", .{value}) catch unreachable;
    }

    const magnitude = @abs(value);
    if (magnitude < human_scientific_min or magnitude >= human_scientific_max) {
        const precision = human_significant_digits - 1;
        const number = std.fmt.bufPrint(
            buffer,
            "{e:.[1]}",
            .{ value, precision },
        ) catch unreachable;
        return trimZeros(number);
    }

    const exponent: i32 = @intFromFloat(@floor(@log10(magnitude)));
    const decimals_signed = @as(i32, human_significant_digits - 1) - exponent;
    const decimals: usize = if (decimals_signed > 0) @intCast(decimals_signed) else 0;
    const number = std.fmt.bufPrint(buffer, "{d:.[1]}", .{ value, decimals }) catch unreachable;

    return trimZeros(number);
}

fn trimZeros(number: []u8) []u8 {
    const exponent_start = std.mem.indexOfScalar(u8, number, 'e') orelse number.len;
    const decimal = std.mem.indexOfScalar(u8, number[0..exponent_start], '.') orelse return number;

    var mantissa_end = exponent_start;
    while (mantissa_end > decimal + 1 and number[mantissa_end - 1] == '0') {
        mantissa_end -= 1;
    }
    if (mantissa_end == decimal + 1) {
        mantissa_end = decimal;
    }
    if (exponent_start == number.len) {
        return number[0..mantissa_end];
    }

    const exponent = number[exponent_start..];
    @memmove(number[mantissa_end..][0..exponent.len], exponent);
    return number[0 .. mantissa_end + exponent.len];
}

fn printOptional(
    writer: *Io.Writer,
    value: ?f64,
    number_format: NumberFormat,
) Io.Writer.Error!void {
    if (value) |number| {
        try printNumber(writer, number, number_format);
        return;
    }

    try writer.print(" {s:>[1]}", .{ "n/a", number_width });
}

fn usage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.writeAll(
        \\Usage: mustat [-Ahnpqx] [-C column] [-c confidence] [-d delimiters] [file ...]
        \\
        \\  -C, --column N       Read one-based column N (default: 1)
        \\  -c, --confidence N   Set comparison confidence (default: 95)
        \\  -d, --delimiters S   Split on any byte in S (default: space and tab)
        \\  -h, --human          Use adaptive number formatting
        \\  -p, --percentiles    Include P90, P95, and P99
        \\  -q, --quiet          Omit headers and dataset names
        \\  -x, --extended       Include extended summary statistics
        \\  -A                   Accepted ministat compatibility flag
        \\  -n                   Suppress comparisons
        \\      --help           Show help
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

test "parse output flags" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const options = (try parseArgs(
        std.testing.allocator,
        &.{ "-h", "-p", "-x", "data" },
        &output.writer,
    )).?;
    defer std.testing.allocator.free(options.files);

    try std.testing.expectEqual(NumberFormat.human, options.number_format);
    try std.testing.expectEqual(Percentiles.included, options.percentiles);
    try std.testing.expectEqual(Summary.extended, options.summary);
}

test "select summary headers" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    var options: Options = .{};
    try printHeader(&output.writer, &options);
    try std.testing.expectEqualStrings(
        "       N           Min           Max        Median           Avg        Stddev\n",
        output.written(),
    );

    output.clearRetainingCapacity();
    options.summary = .extended;
    options.percentiles = .included;
    try printHeader(&output.writer, &options);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Q1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "P99") != null);
}

test "human numbers adapt to magnitude" {
    var buffer: [number_buffer_bytes]u8 = undefined;

    try std.testing.expectEqualStrings("50", humanNumber(&buffer, 50.0));
    try std.testing.expectEqualStrings("238.04761", humanNumber(&buffer, 238.047614));
    try std.testing.expectEqualStrings("1e-9", humanNumber(&buffer, 1e-9));
    try std.testing.expectEqualStrings("1e9", humanNumber(&buffer, 1e9));
}

test "print Welch comparison" {
    var baseline_values = [_]f64{ 1, 2, 3, 4, 5 };
    var candidate_values = [_]f64{ 2, 3, 4, 5, 6 };
    const baseline = mustat.calculate(&baseline_values);
    const candidate = mustat.calculate(&candidate_values);

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try printTest(&output.writer, "new", &candidate, "old", &baseline, 95.0, .scientific);
    const heading = std.mem.indexOf(u8, output.written(), "Welch t-test new vs old");
    try std.testing.expect(heading != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "p=") != null);
}
