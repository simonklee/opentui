const std = @import("std");
const text_buffer = @import("../text-buffer.zig");
const text_buffer_view = @import("../text-buffer-view.zig");
const static_backend_mod = @import("../text-buffer-backend-static.zig");
const mem_registry_mod = @import("../mem-registry.zig");
const gp = @import("../grapheme.zig");

const StaticTextBuffer = text_buffer.UnifiedTextBuffer;
const TextBufferView = text_buffer_view.UnifiedTextBufferView;
const StaticBackend = static_backend_mod.StaticBackend;
const MemRegistry = mem_registry_mod.MemRegistry;

fn expectRangeParity(rope_tb: *text_buffer.UnifiedTextBuffer, static_tb: *text_buffer.UnifiedTextBuffer, start: u32, end: u32) !void {
    var rope_out: [256]u8 = undefined;
    var static_out: [256]u8 = undefined;

    const rope_len = rope_tb.getTextRange(start, end, &rope_out);
    const static_len = static_tb.getTextRange(start, end, &static_out);

    try std.testing.expectEqual(rope_len, static_len);
    try std.testing.expectEqualStrings(rope_out[0..rope_len], static_out[0..static_len]);
}

fn expectStaticBackendInvariants(tb: *text_buffer.UnifiedTextBuffer) !void {
    switch (tb.backend) {
        .static => |*backend| {
            const line_count = backend.line_widths.items.len;
            const seg_count = backend.segments.items.len;

            try std.testing.expect(line_count >= 1);
            try std.testing.expectEqual(line_count, backend.line_starts.items.len);
            try std.testing.expectEqual(line_count, backend.line_seg_start.items.len);
            try std.testing.expectEqual(line_count, backend.line_seg_end.items.len);
            try std.testing.expect(backend.max_line_width <= backend.total_width);

            var prev_start: u32 = 0;
            for (backend.line_starts.items, 0..) |line_start, idx| {
                if (idx > 0) {
                    try std.testing.expect(line_start >= prev_start);
                }
                prev_start = line_start;

                const seg_start = backend.line_seg_start.items[idx];
                const seg_end = backend.line_seg_end.items[idx];
                try std.testing.expect(seg_start <= seg_end);
                try std.testing.expect(seg_end <= seg_count);
            }

            if (seg_count > 0) {
                try std.testing.expect(backend.segments.items[0].isLineStart());
            }
        },
        .rope => unreachable,
    }
}

// =============================================================================
// StaticTextBuffer Parity Tests
// =============================================================================
// These tests verify that StaticTextBuffer matches UnifiedTextBuffer behavior.
// Currently StaticTextBuffer is an alias for UnifiedTextBuffer, so these tests
// establish the baseline behavior. When we implement a dedicated StaticTextBuffer
// with flat storage, these tests ensure we maintain behavioral parity.

test "StaticTextBuffer - empty buffer has line count 1" {
    const pool = gp.initGlobalPool(std.testing.allocator);
    defer gp.deinitGlobalPool();

    var sb = try StaticTextBuffer.initWithBackend(std.testing.allocator, pool, .unicode, .static);
    defer sb.deinit();

    // Empty buffer should have exactly 1 empty line (linestart invariant)
    try std.testing.expectEqual(@as(u32, 1), sb.lineCount());
}

test "StaticTextBuffer - empty buffer has max width 0" {
    const pool = gp.initGlobalPool(std.testing.allocator);
    defer gp.deinitGlobalPool();

    var sb = try StaticTextBuffer.initWithBackend(std.testing.allocator, pool, .unicode, .static);
    defer sb.deinit();

    // Empty buffer should have max line width of 0
    try std.testing.expectEqual(@as(u32, 0), sb.maxLineWidth());
}

