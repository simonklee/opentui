const std = @import("std");
const text_buffer = @import("../text-buffer.zig");
const gp = @import("../grapheme.zig");

const StaticTextBuffer = text_buffer.TextBuffer;

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

    var sb = try StaticTextBuffer.init(std.testing.allocator, pool, .unicode, .static);
    defer sb.deinit();

    // Empty buffer should have exactly 1 empty line (linestart invariant)
    try std.testing.expectEqual(@as(u32, 1), sb.lineCount());
}

test "StaticTextBuffer - empty buffer has max width 0" {
    const pool = gp.initGlobalPool(std.testing.allocator);
    defer gp.deinitGlobalPool();

    var sb = try StaticTextBuffer.init(std.testing.allocator, pool, .unicode, .static);
    defer sb.deinit();

    // Empty buffer should have max line width of 0
    try std.testing.expectEqual(@as(u32, 0), sb.maxLineWidth());
}

test "StaticTextBuffer - 'a\\n' yields line count 2" {
    const pool = gp.initGlobalPool(std.testing.allocator);
    defer gp.deinitGlobalPool();

    var sb = try StaticTextBuffer.init(std.testing.allocator, pool, .unicode, .static);
    defer sb.deinit();

    try sb.setText("a\n");

    // "a\n" should create 2 lines: one with 'a', one empty after newline
    try std.testing.expectEqual(@as(u32, 2), sb.lineCount());
}

test "StaticTextBuffer - 'a\\n' line widths are [1, 0]" {
    const pool = gp.initGlobalPool(std.testing.allocator);
    defer gp.deinitGlobalPool();

    var sb = try StaticTextBuffer.init(std.testing.allocator, pool, .unicode, .static);
    defer sb.deinit();

    try sb.setText("a\n");

    // Line 0 has 'a' (width 1), line 1 is empty (width 0)
    try std.testing.expectEqual(@as(u32, 1), sb.lineWidthAt(0));
    try std.testing.expectEqual(@as(u32, 0), sb.lineWidthAt(1));
}

test "StaticTextBuffer - textRange returns exact original bytes for multi-line input" {
    const pool = gp.initGlobalPool(std.testing.allocator);
    defer gp.deinitGlobalPool();

    var sb = try StaticTextBuffer.init(std.testing.allocator, pool, .unicode, .static);
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

    var sb = try StaticTextBuffer.init(std.testing.allocator, pool, .unicode, .static);
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

    var sb = try StaticTextBuffer.init(std.testing.allocator, pool, .unicode, .static);
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

    var sb = try StaticTextBuffer.init(std.testing.allocator, pool, .unicode, .static);
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

    var sb = try StaticTextBuffer.init(std.testing.allocator, pool, .unicode, .static);
    defer sb.deinit();

    try sb.setText("AAA\nBBBBB\nCC");

    try std.testing.expectEqual(@as(u32, 3), sb.lineWidthAt(0)); // "AAA"
    try std.testing.expectEqual(@as(u32, 5), sb.lineWidthAt(1)); // "BBBBB"
    try std.testing.expectEqual(@as(u32, 2), sb.lineWidthAt(2)); // "CC"
}

test "StaticTextBuffer - consecutive newlines" {
    const pool = gp.initGlobalPool(std.testing.allocator);
    defer gp.deinitGlobalPool();

    var sb = try StaticTextBuffer.init(std.testing.allocator, pool, .unicode, .static);
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

    var sb = try StaticTextBuffer.init(std.testing.allocator, pool, .unicode, .static);
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

    var sb = try StaticTextBuffer.init(std.testing.allocator, pool, .unicode, .static);
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

    var sb = try StaticTextBuffer.init(std.testing.allocator, pool, .unicode, .static);
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

    var sb = try StaticTextBuffer.init(std.testing.allocator, pool, .unicode, .static);
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

    var sb = try StaticTextBuffer.init(std.testing.allocator, pool, .unicode, .static);
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

    var sb = try StaticTextBuffer.init(std.testing.allocator, pool, .unicode, .static);
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

    var sb = try StaticTextBuffer.init(std.testing.allocator, pool, .unicode, .static);
    defer sb.deinit();

    const wm = sb.widthMethod();
    try std.testing.expectEqual(@as(@TypeOf(wm), .unicode), wm);

    const tw = sb.tabWidth();
    try std.testing.expect(tw > 0);
}
