const std = @import("std");
const build_options = @import("build_options");
const mustat = @import("mustat");

const Io = std.Io;
const kibibyte = 1024;
const input_buffer_bytes = 64 * kibibyte;
const output_buffer_bytes = 16 * kibibyte;
const number_buffer_bytes = 64;
const number_width = 13;
const version = build_options.version;
const confidence_default = 95.0;
const percent_scale = 100.0;
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

const ParseResult = enum {
    run,
    exit,
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
    var stdout_buffer: [output_buffer_bytes]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file.interface;

    return finish_output(stdout, run(init, stdout));
}

fn finish_output(writer: *Io.Writer, result: anyerror!void) anyerror!void {
    try writer.flush();

    return result;
}

fn run(init: std.process.Init, stdout: *Io.Writer) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);

    var options: Options = .{};
    const parse_result = parse_args(arena, arguments[1..], stdout, &options) catch |err| {
        try usage(stdout);
        return err;
    };
    if (parse_result == .exit) {
        return;
    }

    const paths: []const []const u8 = if (options.files.len == 0) &.{"-"} else options.files;
    var baseline: mustat.Stats = undefined;
    var baseline_name: []const u8 = undefined;
    var baseline_set = false;
    for (paths) |path| {
        const is_stdin = std.mem.eql(u8, path, "-");
        const file = if (is_stdin)
            Io.File.stdin()
        else
            try Io.Dir.cwd().openFile(init.io, path, .{ .mode = .read_only });
        defer {
            if (is_stdin == false) {
                file.close(init.io);
            }
        }

        var input_buffer: [input_buffer_bytes]u8 = undefined;
        var input_file: Io.File.Reader = .initStreaming(file, init.io, &input_buffer);

        const name = if (is_stdin) "<stdin>" else path;

        var stats: mustat.Stats = undefined;
        try report(init.gpa, stdout, name, &input_file.interface, &options, &stats);
        if (baseline_set) {
            if (options.test_output == .enabled) {
                try print_test(
                    stdout,
                    name,
                    &stats,
                    baseline_name,
                    &baseline,
                    options.confidence,
                    options.number_format,
                );
            }
            continue;
        }

        baseline = stats;
        baseline_name = name;
        baseline_set = true;
    }
}

fn parse_args(
    allocator: std.mem.Allocator,
    arguments: []const []const u8,
    stdout: *Io.Writer,
    options: *Options,
) (CliError || Io.Writer.Error)!ParseResult {
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(allocator);

    var index: usize = 0;

    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, "--")) {
            try files.appendSlice(allocator, arguments[index + 1 ..]);
            break;
        }
        if (std.mem.eql(u8, argument, "--help")) {
            try usage(stdout);
            return .exit;
        }
        if (std.mem.eql(u8, argument, "--version")) {
            try stdout.print("mustat {s}\n", .{version});
            return .exit;
        }
        if (argument.len > 1 and argument[0] == '-' and argument[1] != '-') {
            try parse_short(arguments, &index, argument[1..], options);
            continue;
        }
        if (std.mem.eql(u8, argument, "--quiet")) {
            options.quiet = true;
            continue;
        }
        if (std.mem.eql(u8, argument, "--human")) {
            options.number_format = .human;
            continue;
        }
        if (std.mem.eql(u8, argument, "--percentiles")) {
            options.percentiles = .included;
            continue;
        }
        if (std.mem.eql(u8, argument, "--extended")) {
            options.summary = .extended;
            continue;
        }
        if (std.mem.eql(u8, argument, "--column")) {
            options.column = try parse_column(try next_argument(arguments, &index));
            continue;
        }
        if (std.mem.eql(u8, argument, "--delimiters")) {
            options.delimiters = try next_argument(arguments, &index);
            continue;
        }
        if (std.mem.eql(u8, argument, "--confidence")) {
            options.confidence = try parse_confidence(try next_argument(arguments, &index));
            continue;
        }
        if (argument.len > 1) {
            if (argument[0] == '-') {
                return error.UnknownOption;
            }
        }

        try files.append(allocator, argument);
    }

    options.files = try files.toOwnedSlice(allocator);
    return .run;
}

