const std = @import("std");
const text_buffer = @import("../text-buffer.zig");
const text_buffer_view = @import("../text-buffer-view.zig");
const gp = @import("../grapheme.zig");

const TextBuffer = text_buffer.UnifiedTextBuffer;
const TextBufferView = text_buffer_view.UnifiedTextBufferView;

test "word wrap complexity - width changes are O(n)" {
    const pool = gp.initGlobalPool(std.testing.allocator);
    defer gp.deinitGlobalPool();

    const size: usize = 100_000;

    const text = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(text);
    @memset(text, 'x');

    var tb = try TextBuffer.init(std.testing.allocator, pool, .wcwidth);
    defer tb.deinit();
    try tb.setText(text);

    var view = try TextBufferView.init(std.testing.allocator, tb);
    defer view.deinit();
    view.setWrapMode(.word);

    const widths = [_]u32{ 60, 70, 80, 90, 100 };

    // Run multiple iterations and use median to reduce noise from CI variability
    const iterations = 5;
    var median_times: [widths.len]u64 = undefined;

    for (widths, 0..) |width, width_idx| {
        var iter_times: [iterations]u64 = undefined;

        for (0..iterations) |iter| {
            // Reset cache by setting a different width first
            view.setWrapWidth(50);
            _ = view.getVirtualLineCount();

            view.setWrapWidth(width);
            var timer = std.time.Timer.start() catch unreachable;
            _ = view.getVirtualLineCount();
            iter_times[iter] = timer.read();
        }

        // Sort and take median
        std.mem.sort(u64, &iter_times, {}, std.sort.asc(u64));
        median_times[width_idx] = iter_times[iterations / 2];
    }

    var min_time: u64 = std.math.maxInt(u64);
    var max_time: u64 = 0;
    for (median_times) |t| {
        min_time = @min(min_time, t);
        max_time = @max(max_time, t);
    }

    const ratio = @as(f64, @floatFromInt(max_time)) / @as(f64, @floatFromInt(min_time));

    // All times should be roughly similar since text size is constant.
    // Use a generous threshold (5x) to account for CI runner variability.
    try std.testing.expect(ratio < 5.0);
}

test "word wrap - virtual line count correctness" {
    const pool = gp.initGlobalPool(std.testing.allocator);
    defer gp.deinitGlobalPool();

    var tb = try TextBuffer.init(std.testing.allocator, pool, .wcwidth);
    defer tb.deinit();

    var view = try TextBufferView.init(std.testing.allocator, tb);
    defer view.deinit();

    const pattern = "var abc=123;function foo(){return bar+baz;}if(x>0){y=z*2;}else{y=0;}";
    const size = 10_000;
    var text = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(text);

    var i: usize = 0;
    while (i < size) {
        const remaining = size - i;
        const copy_len = @min(pattern.len, remaining);
        @memcpy(text[i .. i + copy_len], pattern[0..copy_len]);
        i += copy_len;
    }

    try tb.setText(text);
    view.setWrapMode(.word);

    view.setWrapWidth(80);
    const count_80 = view.getVirtualLineCount();

    view.setWrapWidth(100);
    const count_100 = view.getVirtualLineCount();

    view.setWrapWidth(60);
    const count_60 = view.getVirtualLineCount();

    view.setWrapWidth(80);
    const count_80_again = view.getVirtualLineCount();

    try std.testing.expect(count_80 > 100);
    try std.testing.expectEqual(count_80, count_80_again);
    try std.testing.expect(count_100 < count_80);
    try std.testing.expect(count_60 > count_80);
}

// =============================================================================
// UnifiedTextBuffer vs StaticTextBuffer Benchmark
// =============================================================================
// This benchmark compares setText and wrap times between UnifiedTextBuffer
// and StaticTextBuffer. Currently StaticTextBuffer is an alias for
// UnifiedTextBuffer, so the times should be identical. When we implement
// a dedicated StaticTextBuffer with flat storage, we expect to see
// improvements in setText time and potentially similar wrap times.

const StaticTextBuffer = text_buffer.UnifiedTextBuffer;
const StaticTextBufferView = text_buffer_view.TextBufferView;

