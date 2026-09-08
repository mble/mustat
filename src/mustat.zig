const std = @import("std");

const Io = std.Io;

const byte_value_count = 1 << @bitSizeOf(u8);
const kibibyte = 1024;
const mebibyte = 1024 * kibibyte;
const gibibyte = 1024 * mebibyte;
const line_bytes_max = 1 * mebibyte;
const value_storage_bytes_max: u64 = 4 * gibibyte;
const addressable_value_count = std.math.maxInt(usize) / @sizeOf(f64);
const stored_value_count: u64 = value_storage_bytes_max / @sizeOf(f64);
const value_count_max: usize = @min(addressable_value_count, stored_value_count);
const beta_epsilon = 3e-14;
const beta_iteration_max = 200;
const beta_min = 1e-300;
const quantile_count = 6;
const quantile_rank_max = quantile_count * 2;
const q1_probability = 0.25;
const median_probability = 0.50;
const q3_probability = 0.75;
const p90_probability = 0.90;
const p95_probability = 0.95;
const p99_probability = 0.99;
const percent_scale = 100.0;
const selection_depth_multiplier = 2;
const selection_sort_threshold = 64;
// Wide vectors hide accumulation latency on 128-bit and 256-bit SIMD.
const simd_lane_count = 16;
const order_increasing_mask: u2 = 1 << 0;
const order_decreasing_mask: u2 = 1 << 1;
const quantile_probabilities = [_]f64{
    q1_probability,
    median_probability,
    q3_probability,
    p90_probability,
    p95_probability,
    p99_probability,
};

const F64Vector = @Vector(simd_lane_count, f64);

comptime {
    std.debug.assert(quantile_count == quantile_probabilities.len);
    std.debug.assert(quantile_rank_max == quantile_count * 2);
    std.debug.assert(simd_lane_count > 0);
    std.debug.assert(std.math.isPowerOfTwo(simd_lane_count));
    std.debug.assert(value_count_max <= stored_value_count);
}

pub const ParseOptions = struct {
    column: usize = 1,
    delimiters: []const u8 = " \t",
};

pub const ParseError = error{
    EmptyDelimiter,
    InvalidColumn,
    InvalidNumber,
    LineTooLong,
    NoData,
    NonFiniteNumber,
    OutOfMemory,
    TooManyValues,
};

pub const StreamParseError = ParseError || error{ReadFailed};

pub const Stats = struct {
    count: u64,
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

pub const TTest = struct {
    difference: f64,
    relative_percent: ?f64,
    statistic: f64,
    freedom: f64,
    p_value: f64,
};

pub fn parse(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: *const ParseOptions,
) ParseError![]f64 {
    try validate_lines(input);

    var reader: Io.Reader = .fixed(input);

    return parse_reader(allocator, &reader, options) catch |err| switch (err) {
        error.ReadFailed => unreachable,
        else => |parse_error| return parse_error,
    };
}

pub fn parse_reader(
    allocator: std.mem.Allocator,
    reader: *Io.Reader,
    options: *const ParseOptions,
) StreamParseError![]f64 {
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

    var long_line: Io.Writer.Allocating = .init(allocator);
    defer long_line.deinit();

    while (true) {
        const line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.StreamTooLong => {
                const long = try read_long_line(reader, &long_line);
                try parse_line(&values, allocator, long, options.column, &delimiters);
                continue;
            },
        } orelse break;

        try parse_line(&values, allocator, line, options.column, &delimiters);
    }
    if (values.items.len == 0) {
        return error.NoData;
    }

    return try values.toOwnedSlice(allocator);
}

fn validate_lines(input: []const u8) ParseError!void {
    var line_start: usize = 0;
    // Scan wide windows so fixed readers cannot bypass the streaming line cap.
    while (input.len - line_start >= line_bytes_max) {
        const window = input[line_start..][0..line_bytes_max];
        const newline = std.mem.lastIndexOfScalar(u8, window, '\n') orelse {
            return error.LineTooLong;
        };

        line_start += newline + 1;
        std.debug.assert(line_start <= input.len);
    }
}

