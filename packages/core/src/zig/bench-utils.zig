const std = @import("std");

pub fn matchesBenchFilter(bench_name: []const u8, filter: ?[]const u8) bool {
    if (filter == null) return true;
    const filter_str = filter.?;
    if (filter_str.len == 0) return true;

    var i: usize = 0;
    while (i + filter_str.len <= bench_name.len) : (i += 1) {
        var matches = true;
        for (filter_str, 0..) |filter_char, j| {
            const bench_char = bench_name[i + j];
            const filter_lower = if (filter_char >= 'A' and filter_char <= 'Z') filter_char + 32 else filter_char;
            const bench_lower = if (bench_char >= 'A' and bench_char <= 'Z') bench_char + 32 else bench_char;
            if (filter_lower != bench_lower) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

pub const MemStat = struct {
    name: []const u8,
    bytes: usize,
};

pub const BenchResult = struct {
    name: []const u8,
    min_ns: u64,
    avg_ns: u64,
    max_ns: u64,
    total_ns: u64,
    iterations: usize,
    mem_stats: ?[]const MemStat,
};

/// Timing statistics collected during benchmark iterations
pub const BenchStats = struct {
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,
    total_ns: u64 = 0,
    count: usize = 0,

    pub fn record(self: *BenchStats, elapsed_ns: u64) void {
        self.min_ns = @min(self.min_ns, elapsed_ns);
        self.max_ns = @max(self.max_ns, elapsed_ns);
        self.total_ns += elapsed_ns;
        self.count += 1;
    }

    pub fn avg(self: *const BenchStats) u64 {
        if (self.count == 0) return 0;
        return self.total_ns / self.count;
    }
};

/// Helper for running benchmark iterations with timing
pub const BenchRunner = struct {
    allocator: std.mem.Allocator,
    results: std.ArrayListUnmanaged(BenchResult),

    pub fn init(allocator: std.mem.Allocator) BenchRunner {
        return .{
            .allocator = allocator,
            .results = .{},
        };
    }

    /// Add a benchmark result from collected stats
    pub fn addResult(
        self: *BenchRunner,
        name: []const u8,
        stats: BenchStats,
        mem_stats: ?[]const MemStat,
    ) !void {
        try self.results.append(self.allocator, BenchResult{
            .name = name,
            .min_ns = stats.min_ns,
            .avg_ns = stats.avg(),
            .max_ns = stats.max_ns,
            .total_ns = stats.total_ns,
            .iterations = stats.count,
            .mem_stats = mem_stats,
        });
    }

    /// Convenience: run a simple benchmark with the given function
    pub fn bench(
        self: *BenchRunner,
        name: []const u8,
        iterations: usize,
        comptime benchFn: anytype,
        args: anytype,
    ) !void {
        var stats = BenchStats{};
        var iter: usize = 0;
        while (iter < iterations) : (iter += 1) {
            var timer = try std.time.Timer.start();
            @call(.auto, benchFn, args);
            stats.record(timer.read());
        }
        try self.addResult(name, stats, null);
    }

    /// Get the results slice (caller owns memory via arena)
    pub fn finish(self: *BenchRunner) ![]BenchResult {
        return try self.results.toOwnedSlice(self.allocator);
    }

    /// Append results from another runner or slice
    pub fn appendSlice(self: *BenchRunner, other_results: []const BenchResult) !void {
        try self.results.appendSlice(self.allocator, other_results);
    }
};

/// Create a stdout writer with buffer for benchmark output
pub const StdoutWriter = struct {
    buffer: [4096]u8 = undefined,
    writer: std.fs.File.Writer = undefined,

    pub fn init() StdoutWriter {
        var self = StdoutWriter{};
        self.writer = std.fs.File.stdout().writer(&self.buffer);
        return self;
    }

    pub fn interface(self: *StdoutWriter) *std.Io.Writer {
        return &self.writer.interface;
    }

    pub fn print(self: *StdoutWriter, comptime fmt: []const u8, args: anytype) !void {
        try self.writer.interface.print(fmt, args);
    }

    pub fn flush(self: *StdoutWriter) !void {
        try self.writer.interface.flush();
    }
};

pub fn formatDuration(ns: u64) struct { value: f64, unit: []const u8, color: []const u8 } {
    if (ns < 1_000) {
        // Bright green for nanoseconds
        return .{ .value = @as(f64, @floatFromInt(ns)), .unit = "ns", .color = "\x1b[92m" };
    } else if (ns < 1_000_000) {
        // Normal green for microseconds
        return .{ .value = @as(f64, @floatFromInt(ns)) / 1_000.0, .unit = "us", .color = "\x1b[32m" };
    } else if (ns < 1_000_000_000) {
        const ms = @as(f64, @floatFromInt(ns)) / 1_000_000.0;
        if (ms < 1.0) {
            // Normal green for < 1ms
            return .{ .value = ms, .unit = "ms", .color = "\x1b[32m" };
        } else if (ms < 3.0) {
            // Yellow to red gradient from 1ms to 3ms
            if (ms < 1.5) {
                return .{ .value = ms, .unit = "ms", .color = "\x1b[33m" }; // Yellow
            } else if (ms < 2.0) {
                return .{ .value = ms, .unit = "ms", .color = "\x1b[38;5;208m" }; // Orange
            } else if (ms < 2.5) {
                return .{ .value = ms, .unit = "ms", .color = "\x1b[38;5;202m" }; // Dark orange
            } else {
                return .{ .value = ms, .unit = "ms", .color = "\x1b[31m" }; // Red
            }
        } else {
            // Full red for >= 3ms
            return .{ .value = ms, .unit = "ms", .color = "\x1b[31m" };
        }
    } else {
        // Red for seconds
        return .{ .value = @as(f64, @floatFromInt(ns)) / 1_000_000_000.0, .unit = "s", .color = "\x1b[31m" };
    }
}

pub fn formatBytes(bytes: usize) struct { value: f64, unit: []const u8 } {
    if (bytes < 1024) {
        return .{ .value = @as(f64, @floatFromInt(bytes)), .unit = "B" };
    } else if (bytes < 1024 * 1024) {
        return .{ .value = @as(f64, @floatFromInt(bytes)) / 1024.0, .unit = "KiB" };
    } else {
        return .{ .value = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0), .unit = "MiB" };
    }
}

pub fn printResults(writer: anytype, results: []const BenchResult) !void {
    if (results.len == 0) return;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Collect all unique memory stat names
    var mem_stat_names: std.ArrayListUnmanaged([]const u8) = .{};
    for (results) |result| {
        if (result.mem_stats) |stats| {
            for (stats) |stat| {
                // Check if we already have this name
                var found = false;
                for (mem_stat_names.items) |existing_name| {
                    if (std.mem.eql(u8, existing_name, stat.name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try mem_stat_names.append(allocator, stat.name);
                }
            }
        }
    }

    // Calculate column widths
    var max_name_len: usize = 20; // minimum
    var min_col_width: usize = 3; // minimum for "Min"
    var avg_col_width: usize = 3; // minimum for "Avg"
    var max_col_width: usize = 3; // minimum for "Max"

    // Create a map to store column widths for each memory stat
    var mem_col_widths: std.ArrayListUnmanaged(usize) = .{};
    for (mem_stat_names.items) |name| {
        try mem_col_widths.append(allocator, name.len); // minimum is the name length
    }

    // First pass: calculate maximum widths
    for (results) |result| {
        if (result.name.len > max_name_len) {
            max_name_len = result.name.len;
        }

        const min = formatDuration(result.min_ns);
        const avg = formatDuration(result.avg_ns);
        const max = formatDuration(result.max_ns);

        var min_buf: [32]u8 = undefined;
        const min_str = std.fmt.bufPrint(&min_buf, "{d:.2}{s}", .{ min.value, min.unit }) catch unreachable;
        if (min_str.len > min_col_width) min_col_width = min_str.len;

        var avg_buf: [32]u8 = undefined;
        const avg_str = std.fmt.bufPrint(&avg_buf, "{d:.2}{s}", .{ avg.value, avg.unit }) catch unreachable;
        if (avg_str.len > avg_col_width) avg_col_width = avg_str.len;

        var max_buf: [32]u8 = undefined;
        const max_str = std.fmt.bufPrint(&max_buf, "{d:.2}{s}", .{ max.value, max.unit }) catch unreachable;
        if (max_str.len > max_col_width) max_col_width = max_str.len;

        if (result.mem_stats) |stats| {
            for (stats) |stat| {
                const mem = formatBytes(stat.bytes);
                var mem_buf: [32]u8 = undefined;
                const mem_str = std.fmt.bufPrint(&mem_buf, "{d:.2} {s}", .{ mem.value, mem.unit }) catch unreachable;

                // Find the index of this stat name
                for (mem_stat_names.items, 0..) |name, i| {
                    if (std.mem.eql(u8, name, stat.name)) {
                        if (mem_str.len > mem_col_widths.items[i]) {
                            mem_col_widths.items[i] = mem_str.len;
                        }
                        break;
                    }
                }
            }
        }
    }

    // Print header
    var total_width = max_name_len + 3 + min_col_width + 3 + avg_col_width + 3 + max_col_width;
    for (mem_col_widths.items) |width| {
        total_width += 3 + width;
    }
    try writer.writeAll("\x1b[2m");
    try writer.splatByteAll('-', total_width);
    try writer.writeAll("\x1b[0m\n");

    // Column headers
    try writer.writeAll("\x1b[36m");
    try writer.writeAll("Benchmark");
    try writer.splatByteAll(' ', max_name_len - 9);
    try writer.writeAll("\x1b[0m\x1b[2m | \x1b[0m");

    try writer.writeAll("\x1b[36m");
    try writer.writeAll("Min");
    try writer.splatByteAll(' ', min_col_width - 3);
    try writer.writeAll("\x1b[0m\x1b[2m | \x1b[0m");

    try writer.writeAll("\x1b[36m");
    try writer.writeAll("Avg");
    try writer.splatByteAll(' ', avg_col_width - 3);
    try writer.writeAll("\x1b[0m\x1b[2m | \x1b[0m");

    try writer.writeAll("\x1b[36m");
    try writer.writeAll("Max");
    try writer.splatByteAll(' ', max_col_width - 3);
    try writer.writeAll("\x1b[0m");

    // Dynamic memory stat headers
    for (mem_stat_names.items, 0..) |name, i| {
        try writer.writeAll("\x1b[2m | \x1b[0m");
        try writer.writeAll("\x1b[36m");
        try writer.writeAll(name);
        if (name.len < mem_col_widths.items[i]) {
            try writer.splatByteAll(' ', mem_col_widths.items[i] - name.len);
        }
        try writer.writeAll("\x1b[0m");
    }

    try writer.writeByte('\n');

    try writer.writeAll("\x1b[2m");
    try writer.splatByteAll('-', total_width);
    try writer.writeAll("\x1b[0m\n");

    // Print each result
    for (results, 0..) |result, row_idx| {
        const min = formatDuration(result.min_ns);
        const avg = formatDuration(result.avg_ns);
        const max = formatDuration(result.max_ns);

        // Format duration strings
        var min_buf: [32]u8 = undefined;
        const min_str = try std.fmt.bufPrint(&min_buf, "{d:.2}{s}", .{ min.value, min.unit });

        var avg_buf: [32]u8 = undefined;
        const avg_str = try std.fmt.bufPrint(&avg_buf, "{d:.2}{s}", .{ avg.value, avg.unit });

        var max_buf: [32]u8 = undefined;
        const max_str = try std.fmt.bufPrint(&max_buf, "{d:.2}{s}", .{ max.value, max.unit });

        if (row_idx % 2 == 1) {
            try writer.writeAll("\x1b[48;5;234m");
        }

        // Benchmark name
        try writer.writeAll(result.name);
        try writer.splatByteAll(' ', max_name_len - result.name.len);
        try writer.writeAll("\x1b[2m | \x1b[0m");
        if (row_idx % 2 == 1) {
            try writer.writeAll("\x1b[48;5;234m");
        }

        // Min (right-aligned with color)
        if (min_str.len < min_col_width) {
            try writer.splatByteAll(' ', min_col_width - min_str.len);
        }
        try writer.writeAll(min.color);
        try writer.writeAll(min_str);
        try writer.writeAll("\x1b[0m");
        try writer.writeAll("\x1b[2m | \x1b[0m");
        if (row_idx % 2 == 1) {
            try writer.writeAll("\x1b[48;5;234m");
        }

        // Avg (right-aligned with color)
        if (avg_str.len < avg_col_width) {
            try writer.splatByteAll(' ', avg_col_width - avg_str.len);
        }
        try writer.writeAll(avg.color);
        try writer.writeAll(avg_str);
        try writer.writeAll("\x1b[0m");
        try writer.writeAll("\x1b[2m | \x1b[0m");
        if (row_idx % 2 == 1) {
            try writer.writeAll("\x1b[48;5;234m");
        }

        // Max (right-aligned with color)
        if (max_str.len < max_col_width) {
            try writer.splatByteAll(' ', max_col_width - max_str.len);
        }
        try writer.writeAll(max.color);
        try writer.writeAll(max_str);
        try writer.writeAll("\x1b[0m");

        // Dynamic memory stats columns
        for (mem_stat_names.items, 0..) |stat_name, i| {
            try writer.writeAll("\x1b[2m | \x1b[0m");
            if (row_idx % 2 == 1) {
                try writer.writeAll("\x1b[48;5;234m");
            }

            // Look for this stat in the result's memory stats
            var found_stat: ?usize = null;
            if (result.mem_stats) |stats| {
                for (stats) |stat| {
                    if (std.mem.eql(u8, stat.name, stat_name)) {
                        found_stat = stat.bytes;
                        break;
                    }
                }
            }

            if (found_stat) |bytes| {
                const mem = formatBytes(bytes);
                var mem_buf: [32]u8 = undefined;
                const mem_str = std.fmt.bufPrint(&mem_buf, "{d:.2} {s}", .{ mem.value, mem.unit }) catch unreachable;

                // Right-aligned
                if (mem_str.len < mem_col_widths.items[i]) {
                    try writer.splatByteAll(' ', mem_col_widths.items[i] - mem_str.len);
                }
                try writer.writeAll(mem_str);
            } else {
                // Empty column
                try writer.splatByteAll(' ', mem_col_widths.items[i]);
            }
        }

        if (row_idx % 2 == 1) {
            try writer.writeAll("\x1b[0m");
        }
        try writer.writeByte('\n');
    }

    try writer.writeAll("\x1b[2m");
    try writer.splatByteAll('-', total_width);
    try writer.writeAll("\x1b[0m\n");
    try writer.flush();
}

// JSON output for machine-readable results
pub fn printResultsJson(writer: anytype, results: []const BenchResult, bench_name: []const u8) !void {
    try writer.writeAll("{");
    try writer.print("\"benchmark\":\"{s}\",", .{bench_name});
    try writer.writeAll("\"results\":[");

    for (results, 0..) |result, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{");
        try writer.print("\"name\":\"{s}\",", .{result.name});
        try writer.print("\"min_ns\":{d},", .{result.min_ns});
        try writer.print("\"avg_ns\":{d},", .{result.avg_ns});
        try writer.print("\"max_ns\":{d},", .{result.max_ns});
        try writer.print("\"total_ns\":{d},", .{result.total_ns});
        try writer.print("\"iterations\":{d}", .{result.iterations});

        if (result.mem_stats) |stats| {
            try writer.writeAll(",\"mem_stats\":[");
            for (stats, 0..) |stat, j| {
                if (j > 0) try writer.writeByte(',');
                try writer.print("{{\"name\":\"{s}\",\"bytes\":{d}}}", .{ stat.name, stat.bytes });
            }
            try writer.writeByte(']');
        }
        try writer.writeByte('}');
    }
    try writer.writeAll("]}\n");
}

// Baseline file format for storing benchmark results
// Format: name=avg_ns|mem:stat_name=bytes|mem:stat_name2=bytes2
// Memory stats are optional and pipe-separated
pub const BaselineEntry = struct {
    avg_ns: u64,
    mem_stats: ?std.StringHashMap(usize), // stat_name -> bytes
};

pub const BaselineData = struct {
    entries: std.StringHashMap(BaselineEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BaselineData {
        return .{
            .entries = std.StringHashMap(BaselineEntry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BaselineData) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.mem_stats) |*mem| {
                var mem_it = mem.iterator();
                while (mem_it.next()) |mem_entry| {
                    self.allocator.free(mem_entry.key_ptr.*);
                }
                mem.deinit();
            }
        }
        self.entries.deinit();
    }

    pub fn put(self: *BaselineData, name: []const u8, avg_ns: u64, mem_stats: ?[]const MemStat) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        var owned_mem: ?std.StringHashMap(usize) = null;
        if (mem_stats) |stats| {
            owned_mem = std.StringHashMap(usize).init(self.allocator);
            errdefer if (owned_mem) |*m| {
                var mem_it = m.iterator();
                while (mem_it.next()) |mem_entry| {
                    self.allocator.free(mem_entry.key_ptr.*);
                }
                m.deinit();
            };
            for (stats) |stat| {
                const owned_stat_name = try self.allocator.dupe(u8, stat.name);
                try owned_mem.?.put(owned_stat_name, stat.bytes);
            }
        }

        try self.entries.put(owned_name, .{
            .avg_ns = avg_ns,
            .mem_stats = owned_mem,
        });
    }

    pub fn get(self: *const BaselineData, name: []const u8) ?BaselineEntry {
        return self.entries.get(name);
    }

    pub fn getAvgNs(self: *const BaselineData, name: []const u8) ?u64 {
        if (self.entries.get(name)) |entry| {
            return entry.avg_ns;
        }
        return null;
    }
};

// Save benchmark results to a baseline file
// Format: name=avg_ns|mem:stat_name=bytes|mem:stat_name2=bytes2
pub fn saveBaseline(file_path: []const u8, results: []const BenchResult) !void {
    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();

    var write_buf: [4096]u8 = undefined;
    var file_writer = file.writer(&write_buf);
    const writer = &file_writer.interface;
    for (results) |result| {
        try writer.print("{s}={d}", .{ result.name, result.avg_ns });

        // Append memory stats if present
        if (result.mem_stats) |stats| {
            for (stats) |stat| {
                try writer.print("|mem:{s}={d}", .{ stat.name, stat.bytes });
            }
        }
        try writer.writeByte('\n');
    }
    try writer.flush();
}

// Load baseline from file
// Parses format: name=avg_ns|mem:stat_name=bytes|mem:stat_name2=bytes2
// Backward-compatible with old format (name=avg_ns)
pub fn loadBaseline(allocator: std.mem.Allocator, file_path: []const u8) !BaselineData {
    var baseline = BaselineData.init(allocator);
    errdefer baseline.deinit();

    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return baseline; // Return empty baseline if file doesn't exist
        }
        return err;
    };
    defer file.close();

    const contents = file.readToEndAlloc(allocator, 1024 * 1024) catch return baseline;
    defer allocator.free(contents);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        // Split by pipe to separate main entry from memory stats
        var pipe_iter = std.mem.splitScalar(u8, line, '|');
        const main_part = pipe_iter.first();

        // Parse "name=avg_ns" from main part (use lastIndexOf since names may contain '=')
        if (std.mem.lastIndexOfScalar(u8, main_part, '=')) |eq_pos| {
            const name = main_part[0..eq_pos];
            const value_str = main_part[eq_pos + 1 ..];
            const avg_ns = std.fmt.parseInt(u64, value_str, 10) catch continue;

            // Parse memory stats from remaining pipe-separated parts
            var mem_stats_list: std.ArrayListUnmanaged(MemStat) = .{};
            defer mem_stats_list.deinit(allocator);

            while (pipe_iter.next()) |mem_part| {
                // Expected format: mem:stat_name=bytes
                if (std.mem.startsWith(u8, mem_part, "mem:")) {
                    const mem_content = mem_part[4..]; // Skip "mem:"
                    if (std.mem.indexOf(u8, mem_content, "=")) |mem_eq_pos| {
                        const stat_name = mem_content[0..mem_eq_pos];
                        const bytes_str = mem_content[mem_eq_pos + 1 ..];
                        const bytes = std.fmt.parseInt(usize, bytes_str, 10) catch continue;

                        // Dupe the stat name for storage
                        const owned_stat_name = try allocator.dupe(u8, stat_name);
                        try mem_stats_list.append(allocator, .{
                            .name = owned_stat_name,
                            .bytes = bytes,
                        });
                    }
                }
            }

            // Convert to owned slice if we have any memory stats
            const mem_stats: ?[]const MemStat = if (mem_stats_list.items.len > 0)
                try mem_stats_list.toOwnedSlice(allocator)
            else
                null;

            try baseline.put(name, avg_ns, mem_stats);

            // Free the temporary mem_stats slice (baseline.put dupes everything)
            if (mem_stats) |stats| {
                for (stats) |stat| {
                    allocator.free(@constCast(stat.name));
                }
                allocator.free(stats);
            }
        }
    }

    return baseline;
}

