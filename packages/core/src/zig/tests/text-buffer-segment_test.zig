const std = @import("std");
const testing = std.testing;
const seg_mod = @import("../text-buffer-segment.zig");
const mem_registry_mod = @import("../mem-registry.zig");
const utf8 = @import("../utf8.zig");

const Segment = seg_mod.Segment;
const UnifiedRope = seg_mod.UnifiedRope;
const TextChunk = seg_mod.TextChunk;
const MemRegistry = mem_registry_mod.MemRegistry;
const LayoutCacheMode = seg_mod.LayoutCacheMode;
const LayoutSpanScratch = seg_mod.LayoutSpanScratch;

const SpanCollection = struct {
    allocator: std.mem.Allocator,
    spans: std.ArrayListUnmanaged(seg_mod.GraphemeSpan) = .{},

    fn deinit(self: *SpanCollection) void {
        self.spans.deinit(self.allocator);
    }
};

fn collectSpan(ctx_ptr: *anyopaque, span: seg_mod.GraphemeSpan) anyerror!void {
    const ctx = @as(*SpanCollection, @ptrCast(@alignCast(ctx_ptr)));
    try ctx.spans.append(ctx.allocator, span);
}

fn buildRepeatedText(allocator: std.mem.Allocator, pattern: []const u8, repetitions: usize) ![]u8 {
    var text: std.ArrayListUnmanaged(u8) = .{};
    errdefer text.deinit(allocator);

    for (0..repetitions) |_| {
        try text.appendSlice(allocator, pattern);
    }

    return text.toOwnedSlice(allocator);
}

fn collectChunkSpansWithMode(
    chunk: *const TextChunk,
    registry: *const MemRegistry,
    allocator: std.mem.Allocator,
    tab_width: u8,
    width_method: utf8.WidthMethod,
    mode: LayoutCacheMode,
    include_breaks: bool,
) ![]const seg_mod.GraphemeSpan {
    var chunk_copy = chunk.*;
    chunk_copy.layout_spans = null;
    chunk_copy.layout_cache_allocator = null;
    chunk_copy.layout_cache_valid = true;
    chunk_copy.layout_cache_tab_width = tab_width;
    chunk_copy.layout_cache_width_method = width_method;
    chunk_copy.layout_cache_mode = mode;

    var scratch = LayoutSpanScratch.init();
    var collection = SpanCollection{ .allocator = allocator };
    errdefer collection.deinit();

    if (include_breaks) {
        try chunk_copy.forEachLayoutSpans(registry, allocator, tab_width, width_method, &scratch, &collection, collectSpan);
    } else {
        try chunk_copy.forEachLayoutSpansNoBreaks(registry, allocator, tab_width, width_method, &scratch, &collection, collectSpan);
    }

    return collection.spans.toOwnedSlice(allocator);
}

fn collectChunkRangeSpansWithMode(
    chunk: *const TextChunk,
    registry: *const MemRegistry,
    allocator: std.mem.Allocator,
    tab_width: u8,
    width_method: utf8.WidthMethod,
    mode: LayoutCacheMode,
    range: seg_mod.LayoutSpanRange,
) ![]const seg_mod.GraphemeSpan {
    var chunk_copy = chunk.*;
    chunk_copy.layout_spans = null;
    chunk_copy.layout_cache_allocator = null;
    chunk_copy.layout_cache_valid = true;
    chunk_copy.layout_cache_tab_width = tab_width;
    chunk_copy.layout_cache_width_method = width_method;
    chunk_copy.layout_cache_mode = mode;

    var scratch = LayoutSpanScratch.init();
    var collection = SpanCollection{ .allocator = allocator };
    errdefer collection.deinit();

    try chunk_copy.forEachLayoutSpansRangeNoBreaks(
        registry,
        allocator,
        tab_width,
        width_method,
        range,
        &scratch,
        &collection,
        collectSpan,
    );

    return collection.spans.toOwnedSlice(allocator);
}