test "benchmark - setText time: UnifiedTextBuffer vs StaticTextBuffer" {
    const pool = gp.initGlobalPool(std.testing.allocator);
    defer gp.deinitGlobalPool();

    const size: usize = 50_000;
    const pattern = "The quick brown fox jumps over the lazy dog. ";

    const text = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(text);

    var i: usize = 0;
    while (i < size) {
        const remaining = size - i;
        const copy_len = @min(pattern.len, remaining);
        @memcpy(text[i .. i + copy_len], pattern[0..copy_len]);
        i += copy_len;
    }

    const iterations = 5;

    // Benchmark UnifiedTextBuffer setText
    var unified_times: [iterations]u64 = undefined;
    for (0..iterations) |iter| {
        var tb = try TextBuffer.init(std.testing.allocator, pool, .wcwidth);
        defer tb.deinit();

        var timer = std.time.Timer.start() catch unreachable;
        try tb.setText(text);
        unified_times[iter] = timer.read();
    }

    // Benchmark StaticTextBuffer setText
    var static_times: [iterations]u64 = undefined;
    for (0..iterations) |iter| {
        var sb = try StaticTextBuffer.initWithBackend(std.testing.allocator, pool, .wcwidth, .static);
        defer sb.deinit();

        var timer = std.time.Timer.start() catch unreachable;
        try sb.setText(text);
        static_times[iter] = timer.read();
    }

    // Sort and take median for stability
    std.mem.sort(u64, &unified_times, {}, std.sort.asc(u64));
    std.mem.sort(u64, &static_times, {}, std.sort.asc(u64));

    const unified_median = unified_times[iterations / 2];
    const static_median = static_times[iterations / 2];

    // Currently they should be similar since StaticTextBuffer is an alias.
    // When StaticTextBuffer is implemented, we expect static_median < unified_median.
    // For now, just verify both complete and aren't wildly different (within 10x).
    const ratio = if (unified_median > static_median)
        @as(f64, @floatFromInt(unified_median)) / @as(f64, @floatFromInt(static_median))
    else
        @as(f64, @floatFromInt(static_median)) / @as(f64, @floatFromInt(unified_median));

    try std.testing.expect(ratio < 10.0);

    // Also verify content is identical
    var tb = try TextBuffer.init(std.testing.allocator, pool, .wcwidth);
    defer tb.deinit();
    try tb.setText(text);

    var sb = try StaticTextBuffer.initWithBackend(std.testing.allocator, pool, .wcwidth, .static);
    defer sb.deinit();
    try sb.setText(text);

    try std.testing.expectEqual(tb.lineCount(), sb.lineCount());
    try std.testing.expectEqual(tb.maxLineWidth(), sb.maxLineWidth());
}

test "benchmark - wrap time: UnifiedTextBuffer vs StaticTextBuffer" {
    const pool = gp.initGlobalPool(std.testing.allocator);
    defer gp.deinitGlobalPool();

    const size: usize = 50_000;
    const pattern = "The quick brown fox jumps over the lazy dog. ";

    const text = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(text);

    var i: usize = 0;
    while (i < size) {
        const remaining = size - i;
        const copy_len = @min(pattern.len, remaining);
        @memcpy(text[i .. i + copy_len], pattern[0..copy_len]);
        i += copy_len;
    }

    const iterations = 5;
    const wrap_width: u32 = 80;

    // Benchmark UnifiedTextBuffer wrap
    var unified_wrap_times: [iterations]u64 = undefined;
    var unified_line_count: u32 = 0;
    {
        var tb = try TextBuffer.init(std.testing.allocator, pool, .wcwidth);
        defer tb.deinit();
        try tb.setText(text);

        var view = try TextBufferView.init(std.testing.allocator, tb);
        defer view.deinit();
        view.setWrapMode(.word);

        for (0..iterations) |iter| {
            // Reset cache by setting different width
            view.setWrapWidth(50);
            _ = view.getVirtualLineCount();

            view.setWrapWidth(wrap_width);
            var timer = std.time.Timer.start() catch unreachable;
            unified_line_count = view.getVirtualLineCount();
            unified_wrap_times[iter] = timer.read();
        }
    }

    // Benchmark StaticTextBuffer wrap
    var static_wrap_times: [iterations]u64 = undefined;
    var static_line_count: u32 = 0;
    {
        var sb = try StaticTextBuffer.initWithBackend(std.testing.allocator, pool, .wcwidth, .static);
        defer sb.deinit();
        try sb.setText(text);

        var view = try StaticTextBufferView.init(std.testing.allocator, sb);
        defer view.deinit();
        view.setWrapMode(.word);

        for (0..iterations) |iter| {
            // Reset cache by setting different width
            view.setWrapWidth(50);
            _ = view.getVirtualLineCount();

            view.setWrapWidth(wrap_width);
            var timer = std.time.Timer.start() catch unreachable;
            static_line_count = view.getVirtualLineCount();
            static_wrap_times[iter] = timer.read();
        }
    }

    // Sort and take median for stability
    std.mem.sort(u64, &unified_wrap_times, {}, std.sort.asc(u64));
    std.mem.sort(u64, &static_wrap_times, {}, std.sort.asc(u64));

    const unified_median = unified_wrap_times[iterations / 2];
    const static_median = static_wrap_times[iterations / 2];

    // Wrap times should be similar (within 10x) since the algorithm is the same
    const ratio = if (unified_median > static_median)
        @as(f64, @floatFromInt(unified_median)) / @as(f64, @floatFromInt(static_median))
    else
        @as(f64, @floatFromInt(static_median)) / @as(f64, @floatFromInt(unified_median));

    try std.testing.expect(ratio < 10.0);

    // Line counts must be identical for behavioral parity
    try std.testing.expectEqual(unified_line_count, static_line_count);
}