// Memory comparison result for a single stat
pub const MemCompareResult = struct {
    name: []const u8,
    baseline_bytes: usize,
    current_bytes: usize,
    change_percent: f64, // positive = regression, negative = improvement
    is_regression: bool,
};

// Comparison result for a single benchmark
pub const CompareResult = struct {
    name: []const u8,
    baseline_ns: u64,
    current_ns: u64,
    change_percent: f64, // positive = regression, negative = improvement
    is_regression: bool,
    mem_comparisons: ?[]const MemCompareResult, // optional memory stat comparisons
};

// Compare current results against baseline
pub fn compareWithBaseline(
    allocator: std.mem.Allocator,
    results: []const BenchResult,
    baseline: *const BaselineData,
    threshold_percent: f64,
) !struct { comparisons: []CompareResult, has_regression: bool, has_mem_regression: bool } {
    var comparisons: std.ArrayListUnmanaged(CompareResult) = .{};
    var has_regression = false;
    var has_mem_regression = false;

    for (results) |result| {
        if (baseline.get(result.name)) |baseline_entry| {
            const baseline_ns = baseline_entry.avg_ns;
            const current_ns = result.avg_ns;
            const change = @as(f64, @floatFromInt(current_ns)) - @as(f64, @floatFromInt(baseline_ns));
            const change_percent = (change / @as(f64, @floatFromInt(baseline_ns))) * 100.0;
            const is_regression = change_percent > threshold_percent;

            if (is_regression) has_regression = true;

            // Compare memory stats if both have them
            var mem_comparisons: ?[]const MemCompareResult = null;
            if (result.mem_stats != null and baseline_entry.mem_stats != null) {
                var mem_list: std.ArrayListUnmanaged(MemCompareResult) = .{};

                for (result.mem_stats.?) |current_stat| {
                    if (baseline_entry.mem_stats.?.get(current_stat.name)) |baseline_bytes| {
                        const current_bytes = current_stat.bytes;
                        const mem_change = @as(f64, @floatFromInt(current_bytes)) - @as(f64, @floatFromInt(baseline_bytes));
                        const mem_change_percent: f64 = if (baseline_bytes > 0)
                            (mem_change / @as(f64, @floatFromInt(baseline_bytes))) * 100.0
                        else if (current_bytes > 0)
                            100.0 // New allocation where there was none
                        else
                            0.0;
                        const mem_is_regression = mem_change_percent > threshold_percent;

                        if (mem_is_regression) has_mem_regression = true;

                        try mem_list.append(allocator, .{
                            .name = current_stat.name,
                            .baseline_bytes = baseline_bytes,
                            .current_bytes = current_bytes,
                            .change_percent = mem_change_percent,
                            .is_regression = mem_is_regression,
                        });
                    }
                }

                if (mem_list.items.len > 0) {
                    mem_comparisons = try mem_list.toOwnedSlice(allocator);
                } else {
                    mem_list.deinit(allocator);
                }
            }

            try comparisons.append(allocator, .{
                .name = result.name,
                .baseline_ns = baseline_ns,
                .current_ns = current_ns,
                .change_percent = change_percent,
                .is_regression = is_regression,
                .mem_comparisons = mem_comparisons,
            });
        }
    }

    return .{
        .comparisons = try comparisons.toOwnedSlice(allocator),
        .has_regression = has_regression,
        .has_mem_regression = has_mem_regression,
    };
}