fn rangeForSpanSlice(spans: []const seg_mod.GraphemeSpan, start_idx: usize, end_idx_exclusive: usize) seg_mod.LayoutSpanRange {
    std.debug.assert(start_idx < end_idx_exclusive);
    std.debug.assert(end_idx_exclusive <= spans.len);

    const start_span = spans[start_idx];
    const end_span = spans[end_idx_exclusive - 1];

    return .{
        .byte_start = start_span.byte_start,
        .byte_end = end_span.byte_start + end_span.byte_len,
        .col_start = start_span.col_start,
        .col_end = end_span.col_start + end_span.col_width,
    };
}

test "Segment.measure - text chunk" {
    const chunk = TextChunk{
        .mem_id = 0,
        .byte_start = 0,
        .byte_end = 10,
        .width = 10,
        .flags = TextChunk.Flags.ASCII_ONLY,
    };
    const seg = Segment{ .text = chunk };
    const metrics = seg.measure();

    try testing.expectEqual(@as(u32, 10), metrics.total_width);
    try testing.expectEqual(@as(u32, 10), metrics.max_line_width);
    try testing.expect(metrics.ascii_only);
}

test "Segment.measure - break" {
    const seg = Segment{ .brk = {} };
    const metrics = seg.measure();

    try testing.expectEqual(@as(u32, 0), metrics.total_width);
    try testing.expectEqual(@as(u32, 0), metrics.max_line_width);
    try testing.expect(metrics.ascii_only);
}

test "Segment.empty and is_empty" {
    const seg = Segment.empty();
    try testing.expect(seg.is_empty());
}

test "Segment.isBreak and isText" {
    const text_seg = Segment{
        .text = TextChunk{
            .mem_id = 0,
            .byte_start = 0,
            .byte_end = 10,
            .width = 10,
            .flags = 0,
        },
    };
    try testing.expect(text_seg.isText());
    try testing.expect(!text_seg.isBreak());

    const brk_seg = Segment{ .brk = {} };
    try testing.expect(brk_seg.isBreak());
    try testing.expect(!brk_seg.isText());
}

test "Segment.asText" {
    const chunk = TextChunk{
        .mem_id = 0,
        .byte_start = 0,
        .byte_end = 10,
        .width = 10,
        .flags = 0,
    };
    const text_seg = Segment{ .text = chunk };
    const retrieved = text_seg.asText();
    try testing.expect(retrieved != null);
    try testing.expectEqual(@as(u32, 10), retrieved.?.width);

    const brk_seg = Segment{ .brk = {} };
    try testing.expect(brk_seg.asText() == null);
}

test "TextChunk.getLayoutSpans caches canonical spans" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = MemRegistry.init(testing.allocator);
    defer registry.deinit();

    const text = "가\ta-b";
    const mem_id = try registry.register(text, false);
    var chunk = TextChunk{
        .mem_id = mem_id,
        .byte_start = 0,
        .byte_end = @intCast(text.len),
        .width = @intCast(utf8.calculateTextWidth(text, 4, false, .unicode)),
        .flags = 0,
    };

    const first = try chunk.getLayoutSpans(&registry, allocator, 4, .unicode);
    const second = try chunk.getLayoutSpans(&registry, allocator, 4, .unicode);

    try testing.expectEqual(first.ptr, second.ptr);
    try testing.expectEqual(LayoutCacheMode.full_cache, chunk.layout_cache_mode);
    try testing.expectEqual(@as(u8, 4), chunk.layout_cache_tab_width);
    try testing.expectEqual(utf8.WidthMethod.unicode, chunk.layout_cache_width_method);
    try testing.expectEqual(@as(usize, 5), first.len);

    try testing.expectEqual(@as(u32, 0), first[0].byte_start);
    try testing.expectEqual(@as(u32, 3), first[0].byte_len);
    try testing.expectEqual(@as(u32, 0), first[0].col_start);
    try testing.expectEqual(@as(u16, 2), first[0].col_width);
    try testing.expectEqual(utf8.BreakKind.none, first[0].break_after);

    try testing.expectEqual(@as(u32, 3), first[1].byte_start);
    try testing.expectEqual(@as(u32, 1), first[1].byte_len);
    try testing.expectEqual(@as(u32, 2), first[1].col_start);
    try testing.expectEqual(@as(u16, 4), first[1].col_width);
    try testing.expectEqual(utf8.BreakKind.whitespace, first[1].break_after);

    try testing.expectEqual(utf8.BreakKind.none, first[2].break_after);
    try testing.expectEqual(utf8.BreakKind.punctuation, first[3].break_after);
    try testing.expectEqual(utf8.BreakKind.none, first[4].break_after);
}