test "StaticTextBuffer - 'a\\n' yields line count 2" {
    const pool = gp.initGlobalPool(std.testing.allocator);
    defer gp.deinitGlobalPool();

    var sb = try StaticTextBuffer.initWithBackend(std.testing.allocator, pool, .unicode, .static);
    defer sb.deinit();

    try sb.setText("a\n");

    // "a\n" should create 2 lines: one with 'a', one empty after newline
    try std.testing.expectEqual(@as(u32, 2), sb.lineCount());
}

test "StaticTextBuffer - 'a\\n' line widths are [1, 0]" {
    const pool = gp.initGlobalPool(std.testing.allocator);
    defer gp.deinitGlobalPool();

    var sb = try StaticTextBuffer.initWithBackend(std.testing.allocator, pool, .unicode, .static);
    defer sb.deinit();

    try sb.setText("a\n");

    // Line 0 has 'a' (width 1), line 1 is empty (width 0)
    try std.testing.expectEqual(@as(u32, 1), sb.lineWidthAt(0));
    try std.testing.expectEqual(@as(u32, 0), sb.lineWidthAt(1));
}

test "StaticTextBuffer - textRange returns exact original bytes for multi-line input" {
    const pool = gp.initGlobalPool(std.testing.allocator);
    defer gp.deinitGlobalPool();

    var sb = try StaticTextBuffer.initWithBackend(std.testing.allocator, pool, .unicode, .static);
    defer sb.deinit();

    const text = "Line 1\nLine 2\nLine 3";
    try sb.setText(text);

    // Extract the entire text range
    var out_buffer: [100]u8 = undefined;
    const len = sb.getTextRange(0, @intCast(text.len), &out_buffer);

    try std.testing.expectEqual(@as(usize, text.len), len);
    try std.testing.expectEqualStrings(text, out_buffer[0..len]);
}

test "StaticTextBuffer - textRange returns exact bytes for Unicode content" {
    const pool = gp.initGlobalPool(std.testing.allocator);
    defer gp.deinitGlobalPool();

    var sb = try StaticTextBuffer.initWithBackend(std.testing.allocator, pool, .unicode, .static);
    defer sb.deinit();

    const text = "Hello 世界\n🌟 Test\nEnd";
    try sb.setText(text);

    // Extract the entire text range
    var out_buffer: [100]u8 = undefined;
    const len = sb.getTextRange(0, @intCast(text.len), &out_buffer);

    try std.testing.expectEqual(@as(usize, text.len), len);
    try std.testing.expectEqualStrings(text, out_buffer[0..len]);
}

test "StaticTextBuffer - textRange partial extraction" {
    const pool = gp.initGlobalPool(std.testing.allocator);
    defer gp.deinitGlobalPool();

    var sb = try StaticTextBuffer.initWithBackend(std.testing.allocator, pool, .unicode, .static);
    defer sb.deinit();

    const text = "Hello World";
    try sb.setText(text);

    // Extract "World" (chars 6-11)
    var out_buffer: [100]u8 = undefined;
    const len = sb.getTextRange(6, 11, &out_buffer);

    try std.testing.expectEqual(@as(usize, 5), len);
    try std.testing.expectEqualStrings("World", out_buffer[0..len]);
}

test "StaticTextBuffer - maxLineWidth with multiple lines" {
    const pool = gp.initGlobalPool(std.testing.allocator);
    defer gp.deinitGlobalPool();

    var sb = try StaticTextBuffer.initWithBackend(std.testing.allocator, pool, .unicode, .static);
    defer sb.deinit();

    // Different line lengths: 5, 10, 3
    try sb.setText("Short\nLonger lin\nEnd");

    const max_width = sb.maxLineWidth();
    // "Longer lin" has 10 chars, should be max
    try std.testing.expectEqual(@as(u32, 10), max_width);
}

test "StaticTextBuffer - lineWidthAt for various lines" {
    const pool = gp.initGlobalPool(std.testing.allocator);
    defer gp.deinitGlobalPool();

    var sb = try StaticTextBuffer.initWithBackend(std.testing.allocator, pool, .unicode, .static);
    defer sb.deinit();

    try sb.setText("AAA\nBBBBB\nCC");

    try std.testing.expectEqual(@as(u32, 3), sb.lineWidthAt(0)); // "AAA"
    try std.testing.expectEqual(@as(u32, 5), sb.lineWidthAt(1)); // "BBBBB"
    try std.testing.expectEqual(@as(u32, 2), sb.lineWidthAt(2)); // "CC"
}

