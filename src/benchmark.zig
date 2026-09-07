const std = @import("std");
const mustat = @import("mustat");

const Io = std.Io;
const value_count = 1_000_000;
const repetition_count = 20;
const random_seed = 0x9f41_24a8_7d31_02cb;
const output_buffer_bytes = 1024;
const u32_decimal_digits_max = 10;

pub fn main(init: std.process.Init) !void {
    const source = try init.gpa.alloc(f64, value_count);
    defer init.gpa.free(source);

    const working = try init.gpa.alloc(f64, value_count);
    defer init.gpa.free(working);

    fillRandom(source);

    const ordered = try init.gpa.dupe(f64, source);
    defer init.gpa.free(ordered);
    std.mem.sortUnstable(f64, ordered, {}, std.sort.asc(f64));

    var input = try makeInput(init.gpa, source);
    defer input.deinit();

    @memcpy(working, source);
    _ = mustat.calculate(working);

    const random_result = benchmarkCalculate(init.io, source, working);
    const ordered_result = benchmarkCalculate(init.io, ordered, working);
    const parse_result = try benchmarkParse(init.gpa, init.io, input.written());
    const copy_result = benchmarkCopy(init.io, source, working);

    var output_buffer: [output_buffer_bytes]u8 = undefined;
    var output_file: Io.File.Writer = .init(.stdout(), init.io, &output_buffer);
    const writer = &output_file.interface;
    defer writer.flush() catch {};

    try writer.print("values: {d}\n", .{value_count});
    try writer.print("random:  {d:.3} ms\n", .{random_result.elapsed_ms});
    try writer.print("ordered: {d:.3} ms\n", .{ordered_result.elapsed_ms});
    try writer.print("parse:   {d:.3} ms\n", .{parse_result.elapsed_ms});
    try writer.print("copy:    {d:.3} ms\n", .{copy_result.elapsed_ms});
    try writer.print("checksum: {d}\n", .{
        random_result.checksum + ordered_result.checksum +
            parse_result.checksum + copy_result.checksum,
    });
}

const BenchmarkResult = struct {
    elapsed_ms: f64,
    checksum: f64,
};

fn fillRandom(values: []f64) void {
    var state = std.Random.DefaultPrng.init(random_seed);
    const random = state.random();
    for (values) |*value| {
        value.* = @floatFromInt(random.int(u32));
    }
}

fn makeInput(allocator: std.mem.Allocator, values: []const f64) !Io.Writer.Allocating {
    const bytes_per_value = u32_decimal_digits_max + 1;
    var input: Io.Writer.Allocating = try .initCapacity(
        allocator,
        values.len * bytes_per_value,
    );
    errdefer input.deinit();

    for (values) |value| {
        try input.writer.print("{d}\n", .{@as(u32, @intFromFloat(value))});
    }

    return input;
}

fn benchmarkCalculate(io: Io, source: []const f64, working: []f64) BenchmarkResult {
    var elapsed_ns: i96 = 0;
    var checksum: f64 = 0.0;
    for (0..repetition_count) |_| {
        @memcpy(working, source);
        const start = Io.Timestamp.now(io, .awake);
        const stats = mustat.calculate(working);
        elapsed_ns += start.untilNow(io, .awake).nanoseconds;
        checksum += stats.median;
    }

    return .{
        .elapsed_ms = averageMilliseconds(elapsed_ns),
        .checksum = checksum,
    };
}

fn benchmarkCopy(io: Io, source: []const f64, working: []f64) BenchmarkResult {
    var elapsed_ns: i96 = 0;
    var checksum: f64 = 0.0;
    for (0..repetition_count) |_| {
        const start = Io.Timestamp.now(io, .awake);
        @memcpy(working, source);
        elapsed_ns += start.untilNow(io, .awake).nanoseconds;
        checksum += working[repetition_count];
    }

    return .{
        .elapsed_ms = averageMilliseconds(elapsed_ns),
        .checksum = checksum,
    };
}

fn benchmarkParse(
    allocator: std.mem.Allocator,
    io: Io,
    input: []const u8,
) !BenchmarkResult {
    var elapsed_ns: i96 = 0;
    var checksum: f64 = 0.0;
    for (0..repetition_count) |_| {
        const start = Io.Timestamp.now(io, .awake);
        const values = try mustat.parse(allocator, input, .{});
        elapsed_ns += start.untilNow(io, .awake).nanoseconds;
        checksum += values[repetition_count];
        allocator.free(values);
    }

    return .{
        .elapsed_ms = averageMilliseconds(elapsed_ns),
        .checksum = checksum,
    };
}

fn averageMilliseconds(elapsed_ns: i96) f64 {
    const nanoseconds_per_millisecond = std.time.ns_per_ms;
    const elapsed: f64 = @floatFromInt(elapsed_ns);
    const repetitions: f64 = @floatFromInt(repetition_count);

    return elapsed / repetitions / nanoseconds_per_millisecond;
}