test "TextChunk.getLayoutSpans invalidates cache on tab width and width method changes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = MemRegistry.init(testing.allocator);
    defer registry.deinit();

    const text = "a\tb👩‍🚀";
    const mem_id = try registry.register(text, false);
    var chunk = TextChunk{
        .mem_id = mem_id,
        .byte_start = 0,
        .byte_end = @intCast(text.len),
        .width = @intCast(utf8.calculateTextWidth(text, 4, false, .unicode)),
        .flags = 0,
    };

    const tab4 = try chunk.getLayoutSpans(&registry, allocator, 4, .unicode);
    const tab8 = try chunk.getLayoutSpans(&registry, allocator, 8, .unicode);
    const wcwidth = try chunk.getLayoutSpans(&registry, allocator, 8, .wcwidth);

    try testing.expect(tab4.ptr != tab8.ptr);
    try testing.expect(tab8.ptr != wcwidth.ptr);
    try testing.expectEqual(@as(u16, 4), tab4[1].col_width);
    try testing.expectEqual(@as(u16, 8), tab8[1].col_width);
    try testing.expectEqual(utf8.WidthMethod.wcwidth, chunk.layout_cache_width_method);
    try testing.expectEqual(@as(u8, 8), chunk.layout_cache_tab_width);
}

test "TextChunk.forEachLayoutSpans full cache and windowed modes match across width methods" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = MemRegistry.init(testing.allocator);
    defer registry.deinit();

    const text = try buildRepeatedText(allocator, "Hello 世界\t👩‍🚀-abc/가나다 path-breaks ", 96);
    const mem_id = try registry.register(text, false);
    const chunk = TextChunk{
        .mem_id = mem_id,
        .byte_start = 0,
        .byte_end = @intCast(text.len),
        .width = @intCast(utf8.calculateTextWidth(text, 4, false, .unicode)),
        .flags = 0,
    };

    for ([_]utf8.WidthMethod{ .wcwidth, .unicode, .no_zwj }) |width_method| {
        const full = try collectChunkSpansWithMode(&chunk, &registry, allocator, 4, width_method, .full_cache, true);
        const windowed = try collectChunkSpansWithMode(&chunk, &registry, allocator, 4, width_method, .windowed, true);
        const windowed_no_breaks = try collectChunkSpansWithMode(&chunk, &registry, allocator, 4, width_method, .windowed, false);

        try testing.expectEqual(full.len, windowed.len);
        try testing.expectEqual(full.len, windowed_no_breaks.len);

        for (full, 0..) |span, idx| {
            try testing.expectEqualDeep(span, windowed[idx]);

            var expected_no_break = span;
            expected_no_break.break_after = .none;
            try testing.expectEqualDeep(expected_no_break, windowed_no_breaks[idx]);
        }
    }
}

test "TextChunk.forEachLayoutSpansRangeNoBreaks full cache and windowed modes match" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = MemRegistry.init(testing.allocator);
    defer registry.deinit();

    const text = try buildRepeatedText(allocator, "Hello 世界\t👩‍🚀-abc/가나다 path-breaks ", 96);
    const mem_id = try registry.register(text, false);
    const chunk = TextChunk{
        .mem_id = mem_id,
        .byte_start = 0,
        .byte_end = @intCast(text.len),
        .width = @intCast(utf8.calculateTextWidth(text, 4, false, .unicode)),
        .flags = 0,
    };

    for ([_]utf8.WidthMethod{ .wcwidth, .unicode, .no_zwj }) |width_method| {
        const full_no_breaks = try collectChunkSpansWithMode(&chunk, &registry, allocator, 4, width_method, .full_cache, false);
        try testing.expect(full_no_breaks.len > 32);

        const start_idx = full_no_breaks.len / 4;
        const end_idx = @min(start_idx + 96, full_no_breaks.len);
        const range = rangeForSpanSlice(full_no_breaks, start_idx, end_idx);

        const full_range = try collectChunkRangeSpansWithMode(&chunk, &registry, allocator, 4, width_method, .full_cache, range);
        const windowed_range = try collectChunkRangeSpansWithMode(&chunk, &registry, allocator, 4, width_method, .windowed, range);

        try testing.expectEqual(end_idx - start_idx, full_range.len);
        try testing.expectEqual(full_range.len, windowed_range.len);

        for (full_range, 0..) |span, idx| {
            const expected = full_no_breaks[start_idx + idx];
            try testing.expectEqualDeep(expected, span);
            try testing.expectEqualDeep(span, windowed_range[idx]);
            try testing.expectEqual(utf8.BreakKind.none, span.break_after);
        }
    }
}