test "StaticTextBuffer - consecutive newlines" {
    const pool = gp.initGlobalPool(std.testing.allocator);
    defer gp.deinitGlobalPool();

    var sb = try StaticTextBuffer.initWithBackend(std.testing.allocator, pool, .unicode, .static);
    defer sb.deinit();

    try sb.setText("A\n\nB");

    // Should have 3 lines: "A", "", "B"
    try std.testing.expectEqual(@as(u32, 3), sb.lineCount());
    try std.testing.expectEqual(@as(u32, 1), sb.lineWidthAt(0)); // "A"
    try std.testing.expectEqual(@as(u32, 0), sb.lineWidthAt(1)); // empty
    try std.testing.expectEqual(@as(u32, 1), sb.lineWidthAt(2)); // "B"
}

test "StaticTextBuffer - only newlines" {
    const pool = gp.initGlobalPool(std.testing.allocator);
    defer gp.deinitGlobalPool();

    var sb = try StaticTextBuffer.initWithBackend(std.testing.allocator, pool, .unicode, .static);
    defer sb.deinit();

    try sb.setText("\n\n\n");

    // Should have 4 lines, all empty
    try std.testing.expectEqual(@as(u32, 4), sb.lineCount());
    for (0..4) |i| {
        try std.testing.expectEqual(@as(u32, 0), sb.lineWidthAt(@intCast(i)));
    }
}

test "StaticTextBuffer - view registration works" {
    const pool = gp.initGlobalPool(std.testing.allocator);
    defer gp.deinitGlobalPool();

    var sb = try StaticTextBuffer.initWithBackend(std.testing.allocator, pool, .unicode, .static);
    defer sb.deinit();

    const view_id = try sb.registerView();
    defer sb.unregisterView(view_id);

    // New view should be dirty
    try std.testing.expect(sb.isViewDirty(view_id));

    sb.clearViewDirty(view_id);
    try std.testing.expect(!sb.isViewDirty(view_id));

    try sb.setText("Hello");
    try std.testing.expect(sb.isViewDirty(view_id));
}

test "StaticTextBuffer - content epoch increments on setText" {
    const pool = gp.initGlobalPool(std.testing.allocator);
    defer gp.deinitGlobalPool();

    var sb = try StaticTextBuffer.initWithBackend(std.testing.allocator, pool, .unicode, .static);
    defer sb.deinit();

    const epoch1 = sb.getContentEpoch();
    try sb.setText("First");
    const epoch2 = sb.getContentEpoch();
    try sb.setText("Second");
    const epoch3 = sb.getContentEpoch();

    try std.testing.expect(epoch2 > epoch1);
    try std.testing.expect(epoch3 > epoch2);
}

test "StaticTextBuffer - getPlainTextIntoBuffer round-trip" {
    const pool = gp.initGlobalPool(std.testing.allocator);
    defer gp.deinitGlobalPool();

    var sb = try StaticTextBuffer.initWithBackend(std.testing.allocator, pool, .unicode, .static);
    defer sb.deinit();

    const text = "First\nSecond\nThird";
    try sb.setText(text);

    var out_buffer: [100]u8 = undefined;
    const len = sb.getPlainTextIntoBuffer(&out_buffer);

    try std.testing.expectEqualStrings(text, out_buffer[0..len]);
}

