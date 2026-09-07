const std = @import("std");

const byte_value_count = 1 << @bitSizeOf(u8);
const count_exact_max: u64 = 1 << 53;

pub const ParseOptions = struct {
    column: usize = 1,
    delimiters: []const u8 = " \t",
};

pub const ParseError = error{
    EmptyDelimiter,
    InvalidColumn,
    InvalidNumber,
    NoData,
    NonFiniteNumber,
    OutOfMemory,
    TooManyValues,
};

pub const Stats = struct {
    count: usize,
    min: f64,
    q1: f64,
    median: f64,
    q3: f64,
    max: f64,
    iqr: f64,
    mean: f64,
    range: f64,
    variance: ?f64,
    stddev: ?f64,
    stderr: ?f64,
    cv_percent: ?f64,
    p90: f64,
    p95: f64,
    p99: f64,
};

pub fn parse(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: ParseOptions,
) ParseError![]f64 {
    if (options.column == 0) {
        return error.InvalidColumn;
    }
    if (options.delimiters.len == 0) {
        return error.EmptyDelimiter;
    }

    var values: std.ArrayList(f64) = .empty;
    errdefer values.deinit(allocator);

    // A lookup table keeps the hot parsing loop independent of delimiter count.
    var delimiters = [_]bool{false} ** byte_value_count;
    for (options.delimiters) |delimiter| {
        delimiters[delimiter] = true;
    }

    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        const token = findColumn(line, options.column, &delimiters) orelse continue;
        const value = std.fmt.parseFloat(f64, token) catch {
            return error.InvalidNumber;
        };
        if (std.math.isFinite(value) == false) {
            return error.NonFiniteNumber;
        }
        if (@as(u64, @intCast(values.items.len)) == count_exact_max) {
            return error.TooManyValues;
        }

        try values.append(allocator, value);
    }
    if (values.items.len == 0) {
        return error.NoData;
    }

    return try values.toOwnedSlice(allocator);
}

pub fn calculate(values: []f64) Stats {
    std.debug.assert(values.len > 0);
    std.debug.assert(@as(u64, @intCast(values.len)) <= count_exact_max);

    // PDQ sort gives exact order statistics without auxiliary storage.
    std.mem.sortUnstable(f64, values, {}, std.sort.asc(f64));

    const mean = calculateMean(values);
    const variance = calculateVariance(values, mean);
    const stddev = if (variance) |value| @sqrt(value) else null;
    const stderr = if (stddev) |value| value / @sqrt(@as(f64, @floatFromInt(values.len))) else null;
    const cv_percent = if (stddev) |value| calculateCv(value, mean) else null;

    const q1 = quantile(values, 0.25);
    const q3 = quantile(values, 0.75);

    return .{
        .count = values.len,
        .min = values[0],
        .q1 = q1,
        .median = quantile(values, 0.50),
        .q3 = q3,
        .max = values[values.len - 1],
        .iqr = q3 - q1,
        .mean = mean,
        .range = values[values.len - 1] - values[0],
        .variance = variance,
        .stddev = stddev,
        .stderr = stderr,
        .cv_percent = cv_percent,
        .p90 = quantile(values, 0.90),
        .p95 = quantile(values, 0.95),
        .p99 = quantile(values, 0.99),
    };
}

fn findColumn(
    line: []const u8,
    column_wanted: usize,
    delimiters: *const [byte_value_count]bool,
) ?[]const u8 {
    var token_start: ?usize = null;
    var column: usize = 0;

    for (line, 0..) |byte, index| {
        if (byte == '#') {
            return finishToken(line, token_start, index, column, column_wanted);
        }
        if (delimiters[byte]) {
            const token = finishToken(line, token_start, index, column, column_wanted);
            if (token != null) {
                return token;
            }
            if (token_start != null) {
                column += 1;
                token_start = null;
            }
            continue;
        }
        if (token_start == null) {
            token_start = index;
        }
    }

    return finishToken(line, token_start, line.len, column, column_wanted);
}

fn finishToken(
    line: []const u8,
    token_start: ?usize,
    token_end: usize,
    column_zero: usize,
    column_wanted: usize,
) ?[]const u8 {
    const start = token_start orelse return null;
    if (column_zero + 1 != column_wanted) {
        return null;
    }

    return std.mem.trimEnd(u8, line[start..token_end], "\r");
}

fn calculateMean(values: []const f64) f64 {
    const reference = interpolate(values[0], values[values.len - 1], 0.5);
    const count: f64 = @floatFromInt(values.len);
    var sum: f64 = 0.0;
    var correction: f64 = 0.0;

    // Centered Neumaier summation retains small terms without overflowing.
    for (values) |value| {
        const term = (value - reference) / count;
        const next = sum + term;
        if (@abs(sum) >= @abs(term)) {
            correction += (sum - next) + term;
        } else {
            correction += (term - next) + sum;
        }
        sum = next;
    }

    return reference + sum + correction;
}