test "TextChunk.forEachLayoutSpansRangeNoBreaks reuses shared scratch across adjacent ranges" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = MemRegistry.init(testing.allocator);
    defer registry.deinit();

    const text = try buildRepeatedText(allocator, "abcdefghijklmnopqrstuvwxyz0123456789", 256);
    const mem_id = try registry.register(text, false);
    var chunk = TextChunk{
        .mem_id = mem_id,
        .byte_start = 0,
        .byte_end = @intCast(text.len),
        .width = @intCast(text.len),
        .flags = TextChunk.Flags.ASCII_ONLY,
        .layout_cache_valid = true,
        .layout_cache_tab_width = 4,
        .layout_cache_width_method = .unicode,
        .layout_cache_mode = .windowed,
    };

    const full_no_breaks = try collectChunkSpansWithMode(&chunk, &registry, allocator, 4, .unicode, .full_cache, false);
    try testing.expect(full_no_breaks.len > 200);

    const first_start: usize = 32;
    const first_end: usize = 96;
    const second_start: usize = first_end;
    const second_end: usize = 192;

    const first_range = rangeForSpanSlice(full_no_breaks, first_start, first_end);
    const second_range = rangeForSpanSlice(full_no_breaks, second_start, second_end);

    var scratch = LayoutSpanScratch.init();
    var collection = SpanCollection{ .allocator = allocator };
    defer collection.deinit();

    try chunk.forEachLayoutSpansRangeNoBreaks(&registry, allocator, 4, .unicode, first_range, &scratch, &collection, collectSpan);
    try chunk.forEachLayoutSpansRangeNoBreaks(&registry, allocator, 4, .unicode, second_range, &scratch, &collection, collectSpan);

    const expected_len = (first_end - first_start) + (second_end - second_start);
    try testing.expectEqual(expected_len, collection.spans.items.len);

    var idx: usize = 0;
    while (idx < first_end - first_start) : (idx += 1) {
        const expected = full_no_breaks[first_start + idx];
        try testing.expectEqualDeep(expected, collection.spans.items[idx]);
    }

    var second_idx: usize = 0;
    while (second_idx < second_end - second_start) : (second_idx += 1) {
        const expected = full_no_breaks[second_start + second_idx];
        try testing.expectEqualDeep(expected, collection.spans.items[(first_end - first_start) + second_idx]);
    }
}

test "TextChunk legacy metadata projections derive from canonical spans" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = MemRegistry.init(testing.allocator);
    defer registry.deinit();

    const cases = [_]struct {
        text: []const u8,
        tab_width: u8,
        is_ascii_only: bool,
    }{
        .{ .text = "hello\tworld", .tab_width = 4, .is_ascii_only = false },
        .{ .text = "Hello 世界-👩‍🚀/abc", .tab_width = 4, .is_ascii_only = false },
        .{ .text = "ASCII punctuation - / brackets []", .tab_width = 4, .is_ascii_only = true },
    };

    for (cases) |case| {
        const mem_id = try registry.register(case.text, false);
        var chunk = TextChunk{
            .mem_id = mem_id,
            .byte_start = 0,
            .byte_end = @intCast(case.text.len),
            .width = @intCast(utf8.calculateTextWidth(case.text, case.tab_width, case.is_ascii_only, .unicode)),
            .flags = if (case.is_ascii_only) TextChunk.Flags.ASCII_ONLY else 0,
        };

        for ([_]utf8.WidthMethod{ .wcwidth, .unicode, .no_zwj }) |width_method| {
            var legacy_wrap = utf8.WrapBreakResult.init(allocator);
            defer legacy_wrap.deinit();
            try utf8.findWrapBreaks(case.text, &legacy_wrap, width_method);

            const projected_wrap = try chunk.getWrapOffsets(&registry, allocator, case.tab_width, width_method);
            try testing.expectEqual(legacy_wrap.breaks.items.len, projected_wrap.len);
            for (legacy_wrap.breaks.items, projected_wrap) |expected_break, actual_break| {
                try testing.expectEqual(expected_break.byte_offset, actual_break.byte_offset);
                if (width_method != .no_zwj) {
                    try testing.expectEqual(expected_break.char_offset, actual_break.char_offset);
                }
            }

            var legacy_graphemes: std.ArrayListUnmanaged(utf8.GraphemeInfo) = .{};
            defer legacy_graphemes.deinit(allocator);
            try utf8.findGraphemeInfo(case.text, case.tab_width, case.is_ascii_only, width_method, allocator, &legacy_graphemes);

            const projected_graphemes = try chunk.getGraphemes(&registry, allocator, case.tab_width, width_method);
            try testing.expectEqual(legacy_graphemes.items.len, projected_graphemes.len);
            for (legacy_graphemes.items, projected_graphemes) |expected_grapheme, actual_grapheme| {
                try testing.expectEqualDeep(expected_grapheme, actual_grapheme);
            }
        }
    }
}