test "StaticTextBuffer - defaults accessor" {
    const pool = gp.initGlobalPool(std.testing.allocator);
    defer gp.deinitGlobalPool();

    var sb = try StaticTextBuffer.initWithBackend(std.testing.allocator, pool, .unicode, .static);
    defer sb.deinit();

    sb.setDefaultFg(.{ 1.0, 0.0, 0.0, 1.0 });
    sb.setDefaultBg(.{ 0.0, 1.0, 0.0, 1.0 });

    const defs = sb.defaults();
    try std.testing.expect(defs.fg != null);
    try std.testing.expect(defs.bg != null);
    try std.testing.expectEqual(@as(f32, 1.0), defs.fg.?[0]);
    try std.testing.expectEqual(@as(f32, 1.0), defs.bg.?[1]);
}

test "StaticTextBuffer - memRegistry and allocator accessors" {
    const pool = gp.initGlobalPool(std.testing.allocator);
    defer gp.deinitGlobalPool();

    var sb = try StaticTextBuffer.initWithBackend(std.testing.allocator, pool, .unicode, .static);
    defer sb.deinit();

    // Just verify these don't crash
    const mem_reg = sb.memRegistry();
    _ = mem_reg; // Verify it returns a valid pointer

    const alloc = sb.allocator();
    _ = alloc; // Just verify it compiles
}

test "StaticTextBuffer - widthMethod and tabWidth accessors" {
    const pool = gp.initGlobalPool(std.testing.allocator);
    defer gp.deinitGlobalPool();

    var sb = try StaticTextBuffer.initWithBackend(std.testing.allocator, pool, .unicode, .static);
    defer sb.deinit();

    const wm = sb.widthMethod();
    try std.testing.expectEqual(@as(@TypeOf(wm), .unicode), wm);

    const tw = sb.tabWidth();
    try std.testing.expect(tw > 0);
}

test "backend parity - mixed CRLF LF tabs CJK and emoji" {
    const pool = gp.initGlobalPool(std.testing.allocator);
    defer gp.deinitGlobalPool();

    var rope_tb = try text_buffer.UnifiedTextBuffer.init(std.testing.allocator, pool, .unicode);
    defer rope_tb.deinit();

    var static_tb = try text_buffer.UnifiedTextBuffer.initWithBackend(std.testing.allocator, pool, .unicode, .static);
    defer static_tb.deinit();

    const input = "A\t世🌍\r\nB\tC\n👩‍🚀\tZ";
    rope_tb.setTabWidth(4);
    static_tb.setTabWidth(4);
    try rope_tb.setText(input);
    try static_tb.setText(input);

    try std.testing.expectEqual(rope_tb.lineCount(), static_tb.lineCount());

    var row: u32 = 0;
    while (row < rope_tb.lineCount()) : (row += 1) {
        try std.testing.expectEqual(rope_tb.lineWidthAt(row), static_tb.lineWidthAt(row));
    }

    var rope_plain: [256]u8 = undefined;
    var static_plain: [256]u8 = undefined;
    const rope_plain_len = rope_tb.getPlainTextIntoBuffer(&rope_plain);
    const static_plain_len = static_tb.getPlainTextIntoBuffer(&static_plain);
    try std.testing.expectEqual(rope_plain_len, static_plain_len);
    try std.testing.expectEqualStrings(rope_plain[0..rope_plain_len], static_plain[0..static_plain_len]);

    var rope_view = try TextBufferView.init(std.testing.allocator, rope_tb);
    defer rope_view.deinit();
    var static_view = try TextBufferView.init(std.testing.allocator, static_tb);
    defer static_view.deinit();

    rope_view.setWrapMode(.char);
    static_view.setWrapMode(.char);
    rope_view.setWrapWidth(6);
    static_view.setWrapWidth(6);

    try std.testing.expectEqual(rope_view.getVirtualLineCount(), static_view.getVirtualLineCount());

    const rope_info = rope_view.getCachedLineInfo();
    const static_info = static_view.getCachedLineInfo();
    try std.testing.expectEqual(rope_info.starts.len, static_info.starts.len);
    try std.testing.expectEqual(rope_info.widths.len, static_info.widths.len);

    for (rope_info.starts, 0..) |start, idx| {
        try std.testing.expectEqual(start, static_info.starts[idx]);
    }
    for (rope_info.widths, 0..) |width, idx| {
        try std.testing.expectEqual(width, static_info.widths[idx]);
    }

    _ = rope_view.setLocalSelection(1, 0, 3, 2, null, null);
    _ = static_view.setLocalSelection(1, 0, 3, 2, null, null);

    var rope_sel: [256]u8 = undefined;
    var static_sel: [256]u8 = undefined;
    const rope_sel_len = rope_view.getSelectedTextIntoBuffer(&rope_sel);
    const static_sel_len = static_view.getSelectedTextIntoBuffer(&static_sel);

    try std.testing.expectEqual(rope_sel_len, static_sel_len);
    try std.testing.expectEqualStrings(rope_sel[0..rope_sel_len], static_sel[0..static_sel_len]);
}