// Print comparison results
pub fn printComparison(writer: anytype, comparisons: []const CompareResult, threshold_percent: f64, has_mem_regression: bool) !void {
    if (comparisons.len == 0) {
        try writer.writeAll("\nNo baseline comparisons available.\n");
        return;
    }

    try writer.writeAll("\n\x1b[36m=== Baseline Comparison ===\x1b[0m\n\n");
    try writer.print("Threshold: {d:.1}% regression tolerance\n\n", .{threshold_percent});

    // Calculate column widths
    var max_name_len: usize = 20;
    for (comparisons) |c| {
        if (c.name.len > max_name_len) max_name_len = c.name.len;
    }

    // Header
    try writer.writeAll("\x1b[2m");
    try writer.splatByteAll('-', max_name_len + 50);
    try writer.writeAll("\x1b[0m\n");
    try writer.writeAll("\x1b[36mBenchmark");
    try writer.splatByteAll(' ', max_name_len - 9);
    try writer.writeAll("\x1b[0m\x1b[2m | \x1b[0m");
    try writer.writeAll("\x1b[36mBaseline\x1b[0m\x1b[2m | \x1b[0m");
    try writer.writeAll("\x1b[36mCurrent\x1b[0m\x1b[2m | \x1b[0m");
    try writer.writeAll("\x1b[36mChange\x1b[0m\n");
    try writer.writeAll("\x1b[2m");
    try writer.splatByteAll('-', max_name_len + 50);
    try writer.writeAll("\x1b[0m\n");

    var regressions: usize = 0;
    var improvements: usize = 0;
    var mem_regressions: usize = 0;
    var mem_improvements: usize = 0;

    for (comparisons) |c| {
        try writer.writeAll(c.name);
        try writer.splatByteAll(' ', max_name_len - c.name.len);
        try writer.writeAll("\x1b[2m | \x1b[0m");

        const base_fmt = formatDuration(c.baseline_ns);
        const curr_fmt = formatDuration(c.current_ns);

        var base_buf: [32]u8 = undefined;
        const base_str = try std.fmt.bufPrint(&base_buf, "{d:.2}{s}", .{ base_fmt.value, base_fmt.unit });
        try writer.splatByteAll(' ', 8 - @min(base_str.len, 8));
        try writer.writeAll(base_str);
        try writer.writeAll("\x1b[2m | \x1b[0m");

        var curr_buf: [32]u8 = undefined;
        const curr_str = try std.fmt.bufPrint(&curr_buf, "{d:.2}{s}", .{ curr_fmt.value, curr_fmt.unit });
        try writer.splatByteAll(' ', 8 - @min(curr_str.len, 8));
        try writer.writeAll(curr_str);
        try writer.writeAll("\x1b[2m | \x1b[0m");

        // Color-coded change
        if (c.is_regression) {
            try writer.writeAll("\x1b[31m"); // Red for regression
            regressions += 1;
        } else if (c.change_percent < -5.0) {
            try writer.writeAll("\x1b[32m"); // Green for significant improvement
            improvements += 1;
        } else {
            try writer.writeAll("\x1b[33m"); // Yellow for minor change
        }

        if (c.change_percent >= 0) {
            try writer.print("+{d:.1}%", .{c.change_percent});
        } else {
            try writer.print("{d:.1}%", .{c.change_percent});
        }
        try writer.writeAll("\x1b[0m");

        if (c.is_regression) {
            try writer.writeAll(" \x1b[31m[REGRESSION]\x1b[0m");
        }
        try writer.writeByte('\n');

        // Print memory comparisons if present (indented)
        if (c.mem_comparisons) |mem_comps| {
            for (mem_comps) |mc| {
                try writer.writeAll("  \x1b[2m└─ ");
                try writer.writeAll(mc.name);
                try writer.writeAll(": \x1b[0m");

                const base_mem = formatBytes(mc.baseline_bytes);
                const curr_mem = formatBytes(mc.current_bytes);

                var base_mem_buf: [32]u8 = undefined;
                const base_mem_str = try std.fmt.bufPrint(&base_mem_buf, "{d:.2} {s}", .{ base_mem.value, base_mem.unit });
                try writer.writeAll(base_mem_str);
                try writer.writeAll(" → ");

                var curr_mem_buf: [32]u8 = undefined;
                const curr_mem_str = try std.fmt.bufPrint(&curr_mem_buf, "{d:.2} {s}", .{ curr_mem.value, curr_mem.unit });
                try writer.writeAll(curr_mem_str);
                try writer.writeAll(" (");

                if (mc.is_regression) {
                    try writer.writeAll("\x1b[31m");
                    mem_regressions += 1;
                } else if (mc.change_percent < -5.0) {
                    try writer.writeAll("\x1b[32m");
                    mem_improvements += 1;
                } else {
                    try writer.writeAll("\x1b[33m");
                }

                if (mc.change_percent >= 0) {
                    try writer.print("+{d:.1}%", .{mc.change_percent});
                } else {
                    try writer.print("{d:.1}%", .{mc.change_percent});
                }
                try writer.writeAll("\x1b[0m)");

                if (mc.is_regression) {
                    try writer.writeAll(" \x1b[31m[MEM REGRESSION]\x1b[0m");
                }
                try writer.writeByte('\n');
            }
        }
    }

    try writer.writeAll("\x1b[2m");
    try writer.splatByteAll('-', max_name_len + 50);
    try writer.writeAll("\x1b[0m\n");

    // Summary
    try writer.print("\nTiming: {d} regressions, {d} improvements, {d} unchanged\n", .{
        regressions,
        improvements,
        comparisons.len - regressions - improvements,
    });

    if (mem_regressions > 0 or mem_improvements > 0) {
        try writer.print("Memory: {d} regressions, {d} improvements\n", .{
            mem_regressions,
            mem_improvements,
        });
    }

    if (regressions > 0 or has_mem_regression) {
        if (regressions > 0 and has_mem_regression) {
            try writer.writeAll("\x1b[31m✗ Performance and memory regressions detected!\x1b[0m\n");
        } else if (regressions > 0) {
            try writer.writeAll("\x1b[31m✗ Performance regressions detected!\x1b[0m\n");
        } else {
            try writer.writeAll("\x1b[31m✗ Memory regressions detected!\x1b[0m\n");
        }
    } else {
        try writer.writeAll("\x1b[32m✓ No regressions detected\x1b[0m\n");
    }
}