test "TextChunk.forEachLayoutSpans keeps large ASCII chunks windowed by default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = MemRegistry.init(testing.allocator);
    defer registry.deinit();

    const text = try buildRepeatedText(allocator, "abcdefghijklmnopqrstuvwxyz0123456789", 12);
    const mem_id = try registry.register(text, false);
    var chunk = TextChunk{
        .mem_id = mem_id,
        .byte_start = 0,
        .byte_end = @intCast(text.len),
        .width = @intCast(text.len),
        .flags = TextChunk.Flags.ASCII_ONLY,
    };

    var scratch = LayoutSpanScratch.init();
    var collection = SpanCollection{ .allocator = allocator };
    defer collection.deinit();

    try chunk.forEachLayoutSpans(&registry, allocator, 4, .unicode, &scratch, &collection, collectSpan);

    try testing.expectEqual(LayoutCacheMode.windowed, chunk.layout_cache_mode);
    try testing.expectEqual(@as(?[]const seg_mod.GraphemeSpan, null), chunk.layout_spans);
    try testing.expectEqual(text.len, collection.spans.items.len);
}

test "Metrics.add - two text segments" {
    var left = Segment.Metrics{
        .total_width = 10,
        .max_line_width = 10,
        .ascii_only = true,
    };

    const right = Segment.Metrics{
        .total_width = 5,
        .max_line_width = 5,
        .ascii_only = true,
    };

    left.add(right);

    try testing.expectEqual(@as(u32, 15), left.total_width);
    try testing.expectEqual(@as(u32, 10), left.max_line_width);
    try testing.expect(left.ascii_only);
}

test "Metrics.add - text, break, text" {
    var left = Segment.Metrics{
        .total_width = 10,
        .max_line_width = 10,
        .ascii_only = true,
    };

    const middle = Segment.Metrics{
        .total_width = 0,
        .max_line_width = 0,
        .ascii_only = true,
    };

    left.add(middle);

    try testing.expectEqual(@as(u32, 10), left.total_width);
    try testing.expectEqual(@as(u32, 10), left.max_line_width);

    const right = Segment.Metrics{
        .total_width = 5,
        .max_line_width = 5,
        .ascii_only = true,
    };

    left.add(right);

    try testing.expectEqual(@as(u32, 15), left.total_width);
    try testing.expectEqual(@as(u32, 10), left.max_line_width);
}

test "Metrics.add - multiple breaks" {
    var metrics = Segment.Metrics{
        .total_width = 10,
        .max_line_width = 10,
        .ascii_only = true,
    };

    metrics.add(Segment.Metrics{
        .total_width = 0,
        .max_line_width = 0,
        .ascii_only = true,
    });

    metrics.add(Segment.Metrics{
        .total_width = 20,
        .max_line_width = 20,
        .ascii_only = true,
    });

    try testing.expectEqual(@as(u32, 30), metrics.total_width);
    try testing.expectEqual(@as(u32, 20), metrics.max_line_width);

    metrics.add(Segment.Metrics{
        .total_width = 0,
        .max_line_width = 0,
        .ascii_only = true,
    });

    metrics.add(Segment.Metrics{
        .total_width = 5,
        .max_line_width = 5,
        .ascii_only = true,
    });

    try testing.expectEqual(@as(u32, 35), metrics.total_width);
    try testing.expectEqual(@as(u32, 20), metrics.max_line_width);
}