fn parse_short(
    arguments: []const []const u8,
    argument_index: *usize,
    options_text: []const u8,
    options: *Options,
) CliError!void {
    for (options_text, 0..) |option, option_index| {
        switch (option) {
            'A' => {},
            'h' => options.number_format = .human,
            'n' => options.test_output = .disabled,
            'p' => options.percentiles = .included,
            'q' => options.quiet = true,
            'x' => options.summary = .extended,
            'C' => {
                const value = try short_value(arguments, argument_index, options_text, option_index);
                options.column = try parse_column(value);
                return;
            },
            'c' => {
                const value = try short_value(arguments, argument_index, options_text, option_index);
                options.confidence = try parse_confidence(value);
                return;
            },
            'd' => {
                options.delimiters = try short_value(
                    arguments,
                    argument_index,
                    options_text,
                    option_index,
                );
                return;
            },
            else => return error.UnknownOption,
        }
    }
}

fn short_value(
    arguments: []const []const u8,
    argument_index: *usize,
    options_text: []const u8,
    option_index: usize,
) CliError![]const u8 {
    const value_start = option_index + 1;
    if (value_start < options_text.len) {
        return options_text[value_start..];
    }

    return next_argument(arguments, argument_index);
}

fn next_argument(arguments: []const []const u8, index: *usize) CliError![]const u8 {
    index.* += 1;
    if (index.* == arguments.len) {
        return error.MissingOptionValue;
    }

    return arguments[index.*];
}

fn parse_column(argument: []const u8) CliError!usize {
    const column = std.fmt.parseInt(usize, argument, 10) catch {
        return error.InvalidColumn;
    };
    if (column == 0) {
        return error.InvalidColumn;
    }

    return column;
}

fn parse_confidence(argument: []const u8) CliError!f64 {
    const confidence = std.fmt.parseFloat(f64, argument) catch {
        return error.InvalidConfidence;
    };
    if (std.math.isFinite(confidence) == false) {
        return error.InvalidConfidence;
    }
    if (confidence <= 0.0) {
        return error.InvalidConfidence;
    }
    if (confidence >= percent_scale) {
        return error.InvalidConfidence;
    }

    return confidence;
}

inline fn report(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    name: []const u8,
    reader: *Io.Reader,
    options: *const Options,
    stats: *mustat.Stats,
) !void {
    const parse_options: mustat.ParseOptions = .{
        .column = options.column,
        .delimiters = options.delimiters,
    };
    const values = mustat.parse_reader(allocator, reader, &parse_options) catch |err| {
        std.log.err("{s}: {s}", .{ name, @errorName(err) });
        return err;
    };
    defer allocator.free(values);

    mustat.calculate(values, stats);

    if (options.quiet == false) {
        try writer.print("{s}\n", .{name});
        try print_header(writer, options);
    }

    try print_stats(writer, stats, options);
}