fn calculateVariance(values: []const f64, mean: f64) ?f64 {
    if (values.len < 2) {
        return null;
    }

    // Scaled sum-of-squares resists intermediate underflow and overflow.
    var scale: f64 = 0.0;
    var sum_scaled: f64 = 1.0;
    for (values) |value| {
        const deviation = @abs(value - mean);
        if (deviation == 0.0) {
            continue;
        }
        if (scale < deviation) {
            const ratio = scale / deviation;
            sum_scaled = 1.0 + sum_scaled * ratio * ratio;
            scale = deviation;
            continue;
        }

        const ratio = deviation / scale;
        sum_scaled += ratio * ratio;
    }

    const freedom: f64 = @floatFromInt(values.len - 1);
    return scale * scale * (sum_scaled / freedom);
}

fn calculateCv(stddev: f64, mean: f64) ?f64 {
    if (mean == 0.0) {
        return null;
    }

    return stddev / @abs(mean) * 100.0;
}

fn quantile(values: []const f64, probability: f64) f64 {
    std.debug.assert(values.len > 0);
    std.debug.assert(probability >= 0.0);
    std.debug.assert(probability <= 1.0);

    // R-7 interpolation matches common spreadsheet and array tools.
    const span: f64 = @floatFromInt(values.len - 1);
    const position = span * probability;
    const lower: usize = @intFromFloat(@floor(position));
    const upper = @min(lower + 1, values.len - 1);
    const fraction = position - @as(f64, @floatFromInt(lower));

    return interpolate(values[lower], values[upper], fraction);
}

fn interpolate(lower: f64, upper: f64, fraction: f64) f64 {
    if (std.math.signbit(lower) != std.math.signbit(upper)) {
        return lower * (1.0 - fraction) + upper * fraction;
    }

    return lower + (upper - lower) * fraction;
}

test "parse columns delimiters and comments" {
    const input =
        \\# name value
        \\alpha,1.5
        \\ignored
        \\beta,2.5 # trailing comment
        \\
    ;
    const options: ParseOptions = .{ .column = 2, .delimiters = ", \t" };

    const values = try parse(std.testing.allocator, input, options);
    defer std.testing.allocator.free(values);

    try std.testing.expectEqualSlices(f64, &.{ 1.5, 2.5 }, values);
}

test "reject invalid and non-finite selected values" {
    try std.testing.expectError(
        error.InvalidNumber,
        parse(std.testing.allocator, "1\nnope\n", .{}),
    );
    try std.testing.expectError(
        error.NonFiniteNumber,
        parse(std.testing.allocator, "1\nnan\n", .{}),
    );
}

test "calculate linear quantiles and sample dispersion" {
    var values = [_]f64{ 8, 2, 6, 4, 1, 7, 3, 5 };
    const stats = calculate(&values);

    try std.testing.expectEqual(@as(usize, 8), stats.count);
    try std.testing.expectApproxEqAbs(1.0, stats.min, 1e-12);
    try std.testing.expectApproxEqAbs(2.75, stats.q1, 1e-12);
    try std.testing.expectApproxEqAbs(4.5, stats.median, 1e-12);
    try std.testing.expectApproxEqAbs(6.25, stats.q3, 1e-12);
    try std.testing.expectApproxEqAbs(3.5, stats.iqr, 1e-12);
    try std.testing.expectApproxEqAbs(4.5, stats.mean, 1e-12);
    try std.testing.expectApproxEqAbs(6.0, stats.variance.?, 1e-12);
    try std.testing.expectApproxEqAbs(@sqrt(6.0), stats.stddev.?, 1e-12);
    try std.testing.expectApproxEqAbs(7.3, stats.p90, 1e-12);
    try std.testing.expectApproxEqAbs(7.65, stats.p95, 1e-12);
    try std.testing.expectApproxEqAbs(7.93, stats.p99, 1e-12);
}

test "single value has undefined sample dispersion" {
    var values = [_]f64{42};
    const stats = calculate(&values);

    try std.testing.expectEqual(@as(?f64, null), stats.variance);
    try std.testing.expectEqual(@as(?f64, null), stats.stddev);
    try std.testing.expectEqual(@as(?f64, null), stats.stderr);
    try std.testing.expectEqual(@as(?f64, null), stats.cv_percent);
}

test "constant values have zero dispersion" {
    var values = [_]f64{ 3, 3, 3, 3 };
    const stats = calculate(&values);

    try std.testing.expectEqual(@as(?f64, 0.0), stats.variance);
    try std.testing.expectEqual(@as(?f64, 0.0), stats.stddev);
    try std.testing.expectEqual(@as(?f64, 0.0), stats.cv_percent);
}

test "opposite finite extremes have a finite median" {
    var values = [_]f64{ -std.math.floatMax(f64), std.math.floatMax(f64) };
    const stats = calculate(&values);

    try std.testing.expectEqual(@as(f64, 0.0), stats.median);
}

test "mean retains a small term amid cancellation" {
    var values = [_]f64{ -1e16, 1.0, 1e16 };
    const stats = calculate(&values);

    try std.testing.expectApproxEqAbs(1.0 / 3.0, stats.mean, 1e-15);
}