test "Metrics.add - non-ASCII propagation" {
    var left = Segment.Metrics{
        .total_width = 10,
        .max_line_width = 10,
        .ascii_only = true,
    };

    const right = Segment.Metrics{
        .total_width = 5,
        .max_line_width = 5,
        .ascii_only = false,
    };

    left.add(right);
    try testing.expect(!left.ascii_only);
}

test "UnifiedRope - basic operations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var rope = try UnifiedRope.init(allocator);

    const text1 = Segment{
        .text = TextChunk{
            .mem_id = 0,
            .byte_start = 0,
            .byte_end = 10,
            .width = 10,
            .flags = TextChunk.Flags.ASCII_ONLY,
        },
    };
    try rope.append(text1);

    const brk = Segment{ .brk = {} };
    try rope.append(brk);

    const text2 = Segment{
        .text = TextChunk{
            .mem_id = 0,
            .byte_start = 10,
            .byte_end = 15,
            .width = 5,
            .flags = TextChunk.Flags.ASCII_ONLY,
        },
    };
    try rope.append(text2);

    const metrics = rope.root.metrics();
    try testing.expectEqual(@as(u32, 5), rope.count());
    try testing.expectEqual(@as(u32, 15), metrics.custom.total_width);
    try testing.expectEqual(@as(u32, 10), metrics.custom.max_line_width);
}

test "UnifiedRope - empty rope metrics" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rope = try UnifiedRope.init(allocator);
    const metrics = rope.root.metrics();

    try testing.expectEqual(@as(u32, 1), rope.count());
    try testing.expectEqual(@as(u32, 0), metrics.custom.total_width);
}

test "UnifiedRope - single text segment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var rope = try UnifiedRope.init(allocator);
    try rope.append(Segment{
        .text = TextChunk{
            .mem_id = 0,
            .byte_start = 0,
            .byte_end = 20,
            .width = 20,
            .flags = 0,
        },
    });

    const metrics = rope.root.metrics();
    try testing.expectEqual(@as(u32, 2), rope.count());
    try testing.expectEqual(@as(u32, 20), metrics.custom.total_width);
    try testing.expectEqual(@as(u32, 20), metrics.custom.max_line_width);
}

test "UnifiedRope - multiple lines with varying widths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var rope = try UnifiedRope.init(allocator);

    try rope.append(Segment{
        .text = TextChunk{
            .mem_id = 0,
            .byte_start = 0,
            .byte_end = 10,
            .width = 10,
            .flags = 0,
        },
    });
    try rope.append(Segment{ .brk = {} });

    try rope.append(Segment{
        .text = TextChunk{
            .mem_id = 0,
            .byte_start = 10,
            .byte_end = 40,
            .width = 30,
            .flags = 0,
        },
    });
    try rope.append(Segment{ .brk = {} });

    try rope.append(Segment{
        .text = TextChunk{
            .mem_id = 0,
            .byte_start = 40,
            .byte_end = 55,
            .width = 15,
            .flags = 0,
        },
    });

    const metrics = rope.root.metrics();
    try testing.expectEqual(@as(u32, 8), rope.count());
    try testing.expectEqual(@as(u32, 55), metrics.custom.total_width);
    try testing.expectEqual(@as(u32, 30), metrics.custom.max_line_width);
}

fn combineMetrics(left: Segment.Metrics, right: Segment.Metrics) Segment.Metrics {
    var result = left;
    result.add(right);
    return result;
}

test "combineMetrics helper function" {
    const left = Segment.Metrics{
        .total_width = 10,
        .max_line_width = 10,
        .ascii_only = true,
    };

    const right = Segment.Metrics{
        .total_width = 5,
        .max_line_width = 5,
        .ascii_only = true,
    };

    const combined = combineMetrics(left, right);

    try testing.expectEqual(@as(u32, 15), combined.total_width);
    try testing.expectEqual(@as(u32, 10), combined.max_line_width);
    try testing.expect(combined.ascii_only);
}
