const std = @import("std");
const Allocator = std.mem.Allocator;
const seg_mod = @import("text-buffer-segment.zig");

const Highlight = seg_mod.Highlight;
const StyleSpan = seg_mod.StyleSpan;
const TextBufferError = seg_mod.TextBufferError;

pub const LineWidthFn = *const fn (ctx: *anyopaque, line_idx: usize) u32;

pub const HighlightRegistry = struct {
    allocator: Allocator,
    line_highlights: std.ArrayListUnmanaged(std.ArrayListUnmanaged(Highlight)) = .{},
    line_spans: std.ArrayListUnmanaged(std.ArrayListUnmanaged(StyleSpan)) = .{},
    highlight_batch_depth: u32 = 0,
    dirty_span_lines: std.AutoHashMap(usize, void),

    pub fn init(allocator: Allocator) HighlightRegistry {
        return .{
            .allocator = allocator,
            .line_highlights = .{},
            .line_spans = .{},
            .highlight_batch_depth = 0,
            .dirty_span_lines = std.AutoHashMap(usize, void).init(allocator),
        };
    }

    pub fn deinit(self: *HighlightRegistry) void {
        self.clearRetainingCapacity();
        self.line_highlights.deinit(self.allocator);
        self.line_spans.deinit(self.allocator);
        self.dirty_span_lines.deinit();
    }

    pub fn clearRetainingCapacity(self: *HighlightRegistry) void {
        for (self.line_highlights.items) |*hl_list| {
            hl_list.deinit(self.allocator);
        }
        self.line_highlights.clearRetainingCapacity();

        for (self.line_spans.items) |*span_list| {
            span_list.deinit(self.allocator);
        }
        self.line_spans.clearRetainingCapacity();

        self.dirty_span_lines.clearRetainingCapacity();
        self.highlight_batch_depth = 0;
    }

    pub fn clearAllHighlights(self: *HighlightRegistry) void {
        for (self.line_highlights.items) |*hl_list| {
            hl_list.clearRetainingCapacity();
        }
        for (self.line_spans.items) |*span_list| {
            span_list.clearRetainingCapacity();
        }
    }

    pub fn clearLineHighlights(self: *HighlightRegistry, line_idx: usize) void {
        if (line_idx < self.line_highlights.items.len) {
            self.line_highlights.items[line_idx].clearRetainingCapacity();
        }
        if (line_idx < self.line_spans.items.len) {
            self.line_spans.items[line_idx].clearRetainingCapacity();
        }
    }

    pub fn ensureLineStorage(self: *HighlightRegistry, line_idx: usize) TextBufferError!void {
        while (self.line_highlights.items.len <= line_idx) {
            try self.line_highlights.append(self.allocator, .{});
        }
        while (self.line_spans.items.len <= line_idx) {
            try self.line_spans.append(self.allocator, .{});
        }
    }

    pub fn startTransaction(self: *HighlightRegistry) void {
        self.highlight_batch_depth += 1;
    }

    pub fn endTransaction(self: *HighlightRegistry, ctx: *anyopaque, line_width_fn: LineWidthFn) void {
        if (self.highlight_batch_depth == 0) return;
        self.highlight_batch_depth -= 1;
        if (self.highlight_batch_depth == 0) {
            var it = self.dirty_span_lines.keyIterator();
            while (it.next()) |line_idx| {
                self.rebuildLineSpans(ctx, line_width_fn, line_idx.*) catch {};
            }
            self.dirty_span_lines.clearRetainingCapacity();
        }
    }

    pub fn addHighlight(
        self: *HighlightRegistry,
        ctx: *anyopaque,
        line_width_fn: LineWidthFn,
        line_idx: usize,
        hl: Highlight,
    ) TextBufferError!void {
        try self.ensureLineStorage(line_idx);
        try self.line_highlights.items[line_idx].append(self.allocator, hl);

        if (self.highlight_batch_depth == 0) {
            try self.rebuildLineSpans(ctx, line_width_fn, line_idx);
        } else {
            self.markLineSpansDirty(line_idx);
        }
    }

    pub fn getLineHighlights(self: *const HighlightRegistry, line_idx: usize) []const Highlight {
        if (line_idx < self.line_highlights.items.len) {
            return self.line_highlights.items[line_idx].items;
        }
        return &[_]Highlight{};
    }

    pub fn getLineSpans(
        self: *HighlightRegistry,
        ctx: *anyopaque,
        line_width_fn: LineWidthFn,
        line_idx: usize,
    ) []const StyleSpan {
        if (line_idx < self.line_spans.items.len) {
            if (self.dirty_span_lines.contains(line_idx) and self.highlight_batch_depth == 0) {
                self.rebuildLineSpans(ctx, line_width_fn, line_idx) catch {};
                _ = self.dirty_span_lines.remove(line_idx);
            }
            return self.line_spans.items[line_idx].items;
        }
        return &[_]StyleSpan{};
    }

    pub fn getHighlightCount(self: *const HighlightRegistry) u32 {
        var count: u32 = 0;
        for (self.line_highlights.items) |hl_list| {
            count += @intCast(hl_list.items.len);
        }
        return count;
    }

    pub fn removeHighlightsByRef(
        self: *HighlightRegistry,
        ctx: *anyopaque,
        line_width_fn: LineWidthFn,
        hl_ref: u16,
    ) void {
        for (self.line_highlights.items, 0..) |*hl_list, line_idx| {
            var i: usize = 0;
            var changed = false;
            while (i < hl_list.items.len) {
                if (hl_list.items[i].hl_ref == hl_ref) {
                    _ = hl_list.orderedRemove(i);
                    changed = true;
                    continue;
                }
                i += 1;
            }
            if (changed) {
                if (self.highlight_batch_depth == 0) {
                    self.rebuildLineSpans(ctx, line_width_fn, line_idx) catch {};
                } else {
                    self.markLineSpansDirty(line_idx);
                }
            }
        }
    }

    fn markLineSpansDirty(self: *HighlightRegistry, line_idx: usize) void {
        self.dirty_span_lines.put(line_idx, {}) catch {};
    }

    fn rebuildLineSpans(
        self: *HighlightRegistry,
        ctx: *anyopaque,
        line_width_fn: LineWidthFn,
        line_idx: usize,
    ) TextBufferError!void {
        if (line_idx >= self.line_spans.items.len) {
            return TextBufferError.InvalidIndex;
        }

        self.line_spans.items[line_idx].clearRetainingCapacity();

        if (line_idx >= self.line_highlights.items.len or self.line_highlights.items[line_idx].items.len == 0) {
            return;
        }

        const highlights = self.line_highlights.items[line_idx].items;

        // Collect all boundary columns
        const Event = struct {
            col: u32,
            is_start: bool,
            hl_idx: usize,
        };

        var events: std.ArrayListUnmanaged(Event) = .{};
        defer events.deinit(self.allocator);

        for (highlights, 0..) |hl, idx| {
            try events.append(self.allocator, .{ .col = hl.col_start, .is_start = true, .hl_idx = idx });
            try events.append(self.allocator, .{ .col = hl.col_end, .is_start = false, .hl_idx = idx });
        }

        // Sort by column, ends before starts at same position
        const sortFn = struct {
            fn lessThan(_: void, a: Event, b: Event) bool {
                if (a.col != b.col) return a.col < b.col;
                if (a.is_start != b.is_start) return !a.is_start;
                return a.hl_idx < b.hl_idx;
            }
        }.lessThan;
        std.mem.sort(Event, events.items, {}, sortFn);

        // Build spans by tracking active highlights
        var active = std.AutoHashMap(usize, void).init(self.allocator);
        defer active.deinit();

        var current_col: u32 = 0;

        for (events.items) |event| {
            var current_priority: i16 = -1;
            var current_style: u32 = 0;
            var it = active.keyIterator();
            while (it.next()) |hl_idx| {
                const hl = highlights[hl_idx.*];
                if (hl.priority > current_priority) {
                    current_priority = @intCast(hl.priority);
                    current_style = hl.style_id;
                }
            }

            // Emit span for the segment leading up to this event
            if (event.col > current_col) {
                try self.line_spans.items[line_idx].append(self.allocator, StyleSpan{
                    .col = current_col,
                    .style_id = current_style,
                    .next_col = event.col,
                });
                current_col = event.col;
            }

            if (event.is_start) {
                try active.put(event.hl_idx, {});
            } else {
                _ = active.remove(event.hl_idx);
            }
        }

        // Emit final span after last event if there were any highlights
        // This ensures the line returns to default styling after the last highlight ends
        if (events.items.len > 0 and active.count() == 0) {
            const line_width = line_width_fn(ctx, line_idx);
            if (current_col < line_width) {
                try self.line_spans.items[line_idx].append(self.allocator, StyleSpan{
                    .col = current_col,
                    .style_id = 0,
                    .next_col = line_width,
                });
            }
        }
    }
};