fn print_header(writer: *Io.Writer, options: *const Options) Io.Writer.Error!void {
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

fn print_stats(
    writer: *Io.Writer,
    stats: *const mustat.Stats,
    options: *const Options,
) Io.Writer.Error!void {
    try writer.print("{d:>8}", .{stats.count});
    if (options.summary == .standard) {
        try print_number(writer, stats.min, options.number_format);
        try print_number(writer, stats.max, options.number_format);
        try print_number(writer, stats.median, options.number_format);
        try print_number(writer, stats.mean, options.number_format);
        try print_optional(writer, stats.stddev, options.number_format);
    } else {
        try print_number(writer, stats.min, options.number_format);
        try print_number(writer, stats.q1, options.number_format);
        try print_number(writer, stats.median, options.number_format);
        try print_number(writer, stats.q3, options.number_format);
        try print_number(writer, stats.max, options.number_format);
        try print_number(writer, stats.iqr, options.number_format);
        try print_number(writer, stats.mean, options.number_format);
        try print_optional(writer, stats.stddev, options.number_format);
        try print_optional(writer, stats.stderr, options.number_format);
        try print_optional(writer, stats.cv_percent, options.number_format);
    }
    if (options.percentiles == .included) {
        try print_number(writer, stats.p90, options.number_format);
        try print_number(writer, stats.p95, options.number_format);
        try print_number(writer, stats.p99, options.number_format);
    }
    try writer.writeByte('\n');
}

fn print_test(
    writer: *Io.Writer,
    name: []const u8,
    stats: *const mustat.Stats,
    baseline_name: []const u8,
    baseline: *const mustat.Stats,
    confidence: f64,
    number_format: NumberFormat,
) Io.Writer.Error!void {
    var result: mustat.TTest = undefined;
    if (mustat.welch(stats, baseline, &result) == false) {
        try writer.print("Welch t-test {s} vs {s}: unavailable\n", .{ name, baseline_name });
        return;
    }
    const alpha = 1.0 - confidence / percent_scale;
    const conclusion = if (result.p_value < alpha) "difference" else "no difference";

    try writer.print("Welch t-test {s} vs {s}:\n", .{ name, baseline_name });
    try writer.writeAll("  delta=");
    try print_compact(writer, result.difference, number_format);
    if (result.relative_percent) |relative| {
        try writer.writeAll(" (");
        try print_compact(writer, relative, number_format);
        try writer.writeAll("%)");
    }
    try writer.writeAll(", t=");
    try print_compact(writer, result.statistic, number_format);
    try writer.writeAll(", df=");
    try print_compact(writer, result.freedom, number_format);
    try writer.writeAll(", p=");
    try print_compact(writer, result.p_value, number_format);
    try writer.writeByte('\n');
    try writer.print("  {s} at {d:.1}% confidence\n", .{ conclusion, confidence });
}

fn print_number(writer: *Io.Writer, value: f64, number_format: NumberFormat) Io.Writer.Error!void {
    if (number_format == .scientific) {
        try writer.print(" {e:>13.6}", .{value});
        return;
    }

    var buffer: [number_buffer_bytes]u8 = undefined;
    const number = human_number(&buffer, value);
    try writer.print(" {s:>[1]}", .{ number, number_width });
}

fn print_compact(writer: *Io.Writer, value: f64, number_format: NumberFormat) Io.Writer.Error!void {
    if (number_format == .scientific) {
        try writer.print("{e:.6}", .{value});
        return;
    }

    var buffer: [number_buffer_bytes]u8 = undefined;
    try writer.writeAll(human_number(&buffer, value));
}

fn human_number(buffer: []u8, value: f64) []const u8 {
    if (value == 0.0) {
        return std.fmt.bufPrint(buffer, "{}", .{value}) catch unreachable;
    }
    if (std.math.isFinite(value) == false) {
        return std.fmt.bufPrint(buffer, "{}", .{value}) catch unreachable;
    }

    const magnitude = @abs(value);
    if (magnitude < human_scientific_min) {
        return scientific_number(buffer, value);
    }
    if (magnitude >= human_scientific_max) {
        return scientific_number(buffer, value);
    }

    const exponent: i32 = @intFromFloat(@floor(@log10(magnitude)));
    const decimals_signed = @as(i32, human_significant_digits - 1) - exponent;
    const decimals: usize = if (decimals_signed > 0) @intCast(decimals_signed) else 0;
    const number = std.fmt.bufPrint(buffer, "{d:.[1]}", .{ value, decimals }) catch unreachable;

    return trim_zeros(number);
}

fn scientific_number(buffer: []u8, value: f64) []const u8 {
    const precision = human_significant_digits - 1;
    const number = std.fmt.bufPrint(
        buffer,
        "{e:.[1]}",
        .{ value, precision },
    ) catch unreachable;

    return trim_zeros(number);
}

fn trim_zeros(number: []u8) []u8 {
    const exponent_start = std.mem.indexOfScalar(u8, number, 'e') orelse number.len;
    const decimal = std.mem.indexOfScalar(u8, number[0..exponent_start], '.') orelse return number;

    var mantissa_end = exponent_start;
    while (mantissa_end > decimal + 1) {
        if (number[mantissa_end - 1] != '0') {
            break;
        }
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

fn print_optional(
    writer: *Io.Writer,
    value: ?f64,
    number_format: NumberFormat,
) Io.Writer.Error!void {
    if (value) |number| {
        try print_number(writer, number, number_format);
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
    var stats: mustat.Stats = undefined;
    try report(
        std.testing.allocator,
        &output.writer,
        "test",
        &input,
        &options,
        &stats,
    );

    try std.testing.expect(std.mem.indexOf(u8, output.written(), "1.000000e-9") != null);
}

test "reject invalid confidence" {
    try std.testing.expectError(error.InvalidConfidence, parse_confidence("nan"));
    try std.testing.expectError(error.InvalidConfidence, parse_confidence("0"));
    try std.testing.expectError(error.InvalidConfidence, parse_confidence("100"));
}

test "parse output flags" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    var options: Options = .{};
    const result = try parse_args(
        std.testing.allocator,
        &.{ "-Ahpqxn", "data" },
        &output.writer,
        &options,
    );
    defer std.testing.allocator.free(options.files);

    try std.testing.expectEqual(ParseResult.run, result);
    try std.testing.expectEqual(NumberFormat.human, options.number_format);
    try std.testing.expectEqual(Percentiles.included, options.percentiles);
    try std.testing.expectEqual(Summary.extended, options.summary);
    try std.testing.expectEqual(TestOutput.disabled, options.test_output);
}

test "parse attached option values" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    var options: Options = .{};
    const result = try parse_args(
        std.testing.allocator,
        &.{ "-C2", "-c99", "-d,", "data" },
        &output.writer,
        &options,
    );
    defer std.testing.allocator.free(options.files);

    try std.testing.expectEqual(ParseResult.run, result);
    try std.testing.expectEqual(@as(usize, 2), options.column);
    try std.testing.expectEqual(@as(f64, 99), options.confidence);
    try std.testing.expectEqualStrings(",", options.delimiters);
}

test "parse arguments releases storage" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    var options: Options = .{};
    try std.testing.expectError(
        error.UnknownOption,
        parse_args(
            std.testing.allocator,
            &.{ "data", "--unknown" },
            &output.writer,
            &options,
        ),
    );
}

test "flush errors propagate" {
    var buffer = [_]u8{'x'};
    var writer: Io.Writer = .{
        .vtable = &.{ .drain = Io.Writer.failingDrain },
        .buffer = &buffer,
        .end = buffer.len,
    };

    try std.testing.expectError(error.WriteFailed, finish_output(&writer, {}));
}

test "select summary headers" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    var options: Options = .{};
    try print_header(&output.writer, &options);
    try std.testing.expectEqualStrings(
        "       N           Min           Max        Median           Avg        Stddev\n",
        output.written(),
    );

    output.clearRetainingCapacity();
    options.summary = .extended;
    options.percentiles = .included;
    try print_header(&output.writer, &options);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Q1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "P99") != null);
}

test "human numbers adapt to magnitude" {
    var buffer: [number_buffer_bytes]u8 = undefined;

    try std.testing.expectEqualStrings("50", human_number(&buffer, 50.0));
    try std.testing.expectEqualStrings("238.04761", human_number(&buffer, 238.047614));
    try std.testing.expectEqualStrings("1e-9", human_number(&buffer, 1e-9));
    try std.testing.expectEqualStrings("1e9", human_number(&buffer, 1e9));
}

test "print Welch comparison" {
    var baseline_values = [_]f64{ 1, 2, 3, 4, 5 };
    var candidate_values = [_]f64{ 2, 3, 4, 5, 6 };
    var baseline: mustat.Stats = undefined;
    var candidate: mustat.Stats = undefined;
    mustat.calculate(&baseline_values, &baseline);
    mustat.calculate(&candidate_values, &candidate);

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try print_test(&output.writer, "new", &candidate, "old", &baseline, 95.0, .scientific);
    const heading = std.mem.indexOf(u8, output.written(), "Welch t-test new vs old");
    try std.testing.expect(heading != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "p=") != null);
}
