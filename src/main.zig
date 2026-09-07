const std = @import("std");
const mustat = @import("mustat");

const Io = std.Io;
const kibibyte = 1024;
const gibibyte = kibibyte * kibibyte * kibibyte;
const input_bytes_max: usize = if (@sizeOf(usize) == 4)
    std.math.maxInt(usize)
else
    4 * gibibyte;
const output_buffer_bytes = 16 * kibibyte;
const version = "0.1.0";

const Options = struct {
    column: usize = 1,
    delimiters: []const u8 = " \t",
    quiet: bool = false,
    files: []const []const u8 = &.{},
};

const CliError = error{
    InvalidColumn,
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

    if (options.files.len == 0) {
        const input = try readStdin(init.gpa, init.io);
        defer init.gpa.free(input);

        try report(init.gpa, stdout, "<stdin>", input, options);
        return;
    }

    for (options.files) |path| {
        const input = if (std.mem.eql(u8, path, "-"))
            try readStdin(init.gpa, init.io)
        else
            try Io.Dir.cwd().readFileAlloc(
                init.io,
                path,
                init.gpa,
                .limited(input_bytes_max),
            );
        defer init.gpa.free(input);

        const name = if (std.mem.eql(u8, path, "-")) "<stdin>" else path;

        try report(init.gpa, stdout, name, input, options);
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
        if (std.mem.eql(u8, argument, "-A") or std.mem.eql(u8, argument, "-n")) {
            continue;
        }
        if (std.mem.eql(u8, argument, "-C") or std.mem.eql(u8, argument, "--column")) {
            index += 1;
            if (index == arguments.len) {
                return error.MissingOptionValue;
            }
            options.column = std.fmt.parseInt(usize, arguments[index], 10) catch {
                return error.InvalidColumn;
            };
            if (options.column == 0) {
                return error.InvalidColumn;
            }
            continue;
        }
        if (std.mem.eql(u8, argument, "-d") or std.mem.eql(u8, argument, "--delimiters")) {
            index += 1;
            if (index == arguments.len) {
                return error.MissingOptionValue;
            }
            options.delimiters = arguments[index];
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

fn readStdin(allocator: std.mem.Allocator, io: Io) ![]u8 {
    var read_buffer: [64 * kibibyte]u8 = undefined;
    var file_reader: Io.File.Reader = .initStreaming(.stdin(), io, &read_buffer);

    return file_reader.interface.allocRemaining(allocator, .limited(input_bytes_max));
}

fn report(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    name: []const u8,
    input: []const u8,
    options: Options,
) !void {
    const values = mustat.parse(allocator, input, .{
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
        \\Usage: mustat [-Ahnq] [-C column] [-d delimiters] [file ...]
        \\
        \\  -C, --column N       Read one-based column N (default: 1)
        \\  -d, --delimiters S   Split on any byte in S (default: space and tab)
        \\  -q, --quiet          Omit headers and dataset names
        \\  -A, -n               Accepted ministat compatibility flags
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

    try report(
        std.testing.allocator,
        &output.writer,
        "test",
        "0.000000001\n",
        .{ .quiet = true },
    );

    try std.testing.expect(std.mem.indexOf(u8, output.written(), "1.000000e-9") != null);
}