// Print comparison as JSON
pub fn printComparisonJson(writer: anytype, comparisons: []const CompareResult, has_regression: bool, has_mem_regression: bool) !void {
    try writer.writeAll("{\"comparisons\":[");
    for (comparisons, 0..) |c, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{{\"name\":\"{s}\",\"baseline_ns\":{d},\"current_ns\":{d},\"change_percent\":{d:.2},\"is_regression\":{}", .{
            c.name,
            c.baseline_ns,
            c.current_ns,
            c.change_percent,
            c.is_regression,
        });

        // Add memory comparisons if present
        if (c.mem_comparisons) |mem_comps| {
            try writer.writeAll(",\"mem_comparisons\":[");
            for (mem_comps, 0..) |mc, j| {
                if (j > 0) try writer.writeByte(',');
                try writer.print("{{\"name\":\"{s}\",\"baseline_bytes\":{d},\"current_bytes\":{d},\"change_percent\":{d:.2},\"is_regression\":{}}}", .{
                    mc.name,
                    mc.baseline_bytes,
                    mc.current_bytes,
                    mc.change_percent,
                    mc.is_regression,
                });
            }
            try writer.writeByte(']');
        }
        try writer.writeByte('}');
    }
    try writer.print("],\"has_regression\":{},\"has_mem_regression\":{}}}\n", .{ has_regression, has_mem_regression });
}