fn read_long_line(
    reader: *Io.Reader,
    long_line: *Io.Writer.Allocating,
) StreamParseError![]const u8 {
    // Bound allocation while supporting lines larger than the read buffer.
    long_line.clearRetainingCapacity();
    _ = reader.streamDelimiterLimit(
        &long_line.writer,
        '\n',
        .limited(line_bytes_max),
    ) catch |stream_error| {
        return switch (stream_error) {
            error.ReadFailed => error.ReadFailed,
            error.StreamTooLong => error.LineTooLong,
            error.WriteFailed => error.OutOfMemory,
        };
    };
    if (reader.bufferedLen() != 0) {
        std.debug.assert(reader.buffered()[0] == '\n');
        reader.toss(1);
    }

    std.debug.assert(long_line.written().len < line_bytes_max);
    return long_line.written();
}

fn parse_line(
    values: *std.ArrayList(f64),
    allocator: std.mem.Allocator,
    line: []const u8,
    column: usize,
    delimiters: *const [byte_value_count]bool,
) ParseError!void {
    const token = find_column(line, column, delimiters) orelse return;
    const value = std.fmt.parseFloat(f64, token) catch {
        return error.InvalidNumber;
    };
    if (std.math.isFinite(value) == false) {
        return error.NonFiniteNumber;
    }
    try append_value(values, allocator, value);
}

inline fn append_value(
    values: *std.ArrayList(f64),
    allocator: std.mem.Allocator,
    value: f64,
) ParseError!void {
    if (values.items.len == values.capacity) {
        if (values.items.len >= value_count_max) {
            return error.TooManyValues;
        }

        // Clamp only cold growth to keep the per-value path branch-free.
        const grown = std.ArrayList(f64).growCapacity(values.items.len + 1);
        try values.ensureTotalCapacityPrecise(allocator, @min(grown, value_count_max));
        std.debug.assert(values.capacity <= value_count_max);
    }

    values.appendAssumeCapacity(value);
}

pub fn calculate(values: []f64, stats: *Stats) void {
    std.debug.assert(values.len > 0);
    std.debug.assert(values.len <= value_count_max);

    const extrema = calculate_extrema(values);
    const mean = calculate_mean(values, &extrema);
    const variance = calculate_variance(values, mean, &extrema);
    const stddev = if (variance) |value| @sqrt(value) else null;
    const stderr = if (stddev) |value| value / @sqrt(@as(f64, @floatFromInt(values.len))) else null;
    const cv_percent = if (stddev) |value| calculate_cv(value, mean) else null;

    switch (extrema.order) {
        .constant, .increasing => {},
        .decreasing => std.mem.reverse(f64, values),
        .unsorted => {
            // Multi-selection resolves only the required order statistics.
            var rank_buffer: [quantile_rank_max]usize = undefined;
            const rank_count = quantile_ranks(values.len, &rank_buffer);
            select_ranks(values, rank_buffer[0..rank_count]);
        },
    }

    const q1 = quantile(values, q1_probability);
    const q3 = quantile(values, q3_probability);

    stats.* = .{
        .count = @intCast(values.len),
        .min = extrema.min,
        .q1 = q1,
        .median = quantile(values, median_probability),
        .q3 = q3,
        .max = extrema.max,
        .iqr = q3 - q1,
        .mean = mean,
        .range = extrema.max - extrema.min,
        .variance = variance,
        .stddev = stddev,
        .stderr = stderr,
        .cv_percent = cv_percent,
        .p90 = quantile(values, p90_probability),
        .p95 = quantile(values, p95_probability),
        .p99 = quantile(values, p99_probability),
    };
}