test "StaticBackend - reuses line-break scratch allocation across repeated setTextFromMemId" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing_allocator.allocator();

    var backend = try StaticBackend.init(allocator, .unicode);
    defer backend.deinit(allocator);

    var mem_registry = MemRegistry.init(allocator);
    defer mem_registry.deinit();

    const text =
        "line 01\nline 02\nline 03\nline 04\nline 05\nline 06\nline 07\nline 08\nline 09\nline 10\n" ++
        "line 11\nline 12\nline 13\nline 14\nline 15\nline 16\nline 17\nline 18\nline 19\nline 20\n";
    const mem_id = try mem_registry.register(text, false);

    try backend.setTextFromMemId(&mem_registry, mem_id);
    const alloc_after_first_set = failing_allocator.alloc_index;

    try backend.setTextFromMemId(&mem_registry, mem_id);
    const alloc_after_second_set = failing_allocator.alloc_index;

    try std.testing.expectEqual(alloc_after_first_set, alloc_after_second_set);
}

test "StaticTextBuffer - setText OOM preserves previous content and index invariants" {
    const initial_text = "stable\ncontent\nfor baseline";
    const target_text = "line 1\nline 2 with tab\tA\nline 3\nline 4\nline 5 with emoji 🌍\nline 6";

    const allocation_window = blk: {
        var counting_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const allocator = counting_allocator.allocator();

        const pool = gp.initGlobalPool(allocator);
        defer gp.deinitGlobalPool();

        var sb_count = try StaticTextBuffer.initWithBackend(allocator, pool, .unicode, .static);
        defer sb_count.deinit();

        try sb_count.setText(initial_text);
        const before_target = counting_allocator.alloc_index;
        try sb_count.setText(target_text);
        const after_target = counting_allocator.alloc_index;

        try std.testing.expect(after_target > before_target);
        break :blk .{ .before = before_target, .after = after_target };
    };

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = allocation_window.after - 1,
    });

    {
        const allocator = failing_allocator.allocator();
        const pool = gp.initGlobalPool(allocator);
        defer gp.deinitGlobalPool();

        var sb = try StaticTextBuffer.initWithBackend(allocator, pool, .unicode, .static);
        defer sb.deinit();

        try sb.setText(initial_text);

        var before_buf: [128]u8 = undefined;
        const before_len = sb.getPlainTextIntoBuffer(&before_buf);

        try std.testing.expectError(text_buffer.TextBufferError.OutOfMemory, sb.setText(target_text));
        try std.testing.expect(failing_allocator.has_induced_failure);

        try expectStaticBackendInvariants(sb);

        var after_buf: [128]u8 = undefined;
        const after_len = sb.getPlainTextIntoBuffer(&after_buf);
        try std.testing.expectEqual(before_len, after_len);
        try std.testing.expectEqualStrings(before_buf[0..before_len], after_buf[0..after_len]);

        var range_buf: [64]u8 = undefined;
        const range_len = sb.getTextRange(0, 6, &range_buf);
        try std.testing.expectEqualStrings("stable", range_buf[0..range_len]);
    }

    try std.testing.expectEqual(failing_allocator.allocated_bytes, failing_allocator.freed_bytes);
}