pub fn welch(left: *const Stats, right: *const Stats, result: *TTest) bool {
    const left_variance = left.variance orelse return false;
    const right_variance = right.variance orelse return false;
    std.debug.assert(left.count > 1);
    std.debug.assert(right.count > 1);

    const left_count: f64 = @floatFromInt(left.count);
    const right_count: f64 = @floatFromInt(right.count);
    const left_scaled = left_variance / left_count;
    const right_scaled = right_variance / right_count;
    const variance_scale = @max(left_scaled, right_scaled);
    if (variance_scale == 0.0) {
        return false;
    }
    if (std.math.isFinite(variance_scale) == false) {
        return false;
    }

    const left_normalized = left_scaled / variance_scale;
    const right_normalized = right_scaled / variance_scale;
    const normalized_sum = left_normalized + right_normalized;

    const left_freedom: f64 = @floatFromInt(left.count - 1);
    const right_freedom: f64 = @floatFromInt(right.count - 1);
    const freedom_denominator = left_normalized * left_normalized / left_freedom +
        right_normalized * right_normalized / right_freedom;
    if (freedom_denominator == 0.0) {
        return false;
    }

    const difference = left.mean - right.mean;
    const standard_error = @sqrt(variance_scale) * @sqrt(normalized_sum);
    const statistic = difference / standard_error;
    const freedom = normalized_sum * normalized_sum / freedom_denominator;
    const relative_percent = if (right.mean == 0.0)
        null
    else
        difference / @abs(right.mean) * percent_scale;

    const p_value = student_two_tail(@abs(statistic), freedom) orelse return false;
    result.* = .{
        .difference = difference,
        .relative_percent = relative_percent,
        .statistic = statistic,
        .freedom = freedom,
        .p_value = p_value,
    };
    std.debug.assert(result.p_value >= 0.0);
    std.debug.assert(result.p_value <= 1.0);
    return true;
}

fn find_column(
    line: []const u8,
    column_wanted: usize,
    delimiters: *const [byte_value_count]bool,
) ?[]const u8 {
    var token_start: ?usize = null;
    var column: usize = 0;

    for (line, 0..) |byte, index| {
        if (byte == '#') {
            return finish_token(line, token_start, index, column, column_wanted);
        }
        if (delimiters[byte]) {
            const token = finish_token(line, token_start, index, column, column_wanted);
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

    return finish_token(line, token_start, line.len, column, column_wanted);
}

fn finish_token(
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

const Extrema = struct {
    min: f64,
    max: f64,
    order: InputOrder,
};

const InputOrder = enum(u2) {
    unsorted = 0,
    increasing = order_increasing_mask,
    decreasing = order_decreasing_mask,
    constant = order_increasing_mask | order_decreasing_mask,
};

fn calculate_extrema(values: []const f64) Extrema {
    std.debug.assert(values.len > 0);

    var minima: F64Vector = @splat(values[0]);
    var maxima: F64Vector = @splat(values[0]);
    var order_mask: u2 = @intFromEnum(InputOrder.constant);
    var previous = values[0];

    var index: usize = 1;
    while (index + simd_lane_count <= values.len) : (index += simd_lane_count) {
        const input: F64Vector = values[index..][0..simd_lane_count].*;
        const predecessors = std.simd.shiftElementsRight(input, 1, previous);
        minima = @min(minima, input);
        maxima = @max(maxima, input);
        if (@reduce(.Or, predecessors > input)) {
            order_mask &= order_decreasing_mask;
        }
        if (@reduce(.Or, predecessors < input)) {
            order_mask &= order_increasing_mask;
        }
        previous = input[simd_lane_count - 1];
    }

    var result: Extrema = .{
        .min = @reduce(.Min, minima),
        .max = @reduce(.Max, maxima),
        .order = @enumFromInt(order_mask),
    };
    for (values[index..]) |value| {
        result.min = @min(result.min, value);
        result.max = @max(result.max, value);
        result.order = next_order(result.order, previous, value);
        previous = value;
    }

    return result;
}

fn next_order(order: InputOrder, previous: f64, value: f64) InputOrder {
    if (order == .constant) {
        if (previous < value) {
            return .increasing;
        }
        if (previous > value) {
            return .decreasing;
        }
        return .constant;
    }

    return switch (order) {
        .constant => unreachable,
        .increasing => if (previous <= value) .increasing else .unsorted,
        .decreasing => if (previous >= value) .decreasing else .unsorted,
        .unsorted => .unsorted,
    };
}

fn calculate_mean(values: []const f64, extrema: *const Extrema) f64 {
    std.debug.assert(values.len > 0);

    const reference = interpolate(extrema.min, extrema.max, 0.5);
    const count: f64 = @floatFromInt(values.len);
    const references: F64Vector = @splat(reference);
    const counts: F64Vector = @splat(count);
    var sums: F64Vector = @splat(0.0);
    var corrections: F64Vector = @splat(0.0);

    var index: usize = 0;
    while (index + simd_lane_count <= values.len) : (index += simd_lane_count) {
        const input: F64Vector = values[index..][0..simd_lane_count].*;
        const terms = (input - references) / counts;
        const next = sums + terms;
        const sum_larger = @abs(sums) >= @abs(terms);
        corrections += @select(
            f64,
            sum_larger,
            (sums - next) + terms,
            (terms - next) + sums,
        );
        sums = next;
    }

    var total: CompensatedSum = .{};
    const sum_array: [simd_lane_count]f64 = @bitCast(sums);
    const correction_array: [simd_lane_count]f64 = @bitCast(corrections);
    for (sum_array, correction_array) |sum, correction| {
        total.add(sum);
        total.add(correction);
    }
    for (values[index..]) |value| {
        total.add((value - reference) / count);
    }

    return reference + total.value();
}

fn calculate_variance(values: []const f64, mean: f64, extrema: *const Extrema) ?f64 {
    std.debug.assert(values.len > 0);

    if (values.len < 2) {
        return null;
    }

    // Known extrema make scaled sum-of-squares independent and vectorizable.
    const scale = @max(@abs(extrema.min - mean), @abs(extrema.max - mean));
    if (scale == 0.0) {
        return 0.0;
    }
    if (std.math.isFinite(scale) == false) {
        return std.math.inf(f64);
    }

    const means: F64Vector = @splat(mean);
    const scales: F64Vector = @splat(scale);
    var sums: F64Vector = @splat(0.0);
    var index: usize = 0;
    while (index + simd_lane_count <= values.len) : (index += simd_lane_count) {
        const input: F64Vector = values[index..][0..simd_lane_count].*;
        const ratios = (input - means) / scales;
        sums += ratios * ratios;
    }

    var sum_scaled: CompensatedSum = .{};
    const sum_array: [simd_lane_count]f64 = @bitCast(sums);
    for (sum_array) |sum| {
        sum_scaled.add(sum);
    }
    for (values[index..]) |value| {
        const ratio = (value - mean) / scale;
        sum_scaled.add(ratio * ratio);
    }

    const freedom: f64 = @floatFromInt(values.len - 1);
    return scale * scale * (sum_scaled.value() / freedom);
}

const CompensatedSum = struct {
    sum: f64 = 0.0,
    correction: f64 = 0.0,

    fn add(self: *CompensatedSum, term: f64) void {
        const next = self.sum + term;
        if (@abs(self.sum) >= @abs(term)) {
            self.correction += (self.sum - next) + term;
        } else {
            self.correction += (term - next) + self.sum;
        }
        self.sum = next;
    }

    fn value(self: *const CompensatedSum) f64 {
        return self.sum + self.correction;
    }
};

fn calculate_cv(stddev: f64, mean: f64) ?f64 {
    std.debug.assert(stddev >= 0.0);

    if (mean == 0.0) {
        return null;
    }

    return stddev / @abs(mean) * percent_scale;
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

fn quantile_ranks(count: usize, ranks: *[quantile_rank_max]usize) usize {
    std.debug.assert(count > 0);

    const span: f64 = @floatFromInt(count - 1);
    var rank_count: usize = 0;
    for (quantile_probabilities) |probability| {
        const position = span * probability;
        const lower: usize = @intFromFloat(@floor(position));
        const upper = @min(lower + 1, count - 1);

        ranks[rank_count] = lower;
        ranks[rank_count + 1] = upper;
        rank_count += 2;
    }
    std.mem.sortUnstable(usize, ranks[0..rank_count], {}, std.sort.asc(usize));

    var unique_count: usize = 1;
    for (ranks[1..rank_count]) |rank| {
        if (ranks[unique_count - 1] != rank) {
            ranks[unique_count] = rank;
            unique_count += 1;
        }
    }

    return unique_count;
}

const SelectionTask = struct {
    rank_start: usize,
    rank_end: usize,
    value_start: usize,
    value_end: usize,
    depth: usize,
};

fn select_ranks(values: []f64, ranks: []const usize) void {
    std.debug.assert(ranks.len > 0);
    std.debug.assert(ranks.len <= quantile_rank_max);
    std.debug.assert(ranks[ranks.len - 1] < values.len);
    for (ranks[1..], ranks[0 .. ranks.len - 1]) |rank, previous| {
        std.debug.assert(previous < rank);
    }

    const depth_max = selection_depth_multiplier *
        (@as(usize, std.math.log2_int(usize, values.len)) + 1);
    var tasks: [quantile_rank_max]SelectionTask = undefined;
    tasks[0] = .{
        .rank_start = 0,
        .rank_end = ranks.len,
        .value_start = 0,
        .value_end = values.len,
        .depth = depth_max,
    };
    var task_count: usize = 1;
    var iterations_remaining = ranks.len * (depth_max + 1);

    // Each task owns at least one rank, bounding the explicit work stack.
    while (iterations_remaining > 0) : (iterations_remaining -= 1) {
        if (task_count == 0) {
            return;
        }

        task_count -= 1;
        const task = tasks[task_count];
        select_task(values, ranks, &tasks, &task_count, &task);
    }

    std.debug.assert(task_count == 0);
}

inline fn select_task(
    values: []f64,
    ranks: []const usize,
    tasks: *[quantile_rank_max]SelectionTask,
    task_count: *usize,
    task: *const SelectionTask,
) void {
    std.debug.assert(task.rank_start < task.rank_end);
    std.debug.assert(task.value_start < task.value_end);
    std.debug.assert(task.rank_end <= ranks.len);
    std.debug.assert(task.value_end <= values.len);

    const task_ranks = ranks[task.rank_start..task.rank_end];
    if (task.value_end - task.value_start <= selection_sort_threshold) {
        std.mem.sortUnstable(f64, values[task.value_start..task.value_end], {}, std.sort.asc(f64));
        return;
    }
    if (task.depth == 0) {
        std.mem.sortUnstable(f64, values[task.value_start..task.value_end], {}, std.sort.asc(f64));
        return;
    }

    const middle = task.value_start + @divFloor(task.value_end - task.value_start, 2);
    const pivot = median_of_three(
        values[task.value_start],
        values[middle],
        values[task.value_end - 1],
    );
    const equal = partition(values, task.value_start, task.value_end, pivot);
    const left_count = rank_lower_bound(task_ranks, equal.start);
    const right_start = rank_lower_bound(task_ranks, equal.end);

    if (right_start < task_ranks.len) {
        const right: SelectionTask = .{
            .rank_start = task.rank_start + right_start,
            .rank_end = task.rank_end,
            .value_start = equal.end,
            .value_end = task.value_end,
            .depth = task.depth - 1,
        };
        push_task(tasks, task_count, &right);
    }
    if (left_count > 0) {
        const left: SelectionTask = .{
            .rank_start = task.rank_start,
            .rank_end = task.rank_start + left_count,
            .value_start = task.value_start,
            .value_end = equal.start,
            .depth = task.depth - 1,
        };
        push_task(tasks, task_count, &left);
    }
}

inline fn push_task(
    tasks: *[quantile_rank_max]SelectionTask,
    task_count: *usize,
    task: *const SelectionTask,
) void {
    std.debug.assert(task_count.* < tasks.len);

    tasks[task_count.*] = task.*;
    task_count.* += 1;
}

const EqualRange = struct {
    start: usize,
    end: usize,
};

fn partition(values: []f64, start: usize, end: usize, pivot: f64) EqualRange {
    std.debug.assert(start < end);
    std.debug.assert(end <= values.len);

    const pivot_index = find_pivot(values, start, end, pivot);
    std.mem.swap(f64, &values[pivot_index], &values[end - 1]);

    var lower = start;
    var duplicate_count: usize = 0;
    for (start..end - 1) |index| {
        if (values[index] < pivot) {
            if (lower != index) {
                std.mem.swap(f64, &values[lower], &values[index]);
            }
            lower += 1;
            continue;
        }
        if (values[index] == pivot) {
            duplicate_count += 1;
        }
    }
    if (duplicate_count == 0) {
        std.mem.swap(f64, &values[lower], &values[end - 1]);
        return .{ .start = lower, .end = lower + 1 };
    }

    var upper = lower;
    for (lower..end) |index| {
        if (values[index] == pivot) {
            if (upper != index) {
                std.mem.swap(f64, &values[upper], &values[index]);
            }
            upper += 1;
        }
    }

    return .{ .start = lower, .end = upper };
}

fn find_pivot(values: []const f64, start: usize, end: usize, pivot: f64) usize {
    std.debug.assert(start < end);
    std.debug.assert(end <= values.len);

    if (values[start] == pivot) {
        return start;
    }

    const middle = start + @divFloor(end - start, 2);
    if (values[middle] == pivot) {
        return middle;
    }

    std.debug.assert(values[end - 1] == pivot);
    return end - 1;
}

fn median_of_three(first_value: f64, second_value: f64, third_value: f64) f64 {
    var first = first_value;
    var second = second_value;
    var third = third_value;
    if (second < first) {
        std.mem.swap(f64, &first, &second);
    }
    if (third < second) {
        std.mem.swap(f64, &second, &third);
    }
    if (second < first) {
        std.mem.swap(f64, &first, &second);
    }

    return second;
}

fn rank_lower_bound(ranks: []const usize, target: usize) usize {
    var start: usize = 0;
    var end = ranks.len;
    while (start < end) {
        const middle = start + @divFloor(end - start, 2);
        if (ranks[middle] < target) {
            start = middle + 1;
            continue;
        }

        end = middle;
    }

    return start;
}

fn interpolate(lower: f64, upper: f64, fraction: f64) f64 {
    if (std.math.signbit(lower) != std.math.signbit(upper)) {
        return lower * (1.0 - fraction) + upper * fraction;
    }

    return lower + (upper - lower) * fraction;
}

fn student_two_tail(statistic: f64, freedom: f64) ?f64 {
    std.debug.assert(statistic >= 0.0);
    std.debug.assert(freedom > 0.0);
    if (std.math.isFinite(statistic) == false) {
        return 0.0;
    }
    if (std.math.isFinite(freedom) == false) {
        return null;
    }

    const statistic_squared = statistic * statistic;
    const beta_x = freedom / (freedom + statistic_squared);

    return regularized_beta(beta_x, freedom / 2.0, 0.5);
}

fn regularized_beta(x: f64, a: f64, b: f64) ?f64 {
    std.debug.assert(x >= 0.0);
    std.debug.assert(x <= 1.0);
    std.debug.assert(a > 0.0);
    std.debug.assert(b > 0.0);

    if (x == 0.0) {
        return 0.0;
    }
    if (x == 1.0) {
        return 1.0;
    }

    const log_beta = std.math.lgamma(f64, a + b) -
        std.math.lgamma(f64, a) - std.math.lgamma(f64, b);
    const factor = @exp(log_beta + a * @log(x) + b * std.math.log1p(-x));
    if (x < (a + 1.0) / (a + b + 2.0)) {
        const fraction = beta_fraction(a, b, x) orelse return null;
        return factor * fraction / a;
    }

    const fraction = beta_fraction(b, a, 1.0 - x) orelse return null;
    return 1.0 - factor * fraction / b;
}

fn beta_fraction(a: f64, b: f64, x: f64) ?f64 {
    std.debug.assert(a > 0.0);
    std.debug.assert(b > 0.0);

    const sum = a + b;
    const a_next = a + 1.0;
    const a_previous = a - 1.0;
    var c: f64 = 1.0;
    var d = clamp_beta(1.0 - sum * x / a_next);
    d = 1.0 / d;
    var result = d;

    var iteration: usize = 1;
    while (iteration <= beta_iteration_max) : (iteration += 1) {
        const index: f64 = @floatFromInt(iteration);
        const twice = 2.0 * index;
        var coefficient = index * (b - index) * x /
            ((a_previous + twice) * (a + twice));
        d = 1.0 / clamp_beta(1.0 + coefficient * d);
        c = clamp_beta(1.0 + coefficient / c);
        result *= d * c;

        coefficient = -(a + index) * (sum + index) * x /
            ((a + twice) * (a_next + twice));
        d = 1.0 / clamp_beta(1.0 + coefficient * d);
        c = clamp_beta(1.0 + coefficient / c);
        const delta = d * c;
        result *= delta;
        if (@abs(delta - 1.0) <= beta_epsilon) {
            return result;
        }
    }

    // A bounded failure is safer than emitting an unstable probability.
    return null;
}

fn clamp_beta(value: f64) f64 {
    if (@abs(value) >= beta_min) {
        return value;
    }
    if (value < 0.0) {
        return -beta_min;
    }

    return beta_min;
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

    const values = try parse(std.testing.allocator, input, &options);
    defer std.testing.allocator.free(values);

    try std.testing.expectEqualSlices(f64, &.{ 1.5, 2.5 }, values);
}

test "parse reader across buffer boundaries" {
    var buffer: [7]u8 = undefined;
    var reader: std.testing.Reader = .init(&buffer, &.{
        .{ .buffer = "alpha,1.5\nignored\n" },
        .{ .buffer = "beta,2.5 # trailing comment" },
    });
    reader.artificial_limit = .limited(3);

    const values = try parse_reader(
        std.testing.allocator,
        &reader.interface,
        &.{ .column = 2, .delimiters = ", \t" },
    );
    defer std.testing.allocator.free(values);

    try std.testing.expectEqualSlices(f64, &.{ 1.5, 2.5 }, values);
}

test "reject lines beyond the operational limit" {
    const input = try std.testing.allocator.alloc(u8, line_bytes_max + 1);
    defer std.testing.allocator.free(input);
    @memset(input, ' ');

    var buffer: [64]u8 = undefined;
    var reader: std.testing.Reader = .init(&buffer, &.{.{ .buffer = input }});

    try std.testing.expectError(
        error.LineTooLong,
        parse(std.testing.allocator, input, &.{}),
    );
    try std.testing.expectError(
        error.LineTooLong,
        parse_reader(std.testing.allocator, &reader.interface, &.{}),
    );
}

test "reject invalid and non-finite selected values" {
    try std.testing.expectError(
        error.InvalidNumber,
        parse(std.testing.allocator, "1\nnope\n", &.{}),
    );
    try std.testing.expectError(
        error.NonFiniteNumber,
        parse(std.testing.allocator, "1\nnan\n", &.{}),
    );
}

test "calculate linear quantiles and sample dispersion" {
    var values = [_]f64{ 8, 2, 6, 4, 1, 7, 3, 5 };
    var stats: Stats = undefined;
    calculate(&values, &stats);

    try std.testing.expectEqual(@as(u64, 8), stats.count);
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
    var stats: Stats = undefined;
    calculate(&values, &stats);

    try std.testing.expectEqual(@as(?f64, null), stats.variance);
    try std.testing.expectEqual(@as(?f64, null), stats.stddev);
    try std.testing.expectEqual(@as(?f64, null), stats.stderr);
    try std.testing.expectEqual(@as(?f64, null), stats.cv_percent);
}

test "constant values have zero dispersion" {
    var values = [_]f64{ 3, 3, 3, 3 };
    var stats: Stats = undefined;
    calculate(&values, &stats);

    try std.testing.expectEqual(@as(?f64, 0.0), stats.variance);
    try std.testing.expectEqual(@as(?f64, 0.0), stats.stddev);
    try std.testing.expectEqual(@as(?f64, 0.0), stats.cv_percent);
}

test "opposite finite extremes have a finite median" {
    var values = [_]f64{ -std.math.floatMax(f64), std.math.floatMax(f64) };
    var stats: Stats = undefined;
    calculate(&values, &stats);

    try std.testing.expectEqual(@as(f64, 0.0), stats.median);
}

test "mean retains a small term amid cancellation" {
    var values = [_]f64{ -1e16, 1.0, 1e16 };
    var stats: Stats = undefined;
    calculate(&values, &stats);

    try std.testing.expectApproxEqAbs(1.0 / 3.0, stats.mean, 1e-15);
}

test "Welch test matches NIST instrument example" {
    var left_values = [_]f64{ 91, 95, 107, 105, 102, 85, 88, 92, 101, 99, 102, 85, 114, 91, 95 };
    var right_values = [_]f64{ 93, 99, 97, 101, 70, 83, 97, 100, 91, 73, 90, 86, 95, 70, 87 };
    var left: Stats = undefined;
    var right: Stats = undefined;
    calculate(&left_values, &left);
    calculate(&right_values, &right);

    var result: TTest = undefined;
    try std.testing.expect(welch(&left, &right, &result));

    try std.testing.expectApproxEqAbs(8.0, result.difference, 1e-12);
    try std.testing.expectApproxEqAbs(2.2855810195691872, result.statistic, 1e-12);
    try std.testing.expectApproxEqAbs(26.64583000752373, result.freedom, 1e-12);
    try std.testing.expectApproxEqAbs(0.030464211912515, result.p_value, 1e-12);
}

test "Student two-tailed probabilities match known values" {
    try std.testing.expectApproxEqAbs(0.5, student_two_tail(1.0, 1.0).?, 1e-13);
    try std.testing.expectApproxEqAbs(
        0.2928932188134525,
        student_two_tail(@sqrt(2.0), 2.0).?,
        1e-13,
    );
    try std.testing.expectApproxEqAbs(0.05, student_two_tail(12.7062047364, 1.0).?, 2e-7);
    try std.testing.expectApproxEqAbs(0.05, student_two_tail(2.228138852, 10.0).?, 2e-9);
}

test "Student probability converges to normal for large samples" {
    try std.testing.expectApproxEqAbs(
        0.0499957903,
        student_two_tail(1.96, 1e9).?,
        5e-8,
    );
}

test "Welch test requires sample variance" {
    var left_values = [_]f64{1};
    var right_values = [_]f64{ 1, 2 };
    var left: Stats = undefined;
    var right: Stats = undefined;
    calculate(&left_values, &left);
    calculate(&right_values, &right);

    var result: TTest = undefined;
    try std.testing.expect(welch(&left, &right, &result) == false);
}

test "multi-selection matches full sorting" {
    var random_state = std.Random.DefaultPrng.init(0x9f41_24a8_7d31_02cb);
    const random = random_state.random();
    var values: [513]f64 = undefined;
    var expected: [values.len]f64 = undefined;

    for (1..values.len + 1) |count| {
        for (values[0..count]) |*value| {
            value.* = @floatFromInt(random.intRangeAtMost(i16, -100, 100));
        }
        @memcpy(expected[0..count], values[0..count]);
        std.mem.sortUnstable(f64, expected[0..count], {}, std.sort.asc(f64));

        var stats: Stats = undefined;
        calculate(values[0..count], &stats);
        try std.testing.expectEqual(quantile(expected[0..count], q1_probability), stats.q1);
        try std.testing.expectEqual(
            quantile(expected[0..count], median_probability),
            stats.median,
        );
        try std.testing.expectEqual(quantile(expected[0..count], q3_probability), stats.q3);
        try std.testing.expectEqual(quantile(expected[0..count], p90_probability), stats.p90);
        try std.testing.expectEqual(quantile(expected[0..count], p95_probability), stats.p95);
        try std.testing.expectEqual(quantile(expected[0..count], p99_probability), stats.p99);
    }
}

test "descending SIMD path preserves order statistics" {
    var values: [257]f64 = undefined;
    for (&values, 0..) |*value, index| {
        value.* = @floatFromInt(values.len - index);
    }

    var stats: Stats = undefined;
    calculate(&values, &stats);

    try std.testing.expectEqual(1.0, stats.min);
    try std.testing.expectEqual(65.0, stats.q1);
    try std.testing.expectEqual(129.0, stats.median);
    try std.testing.expectEqual(193.0, stats.q3);
    try std.testing.expectEqual(257.0, stats.max);
}
